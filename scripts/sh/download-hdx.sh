#!/usr/bin/env bash
# download-hdx.sh — Download HDX COD-AB administrative boundary GeoJSON (macOS/Linux)
#
# Downloads the GeoJSON zip for each country from the HDX CKAN API and extracts
# all available adminN GeoJSON files into data/hdx/<country>_admN.geojson.
#
# India excluded: no standard COD-AB package on HDX.
# Rwanda excluded: HDX package has no GeoJSON (only SHP/EMF).
#
# Dependencies: curl, jq, unzip  (brew install curl jq unzip)
#
# Usage:
#   ./scripts/sh/download-hdx.sh
#   ./scripts/sh/download-hdx.sh --country kenya
#   ./scripts/sh/download-hdx.sh --force

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HDX_DIR="${BASE_DIR}/data/hdx"
HDX_API="https://data.humdata.org/api/3/action"

COUNTRY_FILTER=""
FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --country) COUNTRY_FILTER="$2"; shift 2 ;;
        --force)   FORCE=true;          shift ;;
        *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
    esac
done

mkdir -p "${HDX_DIR}"

# Country definitions: "package_id:short_name:prefix"
declare -a COUNTRIES=(
    "cod-ab-nga:nigeria:nigeria"
    "cod-ab-ken:kenya:kenya"
    "cod-ab-uga:uganda:uganda"
    "cod-ab-lbr:liberia:liberia"
    "cod-ab-caf:car:central-african-republic"
)

info()    { echo "[INFO]    $*"; }
success() { echo "[SUCCESS] $*"; }
warn()    { echo "[WARN]    $*"; }
error()   { echo "[ERROR]   $*"; }

echo ""
echo "================================================================"
echo "  Downloading HDX COD-AB boundary data (all admin levels)"
echo "================================================================"
echo ""

