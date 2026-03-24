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

## Tenant cache isolation

Append **`?t=${tenantId}`** to hierarchy and GeoJSON URLs so browser cache stays per-tenant (`Vary: X-Tenant-ID` + `Cache-Control: public, max-age=86400`).

## Build configuration

| Env var | Purpose |
|---------|---------|
| `VITE_PROXY_URL` | Nginx API base (e.g. `http://35.224.96.155:8080`) |
| `VITE_MARTIN_URL` | Martin catalog / metadata (port 3000) |

Production builds must use real hosts — not `localhost` — or browsers block with Private Network Access rules.

## Tenant lifecycle and state

- Selected tenant persists in local storage via `newglobe.selectedTenantId`.
- Startup keeps the stored tenant ID first, then `reloadTenantList()` validates against live tenant IDs and falls back to first available tenant when invalid.
- Tenant switching is race-guarded with `tenantLoadVersion` so stale async metadata responses are ignored.
- Map instance is recreated on tenant switch (`map.remove()` then new `Map`) so source/layer state is clean per tenant.

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

## Map interactions

- Popup title resolves from `adm3_name -> adm2_name -> adm1_name/name`; subtitle uses parent context (`adm2/adm1`) where available.
- Popup kind label uses `level_label` first, then country admin label table fallback, then tenant/local defaults (for state/LGA/local area naming).
- Clicking a boundary fits to geometry bounds and opens inspector popup.
- Hierarchy fly behavior differs by level: state targets lower zoom floor, LGA/child targets tighter zoom and parent subtitle context.
- Zone highlight uses `zones-fill`/`zones-outline` paint expressions by matched `pcode`; state/LGA highlight uses the `highlight-overlay` source.

## Layers and overlays

- Zone overlay source/layers: `zones-overlay` source with `zones-fill` and `zones-outline`.
- When zones exist, overlapping PMTiles boundary lines/fills are hidden to avoid duplicate outlines (`boundary-fill`, `boundary-lga-line`, `boundary-state-line`).
- adm3+ outlines render via `ward-overlay` + `ward-outline` with zoom gate (`minzoom: 8`).
- When a PMTiles state boundary line is absent, frontend adds GeoJSON fallback state border layer (`state-scope-line` from `state-scope-source`).
- First-load state fit-bounds enforces a source `minzoom` guard to prevent blank initial maps for legacy z10-only sources.

## Geo hierarchy editor (optional)

When enabled, a **dual-panel** editor uses `/admin/geo-hierarchy/*` and raw vs custom trees (`useGeoHierarchyEditor.ts`, `HierarchyBuilderPanel.vue`, `RawBoundaryPanel.vue`). See `docs/geo-hierarchy-frontend.md` for selection mode, `assignAreasToParent`, and layer wiring in `useMapLayers.ts`.

This is an optional editing flow and not the default tile inspector path.

**Recent UX:** Multi-state tenants no longer auto-open every state in the custom tree; click a state row to **`addStateToHierarchy`** (auto-creates nodes when empty, with loading state). **Dismiss (×)** removes a state from the panel via **`deactivateState`** (and deletes roots if any). Sidebar search uses **`useBoundarySearch`**: when custom `children` exist anywhere, only states with children list by default; search matches nested `children` names/pcodes.

---

*Synced from repo `/docs` for Outline — Map server collection.*
