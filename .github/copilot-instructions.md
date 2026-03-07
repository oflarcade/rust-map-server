# Vector Map Tiles Server - Copilot Instructions

Multi-tenant vector map tile server for NewGlobe Education's School Pin Map. Replaces Google Maps (~$350-700/mo) with self-hosted PMTiles + Martin tile server (~$5-15/mo). Serves OSM-based map tiles via HTTP range requests to education programs across Africa and India.

## Build, Test & Lint Commands

### Tile Generation (Windows PowerShell)
```powershell
.\scripts\setup.ps1                                    # Download Planetiler + OSM data
.\scripts\generate-single.ps1 <country>               # e.g., nigeria, kenya
.\scripts\generate-all.ps1                            # All 7 countries
.\scripts\generate-states.ps1 <profile> <country> ... # States (profiles: full|minimal|terrain)
.\scripts\generate-states.ps1 -List <profile> <country> # List available states
.\scripts\generate-tenants.ps1                        # Full tile generation + tenant config
```

Memory allocation per country: liberia/rwanda/car=2GB, uganda/kenya=4GB, nigeria=6GB, india=8GB. Set `-Force` flag to skip existing tile checks.

### Server & Validation (Windows)
```powershell
.\scripts\run-martin.ps1                 # Start Martin tile server on port 3001
npx serve . -p 8000                     # Browser testing: open test/*.html
```

On Linux/macOS: Use `martin --config tileserver/martin-config.yaml` for Docker (port 3000).

### Configuration Validation
```powershell
node scripts/validate-config.js [--strict] [--no-check-files]  # Validate tenant routing config
```

No automated unit test suite—testing is browser-based via HTML files in `test/`.

## Architecture

### High-Level Data Flow
```
Client Browser (MapLibre GL JS)
    ↓ [X-Tenant-ID header]
Nginx (port 8080)
    ↓ [routes via map directive to Martin source]
Martin (port 3000/3001)
    ↓ [HTTP range request into .pmtiles file]
PMTiles response (protobuf tiles)
```

### Tile Generation Pipeline
```
Geofabrik .osm.pbf → Planetiler (Java)
                      ├─ --maxzoom=14 --exclude-layers=poi,housenumber
                      └─ --storage=ram (Windows) | --storage=mmap (Unix)
                        → <country>-detailed.pmtiles (base map: roads, water, buildings)

HDX COD-AB adm1 GeoJSON → bounds-from-hdx.py (Python)
                          → data/sources/<country>-states/bounds.json + *.json
                            → Planetiler with custom profile
                              → <country>-<state>.pmtiles (state tiles)
```

### Multi-Tenant Routing
1. **Client** sends `X-Tenant-ID` header (e.g., "11" for EKOEXCEL Lagos)
2. **Nginx** map directive (`nginx-tenant-proxy.conf`) looks up tenant ID → Martin source name
3. **Martin** config (`martin-config-windows.yaml`) defines sources → .pmtiles file paths
4. Result: One HTTP endpoint (port 8080) handles all tenants via header-based routing

### Two-Layer Map Rendering
Every map displays:
- **Layer 1**: Base tiles from `<country>-detailed.pmtiles` (OSM: roads, water, buildings, places)
- **Layer 2**: Boundary tiles from OSM/HDX-derived boundary PMTiles

For state-specific requests, uses `<country>-<state>-admin.pmtiles` instead of country-level tiles.

## Key Conventions

### File Naming
- **OSM data**: `<country>-latest.osm.pbf` (e.g., `nigeria-latest.osm.pbf`)
- **Planetiler output**: `<country>-detailed.pmtiles` (base map with roads/water/buildings)
- **Boundary tiles**: `<country>-admin.pmtiles` (country outline) + `<country>-<state>-admin.pmtiles` (state-level)
- **HDX COD-AB**: `data/hdx/<country>_adm1.geojson` (state level); state bounds: `data/sources/<country>-states/bounds.json` (from bounds-from-hdx.py)

### Script Conventions (PowerShell)
- Use `$ErrorActionPreference = "Stop"` for fail-fast behavior
- Compute paths relative to script location: `$BaseDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)`
- Color-coded logging: Blue (INFO), Green (SUCCESS), Yellow (WARN), Red (ERROR), Cyan (STEP)
- Scripts are idempotent (check before download/generate) unless `-Force` flag used

### Generation Parameters
- **Zoom levels**: 0-12 for countries, 10-14 for states (overzoom to 15 supported)
- **Simplification tolerance**: 0.1 (~60% size reduction)
- **Excluded layers**: poi, housenumber (not needed for maps)
- **Included layers by profile**:
  - `full`: water, roads, landuse, landcover, buildings, places
  - `terrain`: water, landuse, landcover, buildings, places
  - `minimal`: water, places
  - `terrain-roads`: water, roads, landuse, landcover, places

### State Name Matching
State names in `generate-states.ps1` must match HDX `adm1_name` property values **exactly** (case-sensitive). Example: "Lagos", "Edo", "Bayelsa" for Nigeria. Use `-List` flag to discover available state names:
```powershell
.\scripts\generate-states.ps1 -List full nigeria
```

### Configuration Files
- **`tileserver/nginx-tenant-proxy.conf`**: Nginx map directive (X-Tenant-ID → Martin source)
- **`tileserver/martin-config.yaml`**: Docker production config (port 3000)
- **`tileserver/martin-config-windows.yaml`**: Windows dev config (port 3001)
- **`scripts/bounds-from-hdx.py`**: HDX state bounds and GeoJSON
  - Usage: `python3 bounds-from-hdx.py <hdx_adm1.geojson> <output_dir> <state1> [state2] ...`
  - Outputs: bounds.json + per-state GeoJSON (adm1_name from HDX COD-AB)

### Tenant Configuration
Each tenant maps to:
1. A unique tenant ID (integer, e.g., 1, 3, 11, 14)
2. One or more Martin source names (routing target)
3. A geographic region (country or state)

Example: Tenant ID 11 (EKOEXCEL) → source "nigeria-lagos" → `pmtiles/nigeria-lagos.pmtiles`

## Adding a New Tenant

1. Generate required tiles: `.\scripts\generate-single.ps1 <country>` or `.\scripts\generate-states.ps1 <profile> <country> <state1> <state2>`
2. Add mapping in `tileserver/nginx-tenant-proxy.conf`: `"<tenant_id>" "<martin_source>";`
3. Add PMTiles source in both Martin configs:
   - `tileserver/martin-config.yaml`: `<source_name>: { path: pmtiles/<file>.pmtiles }`
   - `tileserver/martin-config-windows.yaml`: Same structure
4. Validate: `node scripts/validate-config.js`
5. Restart Martin service or use `.\scripts\run-martin.ps1` for testing

## Supported Tenants

- **7 countries**: Liberia, Nigeria (full + 4 states), Kenya, Uganda, Rwanda, CAR, India
- **13 tenant IDs**: Bridge Kenya (1), Bridge Uganda (2), Bridge Nigeria (3), Bridge Liberia (4), Bridge India (5), EdoBEST Edo (9), EKOEXCEL Lagos (11), Rwanda EQUIP (12), Kwara Learn (14), Manipur Education (15), and others

## Prerequisites

- **Java 17+**: Planetiler (check: `java -version`)
- **Python 3**: bounds-from-hdx.py (check: `python3 --version`)
- **Martin**: Tile server (Windows: included in `tileserver/martin.exe`, Linux: install binary)
- **Nginx**: Web proxy (Docker setup in `tileserver/docker-compose.tenant.yml`, or standalone)
- **Node.js**: Config validation script
