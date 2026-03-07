#!/bin/bash
#
# generate-boundaries.sh - Convert boundary GeoJSON to PMTiles using tippecanoe
#
# For Nigeria: splits nigeria-boundaries.geojson into per-tenant files,
# then converts each to PMTiles.
# For other countries: converts whole-country GeoJSON to PMTiles.
#
# Requires:
#   - tippecanoe  (brew install tippecanoe)  OR  Docker
#   - python3
#   - boundaries/<country>-boundaries.geojson (from extract-boundaries.sh)
#
# Usage:
#   ./scripts/sh/generate-boundaries.sh --all              # All countries
#   ./scripts/sh/generate-boundaries.sh --country nigeria  # Single country
#   ./scripts/sh/generate-boundaries.sh --force            # Overwrite existing
#
# Output:
#   boundaries/<country>-boundaries.pmtiles      (non-Nigeria)
#   boundaries/nigeria-<state>-boundaries.pmtiles (Nigeria per-tenant)
#
# License: OSM data is ODbL - free for commercial use
# Works with bash 3.2 (macOS default) - no bash 4+ features
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOUNDARIES_DIR="$BASE_DIR/boundaries"
TIPPECANOE_IMAGE="felt-tippecanoe:local"
DOCKERFILE="$BASE_DIR/scripts/Dockerfile.tippecanoe"

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
    echo "  --all              Generate boundary tiles for all countries"
    echo "  --country NAME     Generate for one country"
    echo "  --force            Overwrite existing PMTiles"
    echo ""
    echo "Countries: liberia, rwanda, central-african-republic, uganda, kenya, nigeria"
    echo ""
    echo "Nigeria outputs 6 per-tenant files (edo, lagos, kwara, bayelsa, jigawa, lagos-osun)"
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

# ---- Tippecanoe detection: native or Docker ----
USE_DOCKER=false
if command -v tippecanoe >/dev/null 2>&1; then
    log_info "Using native tippecanoe"
elif command -v docker >/dev/null 2>&1; then
    USE_DOCKER=true
    log_info "tippecanoe not found -- using Docker"
    IMAGE_EXISTS=$(docker images -q "$TIPPECANOE_IMAGE" 2>/dev/null || true)
    if [ -z "$IMAGE_EXISTS" ]; then
        log_info "Building tippecanoe Docker image (one-time, takes ~5 min)..."
        docker build -t "$TIPPECANOE_IMAGE" -f "$DOCKERFILE" "$BASE_DIR"
        log_success "Built $TIPPECANOE_IMAGE"
    else
        log_info "Using existing $TIPPECANOE_IMAGE image"
    fi
else
    log_error "Neither tippecanoe nor Docker found."
    log_info "Install: brew install tippecanoe"
    exit 1
fi

# ---- tippecanoe wrapper (handles native vs Docker) ----
run_tippecanoe() {
    INPUT_GEOJSON="$1"
    OUTPUT_PMTILES="$2"
    LAYER_NAME="$3"
    DESCRIPTION="$4"

    if [ "$USE_DOCKER" = true ]; then
        INPUT_BASENAME=$(basename "$INPUT_GEOJSON")
        OUTPUT_BASENAME=$(basename "$OUTPUT_PMTILES")
        docker run --rm \
            -v "${BOUNDARIES_DIR}:/data" \
            "$TIPPECANOE_IMAGE" \
            tippecanoe \
                --output="/data/${OUTPUT_BASENAME}" \
                --force \
                --maximum-zoom=14 \
                --minimum-zoom=0 \
                --no-feature-limit \
                --no-tile-size-limit \
                --detect-shared-borders \
                --no-simplification-of-shared-nodes \
                --coalesce-densest-as-needed \
                --extend-zooms-if-still-dropping \
                --layer="$LAYER_NAME" \
                --name="$LAYER_NAME" \
                --description="$DESCRIPTION" \
                "/data/${INPUT_BASENAME}"
    else
        tippecanoe \
            --output="$OUTPUT_PMTILES" \
            --force \
            --maximum-zoom=14 \
            --minimum-zoom=0 \
            --no-feature-limit \
            --no-tile-size-limit \
            --detect-shared-borders \
            --no-simplification-of-shared-nodes \
            --coalesce-densest-as-needed \
            --extend-zooms-if-still-dropping \
            --layer="$LAYER_NAME" \
            --name="$LAYER_NAME" \
            --description="$DESCRIPTION" \
            "$INPUT_GEOJSON"
    fi
}

