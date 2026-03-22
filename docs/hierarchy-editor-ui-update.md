# Hierarchy editor: level labels & UI workflow update

Summary of changes delivered for the hierarchy editor (canonical admin level labels API, raw/custom tree focus, and adding levels from the custom tree panel).

---

## Backend (API)

| Area | Change |
|------|--------|
| `tileserver/lua/boundary-db.lua` | Added `CANONICAL_LEVEL_LABELS` per ISO country (NG includes INEC types: Senatorial District, Federal Constituency, Emirate, plus HDX-style Local Government Area, Ward). New `get_level_labels_for_tenant(tenant_id)` merges DISTINCT `adm_features.level_label` for the tenant’s country with that allowlist, dedupes, sorts alphabetically. |
| `tileserver/lua/admin-geo-hierarchy.lua` | `GET /admin/geo-hierarchy/level-labels` now uses `get_level_labels_for_tenant` instead of DB-only distinct labels. |

**Behavior:** Nigeria tenants (e.g. Jigawa, tenant 18) receive full NG label options in the dropdown even if INEC polygons are not imported yet. Real geometry for those types still requires the corresponding rows in PostGIS.

---

## UI changes

### Level type picker (levels dialog)

- **Before:** Options came only from existing `adm_features.level_label` values in the database; missing INEC imports meant missing types in the UI.
- **After:** Options are driven by the updated `level-labels` endpoint (DB + canonical allowlist). The level create/edit experience is the same, but the dropdown is authoritative for supported countries.

### New shared dialog: `GeoLevelFormDialog.vue`

- Modal for creating or editing a hierarchy **level** (order, short code, admin level type).
- Replaces the inline form that lived only in `LevelConfigPanel.vue`.
- Used in two places:
  - **Levels** strip at the top (`LevelConfigPanel.vue`) — **+ Level** / pencil still open this dialog.
  - **Custom tree** header (`HierarchyBuilderPanel.vue`) — new **+ Level** opens the same dialog so operators do not have to scroll up to define levels.

### Raw boundary panel — `RawBoundaryPanel.vue`

- **Chevron:** Expands or collapses LGAs only (does not change focus).
- **State name + pcode row:** Sets **focused state**, expands that state, and highlights the row (indigo tint).
- Focus is shared with the custom tree via the composable (see below).

### Custom tree panel — `HierarchyBuilderPanel.vue`

- Each state section has a stable DOM id: `hb-state-{state_pcode}`.
- When a state is focused from the raw panel, the matching section:
  - Scrolls into view (smooth, `nearest`).
  - Shows a visible ring/highlight so the right-hand column matches the left-hand selection.
- Header row includes **+ Level** (see above).

### Composable — `useGeoHierarchyEditor.ts`

- **`focusedStatePcode`** — `ref<string | null>` for the state selected from the raw tree.
- **`focusRawState(pcode)`** — sets focus (or pass `null` to clear if you extend callers later).
- Focus resets when the **tenant** changes (along with selection mode cleanup).

---

## Files touched (reference)

| File | Role |
|------|------|
| `tileserver/lua/boundary-db.lua` | Canonical labels + `get_level_labels_for_tenant` |
| `tileserver/lua/admin-geo-hierarchy.lua` | `level-labels` handler |
| `View/src/components/GeoLevelFormDialog.vue` | **New** — level form modal |
| `View/src/components/LevelConfigPanel.vue` | Uses `GeoLevelFormDialog`; inline form removed |
| `View/src/components/HierarchyBuilderPanel.vue` | Focus scroll/highlight; **+ Level**; imports dialog |
| `View/src/components/RawBoundaryPanel.vue` | Split chevron vs. state click; focus + highlight |
| `View/src/composables/useGeoHierarchyEditor.ts` | `focusedStatePcode`, `focusRawState`, tenant reset |

---

## Deployment notes

After Lua changes, restart the nginx/OpenResty container so Lua is loaded and shared caches behave as expected (e.g. `sudo docker restart tileserver_nginx_1`).

Rebuild the Vue app with production `VITE_PROXY_URL` / `VITE_MARTIN_URL` before shipping `View/dist` so the browser is not pinned to localhost.

---

## Quick API check

```bash
curl -sS -H "X-Tenant-ID: 18" \
  "http://<host>:8080/admin/geo-hierarchy/level-labels"
```

For Nigeria you should see labels including **Senatorial District**, **Federal Constituency**, and **Emirate** alongside **Local Government Area** and **Ward**, independent of whether INEC features are loaded for that state.
