# Rwanda Tenant Setup Guide

**Tenant ID:** 12
**Program:** Rwanda EQUIP
**Hierarchy:** Province → District → Sector (all stored as `adm_features`, no zones)

---

## Overview

Rwanda's geographic hierarchy uses three administrative levels, all stored as `adm_features` rows:

| Level | DB `adm_level` | Count | Pcode format | Label | Source |
|-------|---------------|-------|--------------|-------|--------|
| Province | 1 | 5 | `RW01`–`RW05` | Province | OSM rwanda-boundaries.geojson |
| District | 2 | 30 | `RWD001`–`RWD031` | District | OSM rwanda-boundaries.geojson |
| Sector | 3 | 416 | NISR codes (e.g. `RW1101`) | Sector | HDX NISR SHP |

There are **no zones** for Rwanda. The hierarchy is built entirely from `adm_features` parent-child relationships. This makes it self-maintaining — unlike zone-based tenants, there is nothing to manually audit or sync.

The `/boundaries/hierarchy` endpoint returns the full Province → District → Sector tree via the recursive `build_children` function in `serve-hierarchy.lua`. The `/region` endpoint falls back to raw LGA (adm_level=2, district) lookup for Rwanda since there are no zones.

---

## Data Sources

| Level | Source | License |
|-------|--------|---------|
| Province (adm1) | OSM `admin_level=4`, imported from `boundaries/rwanda-boundaries.geojson` | ODbL |
| District (adm2) | OSM `admin_level=6`, same file | ODbL |
| Sector (adm3) | HDX NISR: `rwa_adm3_2006_NISR_WGS1984_20181002` SHP | CC BY-IGO |

HDX dataset URL: https://data.humdata.org/dataset/administrative-boundaries-rwanda

---

## Province and District Import (Pre-existing)

Provinces and districts were imported from `boundaries/rwanda-boundaries.geojson` using a one-off Python script (`/tmp/import_rwanda.py`, run directly on the GCP VM). The file was derived from OSM data.

**Province pcodes assigned:**

| Province | Pcode |
|----------|-------|
| Kigali City | RW01 |
| Southern Province | RW02 |
| Western Province | RW03 |
| Northern Province | RW04 |
| Eastern Province | RW05 |

The OSM source uses ISO 3166-2 codes (`RW-01` through `RW-05`). These were normalised to `RW01`–`RW05` during import.

**District pcodes assigned:**

Districts were numbered sequentially `RWD001`–`RWD031` based on OSM `admin_level=6` features. There are 30 active districts; `RWD031` is assigned to Rwamagana. One record (`Bugabira`) has `parent_pcode = NULL` — a DRC border artifact — and is treated as orphaned. `serve-hierarchy.lua` guards against this with `if a.parent_pcode then`.

**Province names** were corrected to their proper English names during import (the OSM source uses abbreviated forms). The names in the DB should match Rwanda's official English province designations.

To verify province/district counts in DB:

```bash
gcloud compute ssh martin-tileserver --zone=us-central1-a --command="
  docker exec tileserver_postgres_1 psql -U mapserver -d mapserver -t -c \"
    SELECT adm_level, COUNT(*) FROM adm_features WHERE country_code='RW' GROUP BY adm_level ORDER BY 1;
  \"
"
# Expected: 1 -> 5, 2 -> 30 (or 31 including Bugabira orphan)
```

---

## Sector Import Step-by-Step

### 1. Download the HDX NISR SHP file

From: https://data.humdata.org/dataset/administrative-boundaries-rwanda

Download the file named: `rwa_adm3_2006_NISR_WGS1984_20181002.zip`
(This is the Rwanda adm3 (sector) dataset from NISR/OCHA, last updated 2018-10-02.)

### 2. Upload and extract on the GCP VM

```bash
# Upload from local machine
gcloud compute scp --zone=us-central1-a \
  rwa_adm3_2006_NISR_WGS1984_20181002.zip \
  martin-tileserver:/tmp/

# On the GCP VM: extract
gcloud compute ssh martin-tileserver --zone=us-central1-a --command="
  mkdir -p /tmp/rwa_adm2
  unzip -o /tmp/rwa_adm3_2006_NISR_WGS1984_20181002.zip -d /tmp/rwa_adm2
"
```

The script expects the following files at `/tmp/rwa_adm2/`:

```
/tmp/rwa_adm2/rwa_adm3_2006_NISR_WGS1984_20181002.shp
/tmp/rwa_adm2/rwa_adm3_2006_NISR_WGS1984_20181002.dbf
/tmp/rwa_adm2/rwa_adm3_2006_NISR_WGS1984_20181002.shx
```

### 3. NISR pcode format

NISR uses a composite numeric pcode system for adm3 (sectors):

