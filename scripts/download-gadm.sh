#!/usr/bin/env bash
#
# download-gadm.sh - Download GADM administrative boundary data for all countries
# Usage: ./scripts/download-gadm.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
GADM_DIR="$BASE_DIR/gadm"

mkdir -p "$GADM_DIR"

log_info()    { echo -e "\033[34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR]\033[0m $1"; }

# Country name -> ISO3 code mapping
declare -A COUNTRY_ISO
COUNTRY_ISO=(
    ["nigeria"]="NGA"
    ["kenya"]="KEN"
    ["uganda"]="UGA"
    ["rwanda"]="RWA"
    ["liberia"]="LBR"
    ["central-african-republic"]="CAF"
    ["india"]="IND"
)

COUNTRIES_ORDER=("nigeria" "kenya" "uganda" "rwanda" "liberia" "central-african-republic" "india")
BASE_URL="https://geodata.ucdavis.edu/gadm/gadm4.1/json"

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Downloading GADM boundary data (levels 0-4)\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

TOTAL=${#COUNTRIES_ORDER[@]}
I=0

for COUNTRY in "${COUNTRIES_ORDER[@]}"; do
    I=$((I + 1))
    ISO=${COUNTRY_ISO[$COUNTRY]}
    log_info "[$I/$TOTAL] $COUNTRY ($ISO)..."

    for LEVEL in 0 1 2 3 4; do
        OUT_FILE="$GADM_DIR/${COUNTRY}_${LEVEL}.json"
        URL="${BASE_URL}/gadm41_${ISO}_${LEVEL}.json"

        if [ -f "$OUT_FILE" ]; then
            log_info "  Level $LEVEL already exists - skipping"
        else
            if curl -fSL -o "$OUT_FILE" "$URL" 2>/dev/null; then
                SIZE=$(du -k "$OUT_FILE" | cut -f1)
                if [ "$SIZE" -gt 1024 ]; then
                    SIZE_MB=$((SIZE / 1024))
                    log_success "  Level $LEVEL downloaded (${SIZE_MB} MB)"
                else
                    log_success "  Level $LEVEL downloaded (${SIZE} KB)"
                fi
            else
                log_info "  Level $LEVEL not available or download failed"
                rm -f "$OUT_FILE" 2>/dev/null || true
            fi
        fi
    done
done

echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m  GADM Download Complete!\033[0m"
echo -e "\033[32m================================================================\033[0m"
echo ""

for f in "$GADM_DIR"/*.json; do
    if [ -f "$f" ]; then
        SIZE=$(du -m "$f" | cut -f1)
        echo -e "  \033[32m+ $(basename "$f") (${SIZE} MB)\033[0m"
    fi
done
