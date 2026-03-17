# NewGlobe Map Server — Technical Walkthrough
### HDX Data Pipeline · PostGIS Database · Custom Zone Management

> 30-minute walkthrough. Sections are timed as a guide.

---

## Agenda

| # | Topic | Time |
|---|-------|------|
| 1 | System overview & stack | 3 min |
| 2 | HDX data — what it is and how we download it | 5 min |
| 3 | PostGIS schema — how the database is structured | 5 min |
| 4 | Import pipeline — wiring HDX GeoJSON into the DB | 7 min |
| 5 | How the DB is connected to the server at runtime | 3 min |
| 6 | Custom zoning — concept, API, and SQL | 7 min |

---

## 1. System Overview (3 min)

### The problem we solved
Google Maps was costing ~$350–700/month. We replaced it with a self-hosted vector tile server running on a single GCP VM (`martin-tileserver`, `us-central1-a`) for ~$5–15/month.

### Three-layer stack

```
Client (MapLibre GL JS, Vue)
  └── X-Tenant-ID header ──► OpenResty :8080  (Nginx + Lua)
                                 ├── /tiles/*        ──► Martin :3000 ──► PMTiles file (byte-range)
                                 ├── /boundaries/*   ──► Lua ──► PostGIS
                                 ├── /region         ──► Lua ──► PostGIS  (point-in-polygon)
                                 └── /admin/zones    ──► Lua ──► PostGIS  (zone CRUD)
```

### Key Docker services (`tileserver/docker-compose.tenant.yml`)

| Service | Image | Role |
|---------|-------|------|
| `postgres` | `postgis/postgis:16-3.4-alpine` | Stores all boundary data, tenants, zones |
| `martin` | `ghcr.io/maplibre/martin:v0.14.2` | Serves PMTiles vector tiles (base OSM map) |
| `nginx` | OpenResty custom build | Tenant routing, Lua API endpoints, CORS |
| `vue-app` | `nginx:alpine` | Serves the built Vue SPA |

PostgreSQL is the **first** service to start (via `healthcheck: pg_isready`). Nginx has `depends_on: postgres: condition: service_healthy` — it won't boot until the DB is ready.

---

## 2. HDX Data — What It Is and How We Download It (5 min)

### What is HDX COD-AB?

**HDX** = UN OCHA Humanitarian Data Exchange
**COD-AB** = Common Operational Dataset for Administrative Boundaries

These are the **official UN-maintained shapefiles** for country admin divisions:
- `adm1` = States / Provinces (e.g. Lagos, Tana River County)
- `adm2` = LGAs / Districts (e.g. Agege, Galole)

Each feature carries a **UN p-code** — a stable unique identifier like `NG025` (Lagos State), `NG025001` (Agege LGA). These p-codes are the primary keys we use throughout the entire system.

**License:** CC BY-IGO — commercial use permitted, attribution required.
**Countries covered:** Nigeria, Kenya, Uganda, Liberia, Central African Republic.
**Excluded:** Rwanda (HDX package is SHP only, no GeoJSON), India (no COD-AB package).

### Download script: `scripts/ps1/download-hdx.ps1`

```
HDX CKAN REST API
  GET https://data.humdata.org/api/3/action/package_show?id=cod-ab-nga
    ↓
  Response: JSON package metadata listing all resource files
    ↓
  Script finds: resource where format=GeoJSON AND url ends in .zip
    ↓
  Downloads zip to %TEMP%
    ↓
  Extracts: finds all files matching *admin<N>_*.geojson (excludes _em. simplified variants)
    ↓
  Copies to:
    hdx/nigeria_adm1.geojson     ← 37 states
    hdx/nigeria_adm2.geojson     ← 774 LGAs
    hdx/kenya_adm1.geojson       ← 47 counties
    hdx/kenya_adm2.geojson       ← 290 sub-counties
    ... (same pattern for UG, LR, CF)
    ↓
  Cleanup temp files
```

**Usage:**
```powershell
.\scripts\ps1\download-hdx.ps1                   # all 5 countries
.\scripts\ps1\download-hdx.ps1 -Country kenya    # one country
.\scripts\ps1\download-hdx.ps1 -Force            # re-download even if files exist
```

