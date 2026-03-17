# Map Server — FE API Integration Reference

All requests go to `http://35.239.86.115:8080` and require the `X-Tenant-ID` header.

---

## Authentication

Every request needs:
```http
X-Tenant-ID: <tenant_id>
```

No bearer token. Origin whitelist enforced server-side.

---

## Tenants

| ID | Program | Country | Notes |
|----|---------|---------|-------|
| 1  | Bridge Kenya | Kenya | Full country |
| 2  | Bridge Uganda | Uganda | Full country |
| 3  | Bridge Nigeria | Nigeria | Lagos + Osun states |
| 4  | Bridge Liberia | Liberia | Full country |
| 5  | Bridge India AP | India | Andhra Pradesh state |
| 9  | EdoBEST | Nigeria | Edo state |
| 11 | EKOEXCEL | Nigeria | Lagos state |
| 12 | Rwanda EQUIP | Rwanda | Full country |
| 14 | Kwara Learn | Nigeria | Kwara state |
| 15 | Manipur Education | India | Manipur state |
| 16 | Bayelsa Prime | Nigeria | Bayelsa state |
| 17 | Espoir CAR | Central African Republic | Full country |
| 18 | Jigawa Unite | Nigeria | Jigawa state |

---

## Map Tiles

Served via Martin (port 3000, proxied through nginx on 8080).

```
GET /tiles/{z}/{x}/{y}
X-Tenant-ID: 11
```

Use as a MapLibre vector tile source:
```js
{
  type: 'vector',
  tiles: ['http://35.239.86.115:8080/tiles/{z}/{x}/{y}'],
  minzoom: 0,
  maxzoom: 14,
}
```

Source layers available: `water`, `landcover`, `landuse`, `transportation`, `building`, `place`, `boundary`

---

## Boundary Tiles (vector, for map overlay)

```
GET /boundaries/{z}/{x}/{y}
X-Tenant-ID: 11
```

Vector tile source — scoped to tenant's geographic area. Source layer name varies by country; inspect via Martin catalog at `http://35.239.86.115:3000/catalog`.

---

## Boundary GeoJSON

Returns a GeoJSON FeatureCollection of all boundaries for the tenant:
- Custom zones (ST_Union of constituent LGAs/features)
- States/ADM1 features
- LGAs not grouped into any zone

```
GET /boundaries/geojson?t={tenantId}
X-Tenant-ID: 11
```

**Add `?t={tenantId}` to bust browser cache per-tenant.**

Response:
```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": { "type": "MultiPolygon", "coordinates": [...] },
      "properties": {
        "pcode": "NG025",
        "name": "Lagos",
        "feature_type": "state",      // "state" | "lga" | "zone"
        "parent_pcode": "NG",
        "color": null,                 // hex string for zones, null otherwise
        "constituent_pcodes": null     // comma-separated string for zones, null otherwise
      }
    }
  ]
}
```

`feature_type` values:
- `"zone"` — custom operator-defined grouping (has `color`, `constituent_pcodes`)
- `"state"` — ADM1 region
- `"lga"` — ADM2 region not in any zone

---

## Hierarchy Tree

Returns the full admin hierarchy for the tenant as a nested tree. The tree is variable-depth — tenants with adm3+ data (wards, senatorial districts, etc.) will have a `children` array on each state, in addition to the backward-compatible `lgas` and `zones` arrays.

```
GET /boundaries/hierarchy?t={tenantId}
X-Tenant-ID: 11
```

**Add `?t={tenantId}` to bust browser cache per-tenant.**
Cached server-side in nginx shared memory (24h, invalidated on zone change).

**Response — basic (no adm3+ data, e.g. Lagos):**
```json
{
  "pcode": "NG",
  "name": "Nigeria",
  "source": "PostGIS",
  "state_count": 1,
  "lga_count": 17,
  "zone_count": 2,
  "states": [
    {
      "pcode": "NG025",
      "name": "Lagos",
      "area_sqkm": 3577.0,
      "center_lat": 6.548,
      "center_lon": 3.398,
      "lgas": [
        {
          "pcode": "NG025001",
          "name": "Agege",
          "area_sqkm": 37.5,
          "center_lat": 6.621,
          "center_lon": 3.324
        }
      ],
      "zones": [
        {
          "zone_pcode": "NG025-Z01",
          "zone_name": "Mainland Cluster",
          "zone_type_label": "Operational Zone",
          "zone_level": 1,
          "children_type": "lga",
          "color": "#3b82f6",
          "parent_pcode": "NG025",
          "constituent_pcodes": ["NG025003", "NG025005"]
        }
      ],
      "children": []
    }
  ]
}
```

