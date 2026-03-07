#!/usr/bin/env bash
#
# generate-country-boundaries.sh - Generate country boundary PMTiles for non-India tenants
#
# Targets:
#   - kenya-boundaries
#   - uganda-boundaries
#   - liberia-boundaries
#   - rwanda-boundaries
#   - central-african-republic-boundaries
#
# Requires: tippecanoe (brew install tippecanoe on macOS) or Docker
#
# Usage:
#   ./scripts/generate-country-boundaries.sh
#   ./scripts/generate-country-boundaries.sh --country kenya
#   ./scripts/generate-country-boundaries.sh --force
#
set -euo pipefail

COUNTRY_FILTER=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --country|-c) COUNTRY_FILTER="$2"; shift 2 ;;
        --force|-f) FORCE=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BOUNDARIES_DIR="$BASE_DIR/boundaries"
TIPPECANOE_IMAGE="felt-tippecanoe:local"
DOCKERFILE="$BASE_DIR/scripts/Dockerfile.tippecanoe"

log_info()    { echo -e "\033[34m[INFO] $(date +%H:%M:%S)\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS] $(date +%H:%M:%S)\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR] $(date +%H:%M:%S)\033[0m $1"; }

# Country definitions: Name|File
COUNTRY_DEFS=(
    "kenya|kenya-boundaries"
    "uganda|uganda-boundaries"
    "liberia|liberia-boundaries"
    "rwanda|rwanda-boundaries"
    "car|central-african-republic-boundaries"
)

if [ -n "$COUNTRY_FILTER" ]; then
    FILTERED=()
    for DEF in "${COUNTRY_DEFS[@]}"; do
        IFS='|' read -r C_NAME _ <<< "$DEF"
        if [ "$C_NAME" = "$COUNTRY_FILTER" ]; then
            FILTERED+=("$DEF")
        fi
    done
    if [ ${#FILTERED[@]} -eq 0 ]; then
        log_error "Country '$COUNTRY_FILTER' not found. Available: kenya, uganda, liberia, rwanda, car"
        exit 1
    fi
    COUNTRY_DEFS=("${FILTERED[@]}")
fi

# Check if tippecanoe is available natively or via Docker
USE_DOCKER=false
if command -v tippecanoe &>/dev/null; then
    log_info "Using native tippecanoe"
elif command -v docker &>/dev/null; then
    USE_DOCKER=true
    IMAGE_EXISTS=$(docker images -q "$TIPPECANOE_IMAGE" 2>/dev/null || true)
    if [ -z "$IMAGE_EXISTS" ] || [ "$FORCE" = true ]; then
        log_info "Building tippecanoe Docker image..."
        docker build -t "$TIPPECANOE_IMAGE" -f "$DOCKERFILE" "$BASE_DIR"
        log_success "Built $TIPPECANOE_IMAGE"
    fi
else
    log_error "Neither tippecanoe nor Docker found."
    log_info "Install tippecanoe: brew install tippecanoe"
    exit 1
fi

SUCCEEDED=()
FAILED=()
SKIPPED=()

for DEF in "${COUNTRY_DEFS[@]}"; do
    IFS='|' read -r C_NAME C_FILE <<< "$DEF"
    GEOJSON_FILE="$BOUNDARIES_DIR/${C_FILE}.geojson"
    PMTILES_FILE="$BOUNDARIES_DIR/${C_FILE}.pmtiles"

    if [ ! -f "$GEOJSON_FILE" ]; then
        log_error "Missing GeoJSON: $GEOJSON_FILE"
        FAILED+=("$C_NAME: missing GeoJSON")
        continue
    fi

    if [ -f "$PMTILES_FILE" ] && [ "$FORCE" = false ]; then
        log_info "${C_FILE}.pmtiles already exists - skipping (use --force to regenerate)"
        SKIPPED+=("$C_NAME: exists")
        continue
    fi

    log_info "Generating ${C_FILE}.pmtiles ..."

    if [ "$USE_DOCKER" = true ]; then
        docker run --rm \
            -v "${BOUNDARIES_DIR}:/data" \
            "$TIPPECANOE_IMAGE" \
            tippecanoe \
                --output="/data/${C_FILE}.pmtiles" \
                --force \
                --maximum-zoom=14 \
                --minimum-zoom=0 \
                --no-feature-limit \
                --no-tile-size-limit \
                --detect-shared-borders \
                --no-simplification-of-shared-nodes \
                --coalesce-densest-as-needed \
                --extend-zooms-if-still-dropping \
                --layer=boundaries \
                --name="$C_FILE" \
                --description="Admin boundaries for $C_NAME" \
                "/data/${C_FILE}.geojson"
        TIPPECANOE_EXIT=$?
    else
        tippecanoe \
            --output="$PMTILES_FILE" \
            --force \
            --maximum-zoom=14 \
            --minimum-zoom=0 \
            --no-feature-limit \
            --no-tile-size-limit \
            --detect-shared-borders \
            --no-simplification-of-shared-nodes \
            --coalesce-densest-as-needed \
            --extend-zooms-if-still-dropping \
            --layer=boundaries \
            --name="$C_FILE" \
            --description="Admin boundaries for $C_NAME" \
            "$GEOJSON_FILE"
        TIPPECANOE_EXIT=$?
    fi

    if [ $TIPPECANOE_EXIT -ne 0 ]; then
        log_error "tippecanoe failed for $C_NAME"
        FAILED+=("$C_NAME: tippecanoe error")
        continue
    fi

    log_success "${C_FILE}.pmtiles generated"
    SUCCEEDED+=("$C_NAME")
done

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Country Boundary Generation Complete\033[0m"
echo -e "\033[36m================================================================\033[0m"

if [ ${#SUCCEEDED[@]} -gt 0 ]; then echo -e "\033[32mGenerated: ${SUCCEEDED[*]}\033[0m"; fi
if [ ${#SKIPPED[@]} -gt 0 ]; then echo -e "\033[33mSkipped:   ${SKIPPED[*]}\033[0m"; fi
if [ ${#FAILED[@]} -gt 0 ]; then echo -e "\033[31mFailed:    ${FAILED[*]}\033[0m"; exit 1; fi

log_info "Restart Docker after generation:"
log_info "  docker compose -f tileserver/docker-compose.tenant.yml restart"
