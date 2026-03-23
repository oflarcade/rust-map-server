# Geo Hierarchy Editor — Frontend Documentation

## Overview

The geo hierarchy editor is a dual-panel Vue 3 system for building custom administrative hierarchies and managing boundary visualizations on a MapLibre-based map. Operators create multi-level organizational structures (e.g. States → Districts → Sectors) from raw OSM/HDX boundary data, assign administrative units to custom groupings, and visualize them with per-node color styling and geometry union.

---

## Architecture Layers

### Composable State Management (`useGeoHierarchyEditor.ts`)

Central composable managing all state, queries, and mutations. Uses `@tanstack/vue-query` for server state and reactive refs for client state.

#### Query Layers

```
Raw Boundary Data (read-only)
  └─ fetchRawHierarchy() → country.states[].lgas[].children

Custom Hierarchy Data (mutable)
  ├─ fetchGeoLevels()        → GeoLevel[] (level_order, level_label, level_code)
  ├─ fetchGeoNodes()         → GeoNode[] (parent_id chain, constituent_pcodes, geometry)
  └─ fetchHdxLevelLabels()   → canonical adm3+ labels from tenant's boundary data
```

#### Selection Mode State Machine

```
idle ──enterSelectionMode(nodeId)──────────────┐
     ──enterSelectionModeForArea(statePcode)───► selecting
                                                  │
                              selectedRawPcodes: Set<string>
                              targetNodeId | targetStatePcode
                                                  │
                              assignSelectedToNode()
                              ┌────────────────────┤
                              │ success: invalidate │
                              │ error:   invalidate │
                              └─────────┬──────────┘
                                        │ finally: exitSelectionMode()
                                        ▼
                                       idle
```

#### All Exported Symbols

| Symbol | Type | Description |
|--------|------|-------------|
| `selectedTenantId` | `ComputedRef<string>` | Active tenant |
| `selectionMode` | `Ref<'idle'|'selecting'>` | Raw pcode selection state |
| `selectedRawPcodes` | `Ref<Set<string>>` | Currently checked pcodes |
| `targetNodeId` | `Ref<number|null>` | Node being assigned to |
| `targetStatePcode` | `Ref<string|null>` | State being assigned to |
| `focusedStatePcode` | `Ref<string|null>` | Scrolls custom tree |
| `activeStatePcodes` | `ComputedRef<Set<string>>` | States visible in custom tree: auto-activated (nodes exist) + manually activated, **minus** `suppressedStatePcodes` |
| `showCountryRoot` | `Ref<boolean>` | Show country root row |
| `isMultiStateTenant` | `Ref<boolean>` | Locked to true when ≥2 states |
| `adm1Label` | `ComputedRef<string>` | e.g. "State", "County", "Region" |
| `adm2Label` | `ComputedRef<string>` | e.g. "LGA", "District" |
| `adm2Short` | `ComputedRef<string>` | e.g. "LGA" (abbreviation for buttons) |
| `rawHierarchy` | query data | Full OSM/HDX tree |
| `geoLevels` | query data | Tenant's defined levels |
| `geoNodes` | query data | Flat node list (built into tree client-side) |
| `nodeTree` | `ComputedRef<Map>` | `state_pcode → GeoNode[]` |
| `assignedPcodes` | `ComputedRef<Set<string>>` | All pcodes in any node |
| `enterSelectionMode(nodeId)` | fn | Target existing node |
| `enterSelectionModeForArea(statePcode)` | fn | Target state (new root nodes) |
| `togglePcode(pcode)` | fn | Add/remove from selection |
| `exitSelectionMode()` | fn | Reset selection state |
| `assignSelectedToNode()` | fn | Create nodes from selection |
| `activateState(pcode)` | fn | Add state to custom tree; clears suppression for that pcode |
| `addStateToHierarchy(pcode)` | `async fn` | Left-panel state click: activates state; if it has **no** nodes yet, auto-selects all adm2 + adm3+ pcodes and runs `assignAreasToParent(statePcode, null)` (same effect as select-all + Assign) |
| `deactivateState(pcode)` | fn | Suppresses state from the custom tree (and removes from manual activation); does not delete DB rows by itself |
| `createLevel/updateLevel/deleteLevel` | mutations | Level CRUD |
| `createNode/updateNode/deleteNode` | mutations | Node CRUD |

