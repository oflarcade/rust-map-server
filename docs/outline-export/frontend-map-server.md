# Frontend — Map tile server

> **Source:** `rust-map-server` — `docs/fe-api-integration.md`, `docs/geo-hierarchy-frontend.md`, `View/`.

## Role

**Vue 3 + MapLibre GL JS** apps for tile inspection, boundary exploration, and **zone management**. All API calls go through **nginx (8080)** with header **`X-Tenant-ID`** (no bearer token; origin whitelist on server).

## Typical session flow

```mermaidjs
flowchart TD
  A[Load hierarchy GET /boundaries/hierarchy?t=id]
  B[Load GeoJSON GET /boundaries/geojson?t=id]
  C[Map tiles GET /tiles/z/x/y]
  D[Search GET /boundaries/search?q=]
  E[Pin drop GET /region?lat=&lon=]
  F[Zone admin POST /admin/zones]
  A --> B --> C
  C --> D
  C --> E
  E --> F
```

## Cache-busting

Append **`?t=${tenantId}`** to hierarchy and GeoJSON URLs so browser cache stays per-tenant (`Vary: X-Tenant-ID` + `Cache-Control: public, max-age=86400`).

## Build configuration

| Env var | Purpose |
|---------|---------|
| `VITE_PROXY_URL` | Nginx API base (e.g. `http://35.239.86.115:8080`) |
| `VITE_MARTIN_URL` | Martin catalog / metadata (port 3000) |

Production builds must use real hosts — not `localhost` — or browsers block with Private Network Access rules.

## Main views (Tile Inspector stack)

| Path / area | File | Role |
|-------------|------|------|
| Tile inspector | `View/src/views/TileInspector.vue` | Map + sidebar |
| Zone manager | `View/src/views/ZoneManager.vue` | Draw/select LGAs → zones |
| Sidebar | `View/src/components/BoundaryExplorer.vue` | Tenant selector, search, hierarchy tree |
| Shared state | `View/src/composables/useTileInspector.ts` | Map, tenant, hierarchy, boundaries |
| Styles | `View/src/map/inspectorStyle.ts` | MapLibre style + Martin metadata |

## MapLibre sources

- **Vector tiles:** `GET /tiles/{z}/{x}/{y}` — source layers e.g. `water`, `transportation`, `building`, `place`, `boundary`
- **Boundary overlay:** `GET /boundaries/{z}/{x}/{y}` — tenant-scoped admin boundaries

## Geo hierarchy editor (optional)

When enabled, a **dual-panel** editor uses `/admin/geo-hierarchy/*` and raw vs custom trees (`useGeoHierarchyEditor.ts`, `HierarchyBuilderPanel.vue`, `RawBoundaryPanel.vue`). See `docs/geo-hierarchy-frontend.md` for selection mode, `assignAreasToParent`, and layer wiring in `useMapLayers.ts`.

**Recent UX:** Multi-state tenants no longer auto-open every state in the custom tree; click a state row to **`addStateToHierarchy`** (auto-creates nodes when empty, with loading state). **Dismiss (×)** removes a state from the panel via **`deactivateState`** (and deletes roots if any). Sidebar search uses **`useBoundarySearch`**: when custom `children` exist anywhere, only states with children list by default; search matches nested `children` names/pcodes.

---

*Synced from repo `/docs` for Outline — Map server collection.*
