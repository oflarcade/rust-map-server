# Geo Hierarchy System — Backend Documentation

## 1. Database Schema

### Core Tables

#### tenants
```sql
CREATE TABLE tenants (
    tenant_id    INTEGER      PRIMARY KEY,
    country_code VARCHAR(10)  NOT NULL,
    country_name VARCHAR(255),
    tile_source  VARCHAR(255),   -- Martin source name (e.g. 'nigeria-lagos')
    hdx_prefix   VARCHAR(100)    -- 'nigeria', 'kenya', '' if no HDX data
);
```
- Represents a single operational tenant (program, country, or region)
- `country_code` links to adm_features for hierarchical data
- `tile_source` routes requests to the correct PMTiles file via nginx map directive

#### adm_features
```sql
CREATE TABLE adm_features (
    id           SERIAL       PRIMARY KEY,
    country_code VARCHAR(10)  NOT NULL,
    adm_level    SMALLINT     NOT NULL,  -- 1 = state/province, 2 = LGA/district, 3+ = sub-district
    pcode        VARCHAR(30)  NOT NULL UNIQUE,
    name         VARCHAR(255) NOT NULL,
    parent_pcode VARCHAR(30),
    geom         GEOMETRY(MULTIPOLYGON, 4326) NOT NULL,
    area_sqkm    FLOAT,
    center_lat   FLOAT,
    center_lon   FLOAT,
    level_label  VARCHAR(100)  -- human-readable type name: "Ward", "Senatorial District", etc.
);

CREATE INDEX adm_features_geom_idx    ON adm_features USING GIST(geom);
CREATE INDEX adm_features_country_lvl ON adm_features(country_code, adm_level);
CREATE INDEX adm_features_parent      ON adm_features(parent_pcode);
CREATE INDEX adm_features_name        ON adm_features(LOWER(name));
```
- Shared across all tenants; contains HDX/OSM/INEC admin boundaries
- `pcode`: unique identifier (e.g., "KE004" = Tana River, Kenya)
- `level_label`: dynamic per boundary source (e.g., Nigerian INEC wards vs Rwandan sectors)
- GIST index enables fast `ST_Contains` point-in-polygon lookups

#### tenant_scope
```sql
CREATE TABLE tenant_scope (
    tenant_id INTEGER     NOT NULL REFERENCES tenants(tenant_id),
    pcode     VARCHAR(30) NOT NULL REFERENCES adm_features(pcode),
    PRIMARY KEY (tenant_id, pcode)
);

CREATE INDEX tenant_scope_tenant ON tenant_scope(tenant_id);
CREATE INDEX tenant_scope_pcode  ON tenant_scope(pcode);
```
- Restricts which adm_features each tenant can see
- Populated on tenant creation; country tenants get all states + LGAs, state tenants get only their state's LGAs
- Used in all boundary queries to filter data per tenant

#### geo_hierarchy_levels
```sql
CREATE TABLE geo_hierarchy_levels (
    id          SERIAL PRIMARY KEY,
    tenant_id   INTEGER NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    level_order SMALLINT NOT NULL,
    level_label VARCHAR(100) NOT NULL,
    level_code  VARCHAR(10)  NOT NULL,
    UNIQUE(tenant_id, level_order),
    UNIQUE(tenant_id, level_code)
);
```
- Per-tenant custom hierarchy level definitions
- `level_order`: position in hierarchy (1 = root under state, 2 = next level, etc.)
- `level_label`: display name matching adm_features.level_label (e.g., "Senatorial District", "Ward")
- `level_code`: short code for pcode generation (e.g., "SD", "WD", "DI")

