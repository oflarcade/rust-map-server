# NewGlobe Vector Tile Server — Technical Reference

## Stack Summary

| Component | Technology | Role |
|---|---|---|
| Tile server | Martin v0.14 (MapLibre) | Serves vector tiles from PMTiles files via HTTP |
| Reverse proxy | OpenResty (Nginx + Lua) | Tenant routing, origin whitelist, CORS |
| Tile format | PMTiles | Single-file tile archive, HTTP range-request served |
| Base tile generation | Planetiler (Java) | Converts OSM PBF → PMTiles |
| Boundary conversion | tippecanoe (Docker) | Converts GeoJSON → PMTiles |
| OSM extraction | ogr2ogr / GDAL (Docker) | Extracts admin boundaries from PBF |
| Map renderer | MapLibre GL JS | Client-side vector tile rendering |
| Container runtime | Docker Compose | Martin + OpenResty stack |

---

## Architecture

### Request Flow

```
Client (MapLibre GL JS)
  └─ X-Tenant-ID: 11
       └─ OpenResty :8080
            ├─ Lua: origin whitelist check
            ├─ nginx map: tenant ID → Martin source name
            └─ proxy_pass → Martin :3000
                  └─ HTTP range request → nigeria-lagos.pmtiles (disk)
                        └─ protobuf vector tile (~2–15 KB)
```

### Two-Layer Map Design

Every map renders two independent tile sources simultaneously:

```
MapLibre style
  ├─ source: "base"      → /tiles/{z}/{x}/{y}      (roads, water, buildings, places)
  └─ source: "boundary"  → /boundaries/{z}/{x}/{y}  (state borders, LGA borders)
```

Each source is a separate PMTiles file, separately requested, independently styled. The client assembles them. Either layer can be toggled, replaced, or re-styled without touching the other.

---

## Data Sources

### OpenStreetMap — Base Tiles and Boundary Tiles

All production tile data originates from **OpenStreetMap**.

- **Format at rest:** `.osm.pbf` (Geofabrik regional extracts)
- **Download:** `scripts/setup.ps1` pulls from `download.geofabrik.de`
- **License:** ODbL (Open Database License) — commercial use permitted, attribution required

Base tiles and boundary tiles are both derived from the same `.osm.pbf` files through separate pipelines (see below).

### GADM — Developer Reference Only

GADM 4.1 (Global Administrative Areas, UC Davis) is downloaded and used **exclusively in the developer tile inspector** (`test/tile-inspector.html`) as a visual comparison reference against OSM boundaries.

- **License:** Non-commercial/academic only
- **Not served to any client application**
- **Not part of the production tile stack**
- Files live in `gadm/` and are gitignored

---

## PMTiles Format

PMTiles is a single-file archive where every map tile (a geographic slice at a given zoom/x/y coordinate) is stored at a deterministic byte offset. Serving a tile is a single HTTP range request into the file — no database query, no tile index, no cache layer.

```
GET /nigeria-lagos/10/583/480
  → Martin computes byte offset for tile 10/583/480
  → pread(fd, offset, length) from nigeria-lagos.pmtiles
  → returns protobuf-encoded vector tile
```

Martin holds no state beyond the open file descriptor. All tile files are mounted read-only into the container. Replacing a tile file and restarting Martin is the entire deploy process.

---

## Tile Generation Pipeline

### Base Tiles (OSM PBF → PMTiles)

```
osm-data/<country>-latest.osm.pbf
  └─ Planetiler (Java, --storage=ram on Windows)
       ├─ --bounds=<state bbox>   (state tiles)
       ├─ --minzoom / --maxzoom
       ├─ --only-layers=<profile>
       └─ pmtiles/<country>-<state>.pmtiles
```

**Profiles** control which OSM layers are included:

| Profile | Layers | Use case |
|---|---|---|
| `full` | water, landuse, landcover, building, transportation, place | Default |
| `terrain-roads` | water, landuse, landcover, transportation, place | No buildings |
| `terrain` | water, landuse, landcover, place | No roads, no buildings |
| `minimal` | water, place | Smallest output |