#### Multi-state vs single-state custom tree

When `rawHierarchy` loads:

- **Single-state tenant** (one state in scope): that state is **auto-activated** so the right panel is not empty.
- **Multi-state tenant** (≥2 states): **no** blanket auto-activation of every state. The right panel shows only states that **already have** `geo_hierarchy_nodes`, plus any state the user **clicks** in the left panel (see `addStateToHierarchy`). This avoids many empty state sections (e.g. country-wide Liberia) before any hierarchy is built.

Internal: `suppressedStatePcodes` hides a state even if it would otherwise be auto-active.

---

## Component: Custom Tree Panel (`HierarchyBuilderPanel.vue`)

Renders the right panel showing custom GeoNodes grouped by state with collapsible levels.

### Remove state from custom tree

Each state header row includes a small **dismiss (×)** control (when not in multi-select delete mode). It calls `removeState(pcode, name)`:

- If there are **root** nodes for that state, the user confirms; each root is deleted via `deleteNode` (children cascade).
- Then `deactivateState(pcode)` runs so the state disappears from the right panel without deleting raw boundary data.

### FlatNode Interface

Flattens nested GeoNode tree into a single-pass render list:

```typescript
interface FlatNode {
  node: GeoNode;
  statePcode: string;
  depth: number;                  // 0 = root, 1 = child, ...
  type: 'node' | 'constituent' | 'child-area';
  constituentPcode?: string;      // for 'constituent': grouped LGA pcode
  constituentName?: string;
  childPcode?: string;            // for 'child-area': adm3+ raw pcode
  childName?: string;
  childLabel?: string;            // e.g. "Sector"
}
```

### flattenTree Algorithm

```
for each node in nodes:
  push { type: 'node', depth }

  if node.children.length > 0:
    recurse into children (depth + 1)

  else if isLeafNode(node):           // level_label === adm2Label
    for each adm3+ child in getChildAreasForNode(node):
      push { type: 'child-area' }

  else if constituent_pcodes.length > 0:
    for each pcode in constituent_pcodes:
      if pcode NOT in childPcodeSet:  // skip adm3+ (already shown as GeoNodes)
        push { type: 'constituent' }
```

**Key helpers:**
- `isLeafNode(n)` — `n.level_label === adm2Label` (individual unit, not a grouping)
- `nodeHasChildren(id, flatNodes)` — any flat row references this node id
- `isFlatNodeVisible(flatNode)` — checks collapse state of node + all ancestors

### Collapse State

```typescript
collapsedStates: Set<string>   // state-level (hides all nodes under state)
collapsedNodes:  Set<number>   // node-level (hides constituent/child-area rows)

// Auto-collapse: any node that gains children collapses on first render
// autoCollapseSeen set prevents re-collapsing after manual expand
```

### Multi-Select Delete

```typescript
deleteSelectMode:  Ref<boolean>       // toggles checkbox column
selectedForDelete: Set<number>        // checked node ids

deleteSelectedNodes():
  // Smart cascade: only call deleteNode() on top-most selected nodes
  // DB ON DELETE CASCADE removes children automatically
  toDelete = selected.filter(id =>
    node.parent_id == null || !selected.has(node.parent_id)
  )
  for id in toDelete: await deleteNode(id)
```

**UX:** Select button in header toggles mode. Red checkbox on each node row. Delete (N) button appears when ≥1 checked. +Areas/+Level buttons hidden during select mode.

---

## Component: Raw Boundary Panel (`RawBoundaryPanel.vue`)

Left panel showing raw OSM/HDX boundary hierarchy tree with interactive selection.

### Data Structure (rawHierarchy)

```
states[]:
  pcode, name
  lgas[]:
    pcode, name, level_label
    children[]:               ← adm3+ (e.g. Rwanda Sectors)
      pcode, name, level_label
```

### State row click (build hierarchy)

