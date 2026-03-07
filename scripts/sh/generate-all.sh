#!/usr/bin/env bash
#
# generate-all.sh - Generate PMTiles for all 7 countries on macOS/Linux
# Usage: ./scripts/generate-all.sh
#
# Generates tiles in order from smallest to largest:
#   1. Liberia       (~2 min,  2GB RAM)
#   2. Rwanda        (~3 min,  2GB RAM)
#   3. CAR           (~3 min,  2GB RAM)
#   4. Uganda        (~10 min, 4GB RAM)
#   5. Kenya         (~15 min, 4GB RAM)
#   6. Nigeria       (~30 min, 6GB RAM)
#   7. India         (~90 min, 8GB RAM)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATE_SINGLE="$SCRIPT_DIR/generate-single.sh"

# Colors
log_info()    { echo -e "\033[34m[INFO] $(date +%H:%M:%S)\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS] $(date +%H:%M:%S)\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR] $(date +%H:%M:%S)\033[0m $1"; }

COUNTRIES=(
    "liberia"
    "rwanda"
    "central-african-republic"
    "uganda"
    "kenya"
    "nigeria"
    "india"
)

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Generating PMTiles for ALL countries\033[0m"
echo -e "\033[36m  Total: ${#COUNTRIES[@]} countries\033[0m"
echo -e "\033[36m  Estimated time: 2-3 hours (depending on hardware)\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

TOTAL_START=$(date +%s)
SUCCEEDED=()
FAILED=()

I=0
for COUNTRY in "${COUNTRIES[@]}"; do
    I=$((I + 1))
    echo ""
    echo -e "\033[90m────────────────────────────────────────────────────────\033[0m"
    log_info "[$I/${#COUNTRIES[@]}] Starting: $(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')"
    echo -e "\033[90m────────────────────────────────────────────────────────\033[0m"

    if bash "$GENERATE_SINGLE" "$COUNTRY"; then
        SUCCEEDED+=("$COUNTRY")
        log_success "$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]') done"
    else
        log_error "Failed to generate $(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')"
        FAILED+=("$COUNTRY")
    fi
done

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINUTES=$(( (TOTAL_ELAPSED % 3600) / 60 ))
SECS=$((TOTAL_ELAPSED % 60))

echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m  Generation Complete!\033[0m"
echo -e "\033[32m================================================================\033[0m"
echo ""
echo "  Total time: ${HOURS}h ${MINUTES}m ${SECS}s"
echo ""

if [ ${#SUCCEEDED[@]} -gt 0 ]; then
    echo -e "  \033[32mSucceeded (${#SUCCEEDED[@]}):\033[0m"
    for c in "${SUCCEEDED[@]}"; do
        echo -e "    \033[32m+ $c\033[0m"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo -e "  \033[31mFailed (${#FAILED[@]}):\033[0m"
    for c in "${FAILED[@]}"; do
        echo -e "    \033[31m- $c\033[0m"
    done
    echo ""
    echo -e "  \033[33mRe-run failed countries individually:\033[0m"
    for c in "${FAILED[@]}"; do
        echo "    ./scripts/generate-single.sh $c"
    done
fi

# Show generated files
BASE_DIR="$(dirname "$SCRIPT_DIR")"
PMTILES_DIR="$BASE_DIR/pmtiles"
echo ""
log_info "Generated PMTiles:"
for f in "$PMTILES_DIR"/*-detailed.pmtiles; do
    if [ -f "$f" ]; then
        SIZE=$(du -m "$f" | cut -f1)
        echo -e "  \033[32m+ $(basename "$f") (${SIZE} MB)\033[0m"
    fi
done

echo ""
log_info "Next step: ./scripts/run-martin.sh"
