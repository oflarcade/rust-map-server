#!/usr/bin/env bash
# generate-hdx-boundaries.sh — Generate HDX COD-AB boundary PMTiles for comparison
#
# Converts HDX COD-AB ADM1 + ADM2 GeoJSON files into PMTiles using tippecanoe (Docker).
# Output filenames use the -hdx suffix so they coexist with OSM boundary tiles
# and can be toggled in the tile inspector.
#
# Targets:
#   - nigeria-boundaries-hdx
#   - kenya-boundaries-hdx
#   - uganda-boundaries-hdx
#   - liberia-boundaries-hdx
#   - central-african-republic-boundaries-hdx
#
# Rwanda excluded: HDX package has no GeoJSON (only SHP/EMF). Use OSM boundaries.
#
# Dependencies: docker
#
# Usage:
#   ./scripts/sh/generate-hdx-boundaries.sh
#   ./scripts/sh/generate-hdx-boundaries.sh --country kenya
#   ./scripts/sh/generate-hdx-boundaries.sh --country nigeria --force
#   ./scripts/sh/generate-hdx-boundaries.sh --force

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HDX_DIR="${BASE_DIR}/hdx"
BOUNDARIES_DIR="${BASE_DIR}/boundaries"
TIPPECANOE_IMAGE="felt-tippecanoe:local"
DOCKERFILE="${BASE_DIR}/scripts/Dockerfile.tippecanoe"

COUNTRY_FILTER=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --country) COUNTRY_FILTER="$2"; shift 2 ;;
        --force)   FORCE=true;          shift ;;
        *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
    esac
done

info()    { echo "[INFO]    $(date '+%H:%M:%S') $*"; }
success() { echo "[SUCCESS] $(date '+%H:%M:%S') $*"; }
error()   { echo "[ERROR]   $(date '+%H:%M:%S') $*"; }

# Countries: "short_name:hdx_prefix:out_file:display_name"
declare -a COUNTRIES=(
    "kenya:kenya:kenya-boundaries-hdx:Kenya"
    "uganda:uganda:uganda-boundaries-hdx:Uganda"
    "liberia:liberia:liberia-boundaries-hdx:Liberia"
    "car:central-african-republic:central-african-republic-boundaries-hdx:Central African Republic"
    "nigeria:nigeria:nigeria-boundaries-hdx:Nigeria"
)

# Apply country filter
if [[ -n "${COUNTRY_FILTER}" ]]; then
    filtered=()
    for entry in "${COUNTRIES[@]}"; do
        short_name="${entry%%:*}"
        hdx_prefix=$(echo "${entry}" | cut -d: -f2)
        if [[ "${COUNTRY_FILTER}" == "${short_name}" || "${COUNTRY_FILTER}" == "${hdx_prefix}" ]]; then
            filtered+=("${entry}")
        fi
    done
    if [[ ${#filtered[@]} -eq 0 ]]; then
        error "Country '${COUNTRY_FILTER}' not found. Available: kenya, uganda, liberia, car, nigeria"
        error "(Rwanda excluded -- no GeoJSON in HDX package)"
        exit 1
    fi
    COUNTRIES=("${filtered[@]}")
fi

if ! command -v docker &>/dev/null; then
    error "Docker is required to run tippecanoe."
    exit 1
fi

# Build tippecanoe image if not present
if [[ -z "$(docker images -q "${TIPPECANOE_IMAGE}" 2>/dev/null)" ]]; then
    info "Building tippecanoe Docker image..."
    docker build -t "${TIPPECANOE_IMAGE}" -f "${DOCKERFILE}" "${BASE_DIR}"
    success "Built ${TIPPECANOE_IMAGE}"
fi

mkdir -p "${BOUNDARIES_DIR}"

succeeded=()
failed=()
skipped=()

for entry in "${COUNTRIES[@]}"; do
    IFS=':' read -r short_name hdx_prefix out_file display_name <<< "${entry}"

    adm1_file="${HDX_DIR}/${hdx_prefix}_adm1.geojson"
    adm2_file="${HDX_DIR}/${hdx_prefix}_adm2.geojson"
    pmtiles_file="${BOUNDARIES_DIR}/${out_file}.pmtiles"

    # Validate input files
    missing=()
    [[ ! -f "${adm1_file}" ]] && missing+=("${hdx_prefix}_adm1.geojson")
    [[ ! -f "${adm2_file}" ]] && missing+=("${hdx_prefix}_adm2.geojson")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing HDX files for ${display_name}: ${missing[*]}"
        error "  Run: ./scripts/sh/download-hdx.sh"
        failed+=("${short_name}: missing HDX source files")
        continue
    fi

    if [[ -f "${pmtiles_file}" && "${FORCE}" == "false" ]]; then
        info "${out_file}.pmtiles already exists - skipping (use --force to regenerate)"
        skipped+=("${short_name}: exists")
        continue
    fi

    info "Generating ${out_file}.pmtiles from HDX data..."
    container_name="tippecanoe-hdx-${short_name}-$$"

    docker create --name "${container_name}" \
        --entrypoint="" \
        -v "${HDX_DIR}:/hdx:ro" \
        "${TIPPECANOE_IMAGE}" \
        tippecanoe \
            --output="/tmp/${out_file}.pmtiles" \
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
            --name="${out_file}" \
            --description="HDX COD-AB admin boundaries for ${display_name} (CC BY-IGO)" \
            "/hdx/${hdx_prefix}_adm1.geojson" \
            "/hdx/${hdx_prefix}_adm2.geojson" > /dev/null

    if ! docker start -a "${container_name}"; then
        error "tippecanoe failed for ${display_name}"
        failed+=("${short_name}: tippecanoe error")
        docker rm "${container_name}" 2>/dev/null || true
        continue
    fi

    if ! docker cp "${container_name}:/tmp/${out_file}.pmtiles" "${pmtiles_file}"; then
        error "Failed to copy output for ${display_name}"
        failed+=("${short_name}: docker cp error")
        docker rm "${container_name}" 2>/dev/null || true
        continue
    fi

    docker rm "${container_name}" 2>/dev/null || true
    success "${out_file}.pmtiles generated"
    succeeded+=("${short_name}")
done

echo ""
echo "================================================================"
echo "  HDX Boundary Generation Complete"
echo "================================================================"

[[ ${#succeeded[@]} -gt 0 ]] && echo "Generated: ${succeeded[*]}"
[[ ${#skipped[@]}   -gt 0 ]] && echo "Skipped:   ${skipped[*]}"
[[ ${#failed[@]}    -gt 0 ]] && echo "Failed:    ${failed[*]}"

info "Restart Docker to make tiles discoverable by Martin:"
info "  docker compose -f tileserver/docker-compose.tenant.yml restart"
info "Verify with:"
info "  curl http://localhost:3000/catalog"

[[ ${#failed[@]} -gt 0 ]] && exit 1
exit 0
