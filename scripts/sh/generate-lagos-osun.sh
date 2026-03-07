#!/usr/bin/env bash
#
# generate-lagos-osun.sh - Generate combined Lagos + Osun tiles for tenant 3
# Usage: ./scripts/generate-lagos-osun.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
PLANETILER_JAR="$BASE_DIR/planetiler.jar"
OSM_FILE="$BASE_DIR/data/osm/nigeria-latest.osm.pbf"
OUTPUT_FILE="$BASE_DIR/pmtiles/terrain/nigeria-lagos-osun.pmtiles"
DATA_SOURCES_DIR="$BASE_DIR/data/sources"
TEMP_DIR="$BASE_DIR/temp"

# Safety checks
if [ ! -f "$PLANETILER_JAR" ]; then
    echo -e "\033[31m[ERROR]\033[0m Planetiler not found: $PLANETILER_JAR"
    exit 1
fi

if [ ! -f "$OSM_FILE" ]; then
    echo -e "\033[31m[ERROR]\033[0m OSM file not found: $OSM_FILE"
    echo -e "\033[34m[INFO]\033[0m  Run: ./scripts/setup.sh (downloads to data/osm)"
    exit 1
fi

if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
    echo -e "\033[34m[INFO]\033[0m Already exists: $OUTPUT_FILE (${SIZE} MB) - skipping. Delete file to regenerate."
    exit 0
fi

# Create directories
mkdir -p "$(dirname "$OUTPUT_FILE")" "$DATA_SOURCES_DIR" "$TEMP_DIR"

# Verify tmpdir is not project root
if [ "$TEMP_DIR" = "$BASE_DIR" ]; then
    echo -e "\033[31m[ERROR]\033[0m tmpdir must not be the project root!"
    exit 1
fi

echo ""
echo -e "\033[36mGenerating combined Lagos + Osun tiles (tenant 3)...\033[0m"
echo "  OSM input:  $OSM_FILE"
echo "  Output:     $OUTPUT_FILE"
echo "  TempDir:    $TEMP_DIR"
echo "  SourcesDir: $DATA_SOURCES_DIR"
echo ""

java -Xmx6g -jar "$PLANETILER_JAR" \
    --osm-path="$OSM_FILE" \
    --output="$OUTPUT_FILE" \
    --download \
    --download_dir="$DATA_SOURCES_DIR" \
    --force \
    --bounds="2.696300,6.363200,5.074400,8.094700" \
    --maxzoom=14 \
    --minzoom=10 \
    --simplify-tolerance-at-max-zoom=0.1 \
    --only-layers=water,landuse,landcover,place \
    --nodemap-type=sparsearray \
    --storage=mmap \
    --nodemap-storage=mmap \
    --osm_lazy_reads=false \
    --tmpdir="$TEMP_DIR"

if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
    echo ""
    echo -e "\033[32m[SUCCESS] Lagos+Osun tiles generated (${SIZE} MB)\033[0m"
else
    echo -e "\033[31m[ERROR] No output file produced\033[0m"
    exit 1
fi

# Cleanup temp
rm -rf "$TEMP_DIR" 2>/dev/null || true
