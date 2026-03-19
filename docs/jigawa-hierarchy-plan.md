# Jigawa Hierarchy Plan

## Goal

Replace the "spotlight regions API" with this map server's `/region` endpoint for all tenants. For the `/region` response to be a drop-in replacement, it must return the same region identifiers (pcodes / IDs) that the spotlight app uses to identify each geo level.

This document covers Jigawa (tenant 18) in detail, then provides a per-tenant status table for all 13 tenants.

---

## 1. Current Jigawa Structure

**Tenant ID:** 18 — Jigawa Unite
**State:** NG018 (Jigawa)

The intended operational hierarchy for Jigawa has six levels:

```
State (NG018)
  └── Senatorial District (3)         adm3 in adm_features, level_label="Senatorial District"
        └── Emirate (custom groups)   zones table, children_type='zone', zone_level=1
              └── Federal Constituency (e.g. 7+)  zones table, zone_level=2
                    └── LGA (adm2, 27 LGAs)       adm_features, parent_pcode=NG018
                          └── Ward (adm3, GRID3)  adm_features, level_label="Ward"
```

**What is stored where:**

| Level | Storage | Count | Notes |
|-------|---------|-------|-------|
| State | `adm_features` adm_level=1 | 1 | NG018 |
| Senatorial District | `adm_features` adm_level=3 | 3 | INEC data, parent_pcode=NG018 |
| Emirate | `zones` table | ~5 | Custom zones, `children_type='zone'`, group FCs |
| Federal Constituency | `zones` table | ~7 | Custom zones, `children_type='lga'`, group LGAs |
| LGA | `adm_features` adm_level=2 | 27 | parent_pcode=NG018, NOT pointing to FC |
| Ward | `adm_features` adm_level=3 | TBD | GRID3 data, level_label="Ward" |

**Important:** LGAs have `parent_pcode = NG018` (the state), not pointing to their Federal Constituency. The FC → LGA relationship is expressed only through `zones.constituent_pcodes`. This means the `adm_features` table alone does not encode the FC-level grouping; it lives entirely in the `zones` table.

---

## 2. Rwanda vs Jigawa: Why the Difference

| Aspect | Rwanda (tenant 12) | Jigawa (tenant 18) |
|--------|-------------------|-------------------|
| Hierarchy type | Pure `adm_features` | Mixed: `adm_features` + `zones` |
| Data source for sub-state levels | NISR/OSM official admin data | INEC electoral + custom Emirates |
| Zones | None | Yes (Emirates, FCs) |
| LGA parent_pcode | Points to District | Points to State |
| Self-maintaining? | Yes (parent-child in adm_features) | No (zone membership requires manual management) |
| /region endpoint | Returns District (adm2) match | Returns deepest zone match + LGA |

Rwanda's Province → District → Sector chain is fully encoded in `adm_features.parent_pcode`. Once imported, the hierarchy is static and self-consistent. `serve-hierarchy.lua`'s `build_children` function automatically assembles the tree from those parent-child relationships.

Jigawa uses the `zones` table for the Emirate and FC levels because:
1. **Emirates are not official INEC administrative boundaries** — they are cultural/traditional groupings used operationally by NewGlobe/Jigawa BEST. There is no official SHP file for Emirates.
2. **FCs as grouping units** — while INEC FCs are official, the decision to use them as zone containers (rather than pure `adm_features`) was made to allow custom coloring and to fit the zone management workflow already built into the system.

---

## 3. The Problem With Zone-Based Hierarchies

Custom zones require manual management and can become stale:

- **Zone membership drift**: If a new LGA is created by government redistricting, it will not automatically appear in any zone's `constituent_pcodes`. The FC zone will silently exclude it.
- **No referential integrity**: `constituent_pcodes TEXT[]` has no foreign key constraint to `adm_features.pcode`. A pcode typo or a deleted LGA leaves a dangling reference.
- **Zone pcode format divergence**: Zone pcodes follow the convention `{state_pcode}-Z{nn}` (e.g. `NG018-Z01`). If the spotlight app uses a different ID scheme for Senatorial Districts / Emirates / FCs, the pcodes will not match and `/region` responses will not be interchangeable.
- **Cache invalidation**: Zone changes require `docker restart tileserver_nginx_1` to clear `ngx.shared.hierarchy_cache`. Forgetting this step leaves stale hierarchy data served to clients.

---

## 4. The Goal: Match Spotlight's Geo-Hierarchy

