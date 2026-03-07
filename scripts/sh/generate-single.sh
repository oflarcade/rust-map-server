#!/usr/bin/env bash
#
# generate-single.sh - Generate PMTiles for a single country on macOS/Linux
# Usage: ./scripts/generate-single.sh <country-name> [--force]
# Example: ./scripts/generate-single.sh nigeria
#
set -euo pipefail

FORCE=false
COUNTRY=""

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        *) COUNTRY="$arg" ;;
    esac
done

if [ -z "$COUNTRY" ]; then
    echo -e "\033[31m[ERROR]\033[0m Usage: $0 <country-name> [--force]"
    exit 1
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
PLANETILER_JAR="$BASE_DIR/planetiler.jar"
OSM_DATA_DIR="$BASE_DIR/data/osm"
PMTILES_DIR="$BASE_DIR/pmtiles"
DATA_SOURCES_DIR="$BASE_DIR/data/sources"
TEMP_DIR="$BASE_DIR/temp"

# Colors
log_info()    { echo -e "\033[34m[INFO] $(date +%H:%M:%S)\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS] $(date +%H:%M:%S)\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR] $(date +%H:%M:%S)\033[0m $1"; }

# Memory settings per country (GB)
declare -A MEMORY_MAP
MEMORY_MAP=(
    ["liberia"]=2
    ["rwanda"]=2
    ["central-african-republic"]=2
    ["uganda"]=4
    ["kenya"]=4
    ["nigeria"]=6
    ["india"]=8
)

# Normalize country name
COUNTRY=$(echo "$COUNTRY" | tr '[:upper:]' '[:lower:]' | xargs)

# Validate
if [ -z "${MEMORY_MAP[$COUNTRY]+x}" ]; then
    log_error "Unknown country: $COUNTRY"
    echo ""
    echo -e "\033[33mAvailable countries:\033[0m"
    for c in $(echo "${!MEMORY_MAP[@]}" | tr ' ' '\n' | sort); do
        echo "  - $c"
    done
    exit 1
fi

MEMORY=${MEMORY_MAP[$COUNTRY]}
OSM_FILE="$OSM_DATA_DIR/${COUNTRY}-latest.osm.pbf"
OUTPUT_FILE="$PMTILES_DIR/${COUNTRY}-detailed.pmtiles"

# Ensure directories exist
mkdir -p "$PMTILES_DIR" "$DATA_SOURCES_DIR" "$TEMP_DIR"

# Skip if output already exists (unless --force)
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ] && [ "$FORCE" = false ]; then
    SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
    log_info "$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]') already exists (${SIZE} MB) - skipping. Use --force to regenerate."
    exit 0
fi

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Generating PMTiles: $(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

# Verify Planetiler exists
if [ ! -f "$PLANETILER_JAR" ]; then
    log_error "Planetiler not found at $PLANETILER_JAR"
    log_info "Run ./scripts/setup.sh first"
    exit 1
fi

# Verify OSM file exists
if [ ! -f "$OSM_FILE" ]; then
    log_error "OSM file not found: $OSM_FILE"
    log_info "Run ./scripts/setup.sh to download OSM data"
    exit 1
fi

INPUT_SIZE=$(du -m "$OSM_FILE" | cut -f1)
log_info "Input: $OSM_FILE (${INPUT_SIZE} MB)"
log_info "Output: $OUTPUT_FILE"
log_info "Memory: ${MEMORY}GB"
log_info "Note: First run downloads ~1GB of supporting data (coastlines, etc.)"

# Clean up any leftover _inprogress files
find "$DATA_SOURCES_DIR" -name "*_inprogress" -delete 2>/dev/null || true

START_TIME=$(date +%s)

# Run Planetiler (use mmap storage on macOS/Linux instead of ram)
java "-Xmx${MEMORY}g" -jar "$PLANETILER_JAR" \
    --osm-path="$OSM_FILE" \
    --output="$OUTPUT_FILE" \
    --download \
    --download_dir="$DATA_SOURCES_DIR" \
    --force \
    --maxzoom=14 \
    --minzoom=0 \
    --simplify-tolerance-at-max-zoom=0 \
    --building_merge_z13=true \
    --exclude-layers=poi,housenumber \
    --nodemap-type=sparsearray \
    --storage=mmap \
    --nodemap-storage=mmap \
    --osm_lazy_reads=false \
    --tmpdir="$TEMP_DIR"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    OUTPUT_SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
    echo ""
    log_success "$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]') completed in ${MINUTES}m ${SECONDS}s"
    log_success "Output: $OUTPUT_FILE (${OUTPUT_SIZE} MB)"
else
    log_error "Generation failed - no output file produced or file is empty"
    exit 1
fi

# Cleanup temp
rm -rf "$TEMP_DIR" 2>/dev/null || true
