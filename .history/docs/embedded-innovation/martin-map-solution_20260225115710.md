# Martin-Based Vector Tile Server (Embedded Innovation Notes)

This note outlines how to stand up a Martin-backed vector tile server that serves PMTiles, and how to consume it from MapLibre on web and mobile. It avoids program-specific tenant naming and focuses on reusable patterns.

## Goals
- Ship a self-hosted, low-cost tile service (HTTP range requests against PMTiles) instead of third-party map APIs.
- Support multiple logical tenants via header-based routing, while keeping a single public endpoint.
- Work across browsers and mobile clients using MapLibre.

## Stack Snapshot
- **Tile generation**: Planetiler (OSM → PMTiles), plus optional boundary tiles via tippecanoe.
- **Server**: Martin (vector tile server) fronted by Nginx for header-based routing.
- **Clients**: MapLibre GL JS (web) and MapLibre Native (React Native/iOS/Android) with tenant header injection.

## Prerequisites
- Java 17+ (Planetiler), Python 3 (helper scripts), Node.js (validation/tools), Docker (for Martin/Nginx), osmium-tool/tippecanoe if generating boundaries from OSM.
- Data: country/state `.osm.pbf` files (e.g., from Geofabrik) and optional boundary GeoJSON (HDX COD, geoBoundaries, or OSM-extracted).

## Data Preparation
1) **Download OSM extracts**
   - Source: https://download.geofabrik.de/ (country-level `.osm.pbf`).

2) **Generate base PMTiles** (full country, z0-14)
   - Use Planetiler or the repository scripts, e.g.: `./scripts/generate-tiles.sh --country <country>`
   - Typical flags: `--maxzoom=14 --exclude-layers=poi,housenumber`; storage `ram` on Windows, `mmap` on Unix.

3) **Generate state/region tiles** (if needed)
   - For region-focused tiles, run state generation with wider min-zoom (e.g., z6) so the map is visible when zoomed out.
   - Example: `./scripts/generate-tiles.sh --country <country> --states` (adjust per script options).

4) **Boundary tiles (optional but recommended)**
   - Sources: HDX COD (preferred, CC BY-IGO), geoBoundaries (CC BY 4.0), or OSM-extracted boundaries.
   - Pipeline example: boundary GeoJSON → tippecanoe → `<country>-boundaries.pmtiles`.
   - Keep boundary tiles separate from base tiles; serve as an additional vector source.

5) **File placement for Martin auto-discovery**
   - Put all active `.pmtiles` in the top-level `pmtiles/` directory (and boundary tiles in `boundaries/` if configured). Avoid leaving corrupt files; Martin fails fast on bad PMTiles.

## Server Setup (Martin + Nginx)
1) **Martin config**
   - Use `tileserver/martin-config.yaml` (Docker) or `tileserver/martin-config-windows.yaml` (Windows) as a base.
   - Martin scans `pmtiles/` (and `boundaries/` if enabled) and exposes each file as a source named after the filename (without extension).

2) **Nginx routing pattern (multi-tenant)**
   - Single public endpoint (e.g., `/tiles/{z}/{x}/{y}`) with header `X-Tenant-ID` → Nginx `map` directive → Martin source name.
   - Pseudocode (no tenant names):
     ```nginx
     map $http_x_tenant_id $tenant_source {
       default "";          # fallthrough -> 400
       "<id1>" "<source1>";
       "<id2>" "<source2>";
       # ... add more
     }

     location /tiles/ {
       if ($tenant_source = "") { return 400; }
       proxy_pass http://martin/tiles/$tenant_source/$1/$2/$3;  # adjust upstream/vars as in config
     }
     ```
   - Keep boundary routing similar: tenant source → boundary source map → `/boundaries/{z}/{x}/{y}`.

3) **Docker compose example**
   - Use `tileserver/docker-compose.tenant.yml` as a template: Martin on 3000, Nginx on 8080, both mounting `pmtiles/` (+ `boundaries/`).

4) **Health checks**
   - `GET /health` (proxy) or `GET /catalog` (Martin) to verify sources are discovered.