Clicking a **state row** (left panel, not the chevron) runs **`addStateToHierarchy(pcode)`** — not only `activateState`. While the state has **no** existing nodes, the composable gathers all adm2 + nested adm3+ pcodes for that state and runs **`assignAreasToParent`** so the server creates nodes (same net effect as opening selection mode, select-all, Assign). **While** that request runs, `buildingStates` disables the row and shows a spinner (`title`: “Building hierarchy…”). If nodes already exist for the state, only activation happens.

### Selection Mode Behaviour

When `selectionMode === 'selecting'`:
- Checkboxes appear on LGA rows and adm3+ child rows
- `isAssigned(pcode)` → disabled checkbox (already in a node) unless already selected
- `targetHighlightLgaPcodes` → amber highlight on LGAs currently in the target node
- `selectAllChildren(lga.children)` → toggle all eligible children
- Footer: **Assign N items** (disabled if nothing selected) + **Cancel**

### adm3+ Support

```typescript
parentChildMap:  Map<adm2_pcode, children[]>   // from rawHierarchy
childPcodeSet:   Set<string>                    // all adm3+ pcodes (for quick lookup)

// targetHighlightLgaPcodes logic:
if node.constituent_pcodes contain any childPcodeSet members:
  // show parent adm2 rows as amber (sectors group under their district)
else:
  // show constituent pcodes directly as amber
```

---

## Boundary search (`useBoundarySearch.ts`)

Used by the sidebar hierarchy search (Tile Inspector / boundary explorer).

- **`activeStates`** — If **any** state in the loaded hierarchy has a non-empty `children` array (custom `geo_hierarchy_nodes` tree under that state), the UI only lists **states that already have** such children. States with no custom hierarchy yet are hidden from the flat state list (empty right panel until the user builds at least one state). If **no** state has `children`, all states are shown (legacy / no custom tree).
- **Search text** — Filters states by name/pcode, LGAs as before, and **recursively** matches names/pcodes inside `state.children` (senatorial districts, sectors, nested zones, etc.) via `matchesInTree`.

---

## `assignAreasToParent` — Two-Pass Smart Nesting

Called when user assigns selected pcodes to either a state root or an existing node.

```typescript
async function assignAreasToParent(statePcode, parentId):

  // Build info maps from rawHierarchy
  pcodeInfo:            pcode → { name, level_label }
  sectorToDistrictPcode: sector_pcode → parent_district_pcode

  if parentId === null (Province-level):
    adm2Pcodes = selection.filter(not in sectorToDistrictPcode)
    adm3Pcodes = selection.filter(in sectorToDistrictPcode)

    // PASS 1: create district nodes, capture returned IDs
    for pcode in adm2Pcodes:
      created = await createGeoNode({ parent_id: null, ... })
      districtPcodeToNodeId[pcode] = created.id

    // PASS 2: create sector nodes nested under their parent district
    for pcode in adm3Pcodes:
      districtPcode = sectorToDistrictPcode[pcode]
      effectiveParentId = districtPcodeToNodeId[districtPcode] ?? null
      await createGeoNode({ parent_id: effectiveParentId, ... })

  else (Node-level):
    // All selected go directly under parentId
    for pcode in selection:
      await createGeoNode({ parent_id: parentId, ... })

  invalidate()
```

**Error handling:** wrapped in `try/catch/finally` in `assignSelectedToNode` — `exitSelectionMode()` always fires; `invalidate()` fires in the catch branch to refresh partial state.

---

## Map Rendering (`useMapLayers.ts`)

### Layers

| Layer ID | Source | What it draws |
|----------|--------|---------------|
| `zones-fill` | `zones-overlay` | Polygon fill (hidden by default, shown on interact) |
| `zones-outline` | `zones-overlay` | Polygon border lines (always visible) |
| `ward-outline` | `ward-overlay` | Subtle adm3+ boundaries (visible z8+) |

### GeoJSON Feature Properties

```typescript
{
  pcode: string,
  name: string,
  color: string,              // hex, drives fill + line color
  feature_type: 'zone' | 'geo_node' | 'ward' | 'state' | 'lga',
  level_order: number,        // line width: 1→2px, else 1.5px
}
```

