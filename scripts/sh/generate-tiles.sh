#!/bin/bash
#
# generate-tiles.sh - Generate base map PMTiles from OSM data using Planetiler
#
# Usage:
#   ./scripts/sh/generate-tiles.sh --all                    # All countries + Nigeria state tiles
#   ./scripts/sh/generate-tiles.sh --country nigeria        # Single country (full coverage)
#   ./scripts/sh/generate-tiles.sh --country nigeria --states  # Nigeria state tiles only
#   ./scripts/sh/generate-tiles.sh --states                 # All Nigeria state tiles
#   ./scripts/sh/generate-tiles.sh --force                  # Regenerate even if file exists
#
# Output: pmtiles/<country>-detailed.pmtiles  (country tiles)
#         pmtiles/nigeria-<state>.pmtiles      (state tiles, z6-14)
#
# License: OSM data is ODbL - free for commercial use
# Works with bash 3.2 (macOS default) - no bash 4+ features
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANETILER_JAR="$BASE_DIR/planetiler.jar"
OSM_DATA_DIR="$BASE_DIR/osm-data"
PMTILES_DIR="$BASE_DIR/pmtiles"
DATA_SOURCES_DIR="$BASE_DIR/data/sources"
TEMP_DIR="$BASE_DIR/temp"

log_info()    { printf "\033[34m[INFO]   \033[0m %s\n" "$1"; }
log_success() { printf "\033[32m[OK]     \033[0m %s\n" "$1"; }
log_warn()    { printf "\033[33m[WARN]   \033[0m %s\n" "$1"; }
log_error()   { printf "\033[31m[ERROR]  \033[0m %s\n" "$1"; }

# ---- Argument parsing ----
DO_ALL=false
DO_STATES=false
FORCE=false
COUNTRY_FILTER=""

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all              Generate all country tiles + Nigeria state tiles"
    echo "  --country NAME     Generate tiles for one country"
    echo "  --states           Generate Nigeria state tiles (use with --country nigeria or alone)"
    echo "  --force            Overwrite existing tiles"
    echo ""
    echo "Countries: liberia, rwanda, central-african-republic, uganda, kenya, nigeria"
    echo ""
    echo "Examples:"
    echo "  $0 --all"
    echo "  $0 --country kenya"
    echo "  $0 --country nigeria --states"
    echo "  $0 --states --force"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --all)           DO_ALL=true ;;
        --states)        DO_STATES=true ;;
        --force|-f)      FORCE=true ;;
        --country|-c)    COUNTRY_FILTER="$2"; shift ;;
        --help|-h)       show_usage; exit 0 ;;
        *)               log_error "Unknown argument: $1"; show_usage; exit 1 ;;
    esac
    shift
done

if [ "$DO_ALL" = false ] && [ -z "$COUNTRY_FILTER" ] && [ "$DO_STATES" = false ]; then
    log_error "No target specified."
    show_usage
    exit 1
fi

# ---- Lookup functions (no declare -A, works in bash 3.2) ----

get_memory() {
    case "$1" in
        liberia|rwanda|central-african-republic) echo 2 ;;
        uganda|kenya)                            echo 4 ;;
        nigeria)                                 echo 6 ;;
        *)                                       echo "" ;;
    esac
}

# Nigeria state bounding boxes (from OSM, ODbL)
# Format: minlon,minlat,maxlon,maxlat
get_state_bbox() {
    case "$1" in
        nigeria-jigawa)      echo "8.77,11.22,10.50,13.03" ;;
        nigeria-kwara)       echo "2.51,7.80,6.47,9.48" ;;
        nigeria-bayelsa)     echo "5.60,4.15,6.88,5.44" ;;
        nigeria-edo)         echo "5.05,5.74,6.73,7.19" ;;
        nigeria-lagos)       echo "2.69,6.34,3.73,6.70" ;;
        nigeria-lagos-osun)  echo "2.69,6.34,5.02,8.19" ;;
        *)                   echo "" ;;
    esac
}

# ---- Prereq checks ----
if [ ! -f "$PLANETILER_JAR" ]; then
    log_error "Planetiler not found. Run: ./scripts/sh/setup.sh"
    exit 1
fi

mkdir -p "$PMTILES_DIR" "$DATA_SOURCES_DIR" "$TEMP_DIR"
find "$DATA_SOURCES_DIR" -name "*_inprogress" -delete 2>/dev/null || true

# ---- Country tile generation ----
generate_country() {
    COUNTRY="$1"
    MEM=$(get_memory "$COUNTRY")
    if [ -z "$MEM" ]; then
        log_error "Unknown country: $COUNTRY"
        log_info "Valid: liberia, rwanda, central-african-republic, uganda, kenya, nigeria"
        return 1
    fi

    OSM_FILE="$OSM_DATA_DIR/${COUNTRY}-latest.osm.pbf"
    OUT="$PMTILES_DIR/${COUNTRY}-detailed.pmtiles"

    if [ ! -f "$OSM_FILE" ]; then
        log_error "OSM file missing: $OSM_FILE"
        log_info "Run: ./scripts/sh/setup.sh"
        return 1
    fi

    if [ -f "$OUT" ] && [ -s "$OUT" ] && [ "$FORCE" = false ]; then
        SIZE=$(du -m "$OUT" | cut -f1)
        log_warn "$COUNTRY already exists (${SIZE} MB) -- use --force to regenerate"
        return 0
    fi

    INPUT_SIZE=$(du -m "$OSM_FILE" | cut -f1)
    log_info "Country: $COUNTRY | RAM: ${MEM}GB | Input: ${INPUT_SIZE}MB"
    log_info "Output: $OUT"
    log_info "First run downloads ~1GB of supporting data (ocean, coastlines)..."

    START=$(date +%s)

    java "-Xmx${MEM}g" -jar "$PLANETILER_JAR" \
        --osm-path="$OSM_FILE" \
        --output="$OUT" \
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
        --tmpdir="$TEMP_DIR"

    END=$(date +%s)
    ELAPSED=$((END - START))

    if [ -f "$OUT" ] && [ -s "$OUT" ]; then
        SIZE=$(du -m "$OUT" | cut -f1)
        log_success "$COUNTRY done in $((ELAPSED/60))m $((ELAPSED%60))s -- ${SIZE} MB -> $OUT"
        return 0
    else
        log_error "$COUNTRY: no output produced"
        return 1
    fi
}