For `/region` to replace the spotlight regions API for Jigawa, the following must be true for any given school coordinate:

1. The zone pcode returned in `/region`'s `zone_chain` matches the region ID the spotlight app uses at each hierarchy level.
2. The LGA pcode matches what spotlight calls the LGA.
3. The hierarchy depth and level labels match spotlight's region hierarchy.

This requires **knowing what IDs spotlight uses** for each level in Jigawa — specifically: does it use the INEC Senatorial pcode, a custom emirate ID, a custom FC ID, or something else?

---

## 5. Two Approaches

### Approach A: Keep Zones, Verify Accuracy

Audit existing zones against spotlight's region identifiers. Fix any discrepancies in zone pcodes or constituent_pcodes. No structural DB changes.

**Steps:**
1. Extract spotlight's region IDs for all Jigawa schools.
2. For each level (Senatorial, Emirate, FC), compare spotlight IDs to zone pcodes in `zones` table.
3. If IDs differ in format: either rename zone pcodes or add an alias column.
4. Verify all 27 LGAs appear as `constituent_pcodes` in exactly one FC zone.
5. Verify all FC zone pcodes appear as `constituent_pcodes` in exactly one Emirate zone.

**Pros:** Minimal DB changes. No LGA parent_pcode migration needed. Zones are already used for map highlighting and coloring.

**Cons:** Still requires manual zone management going forward. Any future LGA redistricting requires a manual zone update. Zone membership errors are silent.

### Approach B: Migrate to adm_features (Rwanda-style)

Store Senatorial Districts, Emirates, and FCs as `adm_features` rows with a proper parent-child chain. Update LGA `parent_pcode` to point to their FC rather than the state.

**Steps:**
1. INEC Senatorial pcodes are already in `adm_features` (adm_level=3, parent=NG018). Keep these.
2. Derive Emirate boundaries by `ST_Union` of constituent FC zones → insert as `adm_features` adm_level=4 with custom pcodes.
3. Insert FC boundaries as `adm_features` adm_level=4 (or 5 if after Emirates), derived from INEC FC data.
4. Update `adm_features.parent_pcode` for all 27 Jigawa LGAs to point to their FC row.
5. Remove the corresponding `zones` rows (or keep them in parallel during transition).

**Pros:** Hierarchy is self-consistent in `adm_features`. `build_children` in `serve-hierarchy.lua` automatically handles it. No manual zone management. Future INEC redistricting can be handled by re-running `import-inec-to-pg.js`.

**Cons:** Emirates are not official boundaries — their shapes must be derived from the zone definitions (ST_Union of FC zones), which creates a dependency on the existing zone data being correct before migration. Requires LGA parent_pcode migration, which is a one-time but careful operation. Zone-based coloring in the map UI would need to be rebuilt from adm_features styling instead.

---

## 6. Recommended Approach: Hybrid

Keep zones for map display and coloring — they are genuinely useful for visual highlighting of operational groupings. But ensure that:

1. **Zone pcodes match spotlight's region identifiers** at every level. If spotlight calls the "Dutse Emirate" region by ID `NG018-Z02`, then the zone pcode in the DB must be exactly `NG018-Z02`.
2. **The `/region` endpoint returns matching values**. Because `region_lookup` in `boundary-db.lua` returns `zone_chain` ordered shallowest → deepest, and `region-lookup.lua` maps these to `adm_3`, `adm_4`, `adm_5` keys based on `zone_level`, the response key names must also match spotlight's expected field names.
3. **Zone constituent_pcodes are complete and accurate**. All 27 Jigawa LGAs must appear in exactly one FC zone.

The hybrid approach defers the structural migration decision until the spotlight region IDs are known. If spotlight IDs happen to already match zone pcodes, Approach A (verify and fix) is sufficient. If spotlight uses a completely different ID scheme, Approach B (migrate to adm_features with the spotlight pcodes) may be cleaner long-term.

---

## 7. Migration Checklist

### Phase 1: Audit

