# Backend — Map tile server

> **Source:** `rust-map-server` — `CLAUDE.md`, `docs/fe-api-integration.md`.  
> **Production:** GCP `martin-tileserver`, `us-central1-a`, `35.239.86.115`.

## Purpose

Multi-tenant vector map tile server: **Martin** (PMTiles) + **OpenResty** (Lua) + **PostgreSQL/PostGIS** for admin boundaries and custom **zones**.

```mermaidjs
flowchart LR
  subgraph Client
    FE[MapLibre GL JS + Vue]
  end
  subgraph Edge["Nginx 8080"]
    Lua[Lua + CORS + tenant map]
  end
  subgraph Tiles["Martin 3000"]
    PMT[PMTiles byte-range]
  end
  subgraph Data["PostgreSQL + PostGIS"]
    PG["tenants · adm_features · tenant_scope · zones"]
  end
  FE -->|"X-Tenant-ID"| Lua
  Lua -->|/tiles/*| PMT
  Lua -->|/boundaries/* /region /admin/*| PG
```

## Three-layer stack

```mermaidjs
flowchart TB
  M["Martin Rust: PMTiles vector tiles"]
  N["OpenResty: nginx and Lua"]
  D[("PostgreSQL / PostGIS")]
  M --> N
  N --> D
```

| Layer | Role |
|-------|------|
| **Martin** | Serves base OSM tiles + boundary PMTiles; auto-discovers `.pmtiles` in `pmtiles/` and `boundaries/` |
| **OpenResty** | Tenant routing (`X-Tenant-ID` → source name), boundary GeoJSON/hierarchy/search, `/region`, `/admin/zones` |
| **PostGIS** | `adm_features` geometries (GIST), `tenant_scope`, `zones` with precomputed `ST_Union` |

## Tenant routing

Nginx maps `X-Tenant-ID` → Martin **source name** (e.g. tenant `11` → `nigeria-lagos`). Country extracts often use a `-detailed` suffix; state extracts use `country-state`.

```mermaidjs
sequenceDiagram
  participant C as Client
  participant N as Nginx Lua
  participant M as Martin
  participant P as PostGIS
  C->>N: GET /tiles/z/x/y + X-Tenant-ID
  N->>M: proxy /tiles → mapped PMTiles source
  M-->>C: MVT
  C->>N: GET /boundaries/hierarchy?t=id
  N->>P: Lua → boundary-db queries
  P-->>C: JSON + Cache-Control
```

## PostGIS core schema (summary)

- **tenants** — `tenant_id`, `country_code`, `tile_source`, `hdx_prefix`
- **adm_features** — shared boundaries; `geom` GIST; `level_label` for adm3+ types
- **tenant_scope** — which `adm_features` rows each tenant may use
- **zones** — custom groupings; `constituent_pcodes`, `ST_Union` geometry, `zone_level`, `children_type`

## Boundary & region APIs

| Area | Endpoints | Notes |
|------|-----------|--------|
| Tiles | `GET /tiles/{z}/{x}/{y}` | Martin PMTiles |
| Boundary tiles | `GET /boundaries/{z}/{x}/{y}` | Tenant-scoped vector overlay |
| GeoJSON | `GET /boundaries/geojson?t={tenantId}` | FeatureCollection; `Vary: X-Tenant-ID` |
| Hierarchy | `GET /boundaries/hierarchy?t={tenantId}` | Tree; cached in `ngx.shared` (24h) |
| Search | `GET /boundaries/search?q=` | Indexed name search |
| Region | `GET /region?lat=&lon=` | Point-in-polygon; `ngx.shared` ~1h |
| Zones admin | `GET/POST/PUT/DELETE /admin/zones` | Invalidates hierarchy cache on write |

## Caching model

```mermaidjs
flowchart TB
  H["/boundaries/hierarchy"]
  G["/boundaries/geojson"]
  R["/region"]
  L1["L1: ngx.shared (RAM per worker)"]
  L2["L2: tenant_cache table — optional persistent"]
  H --> L1
  G --> L1
  R --> L1
  L1 -.->|miss| L2
```

**Important:** `openresty -s reload` does **not** clear `ngx.shared`. Use `docker restart tileserver_nginx_1` to clear in-memory caches after sticky issues.

## Zone write → cache invalidation

```mermaidjs
flowchart LR
  Z[POST/PUT/DELETE /admin/zones]
  I[Invalidate hierarchy_cache + geojson keys]
  Z --> I
```

## Key Lua modules

| File | Responsibility |
|------|----------------|
| `boundary-db.lua` | PostGIS queries: geojson, hierarchy, search, region, zones; **`CANONICAL_LEVEL_LABELS`** per country (NG/CF labels merged with DB for level-label picker) |
| `serve-geojson.lua` | `GET /boundaries/geojson` |
| `serve-hierarchy.lua` | `GET /boundaries/hierarchy` + shared dict cache |
| `region-lookup.lua` | `GET /region` + point-in-polygon |
| `admin-zones.lua` | Zone CRUD |
| `nginx-tenant-proxy.conf` | Maps, CORS, `lua_shared_dict` sizes |

## Advanced: geo hierarchy editor (optional)

Some deployments add `/admin/geo-hierarchy/*` with `geo_hierarchy_levels` / `geo_hierarchy_nodes` (see `docs/geo-hierarchy-backend.md`). That path is **separate** from the simpler **zones** model in `zones` + `/admin/zones`.

---

*Synced from repo `/docs` for Outline — Map server collection.*