### Layer Update Flow

```
geojson query → data changes
  → loadZoneOverlay(geojson)
  → filter by feature_type
  → GeoJSONSource.setData()
  → MapLibre re-renders
```

---

## API Layer (`geoHierarchy.ts`)

### Key Types

```typescript
interface GeoLevel {
  id: number; tenant_id: number;
  level_order: number;   // 1, 2, 3...
  level_label: string;   // "District", "Sector", "Zone"
  level_code:  string;   // "DI", "SE", "ZO" (auto from label)
}

interface GeoNode {
  id: number;
  parent_id: number | null;       // null = root under state
  state_pcode: string;
  level_id: number;               // FK to GeoLevel
  pcode: string;                  // auto-generated: "RW02-DI001"
  name: string;
  color?: string;
  level_label?: string;           // denormalized from GeoLevel
  level_order?: number;
  constituent_pcodes?: string[];  // assigned adm_features pcodes
  area_sqkm?: number;
  center_lat?: number; center_lon?: number;
  children?: GeoNode[];           // client-side tree (not from API)
}
```

### Client-Side Tree Building

```typescript
buildNodeTree(nodes: GeoNode[]): Map<state_pcode, GeoNode[]>
  // Algorithm:
  // 1. Build byId index
  // 2. For each node:
  //    - if parent_id: append to parent.children[]
  //    - else: append to rootsByState[state_pcode]
  // 3. Return rootsByState map

labelToCode(label: string): string
  // "Federal Constituency" → "FC" (initials, max 4 chars)
  // "Ward" → "WA" (first 2 chars of single word)

collectAssignedPcodes(nodes): Set<string>
  // Flatten all constituent_pcodes from all nodes
```

### Level Config Panel (`LevelConfigPanel.vue`)

Small wrapper around level mutations:
- List existing levels in level_order
- `openCreate()` → form dialog
- `openEdit(level)` → allow label/code update
- `deleteLevel(id)` → also deletes all nodes at that level

### Node Form Dialog (`GeoNodeFormDialog.vue`)

Create mode: level type input → smart `resolveLevel()` (find existing or create new GeoLevel with next order) → name → color picker.
Edit mode: name + color only (level locked).

---

## Full Data Flow: User Assigns Areas

```
1. Click "+Districts" on a Province state row
   → enterSelectionModeForArea("RW02")

2. Check sectors + districts in raw panel
   → togglePcode("RW5201"), togglePcode("RWD022")...

3. Click "Assign 12 items"
   → assignSelectedToNode()
   → assignAreasToParent("RW02", null)
   → PASS 1: create district GeoNodes (parent_id=null)
   → PASS 2: create sector GeoNodes (parent_id=district.id)
   → invalidate() → refetch geo-nodes, geo-levels, hierarchy, geojson
   → finally: exitSelectionMode()

4. Server (per node create):
   → POST /admin/geo-hierarchy/nodes
   → INSERT into geo_hierarchy_nodes with ST_Union geometry
   → cascade_ancestors(): walk up parent chain, recompute geometries
   → return GeoNode with auto-generated pcode

5. Query invalidation resolves:
   → geoNodes refetched → buildNodeTree() rebuilds tree
   → nodeTree.value updated → flattenTree() re-renders
   → geojson refetched → loadZoneOverlay() → MapLibre redraws polygons
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `useGeoHierarchyEditor.ts` | All selection state, queries, mutations, `assignAreasToParent` |
| `HierarchyBuilderPanel.vue` | Custom tree: `flattenTree`, collapse, multi-select delete |
| `RawBoundaryPanel.vue` | Raw hierarchy tree, selection checkboxes, assign footer |
| `useMapLayers.ts` | MapLibre layer management, zone overlay from GeoJSON |
| `LevelConfigPanel.vue` | Level CRUD wrapper |
| `GeoNodeFormDialog.vue` | Node/level creation form, `resolveLevel` |
| `geoHierarchy.ts` | REST API calls, `buildNodeTree`, `labelToCode`, types |
| `useBoundarySearch.ts` | Hierarchy search + `activeStates` when custom `children` exist |
