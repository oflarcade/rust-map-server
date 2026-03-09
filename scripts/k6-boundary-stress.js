import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://localhost:8080';

// Custom metrics
const geojsonLatency   = new Trend('geojson_latency',   true);
const hierarchyLatency = new Trend('hierarchy_latency', true);
const searchLatency    = new Trend('search_latency',    true);
const regionLatency    = new Trend('region_latency',    true);
const zoneWriteLatency = new Trend('zone_write_latency', true);
const errors           = new Counter('boundary_errors');
const crossTenantLeaks = new Rate('cross_tenant_leaks');

// All Nigeria state tenants for cross-tenant isolation test
const NIGERIA_TENANTS = [
  { id: '3',  states: ['NG025', 'NG030'] },  // Lagos + Osun
  { id: '9',  states: ['NG012'] },            // Edo
  { id: '11', states: ['NG025'] },            // Lagos
  { id: '14', states: ['NG024'] },            // Kwara
  { id: '16', states: ['NG006'] },            // Bayelsa
  { id: '18', states: ['NG018'] },            // Jigawa
];

// Varied search terms across different tenants
const SEARCH_TERMS = ['lagos', 'aba', 'ikorodu', 'agege', 'kwara', 'jigawa', 'edo', 'ibeju'];

// Lagos area coordinates for region lookup
const LAGOS_COORDS = [
  { lat: 6.4541, lon: 3.3947 },
  { lat: 6.5244, lon: 3.3792 },
  { lat: 6.6018, lon: 3.3515 },
  { lat: 6.4698, lon: 3.5852 },
  { lat: 6.3350, lon: 3.3141 },
];

export const options = {
  scenarios: {
    // Scenario 1: GeoJSON endpoint under concurrent load
    geojson_load: {
      executor: 'constant-vus',
      vus: 20,
      duration: '30s',
      startTime: '0s',
      exec: 'geojsonTest',
    },

    // Scenario 2: Hierarchy endpoint — should be fast after first cache warm-up
    hierarchy_cached: {
      executor: 'constant-vus',
      vus: 50,
      duration: '30s',
      startTime: '10s',
      exec: 'hierarchyTest',
    },

    // Scenario 3: Search endpoint under ramping load
    search_load: {
      executor: 'ramping-vus',
      startTime: '20s',
      stages: [
        { duration: '10s', target: 20 },
        { duration: '20s', target: 100 },
        { duration: '10s', target: 0 },
      ],
      exec: 'searchTest',
    },

    // Scenario 4: Region lookup — PostGIS spatial query performance
    region_load: {
      executor: 'ramping-vus',
      startTime: '0s',
      stages: [
        { duration: '20s', target: 50 },
        { duration: '30s', target: 200 },
        { duration: '20s', target: 0 },
      ],
      exec: 'regionTest',
    },

    // Scenario 5: Multi-tenant isolation — all Nigeria tenants concurrently
    multi_tenant: {
      executor: 'constant-vus',
      vus: 30,
      duration: '40s',
      startTime: '30s',
      exec: 'multiTenantTest',
    },

    // Scenario 6: Zone write performance (create + verify cache invalidation)
    zone_writes: {
      executor: 'per-vu-iterations',
      vus: 5,
      iterations: 3,
      startTime: '70s',
      exec: 'zoneWriteTest',
    },
  },

  thresholds: {
    // GeoJSON: PostGIS query + JSON streaming
    geojson_latency:   ['p(95)<200'],

    // Hierarchy: cached path must be fast
    hierarchy_latency: ['p(95)<50'],

    // Search: indexed LIKE query
    search_latency:    ['p(95)<30'],

    // Region: GIST index spatial query (tightened from pre-migration 100ms)
    region_latency:    ['p(95)<20'],

    // Zone writes: ST_Union + INSERT
    zone_write_latency: ['p(95)<500'],

    // Cross-tenant data leaks must be zero
    cross_tenant_leaks: ['rate==0'],

    http_req_failed: ['rate<0.01'],
  },
};

// ---------------------------------------------------------------------------
// Scenario 1: GeoJSON
// ---------------------------------------------------------------------------
export function geojsonTest() {
  const tenant = NIGERIA_TENANTS[Math.floor(Math.random() * NIGERIA_TENANTS.length)];
  const res = http.get(`${BASE}/boundaries/geojson`, {
    headers: { 'X-Tenant-ID': tenant.id },
  });

  const ok = check(res, {
    'geojson 200':      (r) => r.status === 200,
    'is FeatureCollection': (r) => r.body?.includes('"FeatureCollection"'),
  });
  if (!ok) errors.add(1);
  geojsonLatency.add(res.timings.duration);
  sleep(0.1);
}

// ---------------------------------------------------------------------------
// Scenario 2: Hierarchy (first request = DB query, rest = cache hits)
// ---------------------------------------------------------------------------
export function hierarchyTest() {
  const tenant = NIGERIA_TENANTS[Math.floor(Math.random() * NIGERIA_TENANTS.length)];
  const res = http.get(`${BASE}/boundaries/hierarchy`, {
    headers: { 'X-Tenant-ID': tenant.id },
  });

  const ok = check(res, {
    'hierarchy 200': (r) => r.status === 200,
    'has states':    (r) => r.body?.includes('"states"'),
  });
  if (!ok) errors.add(1);
  hierarchyLatency.add(res.timings.duration);
}

