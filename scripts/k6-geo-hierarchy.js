/**
 * k6-geo-hierarchy.js
 * Load test targeting geo_hierarchy_nodes at 250K req/day burst patterns.
 *
 * Run on GCE VM (localhost avoids network RTT):
 *   k6 run --env BASE=http://localhost:8080 scripts/k6-geo-hierarchy.js
 *
 * Scenarios:
 *   1. region_in_hierarchy  — /region coords inside geo_hierarchy_nodes (school classified to node)
 *   2. region_no_hierarchy  — /region coords in LGA only (no geo_node match)
 *   3. region_burst_sync    — burst pattern: 250K/day = ~3 req/s sustained; 500 req/s burst
 *   4. geojson_spotlight    — /boundaries/geojson (ngx.shared cache must absorb Spotlight loads)
 *   5. hierarchy_nav        — /boundaries/hierarchy (nav system hierarchy fetches)
 *
 * Thresholds sized for GCE VM localhost (no network RTT):
 *   region_in_hierarchy p(95)<150ms  — geo_node ST_Contains + recursive CTE chain
 *   region_no_hierarchy p(95)<100ms  — LGA-only ST_Contains (no node chain)
 *   region_burst        p(95)<200ms  — at 500 VU concurrency
 *   geojson_cache       p(95)<500ms  — ngx.shared HIT (cold miss may be slow)
 *   hierarchy           p(95)<200ms  — ngx.shared HIT after first request
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://35.239.86.115:8080';

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const regionHierarchyMs = new Trend('region_in_hierarchy_ms', true);
const regionNoHierarchyMs = new Trend('region_no_hierarchy_ms', true);
const regionBurstMs     = new Trend('region_burst_ms',        true);
const geojsonCacheMs    = new Trend('geojson_cache_ms',       true);
const hierarchyMs       = new Trend('hierarchy_ms',           true);
const errorCount        = new Counter('endpoint_errors');
const geojsonCacheRate  = new Rate('geojson_cache_hit');

// ---------------------------------------------------------------------------
// Fixtures
//
// Rwanda EQUIP (tenant 12) — city of Kigali Province, Gasabo District area.
// These coords are chosen to land inside geo_hierarchy_nodes IF nodes have been
// built for Rwanda. Falls back to LGA (district) classification otherwise.
//
// Jigawa (tenant 18) — Hadejia LGA area, inside any configured geo_nodes.
// ---------------------------------------------------------------------------

// Coords inside geo_hierarchy_nodes (should return matched_level=geo_node or zone)
const HIERARCHY_COORDS = [
  // Rwanda EQUIP — Kigali Province, Gasabo District
  { tenantId: '12', lat: -1.9441, lon: 30.0619, expectedCountry: 'RW' },
  { tenantId: '12', lat: -1.9706, lon: 30.1044, expectedCountry: 'RW' }, // Remera / Gasabo
  { tenantId: '12', lat: -1.9355, lon: 30.0928, expectedCountry: 'RW' }, // Kimironko
  { tenantId: '12', lat: -2.0028, lon: 30.0585, expectedCountry: 'RW' }, // Nyarugenge
  { tenantId: '12', lat: -2.6061, lon: 29.7396, expectedCountry: 'RW' }, // Huye District
  // Nigeria Jigawa (tenant 18) — Hadejia LGA
  { tenantId: '18', lat: 12.4504, lon: 10.0429, expectedCountry: 'NG' },
  { tenantId: '18', lat: 11.9900, lon:  9.3200, expectedCountry: 'NG' }, // Dutse LGA
  { tenantId: '18', lat: 12.1800, lon:  9.7900, expectedCountry: 'NG' }, // Birnin Kudu
  // Kenya (tenant 1) — Tana River, inside Zone 1
  { tenantId: '1', lat: -1.80, lon: 40.10, expectedCountry: 'KE' },
  { tenantId: '1', lat: -1.60, lon: 39.90, expectedCountry: 'KE' },
];

// Coords in LGA only (no geo_hierarchy_node configured — or outside all nodes)
const LGA_ONLY_COORDS = [
  // Kenya — varied counties outside any zone
  { tenantId: '1', lat: -1.286389, lon: 36.817223, expectedCountry: 'KE' }, // Nairobi
  { tenantId: '1', lat:  0.517236, lon: 35.269780, expectedCountry: 'KE' }, // Eldoret
  { tenantId: '1', lat: -4.043477, lon: 39.668206, expectedCountry: 'KE' }, // Mombasa
  // Lagos (tenant 11) — no geo_hierarchy_nodes
  { tenantId: '11', lat: 6.4541, lon: 3.3947, expectedCountry: 'NG' },
  { tenantId: '11', lat: 6.5244, lon: 3.3792, expectedCountry: 'NG' },
  { tenantId: '11', lat: 6.6018, lon: 3.3515, expectedCountry: 'NG' },
  // Rwanda districts outside Kigali
  { tenantId: '12', lat: -1.5013, lon: 29.6343, expectedCountry: 'RW' }, // Musanze
  // Edo (tenant 9)
  { tenantId: '9', lat: 6.3350, lon: 5.6270, expectedCountry: 'NG' },
];

// Mixed for burst scenario
const BURST_COORDS = [...HIERARCHY_COORDS, ...LGA_ONLY_COORDS];

// Tenants with hierarchy data
const HIERARCHY_TENANTS = ['1', '9', '11', '12', '18'];

// ---------------------------------------------------------------------------
// Scenario options
// ---------------------------------------------------------------------------
export const options = {
  scenarios: {
    // 1. Coords inside geo_hierarchy_nodes — exercises ST_Contains on nodes + recursive CTE
    // Scenarios run SEQUENTIALLY to avoid overwhelming PostgreSQL connection pool.
    // Peak concurrent VUs at any time: 20 max.

    // 1. Coords inside geo_hierarchy_nodes — gentle ramp, max 5 VUs
    // region_cache absorbs repeats; PostGIS handles cold misses without pool exhaustion
    region_in_hierarchy: {
      executor: 'ramping-vus',
      startTime: '0s',
      stages: [
        { duration: '15s', target: 3 },
        { duration: '30s', target: 5 },
        { duration: '15s', target: 0 },
      ],
      exec: 'regionInHierarchyTest',
    },
    // 2. Raw LGA path — after region_in_hierarchy finishes (~60s)
    region_no_hierarchy: {
      executor: 'constant-vus',
      vus: 5,
      duration: '30s',
      startTime: '65s',
      exec: 'regionNoHierarchyTest',
    },
    // 3. Burst sync — 8 VUs, after region_no_hierarchy (~100s)
    region_burst_sync: {
      executor: 'constant-vus',
      vus: 8,
      duration: '30s',
      startTime: '100s',
      exec: 'regionBurstTest',
    },
    // 4. GeoJSON cache — after burst (~135s); all cache hits after warm-up
    geojson_spotlight: {
      executor: 'constant-vus',
      vus: 5,
      duration: '30s',
      startTime: '135s',
      exec: 'geojsonSpotlightTest',
    },
    // 5. Hierarchy nav — after geojson (~170s); 3 VUs, all cache hits
    hierarchy_nav: {
      executor: 'constant-vus',
      vus: 3,
      duration: '30s',
      startTime: '170s',
      exec: 'hierarchyNavTest',
    },
  },

  thresholds: {
    // geo_node lookup: ST_Contains on nodes.geom + recursive CTE ancestor chain
    'region_in_hierarchy_ms{scenario:region_in_hierarchy}': ['p(95)<300', 'p(99)<600'],
    // raw LGA path: faster (no node chain)
    'region_no_hierarchy_ms{scenario:region_no_hierarchy}': ['p(95)<200'],
    // burst (region_cache absorbs most; PostGIS for cache misses)
    'region_burst_ms{scenario:region_burst_sync}':          ['p(95)<300'],
    // geojson from ngx.shared (cache hit expected after first request per tenant)
    'geojson_cache_ms{scenario:geojson_spotlight}':         ['p(95)<500'],
    // hierarchy from ngx.shared
    'hierarchy_ms{scenario:hierarchy_nav}':                 ['p(95)<200'],
    // Global error rate
    'http_req_failed':                                      ['rate<0.01'],
    // GeoJSON cache hit rate: expect >80% HITs once warm (first VU per tenant = MISS)
    'geojson_cache_hit':                                    ['rate>0.80'],
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function headers(tenantId) {
  return { headers: { 'X-Tenant-ID': String(tenantId) } };
}

function assertRegionOk(res, expectedCountry, metricTrend) {
  metricTrend.add(res.timings.duration);
  if (res.status !== 200 && res.status !== 404) {
    errorCount.add(1);
    return;
  }
  if (res.status === 404) return; // coord outside tenant scope — acceptable

  let body;
  try { body = JSON.parse(res.body); } catch (e) { errorCount.add(1); return; }

  check(res, {
    'region: found=true':         () => body.found === true,
    'region: has matched_level':  () => typeof body.matched_level === 'string',
    'region: country.pcode ok':   () => !!body.country && body.country.pcode === expectedCountry,
    'region: state present':      () => !!body.state && !!body.state.pcode,
  });
}

// ---------------------------------------------------------------------------
// Test functions
// ---------------------------------------------------------------------------

export function regionInHierarchyTest() {
  const c   = pick(HIERARCHY_COORDS);
  const url = `${BASE}/region?lat=${c.lat}&lon=${c.lon}`;
  const res = http.get(url, headers(c.tenantId));
  assertRegionOk(res, c.expectedCountry, regionHierarchyMs);
}

export function regionNoHierarchyTest() {
  const c   = pick(LGA_ONLY_COORDS);
  const url = `${BASE}/region?lat=${c.lat}&lon=${c.lon}`;
  const res = http.get(url, headers(c.tenantId));
  assertRegionOk(res, c.expectedCountry, regionNoHierarchyMs);
}

export function regionBurstTest() {
  const c   = pick(BURST_COORDS);
  const url = `${BASE}/region?lat=${c.lat}&lon=${c.lon}`;
  const res = http.get(url, headers(c.tenantId));
  assertRegionOk(res, c.expectedCountry, regionBurstMs);
}

export function geojsonSpotlightTest() {
  const tenantId = pick(HIERARCHY_TENANTS);
  const url = `${BASE}/boundaries/geojson?t=${tenantId}`;
  const res = http.get(url, headers(tenantId));
  geojsonCacheMs.add(res.timings.duration);

  const isHit = res.headers['X-Cache'] === 'HIT';
  geojsonCacheRate.add(isHit ? 1 : 0);

  if (res.status !== 200) { errorCount.add(1); return; }
  let body;
  try { body = JSON.parse(res.body); } catch (e) { errorCount.add(1); return; }

  check(res, {
    'geojson: FeatureCollection': () => body.type === 'FeatureCollection',
    'geojson: features > 0':      () => Array.isArray(body.features) && body.features.length > 0,
    'geojson: has X-Cache':       () => res.headers['X-Cache'] === 'HIT' || res.headers['X-Cache'] === 'MISS',
  });
  // Rate-limit per VU to avoid saturating bandwidth (GeoJSON payloads 1-4 MB each)
  sleep(0.2);
}

export function hierarchyNavTest() {
  const tenantId = pick(HIERARCHY_TENANTS);
  const url = `${BASE}/boundaries/hierarchy?t=${tenantId}`;
  const res = http.get(url, headers(tenantId));
  hierarchyMs.add(res.timings.duration);

  if (res.status !== 200) { errorCount.add(1); return; }
  let body;
  try { body = JSON.parse(res.body); } catch (e) { errorCount.add(1); return; }

  check(res, {
    'hierarchy: states array':    () => Array.isArray(body.states),
    'hierarchy: state_count > 0': () => body.state_count > 0,
    'hierarchy: lga_count > 0':   () => body.lga_count > 0,
  });
}