**Response — deep hierarchy (e.g. Jigawa with adm3+ imported):**
```json
{
  "pcode": "NG",
  "name": "Nigeria",
  "states": [
    {
      "pcode": "NG018",
      "name": "Jigawa",
      "lgas": [...],
      "zones": [...],
      "children": [
        {
          "pcode": "NG018-SD01",
          "name": "Jigawa North-West",
          "level": 3,
          "level_label": "Senatorial District",
          "area_sqkm": 5200.0,
          "center_lat": 12.4,
          "center_lon": 9.1,
          "children": [
            {
              "pcode": "NG018-FC01",
              "name": "Birnin Kudu/Buji",
              "level": 4,
              "level_label": "Federal Constituency",
              "children": [
                {
                  "pcode": "NG018001",
                  "name": "Birnin Kudu",
                  "level": 2,
                  "level_label": null,
                  "children": []
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

Key fields in state nodes:
- `lgas` — backward-compat array of adm2 LGAs not grouped into a zone (always present)
- `zones` — backward-compat array of zones directly under this state (always present, may be empty)
- `children` — new recursive tree of adm3+ features and nested zones (always present, may be empty)

Key fields in `children` nodes:
- `pcode` — admin pcode or zone_pcode
- `name` / `zone_name` — display name
- `level` — adm_level (2 for LGA, 3 for senatorial/ward/sector, 4 for constituency/cell, etc.)
- `level_label` — human-readable type (`"Senatorial District"`, `"Federal Constituency"`, `"Ward"`, `"Emirate"`, etc.) — `null` for standard adm1/adm2
- `zone_type_label` — operator-assigned label for zone nodes (e.g. `"Operational Zone"`)
- `zone_level` — nesting depth for zone nodes (1 = directly under state)
- `children_type` — `"lga"` or `"zone"` for zone nodes
- `children` — nested children array (recursive)

`zones` array is only present on a state when the tenant has zones defined for it. LGAs that belong to a zone are **excluded** from the `lgas` array.

---

## Region Lookup (point-in-polygon)

Given lat/lon, returns the full administrative path containing that point. Checks custom zones first (deepest zone wins), then falls back to raw LGA.

```
GET /region?lat={lat}&lon={lon}
X-Tenant-ID: 11
```

Result is cached server-side for 1 hour per tenant+coordinate (truncated to 4 decimal places).

**Response — LGA hit (no zones):**
```json
{
  "found": true,
  "matched_level": "lga",
  "adm_0": { "pcode": "NG", "name": "Nigeria" },
  "adm_1": { "pcode": "NG025", "name": "Lagos" },
  "adm_4": { "pcode": "NG025014", "name": "Lagos Island" }
}
```

**Response — single-level zone hit (zone_level=1):**
```json
{
  "found": true,
  "matched_level": "zone",
  "adm_0": { "pcode": "KE", "name": "Kenya" },
  "adm_1": { "pcode": "KE004", "name": "Tana River" },
  "adm_3": { "pcode": "KE004-Z01", "name": "Zone 1", "color": "#3b82f6" },
  "adm_4": { "pcode": "KE004019", "name": "Galole" }
}
```

**Response — multi-level zone hit (zone_level=1 + zone_level=2):**
```json
{
  "found": true,
  "matched_level": "zone",
  "adm_0": { "pcode": "NG", "name": "Nigeria" },
  "adm_1": { "pcode": "NG018", "name": "Jigawa" },
  "adm_3": { "pcode": "NG018-Z01", "name": "North Cluster", "color": "#3b82f6" },
  "adm_4": { "pcode": "NG018-Z01-S01", "name": "Sub-cluster A", "color": "#ef4444" },
  "adm_5": { "pcode": "NG018001", "name": "Birnin Kudu" }
}
```

**Response — not found (outside tenant scope):**
```json
{
  "found": false,
  "error": "Coordinates do not fall within any known boundary for this tenant",
  "code": "REGION_NOT_FOUND",
  "lat": 0.0,
  "lon": 0.0
}
```

**adm_N key mapping for zones:**
- `zone_level=1` → `adm_3`; LGA at `adm_4`
- `zone_level=2` → `adm_4`; LGA at `adm_5` (parent zone at `adm_3`)
- `zone_level=N` → `adm_{N+2}`; LGA at `adm_{N+3}`

Field presence rules:
- `adm_0` — always present when `found: true`
- `adm_1` — always present when `found: true`
- `adm_3`..`adm_N` — one key per zone in the matched zone chain (ordered by zone_level)
- LGA key — `adm_{max_zone_level+3}` or `adm_4` for non-zone hits; present when the specific LGA is spatially determined

---

## Boundary Search

Case-insensitive partial name search across states, LGAs, zones, and adm3+ features for the tenant.

```
GET /boundaries/search?q={query}
X-Tenant-ID: 11
```

Returns up to 50 results, ordered by admin level then name.

Response:
```json
{
  "query": "lagos",
  "count": 3,
  "results": [
    {
      "pcode": "NG025",
      "name": "Lagos",
      "adm_level": 1,
      "parent_pcode": "NG"
    },
    {
      "pcode": "NG025014",
      "name": "Lagos Island",
      "adm_level": 2,
      "parent_pcode": "NG025"
    }
  ]
}
```

`adm_level` values: `1` = state, `2` = LGA, `3+` = adm3/ward/senatorial/etc., zone results appear as `adm_level: 3`

---

## Zone Management (admin)

### List zones
```
GET /admin/zones
X-Tenant-ID: 11
```
```json
[
  {
    "zone_id": 1,
    "zone_pcode": "NG025-Z01",
    "zone_name": "Mainland Cluster",
    "zone_type_label": "Operational Zone",
    "zone_level": 1,
    "children_type": "lga",
    "color": "#3b82f6",
    "parent_pcode": "NG025",
    "constituent_pcodes": ["NG025003", "NG025005"],
    "created_at": "2026-03-10T00:00:00Z"
  }
]
```

New fields (all optional/defaulted for backward compatibility):
- `zone_type_label` — human-readable zone type label (e.g. `"Operational Zone"`, `"Cluster"`)
- `zone_level` — nesting depth: `1` = directly under state, `2` = child of another zone, etc.
- `children_type` — `"lga"` if `constituent_pcodes` are LGA/adm feature pcodes; `"zone"` if they are child zone pcodes

### Create zone
```
POST /admin/zones
X-Tenant-ID: 11
Content-Type: application/json