**Memory allocation** (configured per country in generation scripts):

| Country | Heap |
|---|---|
| Liberia / Rwanda / CAR | 2 GB |
| Uganda / Kenya | 4 GB |
| Nigeria | 6 GB |
| India | 8 GB |

### Boundary Tiles — Non-Nigeria Countries

```
osm-data/<country>-latest.osm.pbf
  └─ generate-osm-boundaries.ps1
       └─ ogr2ogr (GDAL via Docker: ghcr.io/osgeo/gdal)
            └─ filter: boundary=administrative AND admin_level IN (4,5,6)
                 └─ boundaries/<country>-boundaries.geojson
                      └─ generate-country-boundaries.ps1
                           └─ tippecanoe (Docker: felt-tippecanoe:local)
                                └─ boundaries/<country>-boundaries.pmtiles
```

### Boundary Tiles — Nigeria (Per-Tenant Split)

Nigeria boundary tiles are split per tenant because each program covers a different state:

```
boundaries/nigeria-boundaries.geojson  (all Nigeria states + LGAs from OSM)
  └─ scripts/split-boundaries.js (Node.js)
       └─ boundaries/nigeria-{state}-boundaries.geojson  (one per tenant)
            └─ generate-nigeria-boundaries.ps1
                 └─ tippecanoe → boundaries/nigeria-{state}-boundaries.pmtiles
```

`split-boundaries.js` matches state features by `admin_level=4` and selects LGA features (`admin_level=6`) whose centroid falls within the state bounding box.

---

## Tenant Routing

### Nginx Map Directive

Nginx translates the `X-Tenant-ID` request header to a Martin source name using a `map` directive. The client never knows the source name.

```nginx
map $http_x_tenant_id $tenant_source {
    "11"  "nigeria-lagos";
    "1"   "kenya-detailed";
    ...
}
```

A second map translates the resolved source name to its boundary source:

```nginx
map $tenant_source $boundary_source {
    "nigeria-lagos"    "nigeria-lagos-boundaries";
    "kenya-detailed"   "kenya-boundaries";
    ...
}
```

### Tenant → Source Mapping

| Tenant ID | Program | Base tile | Boundary tile |
|---|---|---|---|
| 1 | Bridge Kenya | kenya-detailed | kenya-boundaries |
| 2 | Bridge Uganda | uganda-detailed | uganda-boundaries |
| 3 | Bridge Nigeria (Lagos+Osun) | nigeria-lagos-osun | nigeria-lagos-osun-boundaries |
| 4 | Bridge Liberia | liberia-detailed | liberia-boundaries |
| 5 | Bridge India (AP) | india-andhrapradesh | india-boundaries |
| 9 | EdoBEST | nigeria-edo | nigeria-edo-boundaries |
| 11 | EKOEXCEL | nigeria-lagos | nigeria-lagos-boundaries |
| 12 | Rwanda EQUIP | rwanda-detailed | rwanda-boundaries |
| 14 | Kwara Learn | nigeria-kwara | nigeria-kwara-boundaries |
| 15 | Manipur Education | india-manipur | india-boundaries |
| 16 | Bayelsa Prime | nigeria-bayelsa | nigeria-bayelsa-boundaries |
| 17 | Espoir CAR | central-african-republic-detailed | central-african-republic-boundaries |
| 18 | Jigawa Unite | nigeria-jigawa | nigeria-jigawa-boundaries |

---

## Tile Coverage

### Country-Scoped vs State-Scoped

| Mode | File example | Zoom | Behaviour |
|---|---|---|---|
| Country | kenya-detailed.pmtiles | z0–14 | Full country, never goes blank |
| State (current) | nigeria-lagos.pmtiles | z6–14 | State visible from z6, blank below |
| State (legacy) | nigeria-lagos.pmtiles | z10–14 | Blank below z10 — do not use |

