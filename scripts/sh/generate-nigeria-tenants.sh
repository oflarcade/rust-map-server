#!/usr/bin/env bash
#
# generate-nigeria-tenants.sh - Regenerate all Nigeria tenant tiles from zoom 6
#
# Generates state-level tiles for all Nigeria tenants with minzoom=6
# so the FE can show the full state on initial load.
#
# Usage: ./scripts/sh/generate-nigeria-tenants.sh [--force]
#
# Tenants:
#   3  - Bridge Nigeria (Lagos + Osun combined)
#   9  - EdoBEST (Edo)
#   11 - EKOEXCEL (Lagos)
#   14 - Kwara Learn (Kwara)
#   16 - Bayelsa Prime (Bayelsa)
#   18 - Jigawa Unite (Jigawa)
#
set -euo pipefail

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
    esac
done

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANETILER_JAR="$BASE_DIR/planetiler.jar"
OSM_FILE="$BASE_DIR/data/osm/nigeria-latest.osm.pbf"
OUTPUT_DIR="$BASE_DIR/pmtiles/z6"
DATA_SOURCES_DIR="$BASE_DIR/data/sources"
TEMP_DIR="$BASE_DIR/temp"
HDX_ADM1="$BASE_DIR/data/hdx/nigeria_adm1.geojson"
STATES_BOUNDS_DIR="$BASE_DIR/data/sources/nigeria-states"
BOUNDS_SCRIPT="$BASE_DIR/scripts/bounds-from-hdx.py"

MIN_ZOOM=6
MAX_ZOOM=14
MEMORY=6
LAYERS="water,landuse,landcover,building,transportation,place"

# Colors
log_info()    { echo -e "\033[34m[INFO] $(date +%H:%M:%S)\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS] $(date +%H:%M:%S)\033[0m $1"; }
log_warn()    { echo -e "\033[33m[WARN] $(date +%H:%M:%S)\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR] $(date +%H:%M:%S)\033[0m $1"; }
log_step()    { echo -e "\033[36m[STEP] $(date +%H:%M:%S)\033[0m $1"; }

# Nigeria tenant state definitions
# Format: ID|OutputName|States(comma-sep)
TENANT_DEFS=(
    "9|nigeria-edo|Edo"
    "11|nigeria-lagos|Lagos"
    "14|nigeria-kwara|Kwara"
    "16|nigeria-bayelsa|Bayelsa"
    "18|nigeria-jigawa|Jigawa"
    "3|nigeria-lagos-osun|Lagos,Osun"
)

# Prerequisites
if [ ! -f "$PLANETILER_JAR" ]; then
    log_error "Planetiler not found: $PLANETILER_JAR"
    log_info "Run ./scripts/sh/setup.sh first"
    exit 1
fi

if [ ! -f "$OSM_FILE" ]; then
    log_error "OSM file not found: $OSM_FILE"
    log_info "Run ./scripts/sh/setup.sh to download Nigeria OSM data"
    exit 1
fi

if [ ! -f "$HDX_ADM1" ]; then
    log_error "HDX file not found: $HDX_ADM1"
    log_info "Run ./scripts/ps1/download-hdx.ps1 to fetch Nigeria HDX COD-AB data"
    exit 1
fi

mkdir -p "$OUTPUT_DIR" "$DATA_SOURCES_DIR" "$TEMP_DIR" "$STATES_BOUNDS_DIR"

# Clean up any leftover _inprogress files
find "$DATA_SOURCES_DIR" -name "*_inprogress" -delete 2>/dev/null || true

