#!/usr/bin/env python3
"""
import-rwa-sectors.py
Reads the HDX Rwanda NISR SHP file (adm3 = sectors) and imports into adm_features.

Requires the SHP to already be extracted at /tmp/rwa_adm2/.
Runs on the GCP VM where the postgis container is accessible.

Usage:
  python3 scripts/import-rwa-sectors.py [--dry-run]

Parent pcode mapping:
  NISR district pcodes (RW11..RW57) -> our DB pcodes (RWD001..RWD031)
  Done by name match since both datasets now use the same English district names.
"""

import struct
import json
import subprocess
import sys
import os

DRY_RUN = '--dry-run' in sys.argv

SHP_DIR = '/tmp/rwa_adm2'
SHP_BASE = os.path.join(SHP_DIR, 'rwa_adm3_2006_NISR_WGS1984_20181002')

# ---------------------------------------------------------------------------
# NISR district pcode -> our RWD pcode (name-matched)
# ---------------------------------------------------------------------------
NISR_TO_RWD = {
    'RW11': 'RWD005',  # Nyarugenge
    'RW12': 'RWD002',  # Gasabo
    'RW13': 'RWD003',  # Kicukiro
    'RW21': 'RWD025',  # Nyanza
    'RW22': 'RWD012',  # Gisagara
    'RW23': 'RWD006',  # Nyaruguru
    'RW24': 'RWD013',  # Huye
    'RW25': 'RWD023',  # Nyamagabe
    'RW26': 'RWD027',  # Ruhango
    'RW27': 'RWD004',  # Muhanga
    'RW28': 'RWD014',  # Kamonyi
    'RW31': 'RWD015',  # Karongi
    'RW32': 'RWD030',  # Rutsiro
    'RW33': 'RWD026',  # Rubavu
    'RW34': 'RWD021',  # Nyabihu
    'RW35': 'RWD020',  # Ngororero
    'RW36': 'RWD029',  # Rusizi
    'RW37': 'RWD024',  # Nyamasheke
    'RW41': 'RWD028',  # Rulindo
    'RW42': 'RWD009',  # Gakenke
    'RW43': 'RWD018',  # Musanze
    'RW44': 'RWD001',  # Burera
    'RW45': 'RWD011',  # Gicumbi
    'RW51': 'RWD031',  # Rwamagana
    'RW52': 'RWD022',  # Nyagatare
    'RW53': 'RWD010',  # Gatsibo
    'RW54': 'RWD016',  # Kayonza
    'RW55': 'RWD017',  # Kirehe
    'RW56': 'RWD019',  # Ngoma
    'RW57': 'RWD008',  # Bugesera
}

# ---------------------------------------------------------------------------
# Read DBF attributes
# ---------------------------------------------------------------------------
def read_dbf(path):
    with open(path, 'rb') as f:
        f.seek(4)
        num_records = struct.unpack('<I', f.read(4))[0]
        header_size = struct.unpack('<H', f.read(2))[0]
        f.seek(32)
        fields = []
        while True:
            field_rec = f.read(32)
            if not field_rec or field_rec[0] == 0x0D:
                break
            name = field_rec[:11].replace(b'\x00', b'').decode('ascii', errors='ignore').strip()
            length = field_rec[16]
            fields.append((name, length))
        f.seek(header_size)
        records = []
        for _ in range(num_records):
            f.read(1)  # deletion flag
            row = {}
            for fname, flen in fields:
                val = f.read(flen)
                try:
                    row[fname] = val.decode('utf-8', errors='replace').strip()
                except Exception:
                    row[fname] = ''
            records.append(row)
    return records

# ---------------------------------------------------------------------------
# Read SHP geometry -> GeoJSON polygon string per record
# ---------------------------------------------------------------------------
def read_shp_geometries(path):
    """Returns list of GeoJSON geometry strings, one per record (same order as DBF)."""
    geometries = []
    with open(path, 'rb') as f:
        # File header: 100 bytes
        f.seek(100)
        while True:
            rec_header = f.read(8)
            if len(rec_header) < 8:
                break
            # rec_num = struct.unpack('>I', rec_header[:4])[0]  # big-endian
            content_len = struct.unpack('>I', rec_header[4:8])[0] * 2  # in bytes

            content = f.read(content_len)
            if len(content) < 4:
                break

            shape_type = struct.unpack('<i', content[:4])[0]

            if shape_type == 0:  # Null shape
                geometries.append(None)
                continue

            if shape_type not in (5, 15, 25):  # Polygon variants
                geometries.append(None)
                continue

            # Bounding box: 32 bytes (4 doubles)
            offset = 4 + 32
            num_parts = struct.unpack('<i', content[offset:offset+4])[0]; offset += 4
            num_points = struct.unpack('<i', content[offset:offset+4])[0]; offset += 4

            parts = []
            for _ in range(num_parts):
                parts.append(struct.unpack('<i', content[offset:offset+4])[0]); offset += 4

            points = []
            for _ in range(num_points):
                x = struct.unpack('<d', content[offset:offset+8])[0]; offset += 8
                y = struct.unpack('<d', content[offset:offset+8])[0]; offset += 8
                points.append([round(x, 7), round(y, 7)])

            # Build rings
            rings = []
            for i, start in enumerate(parts):
                end = parts[i+1] if i+1 < num_parts else num_points
                rings.append(points[start:end])

            geom = {'type': 'MultiPolygon', 'coordinates': [rings]} if len(rings) > 0 else None
            geometries.append(json.dumps(geom) if geom else None)

    return geometries