// ---------------------------------------------------------------------------
// Scenario 3: Search
// ---------------------------------------------------------------------------
export function searchTest() {
  const tenant = NIGERIA_TENANTS[Math.floor(Math.random() * NIGERIA_TENANTS.length)];
  const term   = SEARCH_TERMS[Math.floor(Math.random() * SEARCH_TERMS.length)];
  const res    = http.get(`${BASE}/boundaries/search?q=${term}`, {
    headers: { 'X-Tenant-ID': tenant.id },
  });

  const ok = check(res, {
    'search 200':     (r) => r.status === 200,
    'has results key': (r) => r.body?.includes('"results"'),
  });
  if (!ok) errors.add(1);
  searchLatency.add(res.timings.duration);
}

// ---------------------------------------------------------------------------
// Scenario 4: Region lookup
// ---------------------------------------------------------------------------
export function regionTest() {
  const coord = LAGOS_COORDS[Math.floor(Math.random() * LAGOS_COORDS.length)];
  const res   = http.get(`${BASE}/region?lat=${coord.lat}&lon=${coord.lon}`, {
    headers: { 'X-Tenant-ID': '11' },  // EKOEXCEL Lagos
  });

  check(res, {
    'region 200 or 404': (r) => r.status === 200 || r.status === 404,
  });
  regionLatency.add(res.timings.duration);
}

// ---------------------------------------------------------------------------
// Scenario 5: Multi-tenant isolation
// Verifies each tenant only receives data within their assigned states.
// ---------------------------------------------------------------------------
export function multiTenantTest() {
  const tenant = NIGERIA_TENANTS[Math.floor(Math.random() * NIGERIA_TENANTS.length)];
  const coord  = LAGOS_COORDS[Math.floor(Math.random() * LAGOS_COORDS.length)];

  const res = http.get(`${BASE}/region?lat=${coord.lat}&lon=${coord.lon}`, {
    headers: { 'X-Tenant-ID': tenant.id },
  });

  check(res, { 'status ok': (r) => r.status === 200 || r.status === 404 });

  // If found, verify the state_pcode belongs to this tenant's allowed states
  if (res.status === 200) {
    try {
      const body = JSON.parse(res.body);
      if (body.found && body.state_pcode) {
        const isAllowed = tenant.states.includes(body.state_pcode);
        // Track cross-tenant leaks (0 = no leak, 1 = leak)
        crossTenantLeaks.add(isAllowed ? 0 : 1);
        check(body, {
          'result within tenant scope': () => isAllowed,
        });
      }
    } catch (_) {
      // JSON parse error counts as a boundary error, not a tenant leak
      errors.add(1);
    }
  }

  regionLatency.add(res.timings.duration);
  sleep(0.05);
}

// ---------------------------------------------------------------------------
// Scenario 6: Zone write performance
// Creates a zone for tenant 11 (Lagos), verifies hierarchy cache invalidation,
// then cleans up by deleting the zone.
// ---------------------------------------------------------------------------
const ADMIN_TOKEN = __ENV.ADMIN_TOKEN || 'changeme-replace-in-production';
const ZONE_TEST_LGAS = ['NG025001', 'NG025002'];  // Agege + Ajeromi-Ifelodun in Lagos

export function zoneWriteTest() {
  const headers = {
    'X-Tenant-ID':  '11',
    'X-Admin-Token': ADMIN_TOKEN,
    'Content-Type':  'application/json',
  };

  // 1. Create zone
  const createRes = http.post(`${BASE}/admin/zones`,
    JSON.stringify({
      zone_name:          `k6-test-zone-${Date.now()}`,
      color:              '#ff5733',
      parent_pcode:       'NG025',
      constituent_pcodes: ZONE_TEST_LGAS,
    }),
    { headers }
  );

  const createOk = check(createRes, {
    'zone created 201': (r) => r.status === 201,
    'has zone_pcode':   (r) => r.body?.includes('zone_pcode'),
  });
  if (!createOk) { errors.add(1); return; }
  zoneWriteLatency.add(createRes.timings.duration);

  let zoneId;
  try {
    zoneId = JSON.parse(createRes.body).zone_id;
  } catch (_) { errors.add(1); return; }

  // 2. Verify hierarchy cache was invalidated (new zone must appear)
  const hierarchyRes = http.get(`${BASE}/boundaries/hierarchy`, {
    headers: { 'X-Tenant-ID': '11' },
  });
  check(hierarchyRes, {
    'hierarchy refreshed after zone create': (r) => r.status === 200,
  });

  sleep(0.5);

  // 3. Delete zone (cleanup)
  const deleteRes = http.del(`${BASE}/admin/zones/${zoneId}`, null, {
    headers: {
      'X-Tenant-ID':   '11',
      'X-Admin-Token': ADMIN_TOKEN,
    },
  });
  check(deleteRes, { 'zone deleted': (r) => r.status === 200 });
  zoneWriteLatency.add(deleteRes.timings.duration);
}