- [ ] **Get spotlight's region hierarchy for Jigawa.** What IDs does spotlight use for each level (Senatorial, Emirate, FC)? Extract these from the spotlight API or database directly.
- [ ] **Map spotlight IDs to zone pcodes.** For each spotlight region ID, find the corresponding zone pcode in the `zones` table. Are the pcodes identical, or is there a naming/format divergence?
- [ ] **Verify all 27 LGAs are assigned to exactly one FC zone.** Run:

  ```sql
  SELECT a.pcode, a.name, COUNT(z.zone_pcode) AS zone_count
  FROM adm_features a
  JOIN tenant_scope ts ON ts.pcode = a.pcode AND ts.tenant_id = 18
  WHERE a.adm_level = 2
  LEFT JOIN zones z ON a.pcode = ANY(z.constituent_pcodes) AND z.tenant_id = 18
  GROUP BY a.pcode, a.name
  HAVING COUNT(z.zone_pcode) != 1
  ORDER BY a.name;
  -- Should return 0 rows. Any row is a problem (LGA in 0 or 2+ zones).
  ```

- [ ] **Verify the FC → Emirate → Senatorial chain is complete.** Every FC zone must have a valid `parent_pcode` pointing to an Emirate zone. Every Emirate zone must have a valid `parent_pcode` pointing to NG018 or a Senatorial pcode.

  ```sql
  -- Zones with missing/dangling parent
  SELECT z.zone_pcode, z.zone_name, z.zone_level, z.parent_pcode,
         (SELECT zone_pcode FROM zones WHERE zone_pcode = z.parent_pcode AND tenant_id = 18) AS parent_exists,
         (SELECT pcode FROM adm_features WHERE pcode = z.parent_pcode) AS adm_parent_exists
  FROM zones z
  WHERE z.tenant_id = 18
  ORDER BY z.zone_level, z.zone_name;
  ```

- [ ] **Verify ward → LGA chain.** All wards (adm_level=3, level_label='Ward') for Jigawa LGAs should have `parent_pcode` set to the correct LGA pcode.

  ```sql
  SELECT COUNT(*), COUNT(parent_pcode) AS with_parent
  FROM adm_features
  WHERE country_code = 'NG' AND adm_level = 3 AND level_label = 'Ward'
    AND parent_pcode IN (
      SELECT pcode FROM adm_features
      JOIN tenant_scope ON pcode = adm_features.pcode AND tenant_id = 18
      WHERE adm_level = 2
    );
  ```

### Phase 2: Fix

- [ ] **Fix any zone pcodes that don't match spotlight IDs.** Use `UPDATE zones SET zone_pcode = '...' WHERE zone_pcode = '...' AND tenant_id = 18;` (also update any child zones that reference the old pcode as `parent_pcode`, and any `constituent_pcodes` arrays that contain zone pcodes).
- [ ] **Fill gaps in constituent_pcodes.** For any LGA not assigned to an FC zone, determine the correct FC and add it.
- [ ] **Verify /region for known school coordinates.** Pick 5+ schools from each Senatorial zone with known spotlight region IDs. Compare `/region` response to spotlight:

  ```bash
  curl -s -H "X-Tenant-ID: 18" \
    "http://35.239.86.115:8080/region?lat=<lat>&lon=<lon>" | python3 -m json.tool
  ```

### Phase 3: Validate and Deploy

- [ ] **Run full comparison.** For every school in Jigawa: call `/region`, compare `zone_chain` pcodes at each level to spotlight region IDs. 100% match required before sunsetting spotlight.
- [ ] **Restart nginx to clear hierarchy cache** after any zone changes.
- [ ] **Repeat audit for each other tenant** before sunsetting the regions API (see Per-Tenant Status table below).

---

## 8. /region Endpoint Compatibility with Rwanda

Rwanda's `/region` endpoint currently returns a **district** (adm_level=2) match as the lowest level, because Rwanda has no zones. The `boundary-db.lua` `region_lookup` function:

1. Checks for zones containing the point first.
2. If no zones: falls back to the LGA query (which for Rwanda is `adm_level=2` = District).
3. Returns `matched_level = "lga"` with `state_pcode` = province pcode and `lga_pcode` = district pcode.

The `region-lookup.lua` script then maps this to `adm_0` (country), `adm_1` (province), `adm_4` (district). **Sectors are not yet returned by `/region` for Rwanda** — the region_lookup only queries `adm_level=2` in the LGA fallback. This is a gap: if spotlight uses sector-level region IDs for Rwanda schools, the `/region` endpoint needs to be extended to also query `adm_level=3` for Rwanda.

To add sector-level resolution for Rwanda `/region`:
- Add a second PostGIS query to `region_lookup` that checks `adm_level=3` using `ST_Contains` for the tenant's scope.
- Return a `sector` field alongside `lga` (district) in the matched-lga path.
- Or: treat sectors as zones in a zone-like lookup, leveraging the existing zone_chain machinery.

