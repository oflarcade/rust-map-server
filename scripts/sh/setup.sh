#!/usr/bin/env bash
#
# setup.sh - macOS/Linux Setup: Install prerequisites and download Planetiler + OSM data
#
# Usage: ./scripts/setup.sh
#
# OSM data is downloaded into data/osm/ (e.g. data/osm/nigeria-latest.osm.pbf).
# To download OSM only (e.g. after copying the rest): run this script; it will
# skip existing Planetiler/dirs and only fetch missing .osm.pbf files.
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
PLANETILER_VERSION="0.7.0"
PLANETILER_JAR="$BASE_DIR/planetiler.jar"
OSM_DATA_DIR="$BASE_DIR/data/osm"
GADM_DIR="$BASE_DIR/data/gadm"
BOUNDARIES_DIR="$BASE_DIR/data/boundaries"
PMTILES_DIR="$BASE_DIR/data/pmtiles"
DATA_SOURCES_DIR="$BASE_DIR/data/sources"
TEMP_DIR="$BASE_DIR/data/temp"

# Colors
log_info()    { echo -e "\033[34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
log_warn()    { echo -e "\033[33m[WARN]\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR]\033[0m $1"; }
log_step()    { echo -e "\033[36m[STEP]\033[0m $1"; }

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  PMTiles Generation Pipeline - macOS/Linux Setup Script\033[0m"
echo -e "\033[36m  (OSM base maps + GADM accurate boundaries)\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

cd "$BASE_DIR"
log_info "Working directory: $BASE_DIR"

# -- Step 1: Check Java -----------------------------------------------
log_step "Step 1/5: Checking Java installation..."
if command -v java &>/dev/null; then
    JAVA_VERSION_OUTPUT=$(java -version 2>&1 | head -1)
    JAVA_MAJOR=$(echo "$JAVA_VERSION_OUTPUT" | grep -oE '"[0-9]+' | tr -d '"')
    if [ "$JAVA_MAJOR" -ge 17 ] 2>/dev/null; then
        log_success "Java $JAVA_MAJOR detected (17+ required)"
    else
        log_warn "Java $JAVA_MAJOR detected. Java 17+ required."
        log_info "Install with: brew install openjdk@17"
        exit 1
    fi
else
    log_error "Java not found. Install Java 17+:"
    echo "  brew install openjdk@17"
    exit 1
fi

# -- Step 2: Check Martin ---------------------------------------------
log_step "Step 2/5: Checking Martin installation..."
if command -v martin &>/dev/null; then
    MARTIN_VERSION=$(martin --version 2>&1)
    log_success "Martin installed: $MARTIN_VERSION"
else
    log_warn "Martin not found. Install with: cargo install martin"
    log_info "Martin is needed to serve tiles (Step 2 of the pipeline)"
fi

# -- Step 3: Download Planetiler ---------------------------------------
log_step "Step 3/5: Downloading Planetiler v$PLANETILER_VERSION..."
if [ -f "$PLANETILER_JAR" ]; then
    SIZE=$(du -m "$PLANETILER_JAR" | cut -f1)
    log_success "Planetiler already exists (${SIZE} MB)"
else
    URL="https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar"
    log_info "Downloading from: $URL"
    if curl -L -o "$PLANETILER_JAR" "$URL"; then
        SIZE=$(du -m "$PLANETILER_JAR" | cut -f1)
        log_success "Planetiler downloaded (${SIZE} MB)"
    else
        log_error "Failed to download Planetiler"
        exit 1
    fi
fi

# -- Step 4: Create directories ----------------------------------------
log_step "Step 4/5: Setting up directories..."
mkdir -p "$OSM_DATA_DIR" "$PMTILES_DIR" "$GADM_DIR" "$BOUNDARIES_DIR" "$DATA_SOURCES_DIR" "$TEMP_DIR"
log_success "Directories ready"

# -- Step 5: Download OSM extracts -------------------------------------
log_step "Step 5/5: Downloading OSM extracts from Geofabrik..."

# Country URLs (pipe-delimited for Bash 3.x compatibility on macOS)
COUNTRY_DEFS=(
    "liberia|https://download.geofabrik.de/africa/liberia-latest.osm.pbf"
    "rwanda|https://download.geofabrik.de/africa/rwanda-latest.osm.pbf"
    "central-african-republic|https://download.geofabrik.de/africa/central-african-republic-latest.osm.pbf"
    "uganda|https://download.geofabrik.de/africa/uganda-latest.osm.pbf"
    "kenya|https://download.geofabrik.de/africa/kenya-latest.osm.pbf"
    "nigeria|https://download.geofabrik.de/africa/nigeria-latest.osm.pbf"
    "india|https://download.geofabrik.de/asia/india-latest.osm.pbf"
)

TOTAL=${#COUNTRY_DEFS[@]}
I=0

for DEF in "${COUNTRY_DEFS[@]}"; do
    IFS='|' read -r COUNTRY URL <<< "$DEF"
    I=$((I + 1))
    OUTPUT_FILE="$OSM_DATA_DIR/${COUNTRY}-latest.osm.pbf"

    if [ -f "$OUTPUT_FILE" ]; then
        SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
        log_info "[$I/$TOTAL] $COUNTRY already downloaded (${SIZE} MB) - skipping"
    else
        log_info "[$I/$TOTAL] Downloading $COUNTRY..."
        if curl -L -o "$OUTPUT_FILE" "$URL"; then
            SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
            log_success "$COUNTRY downloaded (${SIZE} MB)"
        else
            log_error "Failed to download $COUNTRY"
        fi
    fi
done

# -- Summary -----------------------------------------------------------
echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m                    Setup Complete!\033[0m"
echo -e "\033[32m================================================================\033[0m"
echo ""

log_info "Downloaded OSM files:"
for f in "$OSM_DATA_DIR"/*.osm.pbf; do
    if [ -f "$f" ]; then
        SIZE=$(du -m "$f" | cut -f1)
        echo -e "  \033[32m+ $(basename "$f") (${SIZE} MB)\033[0m"
    fi
done

echo ""
log_info "Existing boundary tiles:"
for f in "$BOUNDARIES_DIR"/*.pmtiles; do
    if [ -f "$f" ]; then
        SIZE=$(du -m "$f" | cut -f1)
        echo -e "  \033[32m+ $(basename "$f") (${SIZE} MB)\033[0m"
    fi
done

echo ""
log_info "Next steps:"
log_info "  1. Generate tiles:  ./scripts/generate-all.sh"
log_info "  2. Or single:       ./scripts/generate-single.sh nigeria"
log_info "  3. Run Martin:      ./scripts/run-martin.sh"