{
  "zone_name": "Mainland Cluster",
  "zone_type_label": "Operational Zone",
  "zone_level": 1,
  "children_type": "lga",
  "color": "#3b82f6",
  "parent_pcode": "NG025",
  "constituent_pcodes": ["NG025003", "NG025005"]
}
```

All new fields are optional:
- `zone_type_label` — defaults to `null`
- `zone_level` — defaults to `1`
- `children_type` — defaults to `"lga"`
- `zone_pcode` — if omitted, auto-generated as `{parent_pcode}-Z{nn}`

Geometry is computed server-side as `ST_Union` of the constituent feature polygons (works for both LGA pcodes and zone pcodes when `children_type="zone"`). Hierarchy cache is invalidated automatically.

**Creating a nested zone (zone whose children are other zones):**
```json
{
  "zone_name": "North Sub-cluster",
  "zone_type_label": "Sub-cluster",
  "zone_level": 2,
  "children_type": "zone",
  "color": "#ef4444",
  "parent_pcode": "NG025-Z01",
  "constituent_pcodes": ["NG025-Z02", "NG025-Z03"]
}
```

### Update zone
```
PUT /admin/zones/{zone_id}
X-Tenant-ID: 11
Content-Type: application/json

{
  "zone_name": "Updated Name",
  "zone_type_label": "Cluster",
  "zone_level": 1,
  "color": "#ef4444",
  "constituent_pcodes": ["NG025003", "NG025005", "NG025007"]
}
```

All fields are optional — only provided fields are updated.

### Delete zone
```
DELETE /admin/zones/{zone_id}
X-Tenant-ID: 11
```

Constituent LGAs return to ungrouped automatically.

---

## Creating Custom Zones — Step-by-Step Guide

### Via the Zone Manager UI

1. Navigate to `http://35.239.86.115:8080` → Zone Manager tab
2. Select tenant from the dropdown
3. The map shows all LGAs for that tenant's state(s)
4. Click LGA polygons to add them to the pending zone (they highlight)
5. Fill in:
   - **Zone Name** — e.g. "North Cluster"
   - **Zone Type** — optional label like "Operational Zone", "Cluster"
   - **Parent** — select a state (for level-1 zones) or an existing zone (for nested zones)
   - **Color** — hex color picker for map display
6. Click **Create Zone** — geometry is computed and the zone appears immediately on the map
7. To edit: click the zone in the list, modify, click Update
8. To delete: click the zone in the list, click Delete (constituent LGAs become available again)

