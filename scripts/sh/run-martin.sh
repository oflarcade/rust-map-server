#!/usr/bin/env bash
#
# run-martin.sh - Start Martin tile server on macOS/Linux (port 3001)
# Usage: ./scripts/run-martin.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$BASE_DIR/tileserver/martin-config.yaml"
PMTILES_DIR="$BASE_DIR/pmtiles"
BOUNDARIES_DIR="$BASE_DIR/boundaries"

# Colors
log_info()    { echo -e "\033[34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR]\033[0m $1"; }
log_warn()    { echo -e "\033[33m[WARN]\033[0m $1"; }

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Martin Tile Server - macOS/Linux\033[0m"
echo -e "\033[36m  Port: 3000\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

# Check Martin is installed
if command -v martin &>/dev/null; then
    MARTIN_VERSION=$(martin --version 2>&1)
    log_success "Martin: $MARTIN_VERSION"
else
    log_error "'martin' command not found!"
    echo ""
    echo -e "  \033[33mInstall Martin with:\033[0m"
    echo "    cargo install martin"
    echo ""
    echo -e "  \033[33mOr download from:\033[0m"
    echo "    https://github.com/maplibre/martin/releases"
    exit 1
fi

# Check config exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config not found: $CONFIG_FILE"
    exit 1
fi

# Count available tiles
DETAILED_COUNT=$(find "$PMTILES_DIR" -maxdepth 1 -name "*-detailed.pmtiles" 2>/dev/null | wc -l | xargs)
BOUNDARY_COUNT=$(find "$BOUNDARIES_DIR" -maxdepth 1 -name "*.pmtiles" 2>/dev/null | wc -l | xargs)

if [ "$DETAILED_COUNT" -eq 0 ] && [ "$BOUNDARY_COUNT" -eq 0 ]; then
    log_error "No PMTiles files found!"
    log_info "Run ./scripts/generate-all.sh first"
    exit 1
fi

log_info "Detailed tiles: $DETAILED_COUNT files"
log_info "Boundary tiles: $BOUNDARY_COUNT files"

if [ "$DETAILED_COUNT" -eq 0 ]; then
    log_warn "No detailed tiles found in pmtiles/ - only boundaries will be served"
    log_info "Run ./scripts/generate-all.sh to generate detailed tiles"
fi

echo ""
log_info "Config: $CONFIG_FILE"
log_info "Starting Martin..."
echo ""
echo -e "  \033[32mCatalog: http://localhost:3000/catalog\033[0m"
echo -e "  \033[32mHealth:  http://localhost:3000/health\033[0m"
echo ""
echo -e "  \033[90mPress Ctrl+C to stop\033[0m"
echo ""

# cd to project root so relative paths in config work
cd "$BASE_DIR"

# Start Martin
martin --config "$CONFIG_FILE"