State tiles at z0–5 are deliberately omitted — at those zoom levels the country tile provides better context. State tiles start at z6 where the state is large enough to fill the viewport.

### Full Country with Context Bleed

For programs that benefit from cross-state context (e.g. Lagos/Osun spanning two states), the full Nigeria country tile can be routed instead of a state-scoped tile. The boundary overlay still scopes the admin highlighting to the tenant's states. This gives geographic context when zoomed out while preserving tenant-specific boundary data.

---

## Security — Origin Whitelist

All `/tiles/` and `/boundaries/` requests pass through a Lua script (`tileserver/lua/origin-whitelist.lua`) before reaching Martin.

### Logic

```
Request arrives at OpenResty
  ├─ OPTIONS (preflight) → 204, allow (browser CORS handshake)
  ├─ Origin header present
  │    ├─ in ALLOWED table → pass, set Access-Control-Allow-Origin
  │    └─ not in ALLOWED  → 403 ORIGIN_BLOCKED
  ├─ Referer header present (no Origin)
  │    ├─ extracted origin in ALLOWED → pass
  │    └─ not in ALLOWED             → 403 ORIGIN_BLOCKED
  └─ No Origin, no Referer (server-to-server / monitoring) → pass
```

### Whitelist Configuration

Edit `tileserver/lua/origin-whitelist.lua`:

```lua
local ALLOWED = {
    ["http://localhost:5173"]      = true,   -- Vite dev server
    ["http://localhost:3000"]      = true,   -- tile inspector
    ["https://app.newglobe.com"]   = true,   -- production FE
}
```

Restart only the proxy after a whitelist change — no rebuild needed:

```bash
docker compose -f tileserver/docker-compose.tenant.yml restart nginx
```

### Unprotected Endpoints

- `GET /health` — always open, required for load balancer probes
- `GET /catalog` — Martin direct on port 3000, not behind OpenResty; **port 3000 must be firewalled in production**

---

## Docker Stack

```yaml
# tileserver/docker-compose.tenant.yml
martin:   ghcr.io/maplibre/martin:v0.14.2   # tile server
nginx:    openresty/openresty:alpine         # reverse proxy + Lua
```

**Volume mounts:**

| Host path | Container path | Service |
|---|---|---|
| `pmtiles/` | `/data/pmtiles:ro` | Martin |
| `boundaries/` | `/data/boundaries:ro` | Martin |
| `tileserver/martin-config.yaml` | `/config/martin-config.yaml:ro` | Martin |
| `tileserver/nginx-tenant-proxy.conf` | `/etc/nginx/conf.d/default.conf:ro` | OpenResty |
| `tileserver/lua/` | `/etc/nginx/lua:ro` | OpenResty |

Martin auto-discovers all `.pmtiles` files under `/data/pmtiles` and `/data/boundaries` — no manual source registration. Source names match filenames without extension.

### Common Operations

```bash
# Start stack
docker compose -f tileserver/docker-compose.tenant.yml up -d

# Apply whitelist change (no rebuild)
docker compose -f tileserver/docker-compose.tenant.yml restart nginx

# Apply new .pmtiles file
docker compose -f tileserver/docker-compose.tenant.yml restart martin

# Tail Martin logs
docker compose -f tileserver/docker-compose.tenant.yml logs -f martin

# Verify source catalog
curl http://localhost:3000/catalog

# Health check
curl http://localhost:8080/health
```

---

## API

| Endpoint | Auth | Description |
|---|---|---|
| `GET /tiles/{z}/{x}/{y}` | `X-Tenant-ID` header | Base map vector tile |
| `GET /boundaries/{z}/{x}/{y}` | `X-Tenant-ID` header | Admin boundary vector tile |
| `GET /health` | None | Health probe — always returns 200 |
| `GET /catalog` | None (port 3000 only) | Martin source list |

### Error Codes