**Key design decisions in the script:**
- Idempotent by default (skips if files already exist, override with `-Force`)
- Uses HDX's CKAN API (standard humanitarian data API) to avoid hardcoded download URLs — URLs change when packages are updated
- Extracts every `admN` level found in the zip (not just adm1/adm2) so future data with adm3 works automatically
- `$ErrorActionPreference = "Stop"` — any failure aborts the script, no partial state

**Output check:**
```powershell
# Script prints this at the end automatically:
#   + nigeria_adm1.geojson (2.1 MB)
#   + nigeria_adm2.geojson (8.4 MB)
#   ...
```

---

## 3. PostGIS Schema (5 min)

**File:** `scripts/schema.sql`
**Auto-executed** by the postgres container on first boot via Docker's `docker-entrypoint-initdb.d/` mechanism. You never run this manually — starting the stack for the first time creates the schema automatically.

### Four tables

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
```
This one line gives us all spatial functions (`ST_Contains`, `ST_Union`, `ST_AsGeoJSON`, etc.).

---

#### Table 1: `tenants`
```sql
CREATE TABLE tenants (
    tenant_id    INTEGER      PRIMARY KEY,
    country_code VARCHAR(10)  NOT NULL,       -- 'NG', 'KE', 'UG', etc.
    country_name VARCHAR(255),
    tile_source  VARCHAR(255),                -- Martin source name e.g. 'nigeria-lagos'
    hdx_prefix   VARCHAR(100)                 -- 'nigeria', 'kenya', '' = no HDX data
);
```
One row per tenant. `tile_source` mirrors the nginx map — same value Nginx uses to route tile requests to Martin. `hdx_prefix` tells the import script which HDX files belong to this tenant.

---

#### Table 2: `adm_features` — the core geometry table
```sql
CREATE TABLE adm_features (
    id           SERIAL       PRIMARY KEY,
    country_code VARCHAR(10)  NOT NULL,
    adm_level    SMALLINT     NOT NULL,       -- 1 = state, 2 = LGA, 3+ = sub-district
    pcode        VARCHAR(30)  NOT NULL UNIQUE, -- UN p-code, e.g. 'NG025', 'NG025001'
    name         VARCHAR(255) NOT NULL,
    parent_pcode VARCHAR(30),                 -- NG025001 → parent = NG025
    geom         GEOMETRY(MULTIPOLYGON, 4326) NOT NULL,
    area_sqkm    FLOAT,
    center_lat   FLOAT,
    center_lon   FLOAT
);
```

**Why MULTIPOLYGON?** HDX GeoJSON files contain a mix of `Polygon` (simple shapes) and `MultiPolygon` (islands, exclaves). Storing everything as `MULTIPOLYGON` and calling `ST_Multi()` on insert normalises this — every row is the same type, no runtime casting needed.

**Indexes — this is what makes everything fast:**
```sql
CREATE INDEX adm_features_geom_idx    ON adm_features USING GIST(geom);
-- ↑ GIST spatial index — makes ST_Contains fast (used by /region)

CREATE INDEX adm_features_country_lvl ON adm_features(country_code, adm_level);
-- ↑ filters to "all Nigerian states" or "all Kenyan LGAs" in one seek

CREATE INDEX adm_features_parent      ON adm_features(parent_pcode);
-- ↑ parent→children lookups (hierarchy building)