### Via API (curl examples)

**Create a level-1 zone grouping LGAs under a state:**
```bash
curl -X POST http://35.239.86.115:8080/admin/zones \
  -H "X-Tenant-ID: 18" \
  -H "Content-Type: application/json" \
  -d '{
    "zone_name": "Jigawa North Cluster",
    "zone_type_label": "Operational Zone",
    "zone_level": 1,
    "children_type": "lga",
    "color": "#3b82f6",
    "parent_pcode": "NG018",
    "constituent_pcodes": ["NG018001", "NG018002", "NG018003"]
  }'
```

**Create a level-2 zone grouping existing zones:**
```bash
curl -X POST http://35.239.86.115:8080/admin/zones \
  -H "X-Tenant-ID: 18" \
  -H "Content-Type: application/json" \
  -d '{
    "zone_name": "North Super-cluster",
    "zone_type_label": "Regional Cluster",
    "zone_level": 2,
    "children_type": "zone",
    "color": "#7c3aed",
    "parent_pcode": "NG018-Z01",
    "constituent_pcodes": ["NG018-Z02", "NG018-Z03"]
  }'
```

**List current zones for a tenant:**
```bash
curl -H "X-Tenant-ID: 18" http://35.239.86.115:8080/admin/zones | jq .
```

**Verify hierarchy tree after zone creation:**
```bash
curl -H "X-Tenant-ID: 18" "http://35.239.86.115:8080/boundaries/hierarchy?t=18" | jq '.states[0].zones'
```

**Note:** After zone changes, the hierarchy cache is automatically invalidated. If the old hierarchy still appears, restart nginx to fully clear shared memory:
```bash
sudo docker restart tileserver_nginx_1
```

---

## Jigawa Tenant (ID 18) Setup Guide

Tenant 18 (Jigawa Unite) covers Jigawa state, Nigeria (pcode `NG018`).

### Current data status

| Level | Data | Status | Source |
|-------|------|--------|--------|
| ADM1 — State | Jigawa (NG018) | Imported | HDX Nigeria COD-AB |
| ADM2 — LGA | 27 LGAs | Imported | HDX Nigeria COD-AB |
| ADM3 — Senatorial Districts | 3 districts | Available (NE NG only) | HDX Nigeria adm3 |
| ADM4 — Federal Constituencies | ~9 constituencies | Pending | INEC/HDX download |
| ADM5 — Wards | ~287 wards | Pending download | GRID3 |

**Note:** HDX Nigeria adm3 only covers Borno, Adamawa, and Yobe states (NE Nigeria). Jigawa adm3 data requires the INEC electoral dataset or GRID3.

### Importing Jigawa boundary data

**Step 1 — Import available HDX adm3 (NE Nigeria wards, validation only):**
```bash
node scripts/import-hdx-to-pg.js
```
This imports adm3 for Borno/Adamawa/Yobe. Validates the pipeline works.

**Step 2 — Download INEC electoral boundaries:**
```powershell
# Search HDX for the correct package ID
.\scripts\ps1\download-inec.ps1 -Search

# Or place files manually in data\inec\:
#   nigeria_senatorial.geojson    (senatorial districts - adm3)
#   nigeria_constituencies.geojson (federal constituencies - adm4)
```

If the HDX package is not found, obtain from:
- `https://data.humdata.org/dataset?q=nigeria+senatorial+electoral`
- `https://grid3.org/resources/results?q=nigeria` (wards, adm5)

**Step 3 — Import INEC data (Jigawa only):**
```bash
node scripts/import-inec-to-pg.js --state NG018
# Full dry-run first:
node scripts/import-inec-to-pg.js --state NG018 --dry-run
```

**Step 4 — Import GRID3 wards (when available):**
Place `nigeria_wards.geojson` (from GRID3) in `data/inec/`, then:
```bash
node scripts/import-inec-to-pg.js --state NG018
```

**Step 5 — Verify in database:**
```sql
SELECT adm_level, level_label, COUNT(*)
FROM adm_features
WHERE country_code = 'NG' AND pcode LIKE 'NG018%'
GROUP BY 1, 2 ORDER BY 1;
```

**Step 6 — Verify hierarchy API:**
```bash
curl -H "X-Tenant-ID: 18" "http://35.239.86.115:8080/boundaries/hierarchy?t=18" | \
  jq '.states[0] | {pcode, name, lga_count: (.lgas | length), children_count: (.children | length)}'
```

### Apply schema migration (production)

