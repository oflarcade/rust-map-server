#!/opt/homebrew/bin/bash
#
# generate-states.sh - Generate PMTiles for states within a country on macOS/Linux
#
# Usage: ./scripts/sh/generate-states.sh <profile> <country> [state1] [state2] ...
#        ./scripts/sh/generate-states.sh --list <profile> <country>
#        ./scripts/sh/generate-states.sh --minzoom 6 <profile> <country>
#
# If no states are specified, auto-discovers ALL states from HDX adm1 and generates
# tiles for each one. Use --list to see available states. Requires HDX COD-AB data.
#
# Profiles:
#   full     - water + roads + places (largest, most detail)
#   minimal  - water + places only (smallest, bare minimum)
#   terrain  - water + landuse + landcover + buildings + places (balanced)
#
# Examples:
#   ./scripts/sh/generate-states.sh full nigeria                          # All states, z10-14
#   ./scripts/sh/generate-states.sh --minzoom 6 full kenya                # All states, z6-14
#   ./scripts/sh/generate-states.sh full nigeria Lagos Edo Bayelsa        # Specific states
#   ./scripts/sh/generate-states.sh --list full nigeria                   # List states only
#
set -euo pipefail

LIST_MODE=false
PROFILE=""
COUNTRY=""
STATES=()
CUSTOM_MIN_ZOOM=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --minzoom) CUSTOM_MIN_ZOOM="$2"; shift 2; continue ;;
        --list|-l) LIST_MODE=true; shift ;;
        *)
            if [ -z "$PROFILE" ]; then
                PROFILE="$1"
            elif [ -z "$COUNTRY" ]; then
                COUNTRY="$1"
            else
                STATES+=("$1")
            fi
            shift
            ;;
    esac
done

if [ -z "$PROFILE" ] || [ -z "$COUNTRY" ]; then
    echo -e "\033[31m[ERROR]\033[0m Usage: $0 [--list] <profile> <country> [state1] [state2] ..."
    exit 1
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANETILER_JAR="$BASE_DIR/planetiler.jar"
OSM_DATA_DIR="$BASE_DIR/data/osm"
TEMP_DIR="$BASE_DIR/temp"
DATA_SOURCES_DIR="$BASE_DIR/data/sources"
BOUNDS_SCRIPT="$BASE_DIR/scripts/bounds-from-hdx.py"

MIN_ZOOM=${CUSTOM_MIN_ZOOM:-6}
MAX_ZOOM=14

# Colors
log_info()    { echo -e "\033[34m[INFO] $(date +%H:%M:%S)\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS] $(date +%H:%M:%S)\033[0m $1"; }
log_warn()    { echo -e "\033[33m[WARN] $(date +%H:%M:%S)\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR] $(date +%H:%M:%S)\033[0m $1"; }
log_step()    { echo -e "\033[36m[STEP] $(date +%H:%M:%S)\033[0m $1"; }

# Profile definitions
declare -A PROFILE_LAYERS
PROFILE_LAYERS=(
    ["full"]="water,landuse,landcover,building,transportation,place"
    ["terrain-roads"]="water,landuse,landcover,transportation,place"
    ["terrain"]="water,landuse,landcover,place"
    ["minimal"]="water,place"
)

declare -A PROFILE_DESC
PROFILE_DESC=(
    ["full"]="Water + roads + landuse + buildings + places (largest)"
    ["terrain-roads"]="Water + landuse + roads + places (no buildings)"
    ["terrain"]="Water + landuse + landcover + places (no buildings, no roads)"
    ["minimal"]="Water + places only (smallest)"
)

# Memory allocation per country (GB)
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

# Normalize
COUNTRY=$(echo "$COUNTRY" | tr '[:upper:]' '[:lower:]' | xargs)
PROFILE=$(echo "$PROFILE" | tr '[:upper:]' '[:lower:]' | xargs)

# Validate profile
if [ -z "${PROFILE_LAYERS[$PROFILE]+x}" ]; then
    log_error "Unknown profile: $PROFILE"
    echo ""
    echo -e "\033[33mAvailable profiles:\033[0m"
    for p in $(echo "${!PROFILE_LAYERS[@]}" | tr ' ' '\n' | sort); do
        echo "  $p - ${PROFILE_DESC[$p]}"
    done
    exit 1
