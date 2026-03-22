# Geo Hierarchy — Per-Tenant Findings & Unified Method

> **Status (2026-03-21):** Tenants 14 (Kwara) and 18 (Jigawa) have built custom hierarchies.
> All others are `0 levels / 0 nodes`. Rwanda (12) was broken at investigation time (empty `tenant_scope` — now fixed).

---

## 1. What the System Stores

### Two parallel tables (both required per tenant)

| Table | Role |
|---|---|
| `geo_hierarchy_levels` | The *type* definitions: "Senatorial District (SD, order=1)", "Federal Constituency (FC, order=2)" |
| `geo_hierarchy_nodes` | The *instances*: "Jigawa North-East SD001", with geometry = ST_Union of its constituent LGAs |

**Pcode formula** (auto-generated on insert):
```
root node:  {state_pcode}-{level_code}{seq:03d}   → NG018-SD001
child node: {parent_pcode}-{level_code}{seq:03d}   → NG018-SD001-EM001 → NG018-SD001-EM001-FC001
```

**adm badge formula** (client-side only, `nodeAdmMap` in HierarchyBuilderPanel.vue):
```
root node (parent_id = null) = adm2
each child = parent_adm + 1
```
This is always correct regardless of depth or level_order.

### Supporting tables

| Table | Role |
|---|---|
| `tenant_scope` | Which adm1+adm2 pcodes this tenant can see. **Must be populated** or hierarchy returns `{}`. |
| `adm_features` | The raw HDX/INEC/OSM admin boundaries (shared across all tenants). |
| `zones` | Old zone grouping system — still served by `/boundaries/hierarchy` but being superseded by `geo_hierarchy_nodes`. |

---

## 2. Current State Per Tenant

| ID | Tenant | Country | adm1 | adm2 | Custom levels | Custom nodes | Status |
|----|--------|---------|------|------|---------------|--------------|--------|
| 1 | Bridge Kenya | KE | 47 counties | 290 sub-counties | 0 | 0 | Not started |
| 2 | Bridge Uganda | UG | 4 regions | 135 districts | 0 | 0 | Not started |
| 3 | Bridge Nigeria (Lagos+Osun) | NG | 2 states | 50 LGAs | 0 | 0 | Not started |
| 4 | Bridge Liberia | LR | 15 counties | 136 districts | 0 | 0 | Not started |
| 5 | Bridge India (AP) | IN | 1 state | 28 districts | 0 | 0 | Not started |
| 9 | EdoBEST | NG | 1 state | 18 LGAs | 0 | 0 | Not started |
| 11 | EKOEXCEL (Lagos) | NG | 1 state | 20 LGAs | 0 | 0 | Not started |
| 12 | Rwanda EQUIP | RW | 5 provinces | 31 districts | 0 | 0 | Not started (scope was missing — fixed) |
| 14 | Kwara Learn | NG | 1 state | 16 LGAs | **2** | **10** | ✅ In progress |
| 15 | Manipur Education | IN | 1 state | 16 districts | 0 | 0 | Not started |
| 16 | Bayelsa Prime | NG | 1 state | 8 LGAs | 0 | 0 | Not started |
| 17 | Espoir CAR | CF | 17 prefectures | 72 sous-préfectures | 0 | 0 | Not started |
| 18 | Jigawa Unite | NG | 1 state | 27 LGAs | **3** | **17** | ✅ In progress |

### Tenant 14 — Kwara Learn
```
Level 1: Senatorial District (SD) — 3 nodes
Level 2: Federal Constituency (FC) — 7 nodes
→ adm depth: State(adm1) → SD(adm2) → FC(adm3) → LGA leaf
```

### Tenant 18 — Jigawa Unite
```
Level 1: Senatorial District (SD) — 3 nodes
Level 2: Emirate (EM) — 5 nodes
Level 3: Federal Constituency (FC) — 9 nodes
→ adm depth: State(adm1) → SD(adm2) → EM(adm3) → FC(adm4) → LGA leaf
```

---

## 3. Country-by-Country Hierarchy Patterns

### Nigeria (NG) — tenants 3, 9, 11, 14, 16, 18

**Available adm data in `adm_features`:**

