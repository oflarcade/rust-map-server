/**
 * k6-all-endpoints.js
 * Comprehensive load test for all FE-consumed map server endpoints.
 *
 * Run on GCE VM (localhost avoids network RTT):
 *   k6 run --env BASE=http://localhost:8080 scripts/k6-all-endpoints.js
 *
 * Scenarios:
 *   1. region_lga      — /region hits that resolve to raw LGA (varied coords)
 *   2. region_cache    — /region same coord repeated to verify ngx.shared hits
 *   3. region_zone     — /region hits inside custom zone boundary
 *   4. geo_node_region — /region hits inside geo_hierarchy_nodes (node chain lookup)
 *   5. hierarchy       — /boundaries/hierarchy (ngx.shared cached per tenant)
 *   6. geojson         — /boundaries/geojson (ngx.shared.geojson_cache; verify X-Cache)
 *   7. search          — /boundaries/search?q=<term> (indexed LIKE)
 *   8. tiles           — /tiles/{z}/{x}/{y} (Martin PMTiles)
 *   9. multi_tenant    — rotate all tenants on /region to catch cross-tenant bleed
 *
 * Response shape verified for /region:
 *   {
 *     found: true, matched_level: "lga"|"zone",
 *     country: { pcode, name },
 *     state:   { pcode, name },
 *     zone?:   { pcode, name, color },   // only when matched_level === "zone"
 *     lga?:    { pcode, name }
 *   }
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://35.239.86.115:8080';

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const regionLgaLatency   = new Trend('region_lga_ms',    true);
const regionZoneLatency  = new Trend('region_zone_ms',   true);
const regionCacheLatency = new Trend('region_cache_ms',  true);
const regionGeoNodeMs    = new Trend('region_geo_node_ms', true);
const hierarchyLatency   = new Trend('hierarchy_ms',     true);
const geojsonLatency     = new Trend('geojson_ms',       true);
const searchLatency      = new Trend('search_ms',        true);
const tileLatency        = new Trend('tile_ms',          true);
const errorCount         = new Counter('endpoint_errors');
const wrongTenantRate    = new Rate('wrong_tenant_response');
const geojsonCacheHitRate = new Rate('geojson_cache_hit');

// ---------------------------------------------------------------------------
// Tenant fixtures — each entry is self-contained (coords belong to that tenant)
// ---------------------------------------------------------------------------
const TENANTS = [
  {
    id: '1', name: 'Kenya', expectedCountry: 'KE',
    coords: [
      { lat: -1.286389, lon: 36.817223 }, // Nairobi
      { lat: -4.043477, lon: 39.668206 }, // Mombasa
      { lat:  0.517236, lon: 35.269780 }, // Eldoret
      { lat: -0.091702, lon: 34.767956 }, // Kisumu
      { lat:  0.283333, lon: 37.450000 }, // Meru
    ],
    // Tana River — inside Zone 1 (constituent LGAs include Garsen, Galole)
    zoneCoords: [
      { lat: -1.80, lon: 40.10 }, // Garsen LGA
      { lat: -1.60, lon: 39.90 }, // Galole LGA
    ],
    // searchTerm known to exist for this tenant
    searchTerm: 'nairo',
    tile: { z: 8, x: 152, y: 130 },
  },
  {
    id: '11', name: 'Lagos', expectedCountry: 'NG',
    coords: [
      { lat: 6.4541, lon: 3.3947 }, // Lagos Island
      { lat: 6.5244, lon: 3.3792 }, // Mainland
      { lat: 6.6018, lon: 3.3515 }, // Agege
      { lat: 6.4698, lon: 3.5852 }, // Ikorodu
      { lat: 6.3350, lon: 3.3141 }, // Badagry
    ],
    zoneCoords: [],
    searchTerm: 'lagos',
    tile: { z: 10, x: 611, y: 516 },
  },
  {
    id: '12', name: 'Rwanda', expectedCountry: 'RW',
    coords: [
      { lat: -1.9441, lon: 30.0619 }, // Kigali
      { lat: -2.6061, lon: 29.7396 }, // Butare / Huye district
      { lat: -1.5013, lon: 29.6343 }, // Musanze
    ],
    zoneCoords: [],
    searchTerm: 'kigali',
    tile: { z: 9, x: 306, y: 248 },
  },
  {
    id: '9', name: 'Edo', expectedCountry: 'NG',
    coords: [
      { lat: 6.3350, lon: 5.6270 }, // Oredo LGA (Benin City area)
      { lat: 6.6200, lon: 5.9600 }, // Esan area
    ],
    zoneCoords: [],
    searchTerm: 'esan',  // matches multiple Esan LGAs in Edo scope
    tile: { z: 10, x: 588, y: 517 },
  },
];

// Fixed coord for cache warmup/hit test — must be a valid point for tenant 11
const CACHE_HIT = { tenantId: '11', lat: 6.4541, lon: 3.3947 };

// Coords inside geo_hierarchy_nodes for geo_node_region scenario (p(95)<150ms target)
const GEO_NODE_COORDS = [
  { tenantId: '12', lat: -1.9441, lon: 30.0619, expectedCountry: 'RW' }, // Kigali/Gasabo
  { tenantId: '12', lat: -1.9706, lon: 30.1044, expectedCountry: 'RW' }, // Remera
  { tenantId: '12', lat: -2.0028, lon: 30.0585, expectedCountry: 'RW' }, // Nyarugenge
  { tenantId: '12', lat: -2.6061, lon: 29.7396, expectedCountry: 'RW' }, // Huye
  { tenantId: '18', lat: 12.4504, lon: 10.0429, expectedCountry: 'NG' }, // Jigawa/Hadejia
  { tenantId: '18', lat: 11.9900, lon:  9.3200, expectedCountry: 'NG' }, // Dutse
  { tenantId: '1',  lat: -1.80,   lon: 40.10,   expectedCountry: 'KE' }, // Kenya Zone 1
  { tenantId: '1',  lat: -1.60,   lon: 39.90,   expectedCountry: 'KE' }, // Kenya Zone 1
];

// ---------------------------------------------------------------------------
// Scenario options
// ---------------------------------------------------------------------------
export const options = {
  scenarios: {
    // 1. Region LGA — varied coords, multiple tenants, ramp up to stress
    region_lga: {
      executor: 'ramping-vus',
      startTime: '0s',
      stages: [
        { duration: '15s', target: 30  },
        { duration: '30s', target: 150 },
        { duration: '30s', target: 300 },
        { duration: '15s', target: 0   },
      ],
      exec: 'regionLgaTest',
    },
    // 2. Cache hit test — same coord hammered at concurrency after region_lga warms it
    region_cache: {
      executor: 'constant-vus',
      vus: 50,
      duration: '30s',
      startTime: '20s',
      exec: 'regionCacheTest',
    },
    // 3. Zone hit — coords inside known custom zone boundaries
    region_zone: {
      executor: 'constant-vus',
      vus: 20,
      duration: '30s',
      startTime: '20s',
      exec: 'regionZoneTest',
    },
    // 4. Geo node region — /region coords inside geo_hierarchy_nodes (node chain + CTE)
    geo_node_region: {
      executor: 'constant-vus',
      vus: 100,
      duration: '60s',
      startTime: '10s',
      exec: 'geoNodeRegionTest',
    },
    // 5. Hierarchy — should be fast after first ngx.shared cache population
    hierarchy: {
      executor: 'constant-vus',
      vus: 30,
      duration: '40s',
      startTime: '10s',
      exec: 'hierarchyTest',
    },
    // 6. GeoJSON — ngx.shared.geojson_cache; verify X-Cache: HIT after cold miss
    geojson: {
      executor: 'constant-vus',
      vus: 10,
      duration: '40s',
      startTime: '10s',
      exec: 'geojsonTest',
    },
    // 7. Search — PostGIS indexed LIKE
    search: {
      executor: 'ramping-vus',
      startTime: '20s',
      stages: [
        { duration: '20s', target: 30 },
        { duration: '20s', target: 60 },
        { duration: '10s', target: 0  },
      ],
      exec: 'searchTest',
    },
    // 8. Tiles — Martin PMTiles HTTP range serving
    tiles: {
      executor: 'constant-vus',
      vus: 20,
      duration: '40s',
      startTime: '10s',
      exec: 'tileTest',
    },
    // 9. Multi-tenant isolation — 1 VU per tenant, verify country never bleeds
    multi_tenant: {
      executor: 'per-vu-iterations',
      vus: 4,
      iterations: 25,
      startTime: '95s',
      exec: 'multiTenantTest',
    },
  },

  thresholds: {
    // Region lookup via PostGIS GIST index (under moderate-to-heavy concurrent load)
    region_lga_ms:      ['p(95)<200', 'p(99)<500'],
    // Cache IS hitting (X-Cache: HIT verified in checks) but nginx is busy under 250+ concurrent VUs.
    // The ngx.shared lookup itself is <1ms; queuing overhead adds latency under heavy load.
    region_cache_ms:    ['p(95)<300'],
    region_zone_ms:     ['p(95)<300'],      // zone ST_Contains + constituent LGA join
    // geo_node lookup: ST_Contains on geo_hierarchy_nodes.geom + recursive CTE ancestor chain
    region_geo_node_ms: ['p(95)<150', 'p(99)<400'],

    // Boundary endpoints
    hierarchy_ms: ['p(95)<400'],      // ngx.shared after first hit; first-hit DB query
    geojson_ms:   ['p(95)<3000'],     // ngx.shared cache hit; cold miss may be slow
    search_ms:    ['p(95)<500'],      // indexed LIKE

    // GeoJSON cache hit rate: expect >80% HITs once warm
    geojson_cache_hit: ['rate>0.80'],

    // Tiles — Martin range serving
    tile_ms: ['p(95)<400'],

    // Global error rate (excludes expected 404s — region outside scope returns 404)
    http_req_failed:       ['rate<0.05'],
    wrong_tenant_response: ['rate<0.001'],
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

function assertRegionShape(res, expectedCountry) {
  if (res.status !== 200 && res.status !== 404) {
    errorCount.add(1);
    return;
  }
  if (res.status !== 200) return; // 404 = coord outside tenant scope — not an error

  let body;
  try { body = JSON.parse(res.body); } catch(e) { errorCount.add(1); return; }

  check(res, {
    'region: found=true':         () => body.found === true,
    'region: has matched_level':  () => body.matched_level === 'lga' || body.matched_level === 'zone',
    'region: country.pcode ok':   () => !!body.country && body.country.pcode === expectedCountry,
    'region: state.pcode present':() => !!body.state && !!body.state.pcode,
    'region: state.name present': () => !!body.state && !!body.state.name,
    'region: has lga or zone':    () => !!body.lga || !!body.zone,
  });

  // Cross-tenant bleed detection
  const correct = body.country && body.country.pcode === expectedCountry;
  wrongTenantRate.add(!correct ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Test functions
// ---------------------------------------------------------------------------
export function geoNodeRegionTest() {
  const c   = GEO_NODE_COORDS[Math.floor(Math.random() * GEO_NODE_COORDS.length)];
  const url = `${BASE}/region?lat=${c.lat}&lon=${c.lon}`;
  const res = http.get(url, { headers: { 'X-Tenant-ID': c.tenantId } });
  regionGeoNodeMs.add(res.timings.duration);

  if (res.status !== 200 && res.status !== 404) { errorCount.add(1); return; }
  if (res.status === 404) return;

  let body;
  try { body = JSON.parse(res.body); } catch (e) { errorCount.add(1); return; }

  check(res, {
    'geo_node: found=true':        () => body.found === true,
    'geo_node: has matched_level': () => typeof body.matched_level === 'string',
    'geo_node: country.pcode ok':  () => !!body.country && body.country.pcode === c.expectedCountry,
    'geo_node: state present':     () => !!body.state && !!body.state.pcode,
  });
}

export function regionLgaTest() {
  const tenant = pick(TENANTS);
  const coord  = pick(tenant.coords);
  const url    = `${BASE}/region?lat=${coord.lat}&lon=${coord.lon}`;
  const res    = http.get(url, headers(tenant.id));
  regionLgaLatency.add(res.timings.duration);
  assertRegionShape(res, tenant.expectedCountry);
}

export function regionCacheTest() {
  const url = `${BASE}/region?lat=${CACHE_HIT.lat}&lon=${CACHE_HIT.lon}`;
  const res = http.get(url, headers(CACHE_HIT.tenantId));
  regionCacheLatency.add(res.timings.duration);
  check(res, {
    'cache hit: status 200':  (r) => r.status === 200,
    'cache hit: X-Cache HIT': (r) => r.headers['X-Cache'] === 'HIT',
  });
}

export function regionZoneTest() {
  const tenant = TENANTS[0]; // Kenya — only tenant with zones configured
  if (tenant.zoneCoords.length === 0) { sleep(0.1); return; }
  const coord = pick(tenant.zoneCoords);
  const url   = `${BASE}/region?lat=${coord.lat}&lon=${coord.lon}`;
  const res   = http.get(url, headers(tenant.id));
  regionZoneLatency.add(res.timings.duration);

  if (res.status !== 200) { errorCount.add(1); return; }
  let body;
  try { body = JSON.parse(res.body); } catch(e) { errorCount.add(1); return; }

  check(res, {
    'zone region: matched_level=zone': () => body.matched_level === 'zone',
    'zone region: zone.pcode present': () => !!body.zone && !!body.zone.pcode,
    'zone region: zone.name present':  () => !!body.zone && !!body.zone.name,
    'zone region: state.pcode ok':     () => !!body.state && body.state.pcode === 'KE004',
    'zone region: country.pcode=KE':   () => !!body.country && body.country.pcode === 'KE',
    'zone region: lga present':        () => !!body.lga && !!body.lga.pcode,
  });
}

export function hierarchyTest() {
  const tenant = pick(TENANTS);
  // ?t= param makes each tenant URL unique so browser cache doesn't serve wrong data.
  // Server-side ngx.shared cache key is just tenant_id (not URL-dependent).
  const url = `${BASE}/boundaries/hierarchy?t=${tenant.id}`;
  const res = http.get(url, headers(tenant.id));
  hierarchyLatency.add(res.timings.duration);

  if (res.status !== 200) { errorCount.add(1); return; }
  let body;
  try { body = JSON.parse(res.body); } catch(e) { errorCount.add(1); return; }

  check(res, {
    'hierarchy: states array':     () => Array.isArray(body.states),
    'hierarchy: state_count > 0':  () => body.state_count > 0,
    'hierarchy: lga_count > 0':    () => body.lga_count > 0,
    'hierarchy: state has pcode':  () => body.states.length > 0 && !!body.states[0].pcode,
    'hierarchy: state has lgas':   () => body.states.length > 0 && Array.isArray(body.states[0].lgas),
  });
}

export function geojsonTest() {
  const tenant = pick(TENANTS);
  const url = `${BASE}/boundaries/geojson?t=${tenant.id}`;
  const res = http.get(url, headers(tenant.id));
  geojsonLatency.add(res.timings.duration);

  const isHit = res.headers['X-Cache'] === 'HIT';
  geojsonCacheHitRate.add(isHit ? 1 : 0);

  if (res.status !== 200) { errorCount.add(1); return; }
  let body;
  try { body = JSON.parse(res.body); } catch(e) { errorCount.add(1); return; }

  check(res, {
    'geojson: FeatureCollection':  () => body.type === 'FeatureCollection',
    'geojson: features > 0':       () => Array.isArray(body.features) && body.features.length > 0,
    'geojson: feature has geom':   () => !!body.features[0].geometry,
    'geojson: feature has pcode':  () => !!body.features[0].properties.pcode,
    'geojson: has X-Cache header': () => res.headers['X-Cache'] === 'HIT' || res.headers['X-Cache'] === 'MISS',
  });
  sleep(0.3); // be gentle — GeoJSON payloads are large (1-4 MB)
}

export function searchTest() {
  const tenant = pick(TENANTS);
  const url = `${BASE}/boundaries/search?q=${tenant.searchTerm}`;
  const res = http.get(url, headers(tenant.id));
  searchLatency.add(res.timings.duration);

  if (res.status !== 200) { errorCount.add(1); return; }
  let body;
  try { body = JSON.parse(res.body); } catch(e) { errorCount.add(1); return; }

  check(res, {
    'search: results is array':    () => Array.isArray(body.results),
    'search: count >= 1':          () => body.count >= 1,
    'search: result has pcode':    () => body.results.length > 0 && !!body.results[0].pcode,
    'search: result has name':     () => body.results.length > 0 && !!body.results[0].name,
    'search: result has adm_level':() => body.results.length > 0 && body.results[0].adm_level != null,
  });
}

export function tileTest() {
  const tenant = pick(TENANTS);
  const t = tenant.tile;
  const url = `${BASE}/tiles/${t.z}/${t.x}/${t.y}`;
  const res = http.get(url, headers(tenant.id));
  tileLatency.add(res.timings.duration);

  // 200 = tile data, 204 = empty tile (valid for sparse PMTiles), 404 = outside coverage
  check(res, {
    'tile: not server error': (r) => r.status < 500,
    // When tile data is returned (200), verify content type
    'tile: 200 has content-type': (r) =>
      r.status !== 200 || (r.headers['Content-Type'] || '').length > 0,
  });
  if (res.status >= 500) errorCount.add(1);
}

export function multiTenantTest() {
  // One VU per tenant — verify response country never bleeds into another tenant
  const vuIndex = (__VU - 1) % TENANTS.length;
  const tenant  = TENANTS[vuIndex];
  const coord   = pick(tenant.coords);
  const url     = `${BASE}/region?lat=${coord.lat}&lon=${coord.lon}`;
  const res     = http.get(url, headers(tenant.id));

  if (res.status !== 200 && res.status !== 404) {
    errorCount.add(1);
    return;
  }
  if (res.status === 200) {
    let body;
    try { body = JSON.parse(res.body); } catch(e) { errorCount.add(1); return; }
    const correct = body.country && body.country.pcode === tenant.expectedCountry;
    wrongTenantRate.add(!correct ? 1 : 0);
    check(res, {
      [`tenant ${tenant.id} country=${tenant.expectedCountry}`]: () => correct,
    });
  }
  sleep(0.05);
}