- `ADM3_PCODE` — sector pcode, e.g. `RW1101`, `RW1102`, `RW5703`
- `ADM2_PCODE` — NISR district pcode, e.g. `RW11`, `RW57`
- `ADM3_EN` — English sector name

The NISR district pcodes (`RW11`–`RW57`) do **not** match the `RWD001`–`RWD031` pcodes already in the DB. The import script maps them via a hardcoded dictionary (`NISR_TO_RWD`) keyed on the NISR code:

```
RW11 -> RWD005  (Nyarugenge)     RW12 -> RWD002  (Gasabo)
RW13 -> RWD003  (Kicukiro)       RW21 -> RWD025  (Nyanza)
RW22 -> RWD012  (Gisagara)       RW23 -> RWD006  (Nyaruguru)
RW24 -> RWD013  (Huye)           RW25 -> RWD023  (Nyamagabe)
RW26 -> RWD027  (Ruhango)        RW27 -> RWD004  (Muhanga)
RW28 -> RWD014  (Kamonyi)        RW31 -> RWD015  (Karongi)
RW32 -> RWD030  (Rutsiro)        RW33 -> RWD026  (Rubavu)
RW34 -> RWD021  (Nyabihu)        RW35 -> RWD020  (Ngororero)
RW36 -> RWD029  (Rusizi)         RW37 -> RWD024  (Nyamasheke)
RW41 -> RWD028  (Rulindo)        RW42 -> RWD009  (Gakenke)
RW43 -> RWD018  (Musanze)        RW44 -> RWD001  (Burera)
RW45 -> RWD011  (Gicumbi)        RW51 -> RWD031  (Rwamagana)
RW52 -> RWD022  (Nyagatare)      RW53 -> RWD010  (Gatsibo)
RW54 -> RWD016  (Kayonza)        RW55 -> RWD017  (Kirehe)
RW56 -> RWD019  (Ngoma)          RW57 -> RWD008  (Bugesera)
```

Sectors are inserted with `parent_pcode` set to the corresponding `RWDxxx` pcode. The sector's own `pcode` is kept as-is from the NISR file (e.g. `RW1101`).

### 4. Upload the import script to the GCP VM

```bash
gcloud compute scp --zone=us-central1-a \
  scripts/import-rwa-sectors.py \
  martin-tileserver:/home/omarlakhdhar_gmail_com/rust-map-server/scripts/
```

### 5. Run dry-run first

```bash
gcloud compute ssh martin-tileserver --zone=us-central1-a --command="
  cd /home/omarlakhdhar_gmail_com/rust-map-server
  sudo python3 scripts/import-rwa-sectors.py --dry-run 2>&1 | head -60
"
```

Expected dry-run output: 416 lines like `[DRY-RUN] RW1101  "Kigali"  parent=RWD005`, followed by a summary showing `Would insert 416 sectors (0 skipped)`. Any `[WARN]` lines indicate missing geometry or unmapped NISR district pcodes.

### 6. Run the actual import

```bash
gcloud compute ssh martin-tileserver --zone=us-central1-a --command="
  cd /home/omarlakhdhar_gmail_com/rust-map-server
  sudo python3 scripts/import-rwa-sectors.py
"
```

The script:
1. Reads the DBF (attributes) and SHP (geometry) files using a pure Python reader — no GDAL/ogr2ogr dependency required.
2. Generates `INSERT INTO adm_features ... ON CONFLICT (pcode) DO UPDATE` SQL for all 416 sectors (idempotent).
3. Executes the SQL inside a transaction via `docker exec -i tileserver_postgres_1 psql`.
4. In a separate transaction: updates `area_sqkm`, `center_lat`, `center_lon` for new rows.
5. Inserts `tenant_scope` rows for all 416 sectors for tenant 12 (`ON CONFLICT DO NOTHING`).
6. Runs `VACUUM ANALYZE` on both tables.

### 7. Clear the hierarchy cache

```bash
gcloud compute ssh martin-tileserver --zone=us-central1-a \
  --command="sudo docker restart tileserver_nginx_1"
```

`openresty -s reload` is NOT sufficient — `ngx.shared.hierarchy_cache` persists across config reloads. A full container restart is required.

---

## Verification

### Count sectors in DB

```bash
gcloud compute ssh martin-tileserver --zone=us-central1-a --command="
  docker exec tileserver_postgres_1 psql -U mapserver -d mapserver -t -c \"
    SELECT COUNT(*) FROM adm_features WHERE country_code='RW' AND adm_level=3;
  \"
"
# Expected: 416
```

### Count tenant_scope entries for sectors

```bash
gcloud compute ssh martin-tileserver --zone=us-central1-a --command="
  docker exec tileserver_postgres_1 psql -U mapserver -d mapserver -t -c \"
    SELECT COUNT(*) FROM tenant_scope ts
    JOIN adm_features a ON a.pcode = ts.pcode
    WHERE ts.tenant_id = 12 AND a.adm_level = 3;
  \"
"
# Expected: 416
```