fi

# Validate country
if [ -z "${MEMORY_MAP[$COUNTRY]+x}" ]; then
    log_error "Unknown country: $COUNTRY"
    echo ""
    echo -e "\033[33mAvailable countries:\033[0m"
    for c in $(echo "${!MEMORY_MAP[@]}" | tr ' ' '\n' | sort); do
        echo "  - $c"
    done
    exit 1
fi

LAYERS=${PROFILE_LAYERS[$PROFILE]}
MEMORY=${MEMORY_MAP[$COUNTRY]}
HDX_ADM1="$BASE_DIR/data/hdx/${COUNTRY}_adm1.geojson"
STATES_BOUNDS_DIR="$BASE_DIR/data/sources/${COUNTRY}-states"

# Profile-specific output directories
OUTPUT_DIR="$BASE_DIR/pmtiles/$PROFILE"
BOUNDARIES_DIR="$BASE_DIR/boundaries/$PROFILE"

# Verify HDX adm1 file
if [ ! -f "$HDX_ADM1" ]; then
    log_error "HDX file not found: $HDX_ADM1"
    log_info "Run ./scripts/ps1/download-hdx.ps1 to fetch HDX COD-AB data for $COUNTRY"
    exit 1
fi

# --list mode: show available states and exit (from HDX adm1_name)
if [ "$LIST_MODE" = true ]; then
    echo ""
    log_info "Available states for ${COUNTRY} (from HDX adm1):"
    echo ""
    python3 -c "
import json
with open('$HDX_ADM1') as f:
    data = json.load(f)
states = sorted(set(f['properties'].get('adm1_name') for f in data['features'] if f['properties'].get('adm1_name')))
for s in states:
    print(f'  - {s}')
print(f'\nTotal: {len(states)} states')
"
    exit 0
fi