## Client Integration (MapLibre)
### Web (MapLibre GL JS)
- Add `X-Tenant-ID` via `transformRequest` so only tenant-aware calls carry the header:
```javascript
import maplibregl from "maplibre-gl";

const TILE_SERVER_URL = "http://localhost:8080"; // Nginx endpoint
const tenantId = "<tenant-id>";

const map = new maplibregl.Map({
  container: "map",
  style: {
    version: 8,
    sources: {
      "base-tiles": {
        type: "vector",
        tiles: [`${TILE_SERVER_URL}/tiles/{z}/{x}/{y}`],
        maxzoom: 14,
      },
      "boundary-tiles": {
        type: "vector",
        tiles: [`${TILE_SERVER_URL}/boundaries/{z}/{x}/{y}`],
        maxzoom: 14,
      },
    },
    layers: [
      // add base layers
      // add boundary stroke/fill layers with source-layer names from your PMTiles
    ],
  },
  transformRequest: (url) => {
    if (url.startsWith(TILE_SERVER_URL)) {
      return { url, headers: { "X-Tenant-ID": tenantId } };
    }
    return { url };
  },
});
```
- If you host Martin directly (no Nginx), you can use per-source URLs instead of headers, but header-based routing keeps one endpoint.

### Mobile (MapLibre Native)
- MapLibre Native (React Native, Android, iOS) supports custom request transformers/interceptors to add headers.
- **React Native (maplibre-gl)** example:
```javascript
import MapboxGL from "@rnmapbox/maps"; // MapLibre Native-compatible fork

MapboxGL.setAccessToken(null);
MapboxGL.setConnected(true);
MapboxGL.addCustomHeader("X-Tenant-ID", tenantId);

<MapboxGL.MapView style={{ flex: 1 }}>
  <MapboxGL.VectorSource
    id="base"
    tileUrlTemplates={[`${TILE_SERVER_URL}/tiles/{z}/{x}/{y}`]}>
    {/* add layers using the source */}
  </MapboxGL.VectorSource>
</MapboxGL.MapView>
```
- **Android/iOS native**: use `ResourceOptions#addCustomHeader` (or platform equivalent) to inject `X-Tenant-ID` for tile requests.
- Mobile caveats: keep maxzoom at 14, prefer simplified styles, and consider offline PMTiles packaging for low-bandwidth scenarios.

### Alternate data access patterns
- **Direct PMTiles delivery**: host the `.pmtiles` file behind a CDN and use the `pmtiles` protocol client-side (MapLibre + pmtiles plugin) to avoid server CPU; still can gate by signed URLs.
- **MBTiles/SQLite offline**: for strictly offline mobile, bundle tiles in the app (size trade-offs).
- **Boundary-only layer**: keep boundary tiles small and overlay on any base source if bandwidth is constrained.

## Multi-Tenant Design Notes (no program-specific names)
- Use numeric or short string tenant IDs; map to Martin source names via Nginx `map` directives.
- Keep Martin source names identical to PMTiles filenames for auto-discovery.
- Separate base and boundary sources; boundary map can default to a country-level source when a state-level source is missing.
- Validation: ensure every tenant ID has both base and boundary mappings, or return explicit `400 INVALID_TENANT_ID` / `404 NO_BOUNDARY_DATA`.

## Validation & Testing
- `node scripts/validate-config.js` (if present) to check routing consistency.
- `curl http://localhost:3000/catalog` to confirm sources are visible.
- `npx serve . -p 8000` then open `test/test-tenant-tiles.html` to exercise requests with headers.
- Watch Martin logs for `InvalidMagicNumber` (indicates a corrupt PMTiles file).

## Operations & Hardening
- Keep PMTiles immutable; replace via new filename + Nginx map update, then reload.
- Add caching at Nginx/CDN for vector tiles; honor `Range` requests.
- Enforce header presence; return `400` on missing/invalid tenant IDs.
- Monitor upstream latency and cache hit rates; PMTiles are efficient but benefit from CDN edge caching.
- Document memory guidance: smaller countries can run with ~2–4 GB RAM; larger extracts need more during generation (Planetiler).

## Quick Start Checklist
- [ ] Generate or obtain base PMTiles and optional boundary PMTiles.
- [ ] Place files in `pmtiles/` (and `boundaries/` if used).
- [ ] Configure Nginx `map` blocks for tenant → source and boundary routing.
- [ ] Run Martin (Docker or native) with provided config; verify `/catalog`.
- [ ] Integrate MapLibre (web/mobile) with `X-Tenant-ID` header injection.
- [ ] Smoke-test tiles and boundaries at multiple zoom levels; handle missing data gracefully.
