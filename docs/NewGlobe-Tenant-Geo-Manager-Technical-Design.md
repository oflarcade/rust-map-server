# NewGlobe Tenant Geo Manager
## Technical Design

---

## Table of Contents

1. [Introduction](#introduction)
2. [Problem Statement](#problem-statement)
3. [Solution](#solution)
4. [Technical Implementation Considerations](#technical-implementation-considerations)
5. [Rollout Plan](#rollout-plan)
6. [Technical Risks](#technical-risks)
7. [Appendix](#appendix)

---

## Introduction

NewGlobe operates programs across multiple countries in Africa and Asia — Kenya, Uganda, Nigeria, Liberia, India, Rwanda, and the Central African Republic. Each program ("tenant") has its own geographic footprint: a set of administrative boundaries — states, districts, LGAs, wards — that define where it operates and how it organizes its territory.

This initiative began with building a self-hosted vector tile server using Martin (Rust) to serve OpenStreetMap-based base map tiles and administrative boundary tiles for Spotlight. Boundary data was sourced from HDX COD-AB (the UN Humanitarian Data Exchange's official administrative boundary datasets) for each tenant's country, imported into PostgreSQL/PostGIS, and served as vector tiles via Martin's PMTiles support.

Once that boundary data was live in PostGIS, it became the foundation for a more powerful capability: a Hierarchy Editor that lets us — via a small Vue frontend — define each tenant's geographic hierarchy level by level, using whatever ADM naming the program uses (e.g., "Emirate", "LGA", "Federal District", "Senatorial District"). Those definitions are stored as geo hierarchy levels and nodes in PostGIS, with geometry automatically computed via `ST_Union` of constituent administrative units. Every edit propagates instantly to the `/region` endpoint — a point-in-polygon lookup that always reflects the latest hierarchy state for each tenant.

The entire backend — tenant routing, boundary queries, hierarchy tree assembly, region lookup, and cache management — is powered by Lua running inside OpenResty, collocated with the tile-serving layer.

The result is a shared geo platform: any internal application that needs map data, boundary lookups, or geographic hierarchy — including the current Tenant Geo Manager (the Vue app built to manage and explore each tenant), and potentially future versions of Situation Room and EWF — can plug into the tile server and API layer, with per-tenant data scoping handled transparently.

---

## Problem Statement

Before this initiative, there was no shared, database-backed geographic infrastructure across NewGlobe's internal applications. Administrative boundary data for each tenant's country existed only as flat HDX GeoJSON files — static assets with no query layer, no shared access, and no API.

What was needed was a single, database-backed geo platform that any internal application could independently use based on its own requirements:

- **HDX boundary data lived as GeoJSON files** — not in a database, so it couldn't be queried, shared, or served to multiple apps programmatically
- **No shared geo platform** — Spotlight, and future apps all need or might need map and boundary data, but there was no single server they could independently call based on their own requirement — one might need the `/region` lookup, another might need the hierarchy tree, another might just want to draw a choropleth from the GeoJSON. That flexibility didn't exist.
- **Per-tenant hierarchy was not expressible** — each program had its own ADM naming and territory structure, and the current NewGlobe region API had no way to express or store that per-tenant structure
- **No live region lookup tied to tenant hierarchy** — there was no point-in-polygon API that understood a tenant's custom geographic structure. Any coordinate-to-boundary resolution had to be hardcoded or approximated, with no way to reflect changes to how a program organized its territory

Beyond serving raw boundaries, there was also no system to express per-tenant geographic hierarchies. Each program organizes its territory differently — using its own ADM level naming conventions (e.g., "Emirate", "Senatorial District", "FC") and its own grouping of administrative units. Those definitions needed to live in a database, preferably manageable through a UI, and propagate automatically to all downstream API consumers without requiring manual file updates or per-app changes.

---

## Solution

### 1. Tile Generation — Martin + PMTiles per Tenant

The base map and boundary tiles are generated offline and served by **Martin** (a Rust-based vector tile server) via the **PMTiles** format — a single-file archive that supports HTTP byte-range requests, eliminating the need for a tile database.

For each tenant, the process is:

- **OSM base tiles** — the country's `.osm.pbf` file is downloaded from the OpenStreetMap Geofabrik mirror and processed by **Planetiler** (Java) to produce a `.pmtiles` file covering the tenant's country or state at zoom levels 0–14
- **Boundary tiles** — HDX COD-AB GeoJSON files are downloaded per country via `download-hdx.ps1 / download-hdx.sh` and converted into a boundary `.pmtiles` file
- **Output** — both tile files are placed in the `pmtiles/` directory; Martin auto-discovers all `.pmtiles` files in that directory on startup

Martin is configured with a tenant-to-source mapping: an nginx `map` directive translates the incoming `X-Tenant-ID` header into the correct Martin source name, so each tenant is routed to their own tile file transparently.

---

### 2. Data Pipeline — HDX to PostGIS

Once tiles are generated, the same HDX boundary data is imported into **PostgreSQL/PostGIS** to power all the API endpoints. The pipeline is:

1. `download-hdx.ps1 / download-hdx.sh` — downloads HDX COD-AB GeoJSON files (`adm1`, `adm2`, `adm3`...) for each country into the `hdx/` directory
2. `import-hdx-to-pg.js` — reads the GeoJSON files and imports each administrative feature into the `adm_features` table, with `country_code`, `adm_level`, `pcode`, `name`, `parent_pcode`, and `geom` (re-projected to EPSG:4326)
3. `tenant_scope` rows are automatically inserted as part of the import to define which specific `adm_features` pcodes each tenant operates in — this is the per-tenant filter applied to every query

The result is a shared PostGIS database where all boundary data lives once per country, and each tenant's view of it is controlled by their `tenant_scope`.

---

### 3. API Layer — Lua + OpenResty + Caching

All API endpoints are implemented in **Lua running inside OpenResty** (nginx + LuaJIT), collocated with the tile-serving layer. Lua handles tenant routing, PostGIS queries, response assembly, and cache management with no separate application server.

**Tile endpoints** — served directly by Martin via PMTiles:

- `GET /tiles/{z}/{x}/{y}` — base map vector tiles (OSM roads, water, buildings)
- `GET /boundaries/{z}/{x}/{y}` — admin boundary vector tiles (HDX COD-AB, for choropleth and boundary overlays)

**Data & query endpoints** — served by Lua/OpenResty against PostGIS:

- `GET /boundaries/geojson` — returns all boundary features for a tenant as GeoJSON (states, zones/geo nodes, ungrouped LGAs, wards)
- `GET /boundaries/hierarchy` — returns the full hierarchy tree for a tenant (country → state → zones/nodes → LGAs)
- `GET /boundaries/search` — name search across `adm_features` and zones
- `GET /region?lat=&lon=` — point-in-polygon lookup; returns the full hierarchy path for a coordinate
- `GET|POST|PUT|DELETE /admin/geo-hierarchy/levels|nodes` — hierarchy editor CRUD
- `GET|POST|PUT|DELETE /admin/zones` — legacy zone CRUD (single-level)

**Caching** is a first-class concern given that boundary data can grow larger based on different apps and changes infrequently. The proposed solution currently uses a two-layer cache:

| Layer | Store | Size | TTL | Scope |
|---|---|---|---|---|
| L1 | `ngx.shared` (in-process memory) | 32MB geojson / 8MB hierarchy / 16MB region | 86400s / 3600s | Lost on nginx restart |
| L2 | `tenant_cache` table (PostgreSQL) | Unlimited | Permanent until invalidated | Survives restarts |

On any write to geo hierarchy, zones, or tenant scope, both cache layers are invalidated for that tenant. The next request rebuilds from PostGIS and repopulates both layers — cold requests after an edit are the only expensive ones; all subsequent requests are served from memory.

---

### 4. Hierarchy Editor — Vue + PostGIS

The Hierarchy Editor is a small **Vue 3 frontend** that allows users to define and manage each tenant's geographic hierarchy, explore and validate against the generated map tiles for each tenant.

The data model behind it introduces two new PostGIS tables:

- **`geo_hierarchy_levels`** — defines the levels in a tenant's hierarchy, each with a `level_order` and a `level_label` using the tenant's own custom naming
- **`geo_hierarchy_nodes`** — the actual geographic groups at each level; each node holds a list of constituent LGA pcodes (or child node pcodes), and its geometry is automatically computed as `ST_Multi(ST_Union(...))` of those constituents

When a node is created or updated, the system cascades upward — recomputing the geometry of every ancestor node so that the entire tree stays geometrically consistent.

Every hierarchy edit propagates immediately to the **`/region` endpoint**. The region lookup queries `geo_hierarchy_nodes` using `ST_Contains` to find the deepest node at a given coordinate, then walks the ancestor chain to return the full hierarchy path with dynamic `adm_N` keys that reflect the tenant's level structure.

New tenants can be onboarded incrementally — define the levels first, then add nodes one state at a time — and the system is queryable at every step.

---

### 5. Proposed Authentication & Authorization Layer

For app-to-app usage — where Situation Room, EWF, or any future consumer calls the geo platform programmatically — a layered auth model is proposed:

- **App identity whitelist** — each calling app is registered with a known `app_id`. On every request, the platform checks the incoming token's `app_id` claim against an `ngx.shared` whitelist. Sub-millisecond memory lookup, no outbound call.
- **App roles + scopes** — each registered app is granted a set of scopes (e.g., `region:read`, `hierarchy:read`, `tiles:read`, `admin:write`). Scopes are baked into the JWT as claims — no extra DB lookup per request.
- **Per-request claim validation** — JWT signature is verified locally in Lua using a cached public key (RS256). No token introspection calls, no network round-trip — validation stays in-process.
- **Managed Identity (no secrets)** — app identity tokens are issued via managed identity (GCP Workload Identity / Azure Managed Identity), removing the need to manage or rotate secrets. Tokens are cached after the first fetch and refreshed automatically.
- **RLS / data-layer enforcement** — PostgreSQL Row Level Security enforces per-tenant data isolation at the query level as a safety net. Since all Lua queries already pass `tenant_id` directly as a query parameter (`WHERE tenant_id = $1`), tenant isolation is enforced inline — RLS mirrors that at the data layer without requiring any additional round-trips or `SET LOCAL` calls. The overhead is 1–3ms on cache-miss requests only; cache hits bypass PostGIS entirely so RLS never runs.

---

## Technical Implementation Considerations

The following points reflect the current implementation in the sandbox:

### Cache Behaviour — Reload vs Restart

The two-layer cache behaves differently depending on how nginx is restarted:

- `openresty -s reload` — hot-reloads Lua and nginx config but **does not clear `ngx.shared`** (L1). Use this for Lua file changes only
- `docker restart tileserver_nginx_1` — clears all `ngx.shared` dictionaries (L1) but L2 (`tenant_cache` in Postgres) survives. Use this after any hierarchy or boundary data changes

Any write to `geo_hierarchy_nodes`, `zones`, or `tenant_scope` automatically invalidates both cache layers for that tenant — the next request rebuilds from PostGIS and repopulates both.

### PMTiles Integrity

Martin crashes on startup if any corrupt `.pmtiles` file exists in a scanned directory (`InvalidMagicNumber` error). A few rules to follow when handling `.pmtiles` files:

- Never place partially generated or transferred tile files directly into `pmtiles/` — generate to a staging location first, then move
- If a file is suspected to be corrupt, rename it to `.bak` immediately to prevent Martin from crashing on restart
- Subdirectories are not auto-discovered — all `.pmtiles` files must be at the top level of the scanned directory

### Adding a New Tenant

The order of steps matters — each depends on the previous:

1. Generate OSM base tiles (Planetiler) → place `.pmtiles` in `pmtiles/`
2. Download HDX boundary data for the new country or state (`download-hdx`) → generate boundary `.pmtiles`
3. Add tenant row to `tenants` table and update nginx source map
4. Run `import-hdx-to-pg.js` to populate `adm_features` and `tenant_scope`
5. Restart Martin + nginx to pick up new tile files
6. Define geo hierarchy levels via the Hierarchy Editor Panel in the Vue app
7. Add geo nodes level by level — endpoints are change-aware immediately

---

## Rollout Plan

The rollout is structured around three independently deployable components with a strict dependency order. The geo hierarchy model is additive and the system auto-detects which model to use per tenant — no feature toggles required.

### Phase 1 — PostGIS Database

The PostgreSQL/PostGIS database is the foundation everything else depends on. Before any other component is deployed:

- Validate schema (`adm_features`, `tenants`, `tenant_scope`, `zones`, `geo_hierarchy_levels`, `geo_hierarchy_nodes`, `tenant_cache`)
- Confirm PostGIS extensions are enabled (`postgis`, `postgis_topology`)
- Verify all indexes are in place (GIST on `geom`, indexes on `pcode`, `country_code`, `adm_level`, `parent_pcode`)
- Add the database to NewGlobe's managed DB infrastructure

### Phase 2 — Martin + Nginx + Lua

Once the database is live and validated:

- Deploy Martin (tile server) with the PMTiles files for each tenant
- Deploy OpenResty (nginx + Lua) with the full API layer
- Verify all endpoints respond correctly for at least one tenant (`/health`, `/tiles`, `/boundaries/geojson`, `/boundaries/hierarchy`, `/region`)
- Confirm cache layers are functioning (L1 `ngx.shared`, L2 `tenant_cache`)

### Phase 3 — Vue App

Once the API layer is live:

- Deploy the Vue app, pointed at the Martin + Lua endpoints
- Verify the Tile Inspector and Hierarchy Editor load correctly for each tenant

### Phase 4 — Per-Country Onboarding

After all three components are live, tenants are onboarded one at a time:

1. Run `import-hdx-to-pg.js` for the tenant's country to populate `adm_features` and `tenant_scope` — all 7 countries' data are generated and ready to be copied to S3
2. Generate OSM base tiles and boundary tiles → place `.pmtiles` files in the correct directories
3. Register the tenant in the `tenants` table and update the nginx source map
4. Restart Martin + nginx to pick up new tile files
5. Define geo hierarchy levels via the Hierarchy Editor
6. Add geo nodes level by level — system is queryable at every step

---

## Technical Risks

**Cache becoming stale after hierarchy edits** is a subtle but common operational risk. Running `openresty -s reload` hot-reloads Lua and nginx config but does not clear `ngx.shared` (L1 cache) — only a full `docker restart` on the nginx container does. Any hierarchy or boundary data change requires a restart, not just a reload. A cache-bust endpoint (`POST /admin/cache/invalidate`) would remove the dependency on direct container access entirely.

**PMTiles corruption** will cause Martin to crash on startup with an `InvalidMagicNumber` error if a corrupt file exists in the scanned directory. Tile files should never be placed directly into the scanned directory during generation — generate to a staging location first, then move. Any file suspected of corruption should be renamed to `.bak` immediately.

---

## Appendix

### Tenant Reference Table

| Tenant ID | Program | Country | Martin Source |
|---|---|---|---|
| 1 | Bridge Kenya | Kenya | kenya-detailed |
| 2 | Bridge Uganda | Uganda | uganda-detailed |
| 3 | Bridge Nigeria | Nigeria | nigeria-lagos-osun |
| 4 | Bridge Liberia | Liberia | liberia-detailed |
| 5 | Bridge India (AP) | India | india-andhrapradesh |
| 9 | EdoBEST | Nigeria (Edo) | nigeria-edo |
| 11 | EKOEXCEL | Nigeria (Lagos) | nigeria-lagos |
| 12 | Rwanda EQUIP | Rwanda | rwanda-detailed |
| 14 | Kwara Learn | Nigeria (Kwara) | nigeria-kwara |
| 15 | Manipur Education | India (Manipur) | india-manipur |
| 16 | Bayelsa Prime | Nigeria (Bayelsa) | nigeria-bayelsa |
| 17 | Espoir CAR | Central African Republic | central-african-republic-detailed |
| 18 | Jigawa Unite | Nigeria (Jigawa) | nigeria-jigawa |

### Boundary Data Sources by Country

| Country | Level | Label | Source |
|---|---|---|---|
| Kenya | adm1 | County | HDX COD-AB |
| Kenya | adm2 | Sub-County | HDX COD-AB |
| Uganda | adm1 | Region | HDX COD-AB |
| Uganda | adm2 | District | HDX COD-AB |
| Nigeria | adm1 | State | HDX COD-AB |
| Nigeria | adm2 | LGA | HDX COD-AB |
| Rwanda | adm1 | Province | OSM (admin_level=4) |
| Rwanda | adm2 | District | OSM (admin_level=6) |
| Liberia | adm1 | County | HDX COD-AB |
| Liberia | adm2 | District | HDX COD-AB |
| Central African Republic | adm1 | Prefecture | HDX COD-AB |
| Central African Republic | adm2 | Sub-Prefecture | HDX COD-AB |
| India | adm1 | State | OSM |
| India | adm2 | District | OSM (partial) |

### Licensing

**OpenStreetMap** (base map tiles and OSM-derived boundary data): licensed under the [Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/). Commercial use permitted; attribution required.

**HDX COD-AB** (official administrative boundary data): licensed under [CC BY-IGO](https://creativecommons.org/licenses/by/3.0/igo/). Commercial use permitted; attribution required.