CREATE INDEX adm_features_name        ON adm_features(LOWER(name));
-- ↑ case-insensitive partial name search
```

---

#### Table 3: `tenant_scope` — access control
```sql
CREATE TABLE tenant_scope (
    tenant_id INTEGER     NOT NULL REFERENCES tenants(tenant_id),
    pcode     VARCHAR(30) NOT NULL REFERENCES adm_features(pcode),
    PRIMARY KEY (tenant_id, pcode)
);
```

This is the join table that determines **what each tenant can see**.
- Full-country tenant (Kenya): all Kenyan adm1 + adm2 pcodes
- Nigerian state tenant (EKOEXCEL/Lagos): only Lagos state pcode + all Lagos LGA pcodes
- No rows = no access. There is no "full access by default" path.

Every boundary query JOINs this table: `JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1`

---

#### Table 4: `zones` — custom groupings
```sql
CREATE TABLE zones (
    zone_id            SERIAL       PRIMARY KEY,
    tenant_id          INTEGER      NOT NULL REFERENCES tenants(tenant_id),
    zone_pcode         VARCHAR(40)  NOT NULL UNIQUE,   -- e.g. 'NG025-Z01'
    zone_name          VARCHAR(255) NOT NULL,
    color              VARCHAR(7),                      -- hex e.g. '#3b82f6'
    parent_pcode       VARCHAR(30)  NOT NULL,           -- state pcode this zone sits in
    constituent_pcodes TEXT[]       NOT NULL,           -- LGA pcodes in this zone
    geom               GEOMETRY(MULTIPOLYGON, 4326),    -- pre-computed ST_Union
    created_at         TIMESTAMPTZ  DEFAULT NOW(),
    updated_at         TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX zones_geom_idx ON zones USING GIST(geom);  -- fast ST_Contains for /region
```

**`constituent_pcodes TEXT[]`** is a PostgreSQL array column. It stores e.g. `{NG025001,NG025002,NG025005}`. This drives the **exclusion rule**: any LGA whose pcode appears here is removed from the flat LGA list and grouped under the zone instead.

**`geom` is pre-computed** on every write (`ST_Union` of all constituent LGA geometries). This means `/region` never computes a union at query time — it's just a `ST_Contains` against a stored polygon.

---

## 4. Import Pipeline (7 min)

**File:** `scripts/import-hdx-to-pg.js`

```bash
node scripts/import-hdx-to-pg.js
```

Idempotent — uses `ON CONFLICT ... DO UPDATE` throughout. Safe to re-run. Wraps everything in a single transaction — either all data lands or nothing does.

### Step 1: Insert tenants

```javascript
await client.query(`
  INSERT INTO tenants(tenant_id, country_code, country_name, tile_source, hdx_prefix)
  VALUES ($1, $2, $3, $4, $5)
  ON CONFLICT (tenant_id) DO UPDATE SET
    country_code = EXCLUDED.country_code,
    country_name = EXCLUDED.country_name,
    tile_source  = EXCLUDED.tile_source,
    hdx_prefix   = EXCLUDED.hdx_prefix
`, [t.tenant_id, t.country_code, t.country_name, t.tile_source, t.hdx_prefix]);
```

`EXCLUDED` is a PostgreSQL pseudo-table that holds the values that *would have been inserted* if there was no conflict. `EXCLUDED.country_code` = the new value coming in. This pattern lets us update all columns on re-run without separate UPDATE statements.

### Step 2: Import `adm_features` from HDX GeoJSON

For each country prefix, for each `admN` file:

```javascript
// Extract the admin level from filename: nigeria_adm2.geojson → 2
const admLevel = parseInt(filename.match(/_adm(\d+)\.geojson$/)[1]);

// For each feature in the GeoJSON FeatureCollection:
const pcode       = p[`adm${admLevel}_pcode`];    // e.g. "NG025001"
const name        = p[`adm${admLevel}_name`];      // e.g. "Agege"
const parentPcode = p[`adm${admLevel - 1}_pcode`]; // e.g. "NG025"
```

The corresponding SQL:

```sql
INSERT INTO adm_features
  (country_code, adm_level, pcode, name, parent_pcode, geom, area_sqkm, center_lat, center_lon)
VALUES (
  $1, $2, $3, $4, $5,
  ST_Multi(ST_GeomFromGeoJSON($6)),   -- converts GeoJSON string → PostGIS geometry,
                                      -- ST_Multi() normalises Polygon → MultiPolygon
  $7, $8, $9
)
ON CONFLICT (pcode) DO UPDATE SET
  country_code = EXCLUDED.country_code,
  name         = EXCLUDED.name,
  parent_pcode = EXCLUDED.parent_pcode,
  geom         = EXCLUDED.geom,
  ...
```

**`ST_GeomFromGeoJSON($6)`** — converts the raw GeoJSON geometry string into a PostGIS geometry object with SRID 4326 (WGS84, lat/lon).
**`ST_Multi(...)`** — wraps any Polygon into a MultiPolygon so the column type is consistent.

After the bulk insert, PostGIS fills in any missing area/center values:

```sql
UPDATE adm_features SET
  area_sqkm  = ST_Area(geom::geography) / 1e6,
  center_lat = ST_Y(ST_Centroid(geom)),
  center_lon = ST_X(ST_Centroid(geom))
WHERE area_sqkm IS NULL OR center_lat IS NULL
```

**`ST_Area(geom::geography)`** — casts the geometry to `geography` type (spherical earth model) before computing area, giving accurate square kilometres instead of degree-squared nonsense.
**`ST_Centroid(geom)`** — returns the geometric centre point; `ST_Y`/`ST_X` extract lat/lon from it.

### Step 3: Populate `tenant_scope`

**Full-country tenants** (Kenya, Uganda, Liberia, CAR, Nigeria country-level):
```sql
INSERT INTO tenant_scope(tenant_id, pcode)
SELECT $1, pcode FROM adm_features
WHERE country_code = $2
ON CONFLICT DO NOTHING
```
One query — every pcode for that country lands in scope.

**Nigerian state tenants** (EKOEXCEL=Lagos, EdoBEST=Edo, etc.):
```sql
-- The state itself (adm1)
INSERT INTO tenant_scope(tenant_id, pcode)
SELECT $1, pcode FROM adm_features WHERE pcode = $2  -- e.g. 'NG025'
ON CONFLICT DO NOTHING;

-- All LGAs belonging to that state (adm2 where parent = state pcode)
INSERT INTO tenant_scope(tenant_id, pcode)
SELECT $1, pcode FROM adm_features
WHERE country_code = $2 AND adm_level = 2 AND parent_pcode = $3
ON CONFLICT DO NOTHING
```

This is how we get **data isolation** — tenant 11 (EKOEXCEL) only ever sees Lagos data because `tenant_scope` only contains Lagos pcodes.

### After import: verify
```sql
SELECT country_code, adm_level, COUNT(*)
FROM adm_features
GROUP BY 1, 2
ORDER BY 1, 2;
```

Expected results:
```
CF | 1 |  17    (CAR prefectures)
CF | 2 |  71    (CAR sub-prefectures)
KE | 1 |  47    (Kenya counties)
KE | 2 | 290    (Kenya sub-counties)
LR | 1 |  15    (Liberia counties)
LR | 2 |  90    (Liberia districts)
NG | 1 |  37    (Nigeria states)
NG | 2 | 774    (Nigeria LGAs)
UG | 1 | 135    (Uganda districts)
UG | 2 | 176    (Uganda sub-counties)
```

---

## 5. How the DB is Connected at Runtime (3 min)

### Connection path: Lua → pgmoon → PostgreSQL

**File:** `tileserver/lua/pg-pool.lua`

```lua
local CONFIG = {
  host     = os.getenv("PGHOST")     or "postgres",  -- Docker service name
  port     = tonumber(os.getenv("PGPORT") or "5432"),
  database = os.getenv("PGDATABASE") or "mapserver",
  user     = os.getenv("PGUSER")     or "mapserver",
  -- no password: postgres uses trust auth on Docker internal network
}
```

The hostname `"postgres"` is the Docker Compose service name — Docker's internal DNS resolves it to the postgres container's IP automatically.

**Every query goes through `pg.exec(sql, params)`:**
```lua
function M.exec(sql, params)
  local pg = pgmoon.new(CONFIG)
  pg:connect()
  result = pg:query(sql, table.unpack(params))
  pg:keepalive(30000, 100)  -- returns connection to pool: 30s TTL, max 100 per worker
  return result
end
```

`keepalive()` is the connection pool. OpenResty runs multiple worker processes; each worker maintains its own pool of up to 100 connections held open for 30 seconds. This means after the first request, subsequent requests reuse existing TCP connections to Postgres — no handshake overhead.

**pgmoon** is a pure-Lua Postgres driver vendored at `tileserver/lua/pgmoon/` (8 files, no luarocks needed). It speaks the Postgres wire protocol natively from within Nginx workers.

### Lua files and what they query

| Lua file | Endpoint | What it queries |
|----------|----------|-----------------|
| `boundary-db.lua` | (shared module) | All PostGIS queries — geojson, hierarchy, search, region, zone |
| `serve-geojson.lua` | `GET /boundaries/geojson` | `get_geojson(tenant_id)` — zones + states + ungrouped LGAs |
| `serve-hierarchy.lua` | `GET /boundaries/hierarchy` | `get_hierarchy_states/zones/lgas()` — tree structure, cached 24h |
| `search-boundaries.lua` | `GET /boundaries/search?q=` | `search(tenant_id, query)` — indexed LIKE on adm_features + zones |
| `region-lookup.lua` | `GET /region?lat=&lon=` | `region_lookup()` — ST_Contains on zones then LGAs |
| `admin-zones.lua` | `GET/POST/PUT/DELETE /admin/zones` | Full zone CRUD |

### Hierarchy cache

`/boundaries/hierarchy` is cached in `ngx.shared.hierarchy_cache` — a shared memory dict available to all Nginx workers:
- **Key:** `"h:" .. tenant_id`
- **TTL:** 24 hours
- **Invalidated on:** every zone write (POST/PUT/DELETE flushes that tenant's key)

**Important:** `openresty -s reload` does NOT clear `ngx.shared`. Must `docker restart tileserver_nginx_1` to clear the cache between sessions.

---

## 6. Custom Zoning — Concept, API, and SQL (7 min)

### What is a zone?

A zone is a **virtual admin level** that sits between state (adm1) and LGA (adm2). An operator groups a set of LGAs into a named zone — e.g. "Zone North" = {Agege, Ifako-Ijaiye, Mushin}.

```
Without zones:          With zones:
Kenya                   Kenya
  └── Tana River          └── Tana River
        ├── Galole               ├── Zone North  (Galole + Bura + Tana Delta)
        ├── Bura                 └── Zone South  (Garsen + Kipini)
        ├── Tana Delta
        ├── Garsen
        └── Kipini
```

Once LGAs are in a zone, they are **excluded from the flat LGA list**. The hierarchy becomes `Country → State → Zone → LGA`.

Zone pcodes follow the pattern `{state_pcode}-Z{nn}` e.g. `KE004-Z01`, `NG025-Z03`.

### How to add a zone: REST API

**`POST /admin/zones`** with `X-Tenant-ID` header:

```bash
curl -X POST http://localhost:8080/admin/zones \
  -H "X-Tenant-ID: 1" \
  -H "Content-Type: application/json" \
  -d '{
    "zone_name": "Zone North",
    "color": "#3b82f6",
    "parent_pcode": "KE004",
    "constituent_pcodes": ["KE004019", "KE004020", "KE004021"]
  }'