| Level | Label | Count | Source |
|---|---|---|---|
| adm2 | Local Government Area | 774 | HDX COD-AB |
| adm3 | Ward (NE states only: Borno, Adamawa, Yobe) | 288 | HDX COD-AB |
| adm3 | Senatorial District | via INEC | import-inec-to-pg.js |
| adm4 | Federal Constituency | via INEC | import-inec-to-pg.js |
| adm5 | Ward (all states) | via INEC/GRID3 | import-inec-to-pg.js |

**Natural hierarchy below state:**
```
State (adm1)
  └── Senatorial District (adm2) ← INEC electoral
        └── [Emirate / Traditional District] (adm3) ← Jigawa-specific INEC
              └── Federal Constituency (adm4) ← INEC electoral
                    └── LGA (adm2 in HDX, used as leaf)
                          └── Ward (adm3/5) ← GRID3 or INEC
```

**Per-state variation:**
- **Jigawa (NG018)**: 3 SD → 5 Emirate → 9 FC → 27 LGA → wards. Emirate is a traditional administrative layer unique to Jigawa.
- **Kwara (NG025)**: 3 SD → FC → 16 LGA. No Emirate layer.
- **Lagos (NG025)**: Extremely dense — 20 LGAs, 245 LCDAs (Local Council Development Areas, not in HDX). Simple flat structure is sufficient.
- **Edo (NG010)**: 18 LGAs. Has senatorial/constituency but flat structure likely sufficient.
- **Bayelsa (NG004)**: 8 LGAs only. Minimal.
- **Lagos+Osun (tenant 3)**: 2 states, 50 LGAs combined. Multi-state → Country root mode.

**Key rule for Nigeria:** Every state is different. INEC data is the authoritative source for sub-LGA groupings. Not all states have Emirate layer. Always check INEC data for the specific state before building.

---

### Kenya (KE) — tenant 1

**Available adm data in `adm_features`:**

| Level | Label | Count | Source |
|---|---|---|---|
| adm1 | County | 47 | HDX COD-AB |
| adm2 | Sub-County | 290 | HDX COD-AB |
| adm3 | Ward | ~1,450 | GRID3 (pending import) |

**Natural hierarchy:**
```
Country (adm0)
  └── County (adm1) — 47
        └── Sub-County (adm2) — 290 ← tenant_scope adm2
              └── Ward (adm3) ← pending GRID3 import
```

**Notes:**
- Multi-state (full country) tenant → Country root shown, `isMultiStateTenant=true`.
- Sub-County is currently the "LGA" in tenant_scope. Ward data from GRID3 would add adm3 level to the custom hierarchy.
- Bridge Kenya likely groups Sub-Counties into operational zones, not the full country hierarchy.

---

### Uganda (UG) — tenant 2

**Available adm data in `adm_features`:**

| Level | Label | Count | Source |
|---|---|---|---|
| adm1 | Region | 4 | HDX COD-AB |
| adm2 | District | 135 | HDX COD-AB |
| adm3 | County / Sub-County / Parish | pending | GRID3 (pending) |

**Natural hierarchy:**
```
Country (adm0)
  └── Region (adm1) — 4
        └── District (adm2) — 135 ← tenant_scope adm2
              └── County (adm3) ← pending GRID3
                    └── Sub-County (adm4)
                          └── Parish (adm5)
```

**Notes:**
- Multi-state (full country) tenant → Country root.
- Regions are very coarse (4 total). Districts are the operational unit. Parish-level data from GRID3 is needed for deep hierarchies.

---

### Rwanda (RW) — tenant 12

**Available adm data in `adm_features`:**

| Level | Label | Count | Source |
|---|---|---|---|
| adm1 | Province | 5 | OSM (rwanda-latest.osm.pbf) |
| adm2 | District | 31 (30 active + 1 orphan) | OSM |
| adm3 | Sector | 416 | OSM (available — not imported to adm_features yet) |

**Natural hierarchy:**
```
Country (adm0) — Rwanda EQUIP is country-wide
  └── Province (adm1) — 5
        └── District (adm2) — 30 active ← tenant_scope adm2
              └── Sector (adm3) — 416 ← in adm_features, usable as custom level
                    └── Cell (adm4)
                          └── Village (adm5)
```