#### geo_hierarchy_nodes
```sql
CREATE TABLE geo_hierarchy_nodes (
    id                 SERIAL PRIMARY KEY,
    tenant_id          INTEGER  NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    parent_id          INTEGER  REFERENCES geo_hierarchy_nodes(id) ON DELETE CASCADE,
    state_pcode        VARCHAR(30) NOT NULL,
    level_id           INTEGER  NOT NULL REFERENCES geo_hierarchy_levels(id),
    pcode              VARCHAR(80) NOT NULL UNIQUE,
    name               VARCHAR(200) NOT NULL,
    color              VARCHAR(7),
    constituent_pcodes TEXT[],
    geom               GEOMETRY(MULTIPOLYGON, 4326),
    area_sqkm          NUMERIC,
    center_lat         NUMERIC,
    center_lon         NUMERIC,
    created_at         TIMESTAMPTZ DEFAULT NOW(),
    updated_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX ghn_tenant_idx ON geo_hierarchy_nodes(tenant_id);
CREATE INDEX ghn_parent_idx ON geo_hierarchy_nodes(parent_id);
CREATE INDEX ghn_state_idx  ON geo_hierarchy_nodes(tenant_id, state_pcode);
CREATE INDEX ghn_pcode_idx  ON geo_hierarchy_nodes(pcode);
CREATE INDEX ghn_geom_idx   ON geo_hierarchy_nodes USING GIST(geom);
```
- Main tree structure for the geo hierarchy system
- `parent_id`: NULL for root nodes (direct children of state); `ON DELETE CASCADE` removes children automatically when parent is deleted
- `state_pcode`: always the root state (e.g., "KE004"), for fast per-state filtering
- `level_id`: FK to geo_hierarchy_levels (defines this node's type/position)
- `pcode`: auto-generated unique code like "RW02-DI001", "RW02-DI001-SE001"
- `constituent_pcodes`: array of assigned adm_features pcodes (leaf nodes) or child geo_hierarchy_nodes pcodes
- `geom`: pre-computed `ST_Union` of constituent geometries; auto-recomputed via `cascade_ancestors()`
- GIST index enables fast point-in-polygon lookups for /region endpoint

#### tenant_cache (persistent L2 cache)
```sql
CREATE TABLE tenant_cache (
    tenant_id  INTEGER NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    cache_key  TEXT    NOT NULL,
    payload    TEXT    NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (tenant_id, cache_key)
);
CREATE UNIQUE INDEX ON tenant_cache (tenant_id, cache_key);
```
- Survives nginx/docker restarts (unlike ngx.shared)
- `cache_key` values: `'hierarchy'`, `'hierarchy_raw'`, `'geojson'`
- Written on first ngx.shared miss; cleared on any admin write via `db.delete_tenant_cache(tenant_id)`

---

## 2. Geo Hierarchy API Endpoints

All endpoints are served by `tileserver/lua/admin-geo-hierarchy.lua`.
All require `X-Tenant-ID` header. Protected by `origin-whitelist.lua`.

### GET /admin/geo-hierarchy/levels

List all hierarchy levels for the tenant.

**Response** (200 OK):
```json
{
  "tenant_id": 12,
  "levels": [
    { "id": 5, "tenant_id": 12, "level_order": 1, "level_label": "District", "level_code": "DI" },
    { "id": 6, "tenant_id": 12, "level_order": 2, "level_label": "Sector",   "level_code": "SE" }
  ]
}
```

**SQL**: `SELECT * FROM geo_hierarchy_levels WHERE tenant_id = $1 ORDER BY level_order`

---

### POST /admin/geo-hierarchy/levels

Create a new hierarchy level.

**Request Body**:
```json
{ "level_order": 1, "level_label": "District", "level_code": "DI" }
```

**Response** (201 Created): the created level object.

**Errors**: 400 on missing fields; 409 on duplicate level_order or level_code per tenant.

---

### PUT /admin/geo-hierarchy/levels/:id

Update a level (label, code, or order). Dynamic UPDATE clause — only provided fields are changed.

**Response** (200 OK): updated level object. **404** if level not found for this tenant.

---

### DELETE /admin/geo-hierarchy/levels/:id

Delete a level and all nodes at that level. Invalidates all caches.

**Response** (200 OK): `{ "deleted": true }`

---

### GET /admin/geo-hierarchy/nodes

List all nodes for the tenant (flat list, JOINed with levels for label/order).

**Response** (200 OK):
```json
{
  "tenant_id": 12,
  "nodes": [
    {
      "id": 100,
      "parent_id": null,
      "state_pcode": "RW02",
      "level_id": 5,
      "pcode": "RW02-DI001",
      "name": "Gasabo",
      "color": "#3b82f6",
      "constituent_pcodes": ["RWD001", "RWD002"],
      "area_sqkm": 429.30,
      "center_lat": -1.848946,
      "center_lon": 30.073503,
      "level_order": 1,
      "level_label": "District",
      "created_at": "2024-01-01T00:00:00Z",
      "updated_at": "2024-01-01T00:00:00Z"
    }
  ]
}
```

**SQL**: `SELECT n.*, l.level_order, l.level_label FROM geo_hierarchy_nodes n JOIN geo_hierarchy_levels l ON l.id = n.level_id WHERE n.tenant_id = $1 ORDER BY l.level_order, n.name`

---

### POST /admin/geo-hierarchy/nodes

Create a new node. Auto-generates `pcode`. Computes geometry via `ST_MakeValid(ST_Multi(ST_Union(...)))`. Triggers `cascade_ancestors()` after creation.

**Request Body**:
```json
{
  "level_id": 5,
  "name": "Gasabo",
  "state_pcode": "RW02",
  "parent_id": null,
  "color": "#3b82f6",
  "constituent_pcodes": ["RWD001", "RWD002"]
}
```

**Response** (201 Created): created node object with computed `pcode`, `area_sqkm`, `center_lat`, `center_lon`.

**SQL** (insert with pcode sequence):
```sql
WITH seq_cte AS (
    SELECT COALESCE(MAX(
        CAST(REGEXP_REPLACE(pcode, '^.*-DI0*', '') AS INTEGER)
    ), 0) + 1 AS seq
    FROM geo_hierarchy_nodes
    WHERE parent_id IS NULL AND state_pcode = 'RW02'
      AND tenant_id = $1
      AND pcode ~ '.*-DI\d+$'
),
geom_cte AS (
    SELECT ST_MakeValid(ST_Multi(ST_Union(a.geom))) AS g
    FROM adm_features a WHERE a.pcode = ANY($5::text[])
),
geom_metrics AS (
    SELECT g,
           ROUND((ABS(ST_Area(g::geography)) / 1000000.0)::numeric, 2) AS area,
           ROUND(ST_Y(ST_Centroid(g))::numeric, 6) AS clat,
           ROUND(ST_X(ST_Centroid(g))::numeric, 6) AS clon
    FROM geom_cte
)
INSERT INTO geo_hierarchy_nodes(tenant_id, parent_id, state_pcode, level_id, pcode, name, color, constituent_pcodes, geom, area_sqkm, center_lat, center_lon)
SELECT $1, $2, $3, $4,
       $6 || '-' || 'DI' || LPAD(seq::text, 3, '0'),
       $7, $8, $5::text[], g, area, clat, clon
FROM seq_cte, geom_metrics
RETURNING *
```

**Implementation note:** In `admin-geo-hierarchy.lua`, the `seq_cte` `WHERE` clause is built from a **scoped predicate** (parent scope + `tenant_id` as needed). The live code avoids duplicating `AND tenant_id = $1` in the same subquery when that would bind the `$1` placeholder twice (Postgres error). The illustrative SQL above may still show `tenant_id = $1` for clarity.

---

### PUT /admin/geo-hierarchy/nodes/:id

Update name, color, or constituent_pcodes. If constituent_pcodes changes, recomputes geometry and triggers `cascade_ancestors()`. Dynamic UPDATE clause.

**Response** (200 OK): updated node object.

---

### DELETE /admin/geo-hierarchy/nodes/:id

Delete node. The `ON DELETE CASCADE` FK constraint automatically deletes all descendants.
After deletion: recomputes parent's `constituent_pcodes` + `geom` from remaining children, then calls `cascade_ancestors()`. Invalidates all caches.

**Response** (200 OK): `{ "deleted": true }`

---

### GET /admin/geo-hierarchy/raw-hierarchy

Returns the raw adm_features tree for the editor's left panel (states → LGAs → adm3+ children).
This is the same data as `/boundaries/hierarchy?raw=1` but bypasses the cache so the editor always sees fresh source data.

**Response**: same shape as `/boundaries/hierarchy?raw=1` (see section 8).

---

## 3. cascade_ancestors() — Recursive Ancestor Update

After any leaf node is created/modified, `cascade_ancestors(start_node_id)` walks up the parent chain recomputing each ancestor's `constituent_pcodes` and `geom`.

**Algorithm** (`admin-geo-hierarchy.lua`):

```lua
local function cascade_ancestors(start_node_id)
    local current_id = start_node_id
    local MAX_DEPTH = 10
    for _ = 1, MAX_DEPTH do
        -- Get parent_id of current node
        local pr = pg.exec(
            "SELECT parent_id FROM geo_hierarchy_nodes WHERE id = $1 AND tenant_id = $2",
            {current_id, tenant_id}
        )
        if not pr or #pr == 0 then break end
        local pid = pr[1].parent_id
        if not pid or pid == ngx.null then break end

        -- Recompute ancestor from its direct children
        pg.exec([[
            WITH child_pcodes AS (
                SELECT ARRAY(
                    SELECT DISTINCT UNNEST(constituent_pcodes)
                    FROM geo_hierarchy_nodes
                    WHERE parent_id = $1 AND constituent_pcodes IS NOT NULL
                ) AS pcodes
            ),
            geom_data AS (
                SELECT ST_MakeValid(ST_Multi(ST_Union(a.geom))) AS g
                FROM adm_features a, child_pcodes cp
                WHERE a.pcode = ANY(cp.pcodes)
                  AND cardinality(cp.pcodes) > 0
            )
            UPDATE geo_hierarchy_nodes SET
                constituent_pcodes = (SELECT pcodes FROM child_pcodes),
                geom       = (SELECT g FROM geom_data),
                area_sqkm  = (SELECT ROUND((ABS(ST_Area(g::geography)) / 1000000.0)::numeric, 2) FROM geom_data),
                center_lat = (SELECT ROUND(ST_Y(ST_Centroid(g))::numeric, 6) FROM geom_data),
                center_lon = (SELECT ROUND(ST_X(ST_Centroid(g))::numeric, 6) FROM geom_data),
                updated_at = NOW()
            WHERE id = $1
        ]], {pid})

        current_id = pid
    end
end
```

**Key points**:
- Walks parent chain by fetching `parent_id` iteratively
- For each ancestor: collects DISTINCT pcodes from all direct children's `constituent_pcodes`
- Computes union geometry from those constituent adm_features
- Stops at depth 10 or when reaching a root node (`parent_id IS NULL`)
- Non-fatal: errors are logged, don't block the original write

---

## 4. Pcode Generation

**Format**: `{parent_pcode}-{LEVEL_CODE}{sequence_padded_to_3}`

**Examples**:
- Root under state: `RW02-DI001`, `RW02-DI002`, `RW02-DI003`
- Nested under district: `RW02-DI001-SE001`, `RW02-DI001-SE002`

**Sequence logic**:
1. Find max existing sequence number at this level/parent via REGEXP_REPLACE
2. COALESCE to 0 if no existing siblings → first node gets sequence 1
3. LPAD to 3 digits: "1" → "001", "12" → "012"

**Parent scope condition**:
- If `parent_id` given: `parent_id = {id}` (nested node)
- If no `parent_id`: `parent_id IS NULL AND state_pcode = '{pcode}'` (root node under state)

---

## 5. Geometry Pipeline

All geometry operations follow this pattern:

```sql
ST_MakeValid(ST_Multi(ST_Union(a.geom))) AS computed_geom
```

**Each step**:
1. **`ST_Union(a.geom)`** — merges all constituent polygons into one shape
2. **`ST_Multi()`** — normalizes to MultiPolygon (wraps Polygon if needed; ensures column type consistency)
3. **`ST_MakeValid()`** — fixes invalid polygons (self-intersecting rings, wrong winding order from OSM data)

**Area calculation**:
```sql
ROUND((ABS(ST_Area(g::geography)) / 1000000.0)::numeric, 2)
```
- `::geography` computes area on the ellipsoid (accurate in meters)
- `ABS()` handles reversed winding order edge case
- Divides m² → km², rounded to 2 decimal places

**Why this matters**: Rwanda sector boundaries imported from OSM had 20 geometries with self-intersecting rings. Without `ST_MakeValid`, PostGIS throws `lwgeom_area_spher returned area < 0.0`. The `ABS()` prevents 502 errors on any residual winding issues.

---

## 6. Cache Architecture

### Three-Level Stack

| Level | Store | TTL | Cleared by |
|-------|-------|-----|------------|
| L1 | `ngx.shared` (per-worker RAM) | 86400s | nginx restart / `docker restart` |
| L2 | `tenant_cache` PostgreSQL table | permanent | any admin write |
| L3 | cold miss | — | always computes |

### Shared Dicts (`nginx-tenant-proxy.conf`)

```nginx
lua_shared_dict region_cache    16m;   -- /region endpoint (1h TTL)
lua_shared_dict hierarchy_cache  8m;   -- /boundaries/hierarchy (24h TTL)
lua_shared_dict geojson_cache   32m;   -- /boundaries/geojson (24h TTL)
```

### Cache Keys

| Endpoint | L1 key | L2 key | TTL |
|----------|--------|--------|-----|
| `/region` | `{tenant}:{lat:.4f}:{lon:.4f}` | — | 3600s |
| `/boundaries/hierarchy` | `h:{tenant_id}` | `hierarchy` | 86400s |
| `/boundaries/hierarchy?raw=1` | `h:{tenant_id}:raw` | `hierarchy_raw` | 86400s |
| `/boundaries/geojson` | `gj:{tenant_id}` | `geojson` | 86400s |

### Invalidation (`invalidate_cache()`)

Called on every POST/PUT/DELETE to levels or nodes:

```lua
local function invalidate_cache()
    -- L1: ngx.shared
    local hc = ngx.shared.hierarchy_cache
    if hc then
        hc:delete("h:" .. tenant_id)
        hc:delete("h:" .. tenant_id .. ":raw")
    end
    local gc = ngx.shared.geojson_cache
    if gc then gc:delete("gj:" .. tenant_id) end
    -- region_cache has no prefix scan; flush all (hierarchy edits are rare admin ops)
    local rc = ngx.shared.region_cache
    if rc then rc:flush_all() end
    -- L2: persistent DB cache
    db.delete_tenant_cache(tenant_id)
end
```

**Note**: `docker restart tileserver_nginx_1` clears L1 (`ngx.shared`). `openresty -s reload` does NOT clear it.

---

## 7. /boundaries/geojson Endpoint

**File**: `tileserver/lua/serve-geojson.lua`
**Query**: `boundary-db.lua → get_geo_nodes_geojson(tenant_id)`

Returns a GeoJSON FeatureCollection with five feature types:

| `feature_type` | Source | Condition |
|----------------|--------|-----------|
| `geo_node` | `geo_hierarchy_nodes` | has geometry |
| `state` | `adm_features` adm_level=1 | parent of scoped LGAs |
| `lga` | `adm_features` adm_level=2 | NOT assigned to any geo_node |
| `grouped_lga` | `adm_features` adm_level=2 | IS assigned to a geo_node |
| `ward` | `adm_features` adm_level≥3 | in tenant scope |

**Feature properties**:
```json
{
  "pcode": "RW02-DI001",
  "name": "Gasabo",
  "feature_type": "geo_node",
  "parent_pcode": "RW02",
  "color": "#3b82f6",
  "level_order": 1,
  "constituent_pcodes": "RWD001,RWD002"
}
```

**Cache flow** (serve-geojson.lua):
1. Check L1 `ngx.shared.geojson_cache` → HIT: return with `X-Cache: HIT`
2. Check L2 `tenant_cache` table → HIT: fill L1, return with `X-Cache: L2-HIT`
3. MISS: run PostGIS query, build GeoJSON via `table.concat(parts)`, write L1 + L2, return with `X-Cache: MISS`

**Headers**: `Content-Type: application/geo+json`, `Cache-Control: public, max-age=86400`, `Vary: X-Tenant-ID`

---

## 8. /boundaries/hierarchy Endpoint

**File**: `tileserver/lua/serve-hierarchy.lua`

Two branches selected by `?raw=1` parameter:

### Default branch (geo_hierarchy_nodes tree)

Returns country → states → [geo_nodes tree] → ungrouped LGAs → wards.

**Build algorithm**:
1. Fetch all `adm_features` in tenant scope (indexed by pcode and parent_pcode)
2. Fetch all `geo_hierarchy_nodes` (JOINed with levels; indexed by `"state:{pcode}"` for roots, `"id:{parent_id}"` for children)
3. Track `assigned_pcodes` — any pcode in any node's `constituent_pcodes`
4. For each state:
   - Recursively build geo node subtree with `build_node_children()`
   - At leaf nodes: attach constituent LGAs (fetched from adm_features by pcode)
   - Add ungrouped LGAs (not in `assigned_pcodes`) to state root
5. Cache result in L1 + L2

### Raw branch (`?raw=1`)

Pure adm_features tree for the editor's left panel. No geo_hierarchy_nodes.

**Build algorithm**:
1. Fetch all adm_features in tenant scope
2. Index adm2 by parent_pcode, adm3+ by parent_pcode
3. For each state: list LGAs, for each LGA recursively attach adm3+ children

**Response shape**:
```json
{
  "pcode": "RW",
  "name": "Rwanda",
  "states": [
    {
      "pcode": "RW02",
      "name": "City of Kigali",
      "lgas": [{ "pcode": "RWD001", "name": "Gasabo", "level_label": "District", "children": [...sectors] }],
      "children": [...geo_nodes or ungrouped lgas]
    }
  ]
}
```

---

## 9. /region Endpoint

**File**: `tileserver/lua/region-lookup.lua`

Point-in-polygon lookup returning the full administrative hierarchy chain.

**Steps**:
1. Validate `lat`/`lon` parameters
2. Check `region_cache` (key: `{tenant}:{lat:.4f}:{lon:.4f}`, TTL 3600s)
3. Lookup LGA via `ST_Contains` on `adm_features` (adm_level=2 in tenant scope)
4. Lookup deepest `geo_hierarchy_node` via `ST_Contains` (ordered by `level_order DESC LIMIT 1`)
5. If geo node found: fetch ancestor chain via recursive CTE
6. Build `adm_N` response keys (adm_0=country, adm_1=state, adm_{2+level_order}=each node, final=LGA)
7. Cache result, return JSON

**Point-in-polygon SQL** (uses GIST index):
```sql
SELECT n.id, n.pcode, n.name, n.color, n.parent_id, n.state_pcode,
       l.level_order, l.level_label
FROM geo_hierarchy_nodes n
JOIN geo_hierarchy_levels l ON l.id = n.level_id
WHERE n.tenant_id = $1
  AND n.geom IS NOT NULL
  AND ST_Contains(n.geom, ST_SetSRID(ST_MakePoint($3, $2), 4326))
ORDER BY l.level_order DESC
LIMIT 1
```

**Ancestor chain SQL** (recursive CTE):
```sql
WITH RECURSIVE chain AS (
    SELECT n.id, n.parent_id, n.pcode, n.name, n.color, n.state_pcode,
           l.level_order, l.level_label
    FROM geo_hierarchy_nodes n
    JOIN geo_hierarchy_levels l ON l.id = n.level_id
    WHERE n.id = $1
    UNION ALL
    SELECT n.id, n.parent_id, n.pcode, n.name, n.color, n.state_pcode,
           l.level_order, l.level_label
    FROM geo_hierarchy_nodes n
    JOIN geo_hierarchy_levels l ON l.id = n.level_id
    JOIN chain c ON n.id = c.parent_id
)
SELECT * FROM chain ORDER BY level_order ASC
```

**Response shapes**:

Geo node hit:
```json
{
  "found": true,
  "matched_level": "geo_node",
  "adm_0": { "pcode": "RW", "name": "Rwanda" },
  "adm_1": { "pcode": "RW02", "name": "City of Kigali" },
  "adm_3": { "pcode": "RW02-DI001", "name": "Gasabo", "color": "#3b82f6", "level_label": "District" },
  "adm_4": { "pcode": "RW02-DI001-SE001", "name": "Bumbogo", "color": "#3b82f6", "level_label": "Sector" },
  "adm_5": { "pcode": "RWD001", "name": "Gasabo" }
}
```

LGA only:
```json
{
  "found": true,
  "matched_level": "lga",
  "adm_0": { "pcode": "RW", "name": "Rwanda" },
  "adm_1": { "pcode": "RW02", "name": "City of Kigali" },
  "adm_4": { "pcode": "RWD001", "name": "Gasabo" }
}
```

---

## 10. Key Query Patterns

### Tenant-scoped adm_features
```sql
FROM adm_features a
JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = $1
WHERE a.adm_level = N
```

### Geometry union with validity fix
```sql
ST_MakeValid(ST_Multi(ST_Union(a.geom)))
```

### Point-in-polygon with GIST index
```sql
WHERE ST_Contains(geom, ST_SetSRID(ST_MakePoint($lon, $lat), 4326))
ORDER BY level_order DESC
LIMIT 1
```

### Recursive ancestor chain
```sql
WITH RECURSIVE chain AS (
    SELECT ... FROM geo_hierarchy_nodes WHERE id = $1
    UNION ALL
    SELECT ... FROM geo_hierarchy_nodes n JOIN chain c ON n.id = c.parent_id
)
SELECT * FROM chain ORDER BY level_order ASC
```

### Cascade recompute constituent_pcodes from children
```sql
WITH child_pcodes AS (
    SELECT ARRAY(
        SELECT DISTINCT UNNEST(constituent_pcodes)
        FROM geo_hierarchy_nodes
        WHERE parent_id = $1 AND constituent_pcodes IS NOT NULL
    ) AS pcodes
)
UPDATE geo_hierarchy_nodes
SET constituent_pcodes = (SELECT pcodes FROM child_pcodes)
WHERE id = $1
```

---

## 11. Full System Data Flow

```
Client (MapLibre GL JS)
  → X-Tenant-ID header → nginx 8080
    ├─ /tiles/*              → Martin (3000) — PMTiles byte-range
    ├─ /boundaries/geojson   → serve-geojson.lua
    │    └─ L1 ngx.shared → L2 tenant_cache → PostGIS (geo_nodes + states + LGAs + wards)
    ├─ /boundaries/hierarchy → serve-hierarchy.lua
    │    ├─ ?raw=1 → pure adm_features tree (editor left panel)
    │    └─ default → geo_hierarchy_nodes tree + ungrouped LGAs
    │         └─ L1 ngx.shared → L2 tenant_cache → PostGIS
    ├─ /region               → region-lookup.lua
    │    └─ L1 ngx.shared → PostGIS (ST_Contains on adm_features + geo_hierarchy_nodes)
    └─ /admin/geo-hierarchy  → admin-geo-hierarchy.lua
         ├─ GET levels/nodes  → direct DB query
         ├─ POST/PUT nodes    → INSERT/UPDATE + cascade_ancestors() + invalidate_cache()
         └─ DELETE nodes      → DELETE (CASCADE to children) + recompute parent + invalidate_cache()
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `tileserver/lua/admin-geo-hierarchy.lua` | Geo hierarchy CRUD: levels + nodes, cascade_ancestors, pcode generation |
| `tileserver/lua/serve-geojson.lua` | GET /boundaries/geojson with L1/L2 cache |
| `tileserver/lua/serve-hierarchy.lua` | GET /boundaries/hierarchy (geo_node tree + raw adm_features) |
| `tileserver/lua/region-lookup.lua` | GET /region — point-in-polygon, geo_node chain, ngx.shared cache |
| `tileserver/lua/boundary-db.lua` | All PostGIS queries: geojson, hierarchy, region, zone, geo-node spatial |
| `tileserver/lua/pg-pool.lua` | pgmoon connection pool (trust auth, keepalive 30s/100 per worker) |
| `tileserver/nginx-tenant-proxy.conf` | Tenant routing, CORS, lua_shared_dict declarations |
| `scripts/schema.sql` | Full PostGIS schema with all tables, indexes, FK constraints |
