#!/bin/bash
#
# extract-boundaries.sh - Extract admin boundary GeoJSON from OSM .pbf files
#
# Source: OpenStreetMap (ODbL license - free for commercial use)
# Requires: osmium-tool  (brew install osmium-tool)
#
# Usage:
#   ./scripts/extract-boundaries.sh --all              # All 6 countries
#   ./scripts/extract-boundaries.sh --country nigeria  # Single country
#   ./scripts/extract-boundaries.sh --force            # Overwrite existing
#
# Output:
#   boundaries/<country>-boundaries.geojson
#     Nigeria:       admin_level 4 (states) + 6 (LGAs)
#     Other countries: admin_level 2 (country) + 4 (regions)
#
# Works with bash 3.2 (macOS default) - no bash 4+ features
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
OSM_DATA_DIR="$BASE_DIR/osm-data"
BOUNDARIES_DIR="$BASE_DIR/boundaries"
TEMP_DIR="$BASE_DIR/temp/boundaries"

log_info()    { printf "\033[34m[INFO]   \033[0m %s\n" "$1"; }
log_success() { printf "\033[32m[OK]     \033[0m %s\n" "$1"; }
log_warn()    { printf "\033[33m[WARN]   \033[0m %s\n" "$1"; }
log_error()   { printf "\033[31m[ERROR]  \033[0m %s\n" "$1"; }

# ---- Argument parsing ----
DO_ALL=false
FORCE=false
COUNTRY_FILTER=""

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all              Extract boundaries for all countries"
    echo "  --country NAME     Extract for one country"
    echo "  --force            Overwrite existing GeoJSON files"
    echo ""
    echo "Countries: liberia, rwanda, central-african-republic, uganda, kenya, nigeria"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --all)          DO_ALL=true ;;
        --country|-c)   COUNTRY_FILTER="$2"; shift ;;
        --force|-f)     FORCE=true ;;
        --help|-h)      show_usage; exit 0 ;;
        *)              log_error "Unknown argument: $1"; show_usage; exit 1 ;;
    esac
    shift
done

if [ "$DO_ALL" = false ] && [ -z "$COUNTRY_FILTER" ]; then
    log_error "Specify --all or --country NAME"
    show_usage
    exit 1
fi

# ---- Prereq checks ----
if ! command -v osmium >/dev/null 2>&1; then
    log_error "osmium-tool not found."
    log_info "Install: brew install osmium-tool"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    log_error "python3 not found."
    exit 1
fi

mkdir -p "$BOUNDARIES_DIR" "$TEMP_DIR"

# ---- Admin level lookup ----
# Nigeria: state=4, LGA=6
# Others: country outline=2, region/state=4
get_admin_levels() {
    case "$1" in
        nigeria) echo "4,6" ;;
        *)       echo "2,4" ;;
    esac
}