**Notes:**
- 1 orphaned district (Bugabira, `parent_pcode=NULL`) — DRC border artifact. `serve-hierarchy.lua` guards against it. **Do not delete it** — it will reappear on re-import.
- Sector-level data IS in `adm_features` (416 rows). These can be used as constituents for custom nodes.
- Multi-state tenant → Country root mode.
- `tenant_scope` was empty on 2026-03-21 — **fixed** by inserting all 36 adm1+adm2 rows.

---

### India (IN) — tenants 5, 15

**Available adm data in `adm_features`:**

| Level | Label | Count | Source |
|---|---|---|---|
| adm1 | State | varies (all India) | OSM (partial) |
| adm2 | District | 779 (all India) | OSM |
| adm3 | Sub-District / Mandal | 6,480 (all India) | OSM |

**Tenant 5 (Bridge India — AP): Andhra Pradesh**
```
State (adm1) — 1
  └── District (adm2) — 28 ← tenant_scope adm2
        └── Mandal (Sub-District, adm3) — ~670 in AP ← in adm_features
```

**Tenant 15 (Manipur Education): Manipur**
```
State (adm1) — 1
  └── District (adm2) — 16 ← tenant_scope adm2
        └── Sub-District (adm3) — ~38 in Manipur ← in adm_features
```

**Notes:**
- No HDX COD-AB for India — OSM only (partial coverage, especially adm3+).
- Sub-District (Mandal in AP) data is in `adm_features` as adm3. These are usable as custom hierarchy nodes.
- Single-state tenants → State root mode (no Country root toggle needed).

---

### Liberia (LR) — tenant 4

**Available adm data in `adm_features`:**

| Level | Label | Count | Source |
|---|---|---|---|
| adm1 | County | 15 | HDX COD-AB |
| adm2 | District | 136 | HDX COD-AB |
| adm3 | Clan | pending | GRID3 or HDX |

**Natural hierarchy:**
```
Country (adm0)
  └── County (adm1) — 15
        └── District (adm2) — 136 ← tenant_scope adm2
              └── Clan (adm3) ← pending
```

**Notes:** Multi-state (full country). HDX COD-AB covers adm1+adm2. Clan data is in HDX but not imported.

---

### Central African Republic (CF) — tenant 17

**Available adm data in `adm_features`:**

| Level | Label | Count | Source |
|---|---|---|---|
| adm1 | Préfecture | 17 | HDX COD-AB |
| adm2 | Sous-préfecture | 72 | HDX COD-AB |
| adm3 | Commune | pending | HDX COD-AB (available) |

**Natural hierarchy:**
```
Country (adm0)
  └── Préfecture (adm1) — 17
        └── Sous-préfecture (adm2) — 72 ← tenant_scope adm2
              └── Commune (adm3) ← pending import
```

**Notes:** Multi-state (full country). HDX covers adm1+adm2. Commune data is available in HDX COD-AB package.

---

## 4. The Unified Method for Building Any Tenant

### Step A — Classify the tenant

```
Single-state?  → adm1 = root, first custom level = adm2
               → isMultiStateTenant = false, Country/State toggle available
Multi-state?   → adm0 = country root, adm1 = states, first custom level = adm2
               → isMultiStateTenant = true, Country root locked ON
```

**Single-state tenants:** 5, 9, 11, 14, 15, 16, 18
**Multi-state tenants:** 1, 2, 3, 4, 12, 17

### Step B — Identify the hierarchy depth for this tenant's country

Use this reference to decide how many `geo_hierarchy_levels` to create:

| Country | Typical depth | Level names (adm2 → leaf) |
|---|---|---|
| NG (state-based) | 1–3 custom levels | SD → [Emirate] → FC → LGA |
| KE | 1 custom level | Sub-County → [Ward] |
| UG | 1–2 custom levels | District → [County → Sub-County] |
| RW | 1–2 custom levels | District → [Sector] |
| IN | 1 custom level | District → [Mandal/Sub-District] |
| LR | 1 custom level | District → [Clan] |
| CF | 1 custom level | Sous-préfecture → [Commune] |

### Step C — Create levels before nodes