# ---- Nigeria state tile generation ----
generate_state() {
    STATE="$1"
    BBOX=$(get_state_bbox "$STATE")
    if [ -z "$BBOX" ]; then
        log_error "Unknown Nigeria state: $STATE"
        return 1
    fi

    OSM_FILE="$OSM_DATA_DIR/nigeria-latest.osm.pbf"
    OUT="$PMTILES_DIR/${STATE}.pmtiles"

    if [ ! -f "$OSM_FILE" ]; then
        log_error "Nigeria OSM file missing. Run: ./scripts/sh/setup.sh"
        return 1
    fi

    if [ -f "$OUT" ] && [ -s "$OUT" ] && [ "$FORCE" = false ]; then
        SIZE=$(du -m "$OUT" | cut -f1)
        log_warn "$STATE already exists (${SIZE} MB) -- use --force to regenerate"
        return 0
    fi

    log_info "State: $STATE | bounds: $BBOX | z6-14"
    log_info "Output: $OUT"

    START=$(date +%s)

    java -Xmx6g -jar "$PLANETILER_JAR" \
        --osm-path="$OSM_FILE" \
        --output="$OUT" \
        --download \
        --download_dir="$DATA_SOURCES_DIR" \
        --force \
        --bounds="$BBOX" \
        --maxzoom=14 \
        --minzoom=6 \
        --simplify-tolerance-at-max-zoom=0.1 \
        --only-layers=water,landuse,landcover,building,transportation,place \
        --nodemap-type=sparsearray \
        --storage=mmap \
        --nodemap-storage=mmap \
        --tmpdir="$TEMP_DIR"

    END=$(date +%s)
    ELAPSED=$((END - START))

    if [ -f "$OUT" ] && [ -s "$OUT" ]; then
        SIZE=$(du -m "$OUT" | cut -f1)
        log_success "$STATE done in $((ELAPSED/60))m $((ELAPSED%60))s -- ${SIZE} MB -> $OUT"
        return 0
    else
        log_error "$STATE: no output produced"
        return 1
    fi
}

# ---- Main dispatch ----
TOTAL_START=$(date +%s)
SUCCEEDED=""
FAILED=""

echo ""
echo "================================================================"
echo "  Tile Generator (Planetiler + OSM)"
echo "================================================================"
echo ""

ALL_COUNTRIES="liberia rwanda central-african-republic uganda kenya nigeria"
NIGERIA_STATES="nigeria-edo nigeria-lagos nigeria-kwara nigeria-bayelsa nigeria-jigawa nigeria-lagos-osun"

# Country tiles
if [ "$DO_ALL" = true ] || { [ -n "$COUNTRY_FILTER" ] && [ "$DO_STATES" = false ]; }; then
    if [ "$DO_ALL" = true ]; then
        TARGETS="$ALL_COUNTRIES"
    else
        TARGETS="$COUNTRY_FILTER"
    fi

    for COUNTRY in $TARGETS; do
        echo ""
        echo "----------------------------------------------------------------"
        if generate_country "$COUNTRY"; then
            SUCCEEDED="$SUCCEEDED $COUNTRY"
        else
            FAILED="$FAILED $COUNTRY"
        fi
    done
fi

# Nigeria state tiles
RUN_STATES=false
if [ "$DO_ALL" = true ]; then
    RUN_STATES=true
elif [ "$DO_STATES" = true ]; then
    if [ -n "$COUNTRY_FILTER" ] && [ "$COUNTRY_FILTER" != "nigeria" ]; then
        log_error "--states is only valid for nigeria"
        exit 1
    fi
    RUN_STATES=true
fi

if [ "$RUN_STATES" = true ]; then
    echo ""
    echo "================================================================"
    echo "  Nigeria state tiles (z6-14)"
    echo "================================================================"
    for STATE in $NIGERIA_STATES; do
        echo ""
        echo "----------------------------------------------------------------"
        if generate_state "$STATE"; then
            SUCCEEDED="$SUCCEEDED $STATE"
        else
            FAILED="$FAILED $STATE"
        fi
    done
fi

# Cleanup
rm -rf "$TEMP_DIR" 2>/dev/null || true

# Summary
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))

echo ""
echo "================================================================"
echo "  Done in $((TOTAL_ELAPSED/3600))h $(( (TOTAL_ELAPSED%3600)/60 ))m $((TOTAL_ELAPSED%60))s"
echo "================================================================"
echo ""
[ -n "$SUCCEEDED" ] && log_success "Generated:$SUCCEEDED"
[ -n "$FAILED" ]    && log_error   "Failed:$FAILED"

if [ -n "$FAILED" ]; then
    echo ""
    log_info "Re-run failed items with --force:"
    for F in $FAILED; do
        log_info "  $0 --country $F --force"
    done
    exit 1
fi

echo ""
log_info "Next: ./scripts/sh/extract-boundaries.sh --all"
echo ""