### Verify hierarchy via API

```bash
# Full hierarchy (should show Province -> District -> Sector tree)
curl -s -H "X-Tenant-ID: 12" "http://35.239.86.115:8080/boundaries/hierarchy?t=12" \
  | python3 -m json.tool | head -80

# Should show: pcode=RW, states=[{pcode=RW01,...,children=[{pcode=RWDxxx,...,children=[{pcode=RW1101,...}]}]}]
```

### Spot-check a known sector

```bash
# Kigali City / Nyarugenge / Gitega sector area
curl -s -H "X-Tenant-ID: 12" \
  "http://35.239.86.115:8080/boundaries/search?q=gitega" | python3 -m json.tool
```

### Test /region endpoint for a point in Rwanda

```bash
# Kigali city center: lat=-1.9441, lon=30.0619
curl -s -H "X-Tenant-ID: 12" \
  "http://35.239.86.115:8080/region?lat=-1.9441&lon=30.0619" | python3 -m json.tool
```

---

## Key Implementation Notes

### Why a pure Python SHP reader (no GDAL)

The GCP VM runs the `tileserver_postgres_1` Docker container but does not have GDAL/ogr2ogr installed at the OS level. The import script reads SHP and DBF files using the Python `struct` module only — no external dependencies beyond the standard library. This means `sudo python3 scripts/import-rwa-sectors.py` runs on a vanilla Debian/Ubuntu VM without any additional package installs.

### Bugs fixed during development

1. **GeoJSON nesting for MultiPolygon**: The SHP reader initially produced `[[rings]]` (list of rings wrapped in an extra list layer). PostGIS `ST_GeomFromGeoJSON` requires `[rings]` for the `coordinates` field of a `MultiPolygon`. Fixed by using `[rings]` directly without the extra wrapping list.

2. **Negative `ST_Area` from winding order**: SHP files can have either clockwise or counter-clockwise ring winding. PostGIS `ST_Area` returns negative values for clockwise exterior rings. The `area_sqkm` UPDATE uses `ABS(ST_Area(...))` to handle both winding orders.

3. **Transaction isolation for area UPDATE**: The `area_sqkm` UPDATE and `tenant_scope` INSERT run in a **separate statement** after the main `COMMIT` — not inside the same transaction as the inserts. This is required because `ST_Area` on a geography column needs the rows to be committed before the geography cast resolves correctly.

### NISR pcode mapping strategy

The NISR dataset uses a two-part district pcode system (`RW11` = Kigali/Nyarugenge, `RW57` = Bugesera) that doesn't correspond to the sequential `RWD001`–`RWD031` pcodes in the DB. Rather than attempting a spatial join (which would be slow and potentially ambiguous at district borders), the script uses a hardcoded dictionary based on name-matching done once offline. All 30 active NISR districts have entries in `NISR_TO_RWD`. If a future NISR file adds a new district code, the script will print a `[WARN] Unmapped NISR district pcode` message and skip those sectors.

### Orphaned Bugabira district

One district (`Bugabira`, `parent_pcode = NULL`) is a DRC border artifact — it appears in OSM data as a district straddling the Rwanda-DRC border but is not officially part of Rwanda's administrative structure. `serve-hierarchy.lua` guards this case with `if a.parent_pcode then` when building the `adm2_by_parent` index. Bugabira's sectors (if any were imported from NISR) would have a valid `parent_pcode` pointing to `RWD...` and would appear in the hierarchy correctly.

---

## Tenant Scope

All 416 sectors are added to `tenant_scope` for tenant 12 (Rwanda EQUIP). The `import-rwa-sectors.py` script handles this automatically:

```sql
INSERT INTO tenant_scope (tenant_id, pcode)
SELECT 12, pcode FROM adm_features
WHERE country_code = 'RW' AND adm_level = 3
ON CONFLICT DO NOTHING;
```

This means the `get_hierarchy_adm_features` query (used by `serve-hierarchy.lua`) will include all sectors when `tenant_id = 12`, and the full Province → District → Sector tree will be assembled via the recursive `build_children` function.

The `get_geojson` query also includes adm3+ features via a `tenant_scope` join and `adm_level >= 3` filter, so sector polygon geometries are available in the FE for click-to-highlight.

---

## Relevant Files

| File | Purpose |
|------|---------|
| `scripts/import-rwa-sectors.py` | SHP → PostgreSQL import for Rwanda adm3 sectors |
| `tileserver/lua/serve-hierarchy.lua` | Hierarchy builder; `build_children` handles Province→District→Sector |
| `tileserver/lua/boundary-db.lua` | `get_hierarchy_adm_features`: fetches all levels for tenant, including sectors |
| `tileserver/lua/region-lookup.lua` | `/region` endpoint; for Rwanda returns district (adm2) as lowest level since no zones |