```

**Response (201):**
```json
{
  "zone_id": 7,
  "zone_pcode": "KE004-Z01",
  "zone_name": "Zone North",
  "color": "#3b82f6",
  "parent_pcode": "KE004",
  "constituent_pcodes": ["KE004019", "KE004020", "KE004021"]
}
```

### The SQL behind `POST /admin/zones` — step by step

**File:** `tileserver/lua/admin-zones.lua`

#### Step A: Validate pcodes belong to this tenant

```sql
SELECT COUNT(*) AS cnt
FROM adm_features a
JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
WHERE a.pcode = ANY($2::text[])
```

- `$1` = tenant_id, `$2` = `{KE004019,KE004020,KE004021}` (PostgreSQL array literal)
- `ANY($2::text[])` = "pcode is in this array" — short for `IN (...)` but works with parameterized arrays
- If `COUNT(*)` ≠ `len(constituent_pcodes)` → 422 error. You cannot add LGAs from another tenant's scope.

#### Step B: Insert the zone with auto-generated pcode

This is a single atomic SQL statement — no race condition possible:

```sql
WITH next_num AS (
  -- Find the next zone number for this parent state
  SELECT COALESCE(
    MAX(CAST(REGEXP_REPLACE(zone_pcode, '^.*-Z0*', '') AS INTEGER)),
    0
  ) + 1 AS n
  FROM zones
  WHERE parent_pcode = $1   -- 'KE004'
    AND tenant_id    = $2
),
new_zone AS (
  INSERT INTO zones(tenant_id, zone_pcode, zone_name, color, parent_pcode, constituent_pcodes, geom)
  SELECT
    $2,
    $1 || '-Z' || LPAD(n::text, 2, '0'),     -- e.g. 'KE004-Z01'
    $3,                                         -- zone_name
    $4,                                         -- color
    $1,                                         -- parent_pcode
    $5::text[],                                 -- constituent_pcodes array

    -- Pre-compute the union geometry from constituent LGA geometries
    (SELECT ST_Multi(ST_Union(geom))
     FROM adm_features
     WHERE pcode = ANY($5::text[]))
  FROM next_num
  RETURNING zone_id, zone_pcode, zone_name, color, parent_pcode, constituent_pcodes
)
SELECT * FROM new_zone
```

**Breaking down the key parts:**

**`REGEXP_REPLACE(zone_pcode, '^.*-Z0*', '')`**
Strips everything up to and including `-Z` and any leading zeros.
`KE004-Z03` → `3`. Then `MAX(...) + 1` = next number = `4`.
`COALESCE(..., 0)` handles the case where no zones exist yet (MAX returns NULL).

**`LPAD(n::text, 2, '0')`**
Left-pads the number to 2 digits with zeros.
`1` → `'01'`, `12` → `'12'`. Zone pcodes are always `KE004-Z01`, never `KE004-Z1`.

**`ST_Multi(ST_Union(geom))`**
This is where the geometry is computed:
- `ST_Union(geom)` — dissolves all the individual LGA polygons into one merged polygon (removes shared borders between adjacent LGAs)
- `ST_Multi(...)` — wraps the result as MultiPolygon for column consistency

This runs once at insert time. Every subsequent `/region` lookup just does `ST_Contains(zone.geom, point)` against this stored polygon — no union at query time.

### The exclusion rule — how zoned LGAs disappear from the flat list

`boundary-db.lua` — `get_geojson()` and `get_hierarchy_lgas()` both use this pattern:

```sql
-- LGAs in tenant scope that are NOT grouped into any zone
SELECT a.pcode, a.name, a.parent_pcode, ...
FROM adm_features a
JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
WHERE a.adm_level = 2
  AND a.pcode NOT IN (
      SELECT UNNEST(constituent_pcodes)   -- flatten TEXT[] array to a set of rows
      FROM zones
      WHERE tenant_id = $1
  )
