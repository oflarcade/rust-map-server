#!/usr/bin/env python3
"""
extract-rwanda-adm1.py — Build data/hdx/rwanda_adm1.geojson from OSM boundary data.

Rwanda's HDX COD-AB package (cod-ab-rwa) only has SHP/EMF — no GeoJSON.
This script extracts the 5 provinces from data/boundaries/rwanda-boundaries.geojson
(OSM-derived, admin_level=4, ISO3166-2 = RW-*) and writes them in HDX adm1 format
(adm1_name / adm1_pcode properties) so generate-states.sh can use them.

Usage:
    python3 scripts/extract-rwanda-adm1.py
"""

import json
import os
import re
import sys

BASE_DIR = os.path.join(os.path.dirname(__file__), "..")
SRC = os.path.join(BASE_DIR, "data", "boundaries", "rwanda-boundaries.geojson")
OUT = os.path.join(BASE_DIR, "data", "hdx", "rwanda_adm1.geojson")

if not os.path.exists(SRC):
    print(f"ERROR: {SRC} not found.", file=sys.stderr)
    sys.exit(1)

with open(SRC) as f:
    data = json.load(f)

provinces = []
for ft in data["features"]:
    p = ft["properties"]
    if p.get("admin_level") != "4":
        continue
    tags = p.get("other_tags", "")
    iso = re.search(r'"ISO3166-2"=>"(RW-\d+)"', tags)
    if not iso:
        continue  # skip cross-border artifacts (e.g. Ugandan district Kabale)
    name_en = re.search(r'"name:en"=>"([^"]+)"', tags)
    en_name = name_en.group(1) if name_en else p["name"]
    pcode = iso.group(1).replace("-", "")  # RW-01 → RW01
    provinces.append({
        "type": "Feature",
        "properties": {
            "adm0_pcode": "RW",
            "adm0_name": "Rwanda",
            "adm1_pcode": pcode,
            "adm1_name": en_name,
        },
        "geometry": ft["geometry"],
    })

provinces.sort(key=lambda x: x["properties"]["adm1_pcode"])

out = {"type": "FeatureCollection", "features": provinces}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(out, f)

print(f"Written {len(provinces)} provinces to {OUT}:")
for pv in provinces:
    print(f"  {pv['properties']['adm1_pcode']}: {pv['properties']['adm1_name']}")