# ---------------------------------------------------------------------------
# Escape SQL string
# ---------------------------------------------------------------------------
def sql_str(s):
    if s is None:
        return 'NULL'
    return "'" + s.replace("'", "''") + "'"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    print()
    print('=' * 52)
    print('  Rwanda Sectors (HDX NISR SHP) -> PostgreSQL')
    if DRY_RUN:
        print('  DRY RUN — no changes will be written')
    print('=' * 52)
    print()

    dbf_path = SHP_BASE + '.dbf'
    shp_path = SHP_BASE + '.shp'

    if not os.path.exists(dbf_path):
        print(f'[ERROR] DBF not found: {dbf_path}')
        sys.exit(1)

    print('[INFO]    Reading DBF attributes...')
    records = read_dbf(dbf_path)
    print(f'[INFO]    {len(records)} sector records')

    print('[INFO]    Reading SHP geometries...')
    geometries = read_shp_geometries(shp_path)
    print(f'[INFO]    {len(geometries)} geometries')

    if len(records) != len(geometries):
        print(f'[ERROR] DBF/SHP count mismatch: {len(records)} vs {len(geometries)}')
        sys.exit(1)

    # Build SQL
    sql_lines = []
    sql_lines.append("BEGIN;")

    inserted = 0
    skipped = 0
    unmapped = set()

    for i, (rec, geom_json) in enumerate(zip(records, geometries)):
        pcode     = rec.get('ADM3_PCODE', '').strip()
        name      = rec.get('ADM3_EN', '').strip()
        nisr_dist = rec.get('ADM2_PCODE', '').strip()
        parent    = NISR_TO_RWD.get(nisr_dist)

        if not pcode or not name:
            print(f'[WARN]    Skipping record {i}: missing pcode/name')
            skipped += 1
            continue

        if not parent:
            unmapped.add(nisr_dist)
            print(f'[WARN]    No RWD mapping for NISR district {nisr_dist} (sector {pcode} {name})')
            skipped += 1
            continue

        if not geom_json:
            print(f'[WARN]    Null geometry for {pcode} {name}')
            skipped += 1
            continue

        if DRY_RUN:
            print(f'[DRY-RUN] {pcode}  "{name}"  parent={parent}')
            inserted += 1
            continue

        geom_escaped = geom_json.replace("'", "''")
        sql_lines.append(
            f"INSERT INTO adm_features "
            f"(country_code, adm_level, pcode, name, parent_pcode, geom, level_label) VALUES ("
            f"'RW', 3, {sql_str(pcode)}, {sql_str(name)}, {sql_str(parent)}, "
            f"ST_Multi(ST_GeomFromGeoJSON('{geom_escaped}')), 'Sector') "
            f"ON CONFLICT (pcode) DO UPDATE SET "
            f"name=EXCLUDED.name, parent_pcode=EXCLUDED.parent_pcode, "
            f"geom=EXCLUDED.geom, level_label=EXCLUDED.level_label;"
        )
        inserted += 1

    if not DRY_RUN:
        # Commit inserts first, then area + tenant_scope in separate transactions
        sql_lines.append("COMMIT;")
        # area + center (ABS handles winding-order negatives)
        sql_lines.append("""
UPDATE adm_features SET
  area_sqkm  = ABS(ST_Area(geom::geography)) / 1e6,
  center_lat = ST_Y(ST_Centroid(geom)),
  center_lon = ST_X(ST_Centroid(geom))
WHERE country_code = 'RW' AND adm_level = 3 AND area_sqkm IS NULL;
""")
        # tenant_scope for tenant 12
        sql_lines.append("""
INSERT INTO tenant_scope (tenant_id, pcode)
SELECT 12, pcode FROM adm_features
WHERE country_code = 'RW' AND adm_level = 3
ON CONFLICT DO NOTHING;
""")
        sql_lines.append("VACUUM ANALYZE adm_features;")
        sql_lines.append("VACUUM ANALYZE tenant_scope;")

        print(f'[INFO]    Executing {inserted} inserts via psql...')
        sql = '\n'.join(sql_lines)
        result = subprocess.run(
            ['docker', 'exec', '-i', 'tileserver_postgres_1',
             'psql', '-U', 'mapserver', '-d', 'mapserver'],
            input=sql.encode('utf-8'),
            capture_output=True
        )
        if result.returncode != 0:
            print('[ERROR]', result.stderr.decode('utf-8', errors='replace')[:500])
            sys.exit(1)

        # Count result
        count_result = subprocess.run(
            ['docker', 'exec', 'tileserver_postgres_1',
             'psql', '-U', 'mapserver', '-d', 'mapserver', '-t', '-c',
             "SELECT COUNT(*) FROM adm_features WHERE country_code='RW' AND adm_level=3"],
            capture_output=True
        )
        count = count_result.stdout.decode().strip()
        print(f'[SUCCESS] {inserted} sectors inserted/updated ({skipped} skipped)')
        print(f'[SUCCESS] Total RW adm3 in DB: {count}')
    else:
        print()
        print(f'[DRY-RUN] Would insert {inserted} sectors ({skipped} skipped)')

    if unmapped:
        print(f'[WARN]    Unmapped NISR district pcodes: {unmapped}')

    print()
    print('=' * 52)
    if not DRY_RUN:
        print('  Done. Restart nginx to clear hierarchy cache:')
        print('  sudo docker restart tileserver_nginx_1')
    print('=' * 52)
    print()

main()
