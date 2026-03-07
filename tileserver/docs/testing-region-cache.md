# Testing Region Lookup Caches

**URLs:** Martin tile server = `http://localhost:3000` (tiles, catalog). Nginx tenant proxy = `http://localhost:8080` (health, `/region`, `/boundaries/*`). Region cache tests use **8080** because `/region` is served by Lua on the proxy.

The `/region` endpoint uses two caches:

1. **Worker-level GeoJSON cache** (`tileserver/lua/hdx-cache.lua`): each OpenResty worker parses adm1/adm2 GeoJSON once per `prefix:level` and reuses the parsed table. Cold = parse + ray-cast (~100–300 ms). Warm = ray-cast only (~1–5 ms).
2. **Result cache** (`tileserver/lua/region-lookup.lua`): `ngx.shared.region_cache` stores full response by key `prefix:lat_4dec:lon_4dec`, TTL 3600s. Checked before ray-casting; any worker can read it. Second request with same (rounded) lat/lon + tenant = cache hit (sub-ms).

---

## Prerequisites

- Tileserver up: `docker compose -f tileserver/docker-compose.tenant.yml up`
- HDX data present for the tenant: `hdx/<prefix>_adm1.geojson` and `hdx/<prefix>_adm2.geojson` (e.g. `hdx/nigeria_adm1.geojson`, `hdx/nigeria_adm2.geojson`). Run `scripts/ps1/download-hdx.ps1` if needed.
- **Always test with Nigeria (heavy GeoJSON):** use a Nigeria tenant such as **3** (nigeria-lagos-osun), **9** (nigeria-edo), **14** (nigeria-kwara), **16** (nigeria-bayelsa), or **18** (nigeria-jigawa). All use prefix `nigeria`; coords below are in Nigeria.

### If you see `HDX_NOT_AVAILABLE` in the response body

The Lua code reads `/data/hdx/<prefix>_adm1.geojson` and `_adm2.geojson` inside the nginx container. If the body shows `"code":"HDX_NOT_AVAILABLE"`, the container cannot open those files.

1. **On the host** (from repo root), confirm the files exist:
   ```powershell
   Get-ChildItem hdx\nigeria_adm*.geojson
   ```
   You should see `nigeria_adm1.geojson` and `nigeria_adm2.geojson`. If not, run `.\scripts\ps1\download-hdx.ps1` (without `-Force` it will skip if it thinks they exist; use `-Force` to re-download).

2. **Inside the container**, confirm the same path is mounted and the files are visible:
   ```bash
   docker compose -f tileserver/docker-compose.tenant.yml exec nginx ls -la /data/hdx/
   ```
   You should see `nigeria_adm1.geojson` and `nigeria_adm2.geojson`. If you get **"No such file or directory"**, the container has no `/data/hdx` mount (e.g. it was created before the volume was added). Recreate the stack **from the repo root** so the `../hdx` volume is applied:
   ```powershell
   cd C:\Users\...\rust-map-server
   docker compose -f tileserver/docker-compose.tenant.yml down
   docker compose -f tileserver/docker-compose.tenant.yml up -d
   ```
   Then run the `exec nginx ls -la /data/hdx/` again. If the directory is empty or still missing, ensure `hdx` exists on the host and run step 1.

---

## 1. Cold vs warm (worker cache)

**Goal:** First request for a tenant parses GeoJSON (slower); subsequent requests in the same worker only ray-cast (faster). Same lat/lon twice also hits result cache (fastest).

**Steps:**

1. **Optional:** Restart nginx to clear in-memory caches:
   ```bash
   docker compose -f tileserver/docker-compose.tenant.yml restart nginx
   ```

2. **First request (cold worker + cold result cache):**  
   Expect ~100–300 ms (parse adm1 + adm2 + ray-cast). Use Nigeria tenant 3 (or 9, 14, 16, 18).
   ```bash
   curl -w "time_total=%{time_total}s\n" -s -H "X-Tenant-ID: 3" "http://localhost:8080/region?lat=6.4541&lon=3.3947"
   ```

