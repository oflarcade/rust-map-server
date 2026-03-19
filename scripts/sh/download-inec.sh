#!/usr/bin/env bash
# download-inec.sh — Download Nigeria INEC electoral boundary GeoJSON from HDX
#
# Attempts to download Nigeria electoral boundaries (senatorial zones + federal
# constituencies) from HDX. Tries multiple known package IDs.
#
# If auto-download fails, prints manual placement instructions.
# Files must end up in data/inec/ for import by import-inec-to-pg.js.
#
# Dependencies: curl, jq  (brew install curl jq)
#
# Usage:
#   ./scripts/sh/download-inec.sh
#   ./scripts/sh/download-inec.sh --force
#   ./scripts/sh/download-inec.sh --search   # just search HDX and print results

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INEC_DIR="${BASE_DIR}/data/inec"
HDX_API="https://data.humdata.org/api/3/action"

FORCE=false
SEARCH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)  FORCE=true;  shift ;;
        --search) SEARCH=true; shift ;;
        *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
    esac
done

mkdir -p "${INEC_DIR}"

info()    { echo "[INFO]    $*"; }
success() { echo "[SUCCESS] $*"; }
warn()    { echo "[WARN]    $*"; }
error()   { echo "[ERROR]   $*"; }

echo ""
echo "================================================================"
echo "  Nigeria INEC Electoral Boundaries downloader"
echo "  Target: ${INEC_DIR}"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
# --search mode: query HDX and print matching packages
# ---------------------------------------------------------------------------
if [[ "${SEARCH}" == "true" ]]; then
    info "Searching HDX for Nigeria electoral boundary datasets..."
    search_url="${HDX_API}/package_search?q=nigeria+electoral+senatorial+boundaries&rows=10"
    result=$(curl -sf --connect-timeout 30 "${search_url}") || { error "Search request failed"; exit 1; }
    count=$(echo "${result}" | jq '.result.results | length')
    if [[ "${count}" -gt 0 ]]; then
        echo ""
        echo "Matching HDX packages:"
        echo "${result}" | jq -r '.result.results[] | "  ID:    \(.id)\n  Name:  \(.name)\n  Title: \(.title)\n"'
        echo "Re-run with the correct package ID set in this script, or place files manually."
    else
        warn "No results found. Try visiting:"
        warn "  https://data.humdata.org/dataset?q=nigeria+electoral+senatorial"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Package IDs to try in order
# ---------------------------------------------------------------------------
PACKAGE_IDS=(
    "nigeria-electoral-boundaries"
    "cod-ab-nga"
    "nigeria-independent-national-electoral-commission-lga-and-wards"
)

# Keywords that identify senatorial / constituency resources
# Format: "keyword1,keyword2,...:output_filename"
declare -A MAPPINGS
MAPPINGS["senat,senatorial,sen_zone,senate"]="nigeria_senatorial.geojson"
MAPPINGS["constit,constituency,fed_const,federal_constituency"]="nigeria_constituencies.geojson"

downloaded=0