# ---- Nigeria: split boundaries.geojson into per-tenant files ----
split_nigeria_boundaries() {
    INPUT="$BOUNDARIES_DIR/nigeria-boundaries.geojson"

    if [ ! -f "$INPUT" ]; then
        log_error "Nigeria boundaries not found: $INPUT"
        log_info "Run: ./scripts/sh/extract-boundaries.sh --country nigeria"
        return 1
    fi

    log_info "Splitting nigeria-boundaries.geojson into per-tenant files..."

    python3 << PYEOF
import json, sys

INPUT  = "$INPUT"
OUTDIR = "$BOUNDARIES_DIR"
FORCE  = "$FORCE" == "true"

# Tenant definitions: output-name -> list of state names to match
TENANTS = [
    ("nigeria-edo-boundaries",        ["Edo"]),
    ("nigeria-lagos-boundaries",      ["Lagos"]),
    ("nigeria-kwara-boundaries",      ["Kwara"]),
    ("nigeria-bayelsa-boundaries",    ["Bayelsa"]),
    ("nigeria-jigawa-boundaries",     ["Jigawa"]),
    ("nigeria-lagos-osun-boundaries", ["Lagos", "Osun"]),
]

with open(INPUT, encoding="utf-8") as f:
    data = json.load(f)

all_features = data.get("features", [])
state_features = [f for f in all_features if str(f.get("properties", {}).get("admin_level", "")) == "4"]
lga_features   = [f for f in all_features if str(f.get("properties", {}).get("admin_level", "")) == "6"]

print(f"  Loaded: {len(state_features)} states, {len(lga_features)} LGAs")

def get_bbox(geometry):
    """Compute [minlon, minlat, maxlon, maxlat] from any GeoJSON geometry."""
    def extract_coords(c):
        if not c:
            return []
        if isinstance(c[0], list):
            return [p for sub in c for p in extract_coords(sub)]
        return [c]
    coords = extract_coords(geometry.get("coordinates", []))
    if not coords:
        return None
    lons = [c[0] for c in coords]
    lats = [c[1] for c in coords]
    return [min(lons), min(lats), max(lons), max(lats)]

def get_centroid(geometry):
    """Compute centroid of a GeoJSON geometry."""
    def extract_coords(c):
        if not c:
            return []
        if isinstance(c[0], list):
            return [p for sub in c for p in extract_coords(sub)]
        return [c]
    coords = extract_coords(geometry.get("coordinates", []))
    if not coords:
        return None
    return [sum(c[0] for c in coords) / len(coords),
            sum(c[1] for c in coords) / len(coords)]

def point_in_bbox(point, bbox, padding=0.001):
    return (point[0] >= bbox[0] - padding and point[0] <= bbox[2] + padding and
            point[1] >= bbox[1] - padding and point[1] <= bbox[3] + padding)

for output_name, state_names in TENANTS:
    import os
    out_path = os.path.join(OUTDIR, f"{output_name}.geojson")
    if os.path.exists(out_path) and not FORCE:
        size_mb = os.path.getsize(out_path) / 1024 / 1024
        print(f"  SKIP {output_name}.geojson ({size_mb:.1f} MB) -- use --force to regenerate")
        continue

    # Match states by name
    matched_states = [f for f in state_features
                      if f.get("properties", {}).get("name", "") in state_names]

    if not matched_states:
        print(f"  WARN {output_name}: no states matched for {state_names}")
        print(f"       Available state names: {sorted(set(f['properties'].get('name','') for f in state_features))[:10]}")
        continue

    # Combined bbox of all matched states
    bboxes = [get_bbox(f["geometry"]) for f in matched_states if get_bbox(f["geometry"])]
    if not bboxes:
        print(f"  WARN {output_name}: could not compute bboxes")
        continue

    combined_bbox = [
        min(b[0] for b in bboxes),
        min(b[1] for b in bboxes),
        max(b[2] for b in bboxes),
        max(b[3] for b in bboxes),
    ]

    # Find LGAs whose centroid falls in the combined state bbox
    matched_lgas = []
    for f in lga_features:
        centroid = get_centroid(f["geometry"])
        if centroid and point_in_bbox(centroid, combined_bbox):
            matched_lgas.append(f)

    output_features = matched_states + matched_lgas
    out_data = {"type": "FeatureCollection", "name": output_name, "features": output_features}
    with open(out_path, "w", encoding="utf-8") as fout:
        json.dump(out_data, fout)

    size_mb = os.path.getsize(out_path) / 1024 / 1024
    print(f"  WROTE {output_name}.geojson: {len(matched_states)} states + {len(matched_lgas)} LGAs ({size_mb:.1f} MB)")

PYEOF
}