# Auto-discover: if no states provided, get ALL states from HDX adm1
if [ ${#STATES[@]} -eq 0 ]; then
    log_info "No states specified - auto-discovering all states from HDX adm1..."
    mapfile -t STATES < <(python3 -c "
import json
with open('$HDX_ADM1') as f:
    data = json.load(f)
states = sorted(set(f['properties'].get('adm1_name') for f in data['features'] if f['properties'].get('adm1_name')))
for s in states:
    print(s)
")
    log_info "Found ${#STATES[@]} states for $COUNTRY"
fi

# Verify prerequisites
if [ ! -f "$PLANETILER_JAR" ]; then
    log_error "Planetiler not found at $PLANETILER_JAR"
    log_info "Run ./scripts/sh/setup.sh first"
    exit 1
fi

OSM_FILE="$OSM_DATA_DIR/${COUNTRY}-latest.osm.pbf"
if [ ! -f "$OSM_FILE" ]; then
    log_error "OSM file not found: $OSM_FILE"
    log_info "Run ./scripts/sh/setup.sh to download OSM data"
    exit 1
fi

# Create directories
mkdir -p "$OUTPUT_DIR" "$BOUNDARIES_DIR" "$TEMP_DIR" "$DATA_SOURCES_DIR" "$STATES_BOUNDS_DIR"

# Clean up any leftover _inprogress files
find "$DATA_SOURCES_DIR" -name "*_inprogress" -delete 2>/dev/null || true

INPUT_SIZE=$(du -m "$OSM_FILE" | cut -f1)

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  State-Level PMTiles Generator\033[0m"
echo -e "\033[36m  Profile: $PROFILE\033[0m"
echo -e "\033[36m  Layers:  $LAYERS\033[0m"
echo -e "\033[36m  Country: $COUNTRY\033[0m"
echo -e "\033[36m  States:  ${STATES[*]}\033[0m"
echo -e "\033[36m  Zoom:    $MIN_ZOOM-$MAX_ZOOM\033[0m"
echo -e "\033[36m  Output:  pmtiles/$PROFILE/\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

TOTAL_START=$(date +%s)

# Step 1: Compute bounding boxes from HDX adm1
echo ""
log_step "Step 1: Computing bounds from HDX adm1 for selected states..."

python3 "$BOUNDS_SCRIPT" "$HDX_ADM1" "$STATES_BOUNDS_DIR" "${STATES[@]}"

BOUNDS_FILE="$STATES_BOUNDS_DIR/bounds.json"
if [ ! -f "$BOUNDS_FILE" ]; then
    log_error "Bounds file not generated"
    exit 1
fi

log_success "Bounds computed from HDX adm1"

# Read state slugs from bounds.json
mapfile -t STATE_SLUGS < <(python3 -c "
import json
with open('$BOUNDS_FILE') as f:
    data = json.load(f)
for key in data:
    print(key)
")

# Step 2: Generate per-state OSM base map tiles
echo ""
log_step "Step 2: Generating [$PROFILE] OSM tiles per state (zoom $MIN_ZOOM-$MAX_ZOOM)..."

SUCCEEDED=()
FAILED=()
STATE_INDEX=0

for SLUG in "${STATE_SLUGS[@]}"; do
    STATE_INDEX=$((STATE_INDEX + 1))

    BOUNDS=$(python3 -c "
import json, sys
slug = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
print(data[slug]['bounds'])
" "$SLUG" "$BOUNDS_FILE")
    STATE_NAME=$(python3 -c "
import json, sys
slug = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
print(data[slug]['name'])
" "$SLUG" "$BOUNDS_FILE")

    STATE_OUTPUT="$OUTPUT_DIR/${COUNTRY}-${SLUG}.pmtiles"

    echo ""
    log_info "[$STATE_INDEX/${#STATE_SLUGS[@]}] Generating [$PROFILE] tiles for ${STATE_NAME}..."
    log_info "  Layers: $LAYERS"
    log_info "  Bounds: $BOUNDS"
    log_info "  Output: $STATE_OUTPUT"
    log_info "  Memory: ${MEMORY}GB | Zoom: $MIN_ZOOM-$MAX_ZOOM"

    STATE_START=$(date +%s)

    if java "-Xmx${MEMORY}g" -jar "$PLANETILER_JAR" \
        --osm-path="$OSM_FILE" \
        --output="$STATE_OUTPUT" \
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

        if [ -f "$STATE_OUTPUT" ] && [ -s "$STATE_OUTPUT" ]; then
            STATE_SIZE=$(du -m "$STATE_OUTPUT" | cut -f1)
            log_success "${STATE_NAME} [$PROFILE] tiles generated in ${STATE_ELAPSED}s (${STATE_SIZE} MB)"
            SUCCEEDED+=("$STATE_NAME")
        else
            log_error "Failed to generate tiles for ${STATE_NAME}"
            FAILED+=("$STATE_NAME")
        fi
    else
        log_error "Planetiler failed for ${STATE_NAME}"
        FAILED+=("$STATE_NAME")
    fi
done

# Step 3: Boundary tiles (tippecanoe)
echo ""
if command -v tippecanoe &>/dev/null; then
    log_step "Step 3: Generating admin boundary tiles..."

    for SLUG in "${STATE_SLUGS[@]}"; do
        STATE_NAME=$(python3 -c "
import json
with open('$BOUNDS_FILE') as f:
    data = json.load(f)
print(data['$SLUG']['name'])
")
        STATE_GEOJSON="$STATES_BOUNDS_DIR/${SLUG}.json"
        BOUNDARY_OUTPUT="$BOUNDARIES_DIR/${COUNTRY}-${SLUG}-boundaries.pmtiles"

        if [ ! -f "$STATE_GEOJSON" ]; then
            log_warn "No state GeoJSON for $STATE_NAME, skipping boundaries"
            continue
        fi

        log_info "Generating boundaries for ${STATE_NAME}..."

        tippecanoe \
            --output="$BOUNDARY_OUTPUT" \
            --force \
            --maximum-zoom=$MAX_ZOOM \
            --minimum-zoom=$MIN_ZOOM \
            --no-feature-limit \
            --no-tile-size-limit \
            --detect-shared-borders \
            --no-simplification-of-shared-nodes \
            --coalesce-densest-as-needed \
            --extend-zooms-if-still-dropping \
            --layer=admin \
            --name="${COUNTRY}-${SLUG}-boundaries" \
            --description="Admin boundaries for ${STATE_NAME}, ${COUNTRY}" \
            "$STATE_GEOJSON"

        if [ -f "$BOUNDARY_OUTPUT" ] && [ -s "$BOUNDARY_OUTPUT" ]; then
            B_SIZE=$(du -m "$BOUNDARY_OUTPUT" | cut -f1)
            log_success "${STATE_NAME} boundaries: ${B_SIZE} MB"
        fi
    done

    # Combined boundary tiles
    COMBINED_GEOJSON="$STATES_BOUNDS_DIR/combined.json"
    COMBINED_BOUNDARY="$BOUNDARIES_DIR/${COUNTRY}-states-boundaries.pmtiles"

    if [ -f "$COMBINED_GEOJSON" ]; then
        log_info "Generating combined boundary tiles..."

        tippecanoe \
            --output="$COMBINED_BOUNDARY" \
            --force \
            --maximum-zoom=$MAX_ZOOM \
            --minimum-zoom=$MIN_ZOOM \
            --no-feature-limit \
            --no-tile-size-limit \
            --detect-shared-borders \
            --no-simplification-of-shared-nodes \
            --coalesce-densest-as-needed \
            --extend-zooms-if-still-dropping \
            --layer=admin \
            --name="${COUNTRY}-states-boundaries" \
            --description="Admin boundaries for selected states in ${COUNTRY}" \
            "$COMBINED_GEOJSON"

        if [ -f "$COMBINED_BOUNDARY" ] && [ -s "$COMBINED_BOUNDARY" ]; then
            C_SIZE=$(du -m "$COMBINED_BOUNDARY" | cut -f1)
            log_success "Combined boundaries: ${C_SIZE} MB"
        fi
    fi
else
    log_warn "tippecanoe not found - skipping boundary tile generation"
    log_info "Install tippecanoe: brew install tippecanoe (macOS) or build from source"
    log_info "https://github.com/felt/tippecanoe"
fi

# Summary
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))
TOTAL_MINUTES=$((TOTAL_ELAPSED / 60))
TOTAL_SECONDS=$((TOTAL_ELAPSED % 60))

echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m  [$PROFILE] State Tile Generation Complete!\033[0m"
echo -e "\033[32m================================================================\033[0m"
echo ""
echo "  Profile: $PROFILE (${PROFILE_DESC[$PROFILE]})"
echo "  Total time: ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
echo ""

if [ ${#SUCCEEDED[@]} -gt 0 ]; then
    log_info "Succeeded (${#SUCCEEDED[@]}):"
    for s in "${SUCCEEDED[@]}"; do
        echo -e "  \033[32m+ $s\033[0m"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    log_error "Failed (${#FAILED[@]}):"
    for f in "${FAILED[@]}"; do
        echo -e "  \033[31m- $f\033[0m"
    done
fi

echo ""
log_info "Generated [$PROFILE] OSM base map tiles:"
for SLUG in "${STATE_SLUGS[@]}"; do
    FILE="$OUTPUT_DIR/${COUNTRY}-${SLUG}.pmtiles"
    if [ -f "$FILE" ]; then
        SIZE=$(du -m "$FILE" | cut -f1)
        echo -e "  \033[32m+ $(basename "$FILE") (${SIZE} MB)\033[0m"
    fi
done

if command -v tippecanoe &>/dev/null; then
    echo ""
    log_info "Generated [$PROFILE] boundary tiles:"
    for SLUG in "${STATE_SLUGS[@]}"; do
        FILE="$BOUNDARIES_DIR/${COUNTRY}-${SLUG}-boundaries.pmtiles"
        if [ -f "$FILE" ]; then
            SIZE=$(du -m "$FILE" | cut -f1)
            echo -e "  \033[32m+ $(basename "$FILE") (${SIZE} MB)\033[0m"
        fi
    done
fi

# Cleanup temp
rm -rf "$TEMP_DIR" 2>/dev/null || true