In the Hierarchy Editor:
1. Click **+ Level** on the state header
2. In the dialog, choose the level type (from the HDX/INEC canonical list)
3. Confirm the auto-generated code (SD, FC, EM, etc.)
4. Repeat for each depth level

Level order is auto-incremented. **Never skip levels** — if you need SD → EM → FC, create all three before adding nodes.

### Step D — Add nodes by assigning LGAs

Two patterns:

**Pattern A — Grouped node** (the common case):
1. Click **+ Level** on state → dialog → set level type → saves → node appears
2. In the node row, click **+LGAs** → left panel enters selection mode
3. Check all LGAs that belong to this group → **Assign**
4. Node geometry auto-computed (ST_Union), cascades to parent

**Pattern B — Direct LGA node** (flat, for simple tenants):
1. Click **+LGAs** on the state header directly
2. Select LGAs → **Assign**
3. Each LGA becomes its own `geo_hierarchy_node` with `level_label = 'Local Government Area'`

### Step E — Verify adm badges

After building:
- Root node (directly under state) must show **adm2**
- Its children must show **adm3**
- Their children must show **adm4**

If badges are wrong, the node's `parent_id` chain is broken. Use the delete → recreate flow (the `delete_level()` fix now handles FK cleanup correctly).

---

## 5. Known Issues & Outstanding Work

### Missing `tenant_scope` data (blocks everything)

If `tenant_scope` is empty for a tenant → hierarchy returns `{}` → frontend crashes with `states.map is not a function`.

**Fixed for:** Rwanda (12) on 2026-03-21.
**Verified for all others:** Yes, all 12 remaining tenants have `tenant_scope` rows.

**Defensive frontend guard** added to both `fetchHierarchy` (boundaries.ts) and `fetchRawHierarchy` (geoHierarchy.ts) — coerces `states: {}` → `states: []`.

### adm3+ data not imported for several countries

| Country | Missing | Source | Script |
|---|---|---|---|
| KE | Ward (adm3) | GRID3 | pending |
| UG | County / Parish (adm3–5) | GRID3 | pending |
| RW | Sector (adm3) | Already in adm_features (416 rows) ✅ | — |
| LR | Clan (adm3) | HDX COD-AB | pending |
| CF | Commune (adm3) | HDX COD-AB | pending |

Rwanda's Sector data is **already in `adm_features`** — it can be used as constituent_pcodes today without further imports.

### Orphaned district (Rwanda)
- Bugabira district has `parent_pcode = NULL` (DRC border artifact)
- `serve-hierarchy.lua` guards against it: `if l.parent_pcode then`
- Do not delete it — will reappear on OSM re-import

### Jigawa `delete_level()` FK violation (fixed)
- Fixed 2026-03-21: `delete_level()` in `admin-geo-hierarchy.lua` now deletes nodes before levels
- Old stale levels from failed deletes purged from production DB

### Nigeria multi-state tenant (3 — Lagos+Osun)
- Only 2 states, 50 LGAs — likely needs no custom hierarchy
- If needed: treat as multi-state, build separate level sets per state

---

## 6. Build Priority Order

Based on program complexity and data availability:

| Priority | Tenant | Reason |
|---|---|---|
| 1 | 14 Kwara | In progress — finish FC nodes |
| 2 | 18 Jigawa | In progress — finish FC nodes |
| 3 | 12 Rwanda | Sector data already in DB — easy to build |
| 4 | 9 EdoBEST | Single state, 18 LGAs — simple flat or 2-level |
| 5 | 11 EKOEXCEL | Lagos, 20 LGAs — simple flat |
| 6 | 16 Bayelsa | 8 LGAs only — trivial |
| 7 | 5 India AP | 28 districts, sub-districts in DB |
| 8 | 15 Manipur | 16 districts, sub-districts in DB |
| 9 | 1 Kenya | 47 counties — large, needs Ward import from GRID3 |
| 10 | 2 Uganda | 135 districts — needs Parish import from GRID3 |
| 11 | 4 Liberia | 136 districts — needs Clan import |
| 12 | 17 CAR | 72 sous-préfectures — needs Commune import |
| 13 | 3 Nigeria multi | 50 LGAs — lowest priority, may not need custom hierarchy |