# ---- Generate Nigeria boundary PMTiles (per tenant) ----
process_nigeria() {
    if ! split_nigeria_boundaries; then
        return 1
    fi

    TENANT_FILES="nigeria-edo nigeria-lagos nigeria-kwara nigeria-bayelsa nigeria-jigawa nigeria-lagos-osun"
    RESULT=0

    for TENANT in $TENANT_FILES; do
        FILE_BASE="${TENANT}-boundaries"
        IN="$BOUNDARIES_DIR/${FILE_BASE}.geojson"
        OUT="$BOUNDARIES_DIR/${FILE_BASE}.pmtiles"

        if [ ! -f "$IN" ] || [ ! -s "$IN" ]; then
            log_warn "$IN not generated (check split output above)"
            continue
        fi

        if [ -f "$OUT" ] && [ -s "$OUT" ] && [ "$FORCE" = false ]; then
            SIZE=$(du -m "$OUT" | cut -f1)
            log_warn "$FILE_BASE.pmtiles already exists (${SIZE} MB) -- use --force to regenerate"
            continue
        fi

        log_info "Generating: $FILE_BASE.pmtiles"
        if run_tippecanoe "$IN" "$OUT" "boundaries" "Nigeria admin boundaries - $TENANT"; then
            SIZE=$(du -m "$OUT" | cut -f1)
            log_success "$FILE_BASE.pmtiles (${SIZE} MB)"
        else
            log_error "tippecanoe failed for $FILE_BASE"
            RESULT=1
        fi
    done
    return $RESULT
}

# ---- Generate country boundary PMTiles (non-Nigeria) ----
process_country() {
    COUNTRY="$1"
    FILE_BASE="${COUNTRY}-boundaries"
    IN="$BOUNDARIES_DIR/${FILE_BASE}.geojson"
    OUT="$BOUNDARIES_DIR/${FILE_BASE}.pmtiles"

    if [ ! -f "$IN" ]; then
        log_error "GeoJSON missing: $IN"
        log_info "Run: ./scripts/sh/extract-boundaries.sh --country $COUNTRY"
        return 1
    fi

    if [ -f "$OUT" ] && [ -s "$OUT" ] && [ "$FORCE" = false ]; then
        SIZE=$(du -m "$OUT" | cut -f1)
        log_warn "$FILE_BASE.pmtiles already exists (${SIZE} MB) -- use --force to regenerate"
        return 0
    fi

    log_info "Generating: $FILE_BASE.pmtiles"
    if run_tippecanoe "$IN" "$OUT" "boundaries" "Admin boundaries for $COUNTRY (OSM)"; then
        SIZE=$(du -m "$OUT" | cut -f1)
        log_success "$FILE_BASE.pmtiles (${SIZE} MB)"
        return 0
    else
        log_error "tippecanoe failed for $COUNTRY"
        return 1
    fi
}

# ---- Main dispatch ----
TOTAL_START=$(date +%s)
SUCCEEDED=""
FAILED=""

echo ""
echo "================================================================"
echo "  Boundary Tile Generator (tippecanoe)"
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
    log_info "Country: $COUNTRY"

    if [ "$COUNTRY" = "nigeria" ]; then
        if process_nigeria; then
            SUCCEEDED="$SUCCEEDED nigeria"
        else
            FAILED="$FAILED nigeria"
        fi
    else
        if process_country "$COUNTRY"; then
            SUCCEEDED="$SUCCEEDED $COUNTRY"
        else
            FAILED="$FAILED $COUNTRY"
        fi
    fi
done

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))

echo ""
echo "================================================================"
echo "  Done in $((TOTAL_ELAPSED/60))m $((TOTAL_ELAPSED%60))s"
echo "================================================================"
echo ""
[ -n "$SUCCEEDED" ] && log_success "Generated:$SUCCEEDED"
[ -n "$FAILED" ]    && log_error   "Failed:$FAILED"

if [ -n "$FAILED" ]; then exit 1; fi

echo ""
log_info "Next steps:"
log_info "  docker compose -f tileserver/docker-compose.tenant.yml up"
log_info "  curl http://localhost:3000/catalog"
echo ""