```

**`UNNEST(constituent_pcodes)`** converts the `TEXT[]` column into a set of individual rows, which `NOT IN (...)` can then filter against. If an LGA pcode appears in any zone's `constituent_pcodes`, it is excluded from the ungrouped LGA list.

### `/region` — point-in-polygon with zone awareness

`boundary-db.lua` — `region_lookup(tenant_id, lat, lon)`:

**First: check zones**
```sql
SELECT
  z.zone_pcode, z.zone_name, z.color, z.parent_pcode, s.name AS state_name,
  lga.pcode AS lga_pcode, lga.name AS lga_name
FROM zones z
JOIN adm_features s ON s.pcode = z.parent_pcode
LEFT JOIN adm_features lga
  ON lga.adm_level = 2
 AND lga.pcode = ANY(z.constituent_pcodes)
 AND ST_Contains(lga.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
WHERE z.tenant_id = $1
  AND ST_Contains(z.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
LIMIT 1
```

**`ST_MakePoint($3, $2)`** — creates a Point geometry from `(lon, lat)`. Note: PostGIS is `(x, y)` = `(lon, lat)`, not `(lat, lon)`.
**`ST_SetSRID(..., 4326)`** — tags it with the WGS84 coordinate reference system.
**`ST_Contains(z.geom, point)`** — returns true if the point falls inside the zone polygon (GIST index makes this fast).
The `LEFT JOIN` on `lga` finds the specific LGA within the zone that contains the point (for even more precise attribution).

**If no zone match, fallback to raw LGA:**
```sql
SELECT a.pcode AS lga_pcode, a.name AS lga_name, a.parent_pcode, s.name AS state_name
FROM adm_features a
JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
JOIN adm_features s  ON s.pcode = a.parent_pcode
WHERE a.adm_level = 2
  AND ST_Contains(a.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
LIMIT 1
```

**Response shape:**
```json
{
  "found": true,
  "matched_level": "zone",
  "adm_0": { "pcode": "KE",      "name": "Kenya" },
  "adm_1": { "pcode": "KE004",   "name": "Tana River" },
  "adm_3": { "pcode": "KE004-Z01", "name": "Zone North", "color": "#3b82f6" },
  "adm_4": { "pcode": "KE004019", "name": "Galole" }
}
```

`adm_3` is only present when `matched_level === "zone"`. For raw LGA hits, only `adm_0`, `adm_1`, and `adm_4` are returned.

### Zone CRUD summary

| Operation | Endpoint | What happens in DB |
|-----------|----------|--------------------|
| List | `GET /admin/zones` | SELECT from zones WHERE tenant_id = $1 |
| Create | `POST /admin/zones` | Validate pcodes → INSERT with ST_Union geom → invalidate cache |
| Update | `PUT /admin/zones/:id` | UPDATE name/color/pcodes → recompute ST_Union if pcodes changed → invalidate cache |
| Delete | `DELETE /admin/zones/:id` | DELETE row → LGAs automatically reappear in ungrouped list → invalidate cache |

**Tenant ownership check on every write:**
```sql
SELECT zone_id FROM zones WHERE zone_id = $1 AND tenant_id = $2
```
If this returns nothing, the API returns 404. You cannot modify another tenant's zones even with a valid X-Tenant-ID.

---

## File Map

```
scripts/
  ps1/download-hdx.ps1         HDX CKAN API download → hdx/*.geojson
  schema.sql                   PostGIS schema (auto-run on first docker up)
  import-hdx-to-pg.js          HDX GeoJSON → PostgreSQL (run once after download)
  build-hdx-hierarchy.js       Builds hdx/<country>-hierarchy.json (offline reference)

hdx/
  nigeria_adm1.geojson         37 states
  nigeria_adm2.geojson         774 LGAs
  kenya_adm1.geojson           47 counties
  kenya_adm2.geojson           290 sub-counties
  ...

tileserver/
  docker-compose.tenant.yml    Full stack: postgres + martin + nginx + vue-app
  lua/
    pg-pool.lua                pgmoon connection pool (cosocket keepalive)
    boundary-db.lua            All PostGIS queries (geojson, hierarchy, search, region)
    serve-geojson.lua          GET /boundaries/geojson
    serve-hierarchy.lua        GET /boundaries/hierarchy + ngx.shared cache
    search-boundaries.lua      GET /boundaries/search?q=
    region-lookup.lua          GET /region?lat=&lon=
    admin-zones.lua            GET/POST/PUT/DELETE /admin/zones
    origin-whitelist.lua       CORS + origin check
    pgmoon/                    Vendored Lua Postgres driver (8 files)

View/src/views/
  TileInspector.vue            Map + sidebar: tenant select, search, hierarchy tree
  ZoneManager.vue              Click LGAs on map to create/edit zones
```

---

## Quick Reference: Commands to Run in Order

```bash
# 1. Download HDX data (once, or when boundaries need updating)
.\scripts\ps1\download-hdx.ps1

# 2. Start the stack (schema.sql runs automatically on first start)
docker compose -f tileserver/docker-compose.tenant.yml up -d

# 3. Wait for postgres healthy, then import
node scripts/import-hdx-to-pg.js

# 4. Verify
psql -h localhost -U mapserver -d mapserver \
  -c "SELECT country_code, adm_level, COUNT(*) FROM adm_features GROUP BY 1,2 ORDER BY 1,2;"

# 5. Test a boundary endpoint
curl -H "X-Tenant-ID: 1" "http://localhost:8080/boundaries/hierarchy?t=1"

# 6. Test region lookup
curl -H "X-Tenant-ID: 1" "http://localhost:8080/region?lat=-1.80&lon=40.10"

# 7. Create a zone via API
curl -X POST http://localhost:8080/admin/zones \
  -H "X-Tenant-ID: 1" \
  -H "Content-Type: application/json" \
  -d '{"zone_name":"Zone A","color":"#3b82f6","parent_pcode":"KE004","constituent_pcodes":["KE004019","KE004020"]}'

# 8. Restart nginx to clear hierarchy cache after zone changes
docker restart tileserver_nginx_1
```