# ---- Extract one country ----
extract_country() {
    COUNTRY="$1"
    LEVELS=$(get_admin_levels "$COUNTRY")
    OSM_FILE="$OSM_DATA_DIR/${COUNTRY}-latest.osm.pbf"
    OUT_GEOJSON="$BOUNDARIES_DIR/${COUNTRY}-boundaries.geojson"
    TEMP_PBF="$TEMP_DIR/${COUNTRY}-admin.pbf"
    TEMP_GEOJSON="$TEMP_DIR/${COUNTRY}-raw.geojson"

    if [ ! -f "$OSM_FILE" ]; then
        log_error "OSM file missing: $OSM_FILE -- run setup.sh first"
        return 1
    fi

    if [ -f "$OUT_GEOJSON" ] && [ -s "$OUT_GEOJSON" ] && [ "$FORCE" = false ]; then
        SIZE=$(du -m "$OUT_GEOJSON" | cut -f1)
        log_warn "$COUNTRY boundaries already exist (${SIZE} MB) -- use --force to regenerate"
        return 0
    fi

    INPUT_SIZE=$(du -m "$OSM_FILE" | cut -f1)
    log_info "Extracting: $COUNTRY | admin_level: $LEVELS | input: ${INPUT_SIZE}MB"

    # Step 1: Filter OSM to only admin boundary relations
    log_info "  Step 1/3: Filtering admin boundary relations..."
    osmium tags-filter \
        "$OSM_FILE" \
        r/boundary=administrative \
        -o "$TEMP_PBF" \
        --overwrite 2>&1 | grep -v "^$" || true

    TEMP_SIZE=$(du -m "$TEMP_PBF" 2>/dev/null | cut -f1 || echo "0")
    log_info "  Filtered: ${TEMP_SIZE}MB"

    # Step 2: Export relations to GeoJSON (osmium assembles multipolygon geometries)
    log_info "  Step 2/3: Exporting to GeoJSON..."
    osmium export \
        "$TEMP_PBF" \
        -f geojson \
        -o "$TEMP_GEOJSON" \
        --overwrite 2>&1 | grep -v "^$" || true

    # Step 3: Filter to target admin levels and clean up properties
    log_info "  Step 3/3: Filtering to admin_level [$LEVELS] and cleaning properties..."

    python3 << PYEOF
import json, sys

geojson_file = "$TEMP_GEOJSON"
output_file  = "$OUT_GEOJSON"
target_levels = set("$LEVELS".split(","))

with open(geojson_file, encoding="utf-8") as f:
    data = json.load(f)

features = []
for feat in data.get("features", []):
    props = feat.get("properties") or {}
    geom  = feat.get("geometry")

    # Must be a polygon or multipolygon
    if not geom or geom.get("type") not in ("Polygon", "MultiPolygon"):
        continue

    admin_level = str(props.get("admin_level", ""))
    boundary    = str(props.get("boundary", ""))

    if boundary != "administrative":
        continue
    if admin_level not in target_levels:
        continue

    # Keep only the properties we need for boundary display and splitting
    clean = {
        "name":        props.get("name") or props.get("name:en") or "",
        "admin_level": admin_level,
        "boundary":    boundary,
    }
    features.append({"type": "Feature", "properties": clean, "geometry": geom})

out = {"type": "FeatureCollection", "features": features}
with open(output_file, "w", encoding="utf-8") as f:
    json.dump(out, f)

print(f"  Kept {len(features)} features (admin_level in {target_levels})")
PYEOF

    # Cleanup temp files
    rm -f "$TEMP_PBF" "$TEMP_GEOJSON"

    if [ -f "$OUT_GEOJSON" ] && [ -s "$OUT_GEOJSON" ]; then
        FEAT_COUNT=$(python3 -c "import json; d=json.load(open('$OUT_GEOJSON')); print(len(d['features']))")
        SIZE=$(du -m "$OUT_GEOJSON" | cut -f1)
        log_success "$COUNTRY: $FEAT_COUNT features -> $OUT_GEOJSON (${SIZE} MB)"
        return 0
    else
        log_error "$COUNTRY: no output produced"
        return 1
    fi
}

# ---- Main dispatch ----
TOTAL_START=$(date +%s)
SUCCEEDED=""
FAILED=""

echo ""
echo "================================================================"
echo "  OSM Boundary Extractor (osmium-tool)"
echo "================================================================"
echo ""

if [ "$DO_ALL" = true ]; then
    TARGETS="liberia rwanda central-african-republic uganda kenya nigeria"
else
    TARGETS="$COUNTRY_FILTER"
fi

for COUNTRY in $TARGETS; do
    echo ""
    echo "----------------------------------------------------------------"
    if extract_country "$COUNTRY"; then
        SUCCEEDED="$SUCCEEDED $COUNTRY"
    else
        FAILED="$FAILED $COUNTRY"
    fi
done

rm -rf "$TEMP_DIR" 2>/dev/null || true

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))

echo ""
echo "================================================================"
echo "  Done in $((TOTAL_ELAPSED/60))m $((TOTAL_ELAPSED%60))s"
echo "================================================================"
echo ""
[ -n "$SUCCEEDED" ] && log_success "Extracted:$SUCCEEDED"
[ -n "$FAILED" ]    && log_error   "Failed:$FAILED"

if [ -n "$FAILED" ]; then exit 1; fi

echo ""
log_info "Next: ./scripts/generate-boundaries.sh --all"
echo ""
