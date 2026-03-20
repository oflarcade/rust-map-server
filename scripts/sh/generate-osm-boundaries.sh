#!/usr/bin/env bash
#
# generate-osm-boundaries.sh - Extract admin boundary GeoJSON from OSM .pbf files
#
# Uses Docker (osgeo/gdal) to run ogr2ogr against each country's .osm.pbf,
# extracting administrative boundaries (admin_level 4/5/6) as GeoJSON.
#
# Output files are placed in boundaries/ and are the input for
# generate-country-boundaries.sh (tippecanoe -> PMTiles step).
#
# License: OSM data is ODbL (open source / commercial-friendly)
#
# Usage:
#   ./scripts/sh/generate-osm-boundaries.sh                    # All countries
#   ./scripts/sh/generate-osm-boundaries.sh --country kenya    # Single country
#   ./scripts/sh/generate-osm-boundaries.sh --force            # Regenerate existing
#
# Countries: kenya, uganda, liberia, rwanda, car, india
# Note: india uses the full Geofabrik extract — GeoJSON output is large; runs a long time.
#
set -euo pipefail

COUNTRY_FILTER=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --country|-c) COUNTRY_FILTER="$2"; shift 2 ;;
        --force|-f)   FORCE=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OSM_DATA_DIR="$BASE_DIR/data/osm"
BOUNDARIES_DIR="$BASE_DIR/boundaries"
GDAL_IMAGE="osgeo/gdal"

log_info()    { echo -e "\033[34m[INFO] $(date +%H:%M:%S)\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS] $(date +%H:%M:%S)\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR] $(date +%H:%M:%S)\033[0m $1"; }

# Country definitions: "name|osm_file|output_base"
COUNTRY_DEFS=(
    "kenya|kenya-latest.osm.pbf|kenya-boundaries"
    "uganda|uganda-latest.osm.pbf|uganda-boundaries"
    "liberia|liberia-latest.osm.pbf|liberia-boundaries"
    "rwanda|rwanda-latest.osm.pbf|rwanda-boundaries"
    "car|central-african-republic-latest.osm.pbf|central-african-republic-boundaries"
    "india|india-latest.osm.pbf|india-boundaries"
)

# Filter to single country if specified
if [ -n "$COUNTRY_FILTER" ]; then
    FILTERED=()
    for DEF in "${COUNTRY_DEFS[@]}"; do
        IFS='|' read -r C_NAME _ _ <<< "$DEF"
        if [ "$C_NAME" = "$COUNTRY_FILTER" ]; then
            FILTERED+=("$DEF")
        fi
    done
    if [ ${#FILTERED[@]} -eq 0 ]; then
        log_error "Country '$COUNTRY_FILTER' not found. Available: kenya, uganda, liberia, rwanda, car, india"
        exit 1
    fi
    COUNTRY_DEFS=("${FILTERED[@]}")
fi

if ! command -v docker &>/dev/null; then
    log_error "Docker is required. Install Docker and try again."
    exit 1
fi

mkdir -p "$BOUNDARIES_DIR"

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  OSM Boundary GeoJSON Extractor\033[0m"
echo -e "\033[36m  Countries: ${#COUNTRY_DEFS[@]}\033[0m"
echo -e "\033[36m  Image: $GDAL_IMAGE\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

SUCCEEDED=()
FAILED=()
SKIPPED=()

for DEF in "${COUNTRY_DEFS[@]}"; do
    IFS='|' read -r C_NAME C_OSM_FILE C_FILE <<< "$DEF"

    OSM_PATH="$OSM_DATA_DIR/$C_OSM_FILE"
    GEOJSON_PATH="$BOUNDARIES_DIR/${C_FILE}.geojson"

    echo -e "\033[90m────────────────────────────────────────────────────────\033[0m"
    log_info "$C_NAME -> ${C_FILE}.geojson"

    # Check OSM source exists
    if [ ! -f "$OSM_PATH" ]; then
        log_error "OSM file missing: $OSM_PATH"
        FAILED+=("$C_NAME: missing $C_OSM_FILE")
        continue
    fi

    # Skip if already exists
    if [ -f "$GEOJSON_PATH" ] && [ "$FORCE" = false ]; then
        SIZE_MB=$(du -m "$GEOJSON_PATH" | cut -f1)
        log_info "${C_FILE}.geojson already exists (${SIZE_MB} MB) - skipping (use --force to regenerate)"
        SKIPPED+=("$C_NAME: exists")
        continue
    fi

    log_info "Running ogr2ogr in Docker (this may take several minutes for large files)..."

    docker run --rm \
        -v "${OSM_DATA_DIR}:/input:ro" \
        -v "${BOUNDARIES_DIR}:/output" \
        "$GDAL_IMAGE" \
        ogr2ogr \
            -f GeoJSON \
            "/output/${C_FILE}.geojson" \
            "/input/${C_OSM_FILE}" \
            multipolygons \
            -where "boundary='administrative' AND (admin_level='4' OR admin_level='5' OR admin_level='6')"

    if [ -f "$GEOJSON_PATH" ] && [ -s "$GEOJSON_PATH" ]; then
        SIZE_MB=$(du -m "$GEOJSON_PATH" | cut -f1)
        log_success "${C_FILE}.geojson written (${SIZE_MB} MB)"
        SUCCEEDED+=("$C_NAME")
    else
        log_error "Output file missing or empty for $C_NAME"
        FAILED+=("$C_NAME: empty output")
    fi
done

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Extraction Complete\033[0m"
echo -e "\033[36m================================================================\033[0m"

if [ ${#SUCCEEDED[@]} -gt 0 ]; then echo -e "\033[32mGenerated: ${SUCCEEDED[*]}\033[0m"; fi
if [ ${#SKIPPED[@]} -gt 0 ];   then echo -e "\033[33mSkipped:   ${SKIPPED[*]}\033[0m"; fi
if [ ${#FAILED[@]} -gt 0 ];    then echo -e "\033[31mFailed:    ${FAILED[*]}\033[0m"; exit 1; fi

echo ""
log_info "Next step: convert GeoJSONs to PMTiles:"
log_info "  ./scripts/sh/generate-country-boundaries.sh"