3. **Second request, same coords (warm worker + result cache hit):**  
   Expect &lt; ~0.01 s (result cache; no ray-cast).
   ```bash
   curl -w "time_total=%{time_total}s\n" -s -H "X-Tenant-ID: 3" "http://localhost:8080/region?lat=6.4541&lon=3.3947"
   ```

4. **Different coords, same tenant (warm worker, result cache miss):**  
   Expect ~1–5 ms (no parse; ray-cast only).
   ```bash
   curl -w "time_total=%{time_total}s\n" -s -H "X-Tenant-ID: 3" "http://localhost:8080/region?lat=6.5244&lon=3.3792"
   ```

5. **Same coords again (result cache hit):**  
   Expect sub-millisecond again.
   ```bash
   curl -w "time_total=%{time_total}s\n" -s -H "X-Tenant-ID: 3" "http://localhost:8080/region?lat=6.5244&lon=3.3792"
   ```

**Interpretation:**  
- First call ≈ cold worker (parse + ray-cast).  
- Same lat/lon second call ≈ result cache hit.  
- New lat/lon after that ≈ warm worker (ray-cast only).  
- OpenResty may use multiple workers; sequential requests often hit the same worker, so you should see the pattern above when running the four commands in order.

---

## 2. Result cache: same key = same response

**Goal:** Same (rounded) lat/lon + tenant → same JSON; second request is a cache hit (no ray-cast). Different lat/lon or different tenant → different key.

**Cache key:** `prefix + ":" + string.format("%.4f", lat) + ":" + string.format("%.4f", lon)`  
So `6.4541,3.3947` and `6.45410,3.39470` share the same key.

**Steps:**

1. **Request A:** `lat=6.4541&lon=3.3947`, Nigeria tenant 3. Save body.
   ```bash
   curl -s -H "X-Tenant-ID: 3" "http://localhost:8080/region?lat=6.4541&lon=3.3947" -o /tmp/r1.json
   ```

2. **Request B:** Same coords, same tenant. Save body.
   ```bash
   curl -s -H "X-Tenant-ID: 3" "http://localhost:8080/region?lat=6.4541&lon=3.3947" -o /tmp/r2.json
   ```

3. **Compare:** Bodies must be identical (result cache returned same stored response).
   ```bash
   diff /tmp/r1.json /tmp/r2.json
   ```

4. **Different tenant, same coords:** Different prefix → different key. Tenant 18 (Jigawa) still uses Nigeria prefix, so it shares result cache with tenant 3 for same lat/lon (`nigeria:6.4541:3.3947`). For a different prefix, use another HDX country (e.g. tenant 1 Kenya):
   ```bash
   curl -s -H "X-Tenant-ID: 1" "http://localhost:8080/region?lat=-1.2921&lon=36.8220" -o /tmp/r_kenya.json
   ```
   Second identical request returns same JSON (result cache hit for `kenya:-1.2921:36.8220`).

5. **Different lat/lon, same tenant:** Different key → cache miss, then ray-cast; response may differ.
   ```bash
   curl -s -H "X-Tenant-ID: 3" "http://localhost:8080/region?lat=6.5244&lon=3.3792"
   ```

**Interpretation:**  
- Same tenant + same (4-decimal) lat/lon → identical response and second request is from result cache.  
- Different tenant (different prefix) or different (rounded) coords → different key; first request fills cache, second with same key hits cache.

---

## 3. Using the test scripts

From repo root, with tileserver running on port 8080:

**PowerShell (Windows):**
```powershell
.\scripts\ps1\test-region-cache.ps1
```

**Bash:** No dedicated .sh script; use the curl commands from section 3 above, or run the .ps1 script under Git Bash/PowerShell.

Scripts call `curl` with `-w "%{time_total}\n"` (or equivalent), run the cold/warm and result-cache checks above, and print timings and pass/fail for body equality.

---

## 4. Worker count and result cache

- **Worker cache:** Per-worker. Sequential requests often land on the same worker, so you typically see cold then warm. With multiple workers, the “first request for this tenant” may be cold on another worker later.
- **Result cache:** Shared across workers (`ngx.shared.region_cache`). Same `prefix:lat:lon` always hits result cache on the second request, regardless of which worker handles it.