| Code | HTTP | Meaning |
|---|---|---|
| `MISSING_TENANT_ID` | 400 | No `X-Tenant-ID` header |
| `INVALID_TENANT_ID` | 400 | Tenant ID not in nginx map |
| `ORIGIN_BLOCKED` | 403 | Request origin not in Lua whitelist |
| `TILE_NOT_FOUND` | 404 | No tile data at this z/x/y (coordinates outside tile bounds) |
| `NO_BOUNDARY_DATA` | 404 | No boundary source mapped for this tenant |
| `UPSTREAM_ERROR` | 502 | Martin is down or unreachable |

---

## Frontend Integration

```javascript
const map = new maplibregl.Map({
  container: "map",
  style: {
    version: 8,
    glyphs: "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf",
    sources: {
      "base": {
        type: "vector",
        tiles: ["https://tiles.example.com/tiles/{z}/{x}/{y}"],
        maxzoom: 14,
      },
      "boundary": {
        type: "vector",
        tiles: ["https://tiles.example.com/boundaries/{z}/{x}/{y}"],
        maxzoom: 14,
      },
    },
    layers: [ /* MapLibre style layers referencing source: "base" and source: "boundary" */ ],
  },
  transformRequest: (url) => {
    if (url.includes("tiles.example.com")) {
      return { url, headers: { "X-Tenant-ID": String(tenantId) } };
    }
  },
});
```

The `transformRequest` hook injects `X-Tenant-ID` on every tile request automatically — both base and boundary tiles use the same header through the same proxy.

---

## OSM Boundary Feature Schema

Properties available on boundary tile features:

| Property | OSM value | Meaning |
|---|---|---|
| `admin_level` | `"4"` | State-level boundary |
| `admin_level` | `"6"` | LGA-level boundary |
| `name` | string | Feature name |
| `osm_id` | string | OSM relation ID |
| `boundary` | `"administrative"` | Always present (filter used during extraction) |

GADM tiles (dev inspector only) use a different schema: `NAME_1` (state), `NAME_2` (LGA), `GID_1`, `GID_2` — no `admin_level` property.

---

## DevOps — Data and Recovery

### What Lives Where

```
pmtiles/                      ← Martin reads these (production-critical)
  *.pmtiles                   ← base map tiles (country or state scoped)
  z6/                         ← Nigeria regenerated tiles (copy to root to activate)

boundaries/
  *.pmtiles                   ← boundary tiles (production-critical)
  *.geojson                   ← source for tippecanoe (regenerable from OSM)

osm-data/
  *-latest.osm.pbf            ← OSM source (re-downloadable, not backed up)

gadm/
  *.json                      ← GADM reference data (re-downloadable, not backed up)
```

### Recovery Priority

| Data | Action if lost | Time |
|---|---|---|
| `pmtiles/*.pmtiles` | Re-run `generate-all.ps1` + `generate-nigeria-tenants.ps1` | 2–8 hrs |
| `boundaries/*.pmtiles` | Re-run boundary generation pipeline | 10–30 min |
| `osm-data/*.osm.pbf` | Re-run `setup.ps1` | 15–60 min download |
| `boundaries/*.geojson` | Re-run `generate-osm-boundaries.ps1` + `split-boundaries.js` | 5–10 min |
| Docker images | `docker compose pull` + `docker build` for tippecanoe | 2–5 min |

**Only `.pmtiles` files warrant backup.** Everything else is re-downloadable or regeneratable from source.

### Backup Options

**Object storage (recommended):** Martin supports reading PMTiles directly from S3-compatible storage. Hosting files in Cloudflare R2 or AWS S3 gives built-in redundancy and eliminates local disk as a single point of failure:

```yaml
# martin-config.yaml
pmtiles:
  sources:
    - s3://bucket/pmtiles/
    - s3://bucket/boundaries/
```

**rsync:** For a simple periodic backup to a secondary server:

```bash
rsync -av pmtiles/ backup:/backups/pmtiles/
rsync -av boundaries/*.pmtiles backup:/backups/boundaries/
```