This should be confirmed against what spotlight expects for Rwanda before any endpoint change is deployed.

---

## 9. Per-Tenant Status

| Tenant ID | Program | Country | Hierarchy Type | Spotlight Match Status | Notes |
|-----------|---------|---------|---------------|----------------------|-------|
| 1 | Bridge Kenya | Kenya | adm_features (adm1/adm2) + zones | Unknown — audit needed | Zones exist (clusters). Need to verify zone pcodes match spotlight |
| 2 | Bridge Uganda | Uganda | adm_features (adm1/adm2) + zones | Unknown — audit needed | Same as Kenya |
| 3 | Bridge Nigeria | Nigeria | adm_features (adm1/adm2) + zones | Unknown — audit needed | Lagos + Osun; zones likely cluster LGAs |
| 4 | Bridge Liberia | Liberia | adm_features (adm1/adm2) | Unknown — audit needed | No zones; simpler hierarchy |
| 5 | Bridge India (AP) | India (Andhra Pradesh) | adm_features (partial) | Unknown — audit needed | No HDX COD-AB for India; OSM only; likely incomplete |
| 9 | EdoBEST | Nigeria (Edo) | adm_features (adm1/adm2) + zones | Unknown — audit needed | Single-state tenant |
| 11 | EKOEXCEL | Nigeria (Lagos) | adm_features (adm1/adm2) + zones | Unknown — audit needed | Single-state tenant (Lagos) |
| 12 | Rwanda EQUIP | Rwanda | adm_features only (Province/District/Sector) | Unknown — sector level gap | /region returns district only; confirm if spotlight uses sector IDs |
| 14 | Kwara Learn | Nigeria (Kwara) | adm_features (adm1/adm2) + zones | Unknown — audit needed | Single-state tenant |
| 15 | Manipur Education | India (Manipur) | adm_features (partial) | Unknown — audit needed | No HDX COD-AB; likely incomplete |
| 16 | Bayelsa Prime | Nigeria (Bayelsa) | adm_features (adm1/adm2) + zones | Unknown — audit needed | Single-state tenant |
| 17 | Espoir CAR | Central African Republic | adm_features (adm1/adm2) | Unknown — audit needed | No zones; CAR HDX data imported |
| 18 | Jigawa Unite | Nigeria (Jigawa) | adm_features + zones (Emirate/FC) | Unknown — detailed audit required | Most complex zone hierarchy; see this document |

### Tenants with no zones (simpler case)

Tenants 4 (Liberia) and 17 (CAR) have no zones. Their `/region` responses return only `adm_0` + `adm_1` + `adm_4` (country, state, LGA). If spotlight only needs country/state/LGA for these programs, the endpoint should already be compatible — just verify LGA pcodes match.

### Tenants with incomplete boundary data

Tenants 5 (India AP) and 15 (India Manipur) have no HDX COD-AB data; OSM admin boundaries for India are partial. The `/region` endpoint may return no match for some school coordinates. These tenants likely need additional boundary data import before the regions API can be sunset.

### Priority order for auditing

Recommended audit order based on program size and complexity:

1. **Tenant 18 (Jigawa)** — most complex zone hierarchy; detailed plan in this document
2. **Tenant 12 (Rwanda)** — sector-level /region gap needs resolution
3. **Tenant 11 (EKOEXCEL / Lagos)** — high-visibility program
4. **Tenant 1 (Bridge Kenya)** — established program; zones likely match existing spotlight
5. **Tenants 9, 14, 16, 3** — single-state Nigeria tenants; similar audit process
6. **Tenant 2 (Bridge Uganda)** — zones likely exist; audit needed
7. **Tenants 4, 17** — no zones, simpler; verify LGA pcode format match
8. **Tenants 5, 15** — India; needs boundary data before this can be completed

---

## Relevant Files

| File | Purpose |
|------|---------|
| `tileserver/lua/boundary-db.lua` | `region_lookup`: zone → LGA chain lookup; `get_hierarchy_zones`: zone tree |
| `tileserver/lua/region-lookup.lua` | `/region` endpoint: maps internal result to `adm_N` keys in response |
| `tileserver/lua/serve-hierarchy.lua` | Hierarchy builder: `build_children` recursive tree from zones + adm_features |
| `scripts/import-inec-to-pg.js` | Nigeria INEC senatorial/FC → adm_features import |
| `scripts/schema.sql` | `zones` table schema: `zone_level`, `children_type`, `constituent_pcodes` |
