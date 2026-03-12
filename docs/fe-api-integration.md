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
- Custom zones (ST_Union of constituent LGAs)
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

Returns the full admin hierarchy for the tenant as a nested tree.

```
GET /boundaries/hierarchy?t={tenantId}
X-Tenant-ID: 11
```

**Add `?t={tenantId}` to bust browser cache per-tenant.**
Cached server-side in nginx shared memory (24h, invalidated on zone change).

Response:
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
          "color": "#3b82f6",
          "parent_pcode": "NG025",
          "constituent_pcodes": ["NG025003", "NG025005"]
        }
      ]
    }
  ]
}
```

`zones` array is only present on a state when the tenant has zones defined for it. LGAs that belong to a zone are **excluded** from the `lgas` array.

---

## Region Lookup (point-in-polygon)

Given lat/lon, returns the full administrative path containing that point. Checks custom zones first, falls back to raw LGA.

```
GET /region?lat={lat}&lon={lon}
X-Tenant-ID: 11
```

Result is cached server-side for 1 hour per tenant+coordinate (truncated to 4 decimal places).

**Response — LGA hit:**
```json
{
  "found": true,
  "matched_level": "lga",
  "adm_0": { "pcode": "NG", "name": "Nigeria" },
  "adm_1": { "pcode": "NG025", "name": "Lagos" },
  "adm_4": { "pcode": "NG025014", "name": "Lagos Island" }
}
```

**Response — Zone hit:**
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

Field presence rules:
- `adm_0` — always present when `found: true`
- `adm_1` — always present when `found: true`
- `adm_3` — only when `matched_level === "zone"`
- `adm_4` — present for LGA hits; also present for zone hits when the specific constituent LGA can be spatially determined

---

## Boundary Search

Case-insensitive partial name search across states, LGAs, and zones for the tenant.

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

`adm_level` values: `1` = state, `2` = LGA, `3` = custom zone

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
    "color": "#3b82f6",
    "parent_pcode": "NG025",
    "constituent_pcodes": ["NG025003", "NG025005"],
    "created_at": "2026-03-10T00:00:00Z"
  }
]
```

### Create zone
```
POST /admin/zones
X-Tenant-ID: 11
Content-Type: application/json

{
  "zone_name": "Mainland Cluster",
  "color": "#3b82f6",
  "parent_pcode": "NG025",
  "constituent_pcodes": ["NG025003", "NG025005"]
}
```

Geometry is computed server-side as `ST_Union` of the constituent LGA polygons. Hierarchy cache is invalidated automatically.

### Update zone
```
PUT /admin/zones/{zone_id}
X-Tenant-ID: 11
Content-Type: application/json

{
  "zone_name": "Updated Name",
  "color": "#ef4444",
  "constituent_pcodes": ["NG025003", "NG025005", "NG025007"]
}
```

### Delete zone
```
DELETE /admin/zones/{zone_id}
X-Tenant-ID: 11
```

Constituent LGAs return to ungrouped automatically.

---

## Browser Cache Notes

- Hierarchy and GeoJSON responses have `Cache-Control: public, max-age=86400` + `Vary: X-Tenant-ID`
- Always append `?t={tenantId}` to hierarchy and geojson URLs so each tenant gets a unique URL in the browser cache — prevents one tenant's cached response being served for another
- `/region` has `Cache-Control: no-store` (can't cache, each lat/lon is unique)

---

## Typical FE Session Flow

```
1. Load hierarchy:         GET /boundaries/hierarchy?t={id}   → build sidebar tree
2. Load boundary GeoJSON:  GET /boundaries/geojson?t={id}     → render boundary polygons
3. Load map tiles:         MapLibre vector source /tiles/{z}/{x}/{y}
4. User searches:          GET /boundaries/search?q={term}    → show results, fly to feature
5. User drops pin:         GET /region?lat=&lon=              → show admin path tooltip
6. Admin creates zone:     POST /admin/zones                  → refresh hierarchy + geojson
```

---

## Current FE Stack (existing Vue app)

```
View/
  src/
    config/
      tenants.ts         — tenant ID → source/boundary mapping
      urls.ts            — VITE_PROXY_URL, VITE_MARTIN_URL env vars
    composables/
      useTileInspector.ts — shared state: map, tenant selection, hierarchy, boundary data
    map/
      inspectorStyle.ts  — buildInspectorStyle(), loadMartinTileMetadata()
    views/
      TileInspector.vue  — developer tile inspector (sidebar + map + layer toggle)
      ZoneManager.vue    — operator zone creation tool
    components/
      BoundaryExplorer.vue — tenant selector, search, hierarchy tree sidebar
      LayerControl.vue     — layer visibility toggle
      MapContainer.vue     — map wrapper
```

Build env vars required:
```bash
VITE_PROXY_URL=http://35.239.86.115:8080   # nginx API
VITE_MARTIN_URL=http://35.239.86.115:3000  # Martin tile metadata
```
