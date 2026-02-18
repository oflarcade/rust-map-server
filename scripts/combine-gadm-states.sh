#!/usr/bin/env bash
#
# combine-gadm-states.sh - Combine multiple GADM state polygons into one GeoJSON FeatureCollection
#
# Usage: ./scripts/combine-gadm-states.sh --gadm-file gadm/nigeria_2.json --output gadm/states/lagos-osun.json --states Lagos,Osun
#
set -euo pipefail

GADM_FILE=""
OUTPUT_FILE=""
STATES=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gadm-file) GADM_FILE="$2"; shift 2 ;;
        --output)    OUTPUT_FILE="$2"; shift 2 ;;
        --states)    STATES="$2"; shift 2 ;;
        *)           echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [ -z "$GADM_FILE" ] || [ -z "$OUTPUT_FILE" ] || [ -z "$STATES" ]; then
    echo -e "\033[31m[ERROR]\033[0m Usage: $0 --gadm-file <file> --output <file> --states State1,State2,..."
    exit 1
fi

if [ ! -f "$GADM_FILE" ]; then
    echo -e "\033[31m[ERROR]\033[0m GADM file not found: $GADM_FILE"
    exit 1
fi

echo -e "\033[34m[INFO]\033[0m Reading $GADM_FILE ..."

# Convert comma-separated states to Python list
STATES_PYTHON=$(echo "$STATES" | sed "s/,/','/g")

RESULT=$(python3 -c "
import json, sys
with open('$GADM_FILE') as f:
    data = json.load(f)
targets = ['$STATES_PYTHON']
features = [f for f in data['features'] if f['properties']['NAME_1'] in targets]
found = set(f['properties']['NAME_1'] for f in features)
missing = [t for t in targets if t not in found]
if missing:
    print('ERROR:States not found: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(1)
out = {'type': 'FeatureCollection', 'features': features}
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(out, f)
print(f'OK:{len(features)} features from {len(found)} states')
")

echo -e "\033[32m[SUCCESS]\033[0m $RESULT -> $OUTPUT_FILE"