### Full Recovery Sequence (from scratch)

```bash
git clone <repo> && cd <repo>
.\scripts\setup.ps1                           # Planetiler + OSM PBF downloads
.\scripts\download-gadm.ps1                   # GADM (dev reference only)
.\scripts\generate-all.ps1                    # Base tiles all countries
.\scripts\generate-nigeria-tenants.ps1        # Nigeria state tiles z6–14
.\scripts\generate-osm-boundaries.ps1         # OSM boundary GeoJSONs (non-Nigeria)
.\scripts\generate-country-boundaries.ps1     # Boundary PMTiles (non-Nigeria)
node scripts/split-boundaries.js              # Nigeria: split per tenant
.\scripts\generate-nigeria-boundaries.ps1     # Nigeria: boundary PMTiles
docker compose -f tileserver/docker-compose.tenant.yml up -d
```

---

## Directory Structure

```
tileserver/
  docker-compose.tenant.yml       Docker stack definition
  nginx-tenant-proxy.conf         Tenant routing + API endpoints (OpenResty)
  lua/
    origin-whitelist.lua          Origin whitelist security (Lua)
  martin-config.yaml              Martin config (Docker)
  martin-config-windows.yaml      Martin config (Windows local dev)

scripts/
  setup.ps1                       Download Planetiler + OSM PBF files
  generate-all.ps1                Generate base tiles for all countries
  generate-single.ps1             Generate base tiles for one country
  generate-states.ps1             Generate state-scoped base tiles
  generate-tenants.ps1            Generate all tenant tiles (configurable profile)
  generate-nigeria-tenants.ps1    Nigeria state tiles from z6
  generate-lagos-osun.ps1         Combined Lagos+Osun tiles (tenant 3)
  generate-osm-boundaries.ps1     Extract admin boundary GeoJSON from OSM PBF
  generate-country-boundaries.ps1 Convert boundary GeoJSON → PMTiles (non-Nigeria)
  generate-nigeria-boundaries.ps1 Convert Nigeria boundary GeoJSON → PMTiles
  generate-gadm-boundaries.ps1    GADM → PMTiles (dev inspector only)
  download-gadm.ps1               Download GADM data (dev reference only)
  filter-gadm.py                  Filter GADM by state, compute bounding boxes
  split-boundaries.js             Split nigeria-boundaries.geojson per tenant
  run-martin.ps1                  Run Martin locally (Windows dev)
  Dockerfile.tippecanoe           Builds felt/tippecanoe Docker image

test/
  tile-inspector.html             Developer tile inspector (Vue + MapLibre)
  test-tenant-tiles.html          Tenant tile debug page
  test-vue-maplibre.html          Vue + MapLibre integration test

boundaries/
  nigeria-boundaries.pmtiles      Nigeria admin boundaries (OSM-derived)
  nigeria-*-boundaries.geojson    Per-tenant split GeoJSON (generated)

gadm/
  <country>_1.json                GADM admin level 1 (states)
  <country>_2.json                GADM admin level 2 (LGAs/districts)
  states/                         Filtered per-state data
```

---

## Status

### Complete

- Base tile generation pipeline for all 7 countries
- Nigeria state boundary tiles (all 6 tenants) — OSM-derived, per-tenant split
- Boundary tile pipeline for Kenya, Uganda, Liberia, Rwanda, CAR
- Tenant routing via Nginx map directive
- Origin whitelist via Lua (OpenResty)
- State tile zoom fix — regenerated at z6–14
- Docker Compose production stack
- Developer tile inspector with OSM/GADM source toggle, feature explorer
- GADM comparison layer (dev inspector only, isolated from production)

### Pending

- Boundary tile generation for India (Andhra Pradesh, Manipur)
- Port 3000 firewall rule in production (Martin direct access should be internal only)
- Production domain + TLS termination in front of OpenResty
- Attribution display in client map ("© OpenStreetMap contributors" — ODbL requirement)
- Monitoring / uptime alerting