The schema migration is idempotent — safe to run on existing installations:
```sql
-- Run on production PostgreSQL:
ALTER TABLE adm_features ADD COLUMN IF NOT EXISTS level_label VARCHAR(100);
ALTER TABLE zones ADD COLUMN IF NOT EXISTS zone_type_label VARCHAR(100);
ALTER TABLE zones ADD COLUMN IF NOT EXISTS zone_level SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE zones ADD COLUMN IF NOT EXISTS children_type VARCHAR(4) NOT NULL DEFAULT 'lga';
```

Or apply via the full schema file (also idempotent):
```bash
# On GCP VM:
docker exec -i tileserver_postgres_1 psql -U mapserver -d mapserver < scripts/schema.sql
```

---

## Browser Cache Notes

- Hierarchy and GeoJSON responses have `Cache-Control: public, max-age=86400` + `Vary: X-Tenant-ID`
- Always append `?t={tenantId}` to hierarchy and geojson URLs so each tenant gets a unique URL in the browser cache — prevents one tenant's cached response being served for another
- `/region` has `Cache-Control: no-store` (can't cache, each lat/lon is unique)

---

## Typical FE Session Flow

```
1. Load hierarchy:         GET /boundaries/hierarchy?t={id}   -> build sidebar tree (variable depth)
2. Load boundary GeoJSON:  GET /boundaries/geojson?t={id}     -> render boundary polygons
3. Load map tiles:         MapLibre vector source /tiles/{z}/{x}/{y}
4. User searches:          GET /boundaries/search?q={term}    -> show results, fly to feature
5. User drops pin:         GET /region?lat=&lon=              -> show admin path tooltip (dynamic adm_N keys)
6. Admin creates zone:     POST /admin/zones                  -> refresh hierarchy + geojson
```

---

## Current FE Stack (existing Vue app)

```
View/
  src/
    config/
      tenants.ts         - tenant ID -> source/boundary mapping
      urls.ts            - VITE_PROXY_URL, VITE_MARTIN_URL env vars
    composables/
      useTileInspector.ts - shared state: map, tenant selection, hierarchy, boundary data
    map/
      inspectorStyle.ts  - buildInspectorStyle(), loadMartinTileMetadata()
    views/
      TileInspector.vue  - developer tile inspector (sidebar + map + layer toggle)
      ZoneManager.vue    - operator zone creation tool (supports variable-depth zones)
    components/
      BoundaryExplorer.vue - tenant selector, search, hierarchy tree sidebar
      LayerControl.vue     - layer visibility toggle
      MapContainer.vue     - map wrapper
```

Build env vars required:
```bash
VITE_PROXY_URL=http://35.239.86.115:8080   # nginx API
VITE_MARTIN_URL=http://35.239.86.115:3000  # Martin tile metadata
```

---

## Deployment

### Deploy Lua backend changes
```powershell
# From Windows, run in PowerShell:
gcloud compute scp --zone=us-central1-a `
  tileserver/lua/boundary-db.lua `
  tileserver/lua/serve-hierarchy.lua `
  tileserver/lua/region-lookup.lua `
  tileserver/lua/admin-zones.lua `
  martin-tileserver:/home/omarlakhdhar_gmail_com/rust-map-server/tileserver/lua/

gcloud compute ssh martin-tileserver --zone=us-central1-a `
  --command="sudo docker restart tileserver_nginx_1"
```

### Apply schema migration on production
```powershell
gcloud compute ssh martin-tileserver --zone=us-central1-a --command="
  docker exec -i tileserver_postgres_1 psql -U mapserver -d mapserver -c \"
    ALTER TABLE adm_features ADD COLUMN IF NOT EXISTS level_label VARCHAR(100);
    ALTER TABLE zones ADD COLUMN IF NOT EXISTS zone_type_label VARCHAR(100);
    ALTER TABLE zones ADD COLUMN IF NOT EXISTS zone_level SMALLINT NOT NULL DEFAULT 1;
    ALTER TABLE zones ADD COLUMN IF NOT EXISTS children_type VARCHAR(4) NOT NULL DEFAULT 'lga';
  \"
"
```

### Deploy Vue app
```powershell
cd View
$env:VITE_PROXY_URL="http://35.239.86.115:8080"
$env:VITE_MARTIN_URL="http://35.239.86.115:3000"
npm run build

gcloud compute scp --zone=us-central1-a --recurse `
  dist/index.html dist/assets `
  martin-tileserver:/home/omarlakhdhar_gmail_com/rust-map-server/View/dist/
```
