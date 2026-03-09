import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const BASE = 'http://35.239.86.115:8080';

// Custom metrics
const coldLatency  = new Trend('cold_latency',  true);
const warmLatency  = new Trend('warm_latency',  true);
const cacheLatency = new Trend('cache_hit_latency', true);
const errors       = new Counter('region_errors');

// Nigeria coordinates (spread across different LGAs for cache-miss variety)
const COORDS = [
  { lat: 6.4541,  lon: 3.3947  }, // Lagos Island
  { lat: 6.5244,  lon: 3.3792  }, // Mainland
  { lat: 6.6018,  lon: 3.3515  }, // Agege
  { lat: 6.4698,  lon: 3.5852  }, // Ikorodu
  { lat: 6.3350,  lon: 3.3141  }, // Badagry
  { lat: 6.4280,  lon: 3.4219  }, // Surulere
  { lat: 6.5780,  lon: 3.4076  }, // Kosofe
  { lat: 6.6403,  lon: 3.3503  }, // Ifako-Ijaiye
  { lat: 6.4474,  lon: 3.4553  }, // Eti-Osa
  { lat: 6.5108,  lon: 3.3794  }, // Mushin
];

// Fixed coord for result-cache hit tests (always same key)
const CACHE_HIT_COORD = { lat: 6.4541, lon: 3.3947 };

export const options = {
  scenarios: {
    // Phase 1: warm up + observe cold vs warm worker cache (low VUs, sequential)
    cache_warmup: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 20,
      startTime: '0s',
      exec: 'warmupTest',
    },
    // Phase 2: result cache hit test (same coord, high concurrency)
    cache_hits: {
      executor: 'constant-vus',
      vus: 50,
      duration: '30s',
      startTime: '25s',
      exec: 'cacheHitTest',
    },
    // Phase 3: stress with varied coords (cache misses + ray-casting)
    stress: {
      executor: 'ramping-vus',
      startTime: '60s',
      stages: [
        { duration: '20s', target: 20  },
        { duration: '30s', target: 100 },
        { duration: '20s', target: 200 },
        { duration: '20s', target: 0   },
      ],
      exec: 'stressTest',
    },
  },
  thresholds: {
    // Result cache hits must be fast
    cache_hit_latency: ['p(95)<50'],
    // Warm worker ray-cast should be well under 100ms
    warm_latency:      ['p(95)<100'],
    // Overall error rate
    http_req_failed:   ['rate<0.01'],
  },
};

const HEADERS = { 'X-Tenant-ID': '11' }; // EKOEXCEL Lagos

// Phase 1: sequential requests, observe cold then warm
export function warmupTest() {
  const coord = COORDS[Math.floor(Math.random() * COORDS.length)];
  const url = `${BASE}/region?lat=${coord.lat}&lon=${coord.lon}`;
  const res = http.get(url, { headers: HEADERS });

  const ok = check(res, { 'status 200': (r) => r.status === 200 });
  if (!ok) { errors.add(1); return; }

  // First few requests = cold (GeoJSON parse); rest = warm (ray-cast only)
  warmLatency.add(res.timings.duration);
  sleep(0.1);
}

// Phase 2: hammer same coord — should all be result-cache hits (sub-ms)
export function cacheHitTest() {
  const url = `${BASE}/region?lat=${CACHE_HIT_COORD.lat}&lon=${CACHE_HIT_COORD.lon}`;
  const res = http.get(url, { headers: HEADERS });

  check(res, { 'status 200': (r) => r.status === 200 });
  cacheLatency.add(res.timings.duration);
}

// Phase 3: varied coords under load — tests ray-casting throughput
export function stressTest() {
  const coord = COORDS[Math.floor(Math.random() * COORDS.length)];
  const url = `${BASE}/region?lat=${coord.lat}&lon=${coord.lon}`;
  const res = http.get(url, { headers: HEADERS });

  const ok = check(res, {
    'status 200 or 404': (r) => r.status === 200 || r.status === 404,
  });
  if (!ok) errors.add(1);

  coldLatency.add(res.timings.duration);
}