succeeded=()
failed=()
skipped=()
total=${#COUNTRIES[@]}
i=0

for entry in "${COUNTRIES[@]}"; do
    IFS=':' read -r pkg_id short_name prefix <<< "${entry}"
    i=$((i + 1))

    # Apply country filter
    if [[ -n "${COUNTRY_FILTER}" && "${COUNTRY_FILTER}" != "${short_name}" && "${COUNTRY_FILTER}" != "${prefix}" ]]; then
        continue
    fi

    info "[${i}/${total}] ${short_name} (${pkg_id})..."

    # Skip check: any existing admN files for this prefix
    existing_count=$(find "${HDX_DIR}" -name "${prefix}_adm*.geojson" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${existing_count}" -gt 0 && "${FORCE}" == "false" ]]; then
        info "  ${existing_count} adm files already exist - skipping (use --force to re-download)"
        skipped+=("${short_name}")
        continue
    fi

    # Fetch package metadata from HDX CKAN API
    api_url="${HDX_API}/package_show?id=${pkg_id}"
    info "  Fetching package metadata..."
    pkg_json=$(curl -sf --connect-timeout 30 "${api_url}") || {
        error "  Failed to fetch package metadata from HDX"
        failed+=("${short_name}: API error")
        continue
    }

    success_flag=$(echo "${pkg_json}" | jq -r '.success')
    if [[ "${success_flag}" != "true" ]]; then
        error "  HDX API returned success=false for ${pkg_id}"
        failed+=("${short_name}: package not found")
        continue
    fi

    # Find GeoJSON zip resource: format=GeoJSON AND url ends with .zip
    zip_url=$(echo "${pkg_json}" | jq -r '
        .result.resources[]
        | select((.format | ascii_downcase | contains("geojson")) and (.url | endswith(".zip")))
        | .url
    ' | head -1)

    if [[ -z "${zip_url}" ]]; then
        # Fallback: any zip with geojson in name/url
        zip_url=$(echo "${pkg_json}" | jq -r '
            .result.resources[]
            | select((.name | ascii_downcase | contains("geojson")) and (.url | endswith(".zip")))
            | .url
        ' | head -1)
    fi

    if [[ -z "${zip_url}" ]]; then
        warn "  No GeoJSON zip resource found for ${short_name}. Available resources:"
        echo "${pkg_json}" | jq -r '.result.resources[] | "    \(.name) [\(.format)] \(.url)"'
        failed+=("${short_name}: no GeoJSON zip found")
        continue
    fi

    info "  GeoJSON zip URL: ${zip_url}"

    # Download zip to temp location
    tmp_zip=$(mktemp /tmp/"${prefix}"_hdx_XXXXXX.zip)
    tmp_dir=$(mktemp -d /tmp/"${prefix}"_hdx_XXXXXX)

    info "  Downloading zip..."
    if ! curl -sf -L --connect-timeout 30 --max-time 300 -o "${tmp_zip}" "${zip_url}"; then
        error "  Failed to download zip"
        rm -f "${tmp_zip}"
        rm -rf "${tmp_dir}"
        failed+=("${short_name}: download error")
        continue
    fi

    sz_mb=$(du -m "${tmp_zip}" | cut -f1)
    success "  Downloaded (${sz_mb} MB)"

    # Extract zip
    if ! unzip -q "${tmp_zip}" -d "${tmp_dir}"; then
        error "  Failed to extract zip"
        rm -f "${tmp_zip}"
        rm -rf "${tmp_dir}"
        failed+=("${short_name}: extract error")
        continue
    fi

    # Find and copy all adminN GeoJSON files (skip _em simplified variants)
    copied_levels=()
    while IFS= read -r -d '' filepath; do
        filename=$(basename "${filepath}")
        # Match adminN[._] pattern, exclude _em. variants
        if [[ "${filename}" =~ [Aa]dmin([0-9]+)[._] ]] && [[ "${filename}" != *"_em."* ]]; then
            level="${BASH_REMATCH[1]}"
            dest="${HDX_DIR}/${prefix}_adm${level}.geojson"
            cp "${filepath}" "${dest}"
            dest_sz_mb=$(du -m "${dest}" | cut -f1)
            success "  ADM${level} -> ${prefix}_adm${level}.geojson (${dest_sz_mb} MB)"
            copied_levels+=("ADM${level}")
        fi
    done < <(find "${tmp_dir}" -type f \( -name "*.geojson" -o -name "*.json" \) -print0)

    rm -f "${tmp_zip}"
    rm -rf "${tmp_dir}"

    if [[ ${#copied_levels[@]} -eq 0 ]]; then
        warn "  No adminN files found in zip"
        failed+=("${short_name}: no adminN files in zip")
        continue
    fi

    info "  Extracted levels: ${copied_levels[*]}"
    succeeded+=("${short_name}")
done

echo ""
echo "================================================================"
echo "  HDX Download Complete"
echo "================================================================"

[[ ${#succeeded[@]} -gt 0 ]] && echo "Downloaded: ${succeeded[*]}"
[[ ${#skipped[@]}   -gt 0 ]] && echo "Skipped:   ${skipped[*]}"
[[ ${#failed[@]}    -gt 0 ]] && echo "Failed:    ${failed[*]}"

echo ""
info "Rwanda: HDX package (cod-ab-rwa) has only SHP — run scripts/extract-rwanda-adm1.py to generate data/hdx/rwanda_adm1.geojson from OSM boundaries."
warn "India excluded: no COD-AB package on HDX."

if [[ ${#succeeded[@]} -gt 0 ]]; then
    echo ""
    info "Next step: import into PostgreSQL with:"
    info "  node scripts/import-hdx-to-pg.js"
fi

echo ""
find "${HDX_DIR}" -name "*.geojson" 2>/dev/null | sort | while read -r f; do
    sz_mb=$(du -m "${f}" | cut -f1)
    echo "  + $(basename "${f}") (${sz_mb} MB)"
done

[[ ${#failed[@]} -gt 0 ]] && exit 1
exit 0