INPUT_SIZE=$(du -m "$OSM_FILE" | cut -f1)

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Nigeria Tenant Tile Generator\033[0m"
echo -e "\033[36m  Zoom:    $MIN_ZOOM-$MAX_ZOOM (full state visible from z$MIN_ZOOM)\033[0m"
echo -e "\033[36m  Layers:  $LAYERS\033[0m"
echo -e "\033[36m  Memory:  ${MEMORY}GB\033[0m"
echo -e "\033[36m  Input:   $OSM_FILE ($INPUT_SIZE MB)\033[0m"
echo -e "\033[36m  Output:  $OUTPUT_DIR/\033[0m"
echo -e "\033[36m  Tenants: ${#TENANT_DEFS[@]}\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

# Step 1: Compute bounding boxes from HDX adm1
log_step "Step 1: Computing bounding boxes from HDX adm1..."

ALL_STATES=()
for DEF in "${TENANT_DEFS[@]}"; do
    IFS='|' read -r _ _ STATES_STR <<< "$DEF"
    IFS=',' read -ra SARR <<< "$STATES_STR"
    for S in "${SARR[@]}"; do
        FOUND=false
        for EXISTING in "${ALL_STATES[@]:-}"; do
            if [ "$EXISTING" = "$S" ]; then FOUND=true; break; fi
        done
        if [ "$FOUND" = false ]; then
            ALL_STATES+=("$S")
        fi
    done
done

log_info "States needed: ${ALL_STATES[*]}"

python3 "$BOUNDS_SCRIPT" "$HDX_ADM1" "$STATES_BOUNDS_DIR" "${ALL_STATES[@]}"

BOUNDS_FILE="$STATES_BOUNDS_DIR/bounds.json"
if [ ! -f "$BOUNDS_FILE" ]; then
    log_error "Bounds file not generated"
    exit 1
fi

log_success "Bounding boxes computed for ${#ALL_STATES[@]} states"

# Step 2: Generate tiles per tenant
log_step "Step 2: Generating tiles for ${#TENANT_DEFS[@]} Nigeria tenants (zoom $MIN_ZOOM-$MAX_ZOOM)..."

TOTAL_START=$(date +%s)
SUCCEEDED=()
SKIPPED=()
FAILED=()
TENANT_INDEX=0

for DEF in "${TENANT_DEFS[@]}"; do
    IFS='|' read -r T_ID OUTPUT_NAME STATES_STR <<< "$DEF"
    TENANT_INDEX=$((TENANT_INDEX + 1))
    OUTPUT_FILE="$OUTPUT_DIR/${OUTPUT_NAME}.pmtiles"

    echo ""
    echo -e "\033[90m────────────────────────────────────────────────────\033[0m"
    log_info "[$TENANT_INDEX/${#TENANT_DEFS[@]}] Tenant $T_ID: $OUTPUT_NAME"

    IFS=',' read -ra T_STATES <<< "$STATES_STR"
    log_info "  States: $(echo "${T_STATES[*]}" | tr ' ' ' + ')"

    # Skip if exists (unless --force)
    if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ] && [ "$FORCE" = false ]; then
        SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
        log_warn "$OUTPUT_NAME already exists (${SIZE} MB) - skipping. Use --force to regenerate."
        SKIPPED+=("$OUTPUT_NAME")
        continue
    fi

    # Compute combined bounds for multi-state tenants
    if [ ${#T_STATES[@]} -eq 1 ]; then
        SLUG=$(echo "${T_STATES[0]}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        BOUNDS=$(python3 -c "
import json
with open('$BOUNDS_FILE') as f:
    data = json.load(f)
print(data['$SLUG']['bounds'])
")
    else
        BOUNDS=$(python3 -c "
import json
with open('$BOUNDS_FILE') as f:
    data = json.load(f)
states = '${STATES_STR}'.split(',')
slugs = [s.strip().lower().replace(' ','-') for s in states]
min_lon = min(data[s]['min_lon'] for s in slugs)
min_lat = min(data[s]['min_lat'] for s in slugs)
max_lon = max(data[s]['max_lon'] for s in slugs)
max_lat = max(data[s]['max_lat'] for s in slugs)
print(f'{min_lon:.6f},{min_lat:.6f},{max_lon:.6f},{max_lat:.6f}')
")
    fi

    log_info "  Bounds: $BOUNDS"
    log_info "  Output: $OUTPUT_FILE"

    STATE_START=$(date +%s)

    if java "-Xmx${MEMORY}g" -jar "$PLANETILER_JAR" \
        --osm-path="$OSM_FILE" \
        --output="$OUTPUT_FILE" \
        --download \
        --download_dir="$DATA_SOURCES_DIR" \
        --force \
        --bounds="$BOUNDS" \
        --maxzoom=$MAX_ZOOM \
        --minzoom=$MIN_ZOOM \
        --simplify-tolerance-at-max-zoom=0.1 \
        --only-layers=$LAYERS \
        --nodemap-type=sparsearray \
        --storage=mmap \
        --nodemap-storage=mmap \
        --osm_lazy_reads=false \
        --tmpdir="$TEMP_DIR"; then

        STATE_END=$(date +%s)
        STATE_ELAPSED=$((STATE_END - STATE_START))

        if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
            OUT_SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
            log_success "$OUTPUT_NAME generated in ${STATE_ELAPSED}s (${OUT_SIZE} MB)"
            SUCCEEDED+=("$OUTPUT_NAME")
        else
            log_error "No output for $OUTPUT_NAME"
            FAILED+=("$OUTPUT_NAME")
        fi
    else
        log_error "Planetiler failed for $OUTPUT_NAME"
        FAILED+=("$OUTPUT_NAME")
    fi
done

# Summary
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))
TOTAL_MINUTES=$((TOTAL_ELAPSED / 60))
TOTAL_SECONDS=$((TOTAL_ELAPSED % 60))

echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m  Nigeria Tenant Tile Generation Complete!\033[0m"
echo -e "\033[32m================================================================\033[0m"
echo ""
echo "  Total time: ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
echo "  Zoom range: $MIN_ZOOM-$MAX_ZOOM"
echo ""

if [ ${#SUCCEEDED[@]} -gt 0 ]; then
    log_success "Generated (${#SUCCEEDED[@]}):"
    for S in "${SUCCEEDED[@]}"; do
        F="$OUTPUT_DIR/${S}.pmtiles"
        SIZE=$(du -m "$F" | cut -f1)
        echo -e "  \033[32m+ $S (${SIZE} MB)\033[0m"
    done
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo ""
    log_warn "Skipped (${#SKIPPED[@]}) - use --force to regenerate:"
    for S in "${SKIPPED[@]}"; do
        F="$OUTPUT_DIR/${S}.pmtiles"
        SIZE=$(du -m "$F" | cut -f1)
        echo -e "  \033[33m~ $S (${SIZE} MB)\033[0m"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    log_error "Failed (${#FAILED[@]}):"
    for F in "${FAILED[@]}"; do
        echo -e "  \033[31mx $F\033[0m"
    done
fi

echo ""
log_info "Next steps:"
log_info "  1. Restart Docker: docker compose -f tileserver/docker-compose.tenant.yml restart"
log_info "  2. Verify catalog: curl http://localhost:3000/catalog"
log_info "  3. Test in browser: http://localhost:8000/test/test-tenant-tiles.html"

# Cleanup temp
rm -rf "$TEMP_DIR" 2>/dev/null || true