try_package() {
    local pkg_id="$1"
    local found=0

    info "Trying package '${pkg_id}'..."
    pkg_url="${HDX_API}/package_show?id=${pkg_id}"
    pkg_json=$(curl -sf --connect-timeout 30 "${pkg_url}" 2>/dev/null) || {
        warn "  Package '${pkg_id}' not found or request failed"
        echo 0; return
    }

    success_flag=$(echo "${pkg_json}" | jq -r '.success')
    if [[ "${success_flag}" != "true" ]]; then
        warn "  Package '${pkg_id}': API returned success=false"
        echo 0; return
    fi

    resource_count=$(echo "${pkg_json}" | jq '.result.resources | length')
    info "  Found ${resource_count} resource(s) in package '${pkg_id}'"

    while IFS= read -r resource; do
        res_name=$(echo "${resource}" | jq -r '.name // ""' | tr '[:upper:]' '[:lower:]')
        res_format=$(echo "${resource}" | jq -r '.format // ""' | tr '[:upper:]' '[:lower:]')
        res_url=$(echo "${resource}" | jq -r '.download_url // .url // ""')

        [[ -z "${res_url}" ]] && continue

        # Only process geojson/zip/json
        is_geojson=false; is_zip=false; is_json=false
        [[ "${res_format}" == "geojson" || "${res_url}" == *.geojson ]] && is_geojson=true
        [[ "${res_format}" == "zip"     || "${res_url}" == *.zip     ]] && is_zip=true
        [[ "${res_format}" == "json"    || "${res_url}" == *.json    ]] && is_json=true
        [[ "${is_geojson}" == "false" && "${is_zip}" == "false" && "${is_json}" == "false" ]] && continue

        for kw_list in "${!MAPPINGS[@]}"; do
            output_file="${MAPPINGS[${kw_list}]}"
            dest="${INEC_DIR}/${output_file}"
            matched=false

            IFS=',' read -ra kws <<< "${kw_list}"
            for kw in "${kws[@]}"; do
                if [[ "${res_name}" == *"${kw}"* ]]; then
                    matched=true; break
                fi
            done
            [[ "${matched}" == "false" ]] && continue

            if [[ -f "${dest}" && "${FORCE}" == "false" ]]; then
                info "  ${output_file} already exists (use --force to re-download)"
                found=$((found + 1))
                continue
            fi

            info "  Downloading: $(echo "${resource}" | jq -r '.name') -> ${output_file}"
            tmp_file=$(mktemp /tmp/inec_XXXXXX)

            if ! curl -sf -L --connect-timeout 30 --max-time 120 -o "${tmp_file}" "${res_url}"; then
                warn "  Download failed for resource"
                rm -f "${tmp_file}"
                continue
            fi

            # Detect ZIP by magic bytes (PK header = 0x50 0x4B)
            is_zip_file=false
            [[ "${res_url}" == *.zip ]] && is_zip_file=true
            if [[ "${is_zip_file}" == "false" ]]; then
                magic=$(xxd -p -l 2 "${tmp_file}" 2>/dev/null || od -An -tx1 -N2 "${tmp_file}" | tr -d ' \n')
                [[ "${magic}" == "504b"* ]] && is_zip_file=true
            fi

            if [[ "${is_zip_file}" == "true" ]]; then
                info "  Extracting ZIP..."
                tmp_dir=$(mktemp -d /tmp/inec_extract_XXXXXX)
                if unzip -q "${tmp_file}" -d "${tmp_dir}"; then
                    # Find best matching geojson in zip
                    best_file=""
                    while IFS= read -r -d '' f; do
                        fname=$(basename "${f}" | tr '[:upper:]' '[:lower:]')
                        for kw in "${kws[@]}"; do
                            if [[ "${fname}" == *"${kw}"* ]]; then
                                best_file="${f}"; break 2
                            fi
                        done
                        [[ -z "${best_file}" ]] && best_file="${f}"
                    done < <(find "${tmp_dir}" -type f \( -name "*.geojson" -o -name "*.json" \) -print0)

                    if [[ -n "${best_file}" ]]; then
                        cp "${best_file}" "${dest}"
                        success "  Extracted $(basename "${best_file}") -> ${output_file}"
                        found=$((found + 1))
                    else
                        warn "  No GeoJSON found in ZIP (may be shapefile only)"
                    fi
                fi
                rm -f "${tmp_file}"
                rm -rf "${tmp_dir}"
            else
                cp "${tmp_file}" "${dest}"
                rm -f "${tmp_file}"
                success "  Saved ${output_file}"
                found=$((found + 1))
            fi
        done
    done < <(echo "${pkg_json}" | jq -c '.result.resources[]')

    echo "${found}"
}

for pkg_id in "${PACKAGE_IDS[@]}"; do
    n=$(try_package "${pkg_id}")
    downloaded=$((downloaded + n))
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"

senat_file="${INEC_DIR}/nigeria_senatorial.geojson"
const_file="${INEC_DIR}/nigeria_constituencies.geojson"
have_senat=false; have_const=false
[[ -f "${senat_file}" ]] && have_senat=true
[[ -f "${const_file}" ]] && have_const=true

if [[ "${have_senat}" == "true" && "${have_const}" == "true" ]]; then
    success "Both INEC files are present in ${INEC_DIR}"
    echo ""
    echo "  Next: node scripts/import-inec-to-pg.js"
    echo "  Jigawa only: node scripts/import-inec-to-pg.js --state NG018"
else
    warn "Auto-download did not produce all required files."
    warn "Files needed in ${INEC_DIR}:"
    [[ "${have_senat}" == "false" ]] && warn "  MISSING: nigeria_senatorial.geojson  (senatorial districts, adm3)"
    [[ "${have_senat}" == "true"  ]] && success "  PRESENT: nigeria_senatorial.geojson"
    [[ "${have_const}" == "false" ]] && warn "  MISSING: nigeria_constituencies.geojson  (federal constituencies, adm4)"
    [[ "${have_const}" == "true"  ]] && success "  PRESENT: nigeria_constituencies.geojson"

    echo ""
    echo "Manual steps to obtain these files:"
    echo ""
    echo "  Option 1 - HDX search (find correct package ID):"
    echo "    ./scripts/sh/download-inec.sh --search"
    echo "    https://data.humdata.org/dataset?q=nigeria+senatorial+electoral"
    echo ""
    echo "  Option 2 - Nigeria COD-AB adm3 (wards, some states only):"
    echo "    Already downloaded by download-hdx.sh as data/hdx/nigeria_adm3.geojson"
    echo "    Copy and rename: nigeria_senatorial.geojson (adjust field names)"
    echo ""
    echo "  Option 3 - GRID3 Nigeria (wards/electoral):"
    echo "    https://grid3.org/resources/results?q=nigeria"
    echo "    Download GeoJSON, rename, place in data/inec/"
    echo ""
    echo "  GeoJSON property requirements (used by import-inec-to-pg.js):"
    echo "    Senatorial:     sen_pcode (or pcode), sen_name (or name), adm1_pcode"
    echo "    Constituencies: con_pcode (or pcode), con_name (or name), sen_pcode"
fi

echo "================================================================"
echo ""
