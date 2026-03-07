#!/usr/bin/env bash
#
# generate-tenants.sh - Generate tiles for all configured tenants on macOS/Linux
#
# Usage: ./scripts/sh/generate-tenants.sh                    # All tenants
#        ./scripts/sh/generate-tenants.sh --tenant 11        # Single tenant
#        ./scripts/sh/generate-tenants.sh --profile terrain   # Override profile (default: full)
#
set -euo pipefail

TENANT_FILTER=0
PROFILE="full"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant|-t) TENANT_FILTER="$2"; shift 2 ;;
        --profile|-p) PROFILE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANETILER_JAR="$BASE_DIR/planetiler.jar"
OSM_DATA_DIR="$BASE_DIR/data/osm"
DATA_SOURCES_DIR="$BASE_DIR/data/sources"
TEMP_DIR="$BASE_DIR/temp"
STATES_BASE="$BASE_DIR/data/sources"

# Profile layers
declare -A PROFILE_LAYERS
PROFILE_LAYERS=(
    ["full"]="water,landuse,landcover,building,transportation,place"
    ["terrain-roads"]="water,landuse,landcover,transportation,place"
    ["terrain"]="water,landuse,landcover,place"
    ["minimal"]="water,place"
)

# Memory per country
declare -A MEMORY_MAP
MEMORY_MAP=(
    ["liberia"]=2 ["rwanda"]=2 ["central-african-republic"]=2
    ["uganda"]=4 ["kenya"]=4 ["nigeria"]=6 ["india"]=8
)

# Colors
log_info()    { echo -e "\033[34m[INFO] $(date +%H:%M:%S)\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS] $(date +%H:%M:%S)\033[0m $1"; }
log_error()   { echo -e "\033[31m[ERROR] $(date +%H:%M:%S)\033[0m $1"; }
log_warn()    { echo -e "\033[33m[WARN] $(date +%H:%M:%S)\033[0m $1"; }
log_step()    { echo -e "\033[36m[STEP] $(date +%H:%M:%S)\033[0m $1"; }

# ================================================================
# TENANT CONFIGURATION
# Format: ID|Name|Country|States(comma-sep)|Combined(true/false)
# States=""        -> full country tile
# States="Lagos"   -> single state tile
# States="Lagos,Osun" + Combined=true -> combined multi-state tile
# ================================================================
TENANT_DEFS=(
    "1|Bridge Kenya|kenya||false"
    "2|Bridge Uganda|uganda||false"
    "3|Bridge Nigeria|nigeria|Lagos,Osun|true"
    "4|Bridge Liberia|liberia||false"
    "5|Bridge India|india|AndhraPradesh|false"
    "9|EdoBEST|nigeria|Edo|false"
    "11|EKOEXCEL|nigeria|Lagos|false"
    "12|Rwanda EQUIP|rwanda||false"
    "14|Kwara Learn|nigeria|Kwara|false"
    "15|Manipur Education|india|Manipur|false"
    "16|Bayelsa Prime|nigeria|Bayelsa|false"
    "17|Espoir CAR|central-african-republic||false"
    "18|Jigawa Unite|nigeria|Jigawa|false"
)

# Validate profile
if [ -z "${PROFILE_LAYERS[$PROFILE]+x}" ]; then
    log_error "Unknown profile: $PROFILE. Available: ${!PROFILE_LAYERS[*]}"
    exit 1
fi

LAYERS=${PROFILE_LAYERS[$PROFILE]}

# Safety checks
if [ ! -f "$PLANETILER_JAR" ]; then
    log_error "Planetiler not found: $PLANETILER_JAR"
    exit 1
fi

echo ""
echo -e "\033[36m================================================================\033[0m"
echo -e "\033[36m  Tenant Tile Generator\033[0m"
echo -e "\033[36m  Profile: $PROFILE\033[0m"
echo -e "\033[36m================================================================\033[0m"
echo ""

# Show what will be generated
FILTERED_DEFS=()
for DEF in "${TENANT_DEFS[@]}"; do
    IFS='|' read -r T_ID T_NAME T_COUNTRY T_STATES T_COMBINED <<< "$DEF"
    if [ "$TENANT_FILTER" -gt 0 ] && [ "$T_ID" != "$TENANT_FILTER" ]; then
        continue
    fi
    FILTERED_DEFS+=("$DEF")

    if [ -z "$T_STATES" ]; then
        echo "  Tenant $T_ID ($T_NAME): $T_COUNTRY full country"
    elif [ "$T_COMBINED" = "true" ]; then
        echo "  Tenant $T_ID ($T_NAME): $T_COUNTRY [$(echo "$T_STATES" | tr ',' ' + ')] combined"
    else
        echo "  Tenant $T_ID ($T_NAME): $T_COUNTRY [$T_STATES]"
    fi
done
echo ""

if [ ${#FILTERED_DEFS[@]} -eq 0 ]; then
    log_error "Tenant $TENANT_FILTER not found"
    exit 1
fi

TOTAL_START=$(date +%s)
SUCCEEDED=()
FAILED=()
SKIPPED=()

# Track generated to avoid duplicates
declare -A GENERATED_COUNTRIES
declare -A GENERATED_STATES

TENANT_INDEX=0
for DEF in "${FILTERED_DEFS[@]}"; do
    IFS='|' read -r T_ID T_NAME T_COUNTRY T_STATES T_COMBINED <<< "$DEF"
    TENANT_INDEX=$((TENANT_INDEX + 1))
    MEMORY=${MEMORY_MAP[$T_COUNTRY]}
    OSM_FILE="$OSM_DATA_DIR/${T_COUNTRY}-latest.osm.pbf"

    echo ""
    echo -e "\033[90m────────────────────────────────────────────────────────\033[0m"
    log_step "[$TENANT_INDEX/${#FILTERED_DEFS[@]}] Tenant $T_ID: $T_NAME"
    echo -e "\033[90m────────────────────────────────────────────────────────\033[0m"

    # Check OSM file exists
    if [ ! -f "$OSM_FILE" ]; then
        log_error "OSM file missing: $OSM_FILE - skipping tenant $T_ID"
        FAILED+=("Tenant $T_ID ($T_NAME): missing $OSM_FILE")
        continue
    fi

    # -- FULL COUNTRY --
    if [ -z "$T_STATES" ]; then
        OUTPUT_FILE="$BASE_DIR/pmtiles/${T_COUNTRY}-detailed.pmtiles"
        mkdir -p "$BASE_DIR/pmtiles" "$DATA_SOURCES_DIR" "$TEMP_DIR"

        if [ "${GENERATED_COUNTRIES[$T_COUNTRY]+x}" ]; then
            log_info "$T_COUNTRY already generated this run - skipping"
            SKIPPED+=("Tenant $T_ID ($T_NAME): $T_COUNTRY (already done)")
            continue
        fi

        if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
            SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
            log_info "$T_COUNTRY already exists (${SIZE} MB) - skipping"
            SKIPPED+=("Tenant $T_ID ($T_NAME): $T_COUNTRY (exists)")
            GENERATED_COUNTRIES[$T_COUNTRY]=1
            continue
        fi

        log_info "Generating full country: $T_COUNTRY (${MEMORY}GB RAM)"

        if java "-Xmx${MEMORY}g" -jar "$PLANETILER_JAR" \
            --osm-path="$OSM_FILE" \
            --output="$OUTPUT_FILE" \
            --download \
            --download_dir="$DATA_SOURCES_DIR" \
            --force \
            --maxzoom=14 \
            --minzoom=0 \
            --simplify-tolerance-at-max-zoom=0 \
            --building_merge_z13=true \
            --exclude-layers=poi,housenumber \
            --nodemap-type=sparsearray \
            --storage=mmap \
            --nodemap-storage=mmap \
            --osm_lazy_reads=false \
            --tmpdir="$TEMP_DIR"; then

            if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
                SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
                log_success "$T_COUNTRY generated (${SIZE} MB)"
                SUCCEEDED+=("Tenant $T_ID ($T_NAME): $T_COUNTRY full")
                GENERATED_COUNTRIES[$T_COUNTRY]=1
            else
                log_error "No output for $T_COUNTRY"
                FAILED+=("Tenant $T_ID ($T_NAME): empty output")
            fi
        else
            log_error "Failed for tenant $T_ID ($T_COUNTRY)"
            FAILED+=("Tenant $T_ID ($T_NAME): Planetiler failed")
        fi

    # -- COMBINED MULTI-STATE --
    elif [ "$T_COMBINED" = "true" ]; then
        SLUGS=$(echo "$T_STATES" | tr '[:upper:]' '[:lower:]' | tr ',' '-')
        OUTPUT_FILE="$BASE_DIR/pmtiles/${T_COUNTRY}-${SLUGS}.pmtiles"
        mkdir -p "$(dirname "$OUTPUT_FILE")" "$DATA_SOURCES_DIR" "$TEMP_DIR"

        STATE_KEY="${T_COUNTRY}-${SLUGS}"
        if [ "${GENERATED_STATES[$STATE_KEY]+x}" ]; then
            log_info "$STATE_KEY already generated this run - skipping"
            SKIPPED+=("Tenant $T_ID ($T_NAME): $STATE_KEY (already done)")
            continue
        fi

        if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
            SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
            log_info "$STATE_KEY already exists (${SIZE} MB) - skipping"
            SKIPPED+=("Tenant $T_ID ($T_NAME): $STATE_KEY (exists)")
            GENERATED_STATES[$STATE_KEY]=1
            continue
        fi

        GEOJSON_FILE="$STATES_BASE/${T_COUNTRY}-states/${SLUGS}.json"
        if [ ! -f "$GEOJSON_FILE" ]; then
            log_error "GeoJSON file missing: $GEOJSON_FILE - run bounds-from-hdx.py or generate-nigeria-tenants.sh first"
            FAILED+=("Tenant $T_ID ($T_NAME): missing GeoJSON file")
            continue
        fi

        # Convert GeoJSON to .poly format
        POLY_FILE="$TEMP_DIR/${SLUGS}.poly"
        mkdir -p "$TEMP_DIR"
        python3 -c "
import json
with open('$GEOJSON_FILE') as f:
    data = json.load(f)
with open('$POLY_FILE', 'w') as out:
    out.write('polygon\n')
    idx = 1
    for feat in data['features']:
        geom = feat['geometry']
        polys = geom['coordinates'] if geom['type'] == 'MultiPolygon' else [geom['coordinates']]
        for poly in polys:
            for i, ring in enumerate(poly):
                prefix = '!' if i > 0 else ''
                out.write(f'{prefix}{idx}\n')
                for lon, lat in ring:
                    out.write(f'   {lon:.6E}   {lat:.6E}\n')
                out.write('END\n')
                idx += 1
    out.write('END\n')
"

        log_info "Generating combined [$(echo "$T_STATES" | tr ',' ' + ')] polygon: $POLY_FILE"

        if java "-Xmx${MEMORY}g" -jar "$PLANETILER_JAR" \
            --osm-path="$OSM_FILE" \
            --output="$OUTPUT_FILE" \
            --download \
            --download_dir="$DATA_SOURCES_DIR" \
            --force \
            --polygon="$POLY_FILE" \
            --maxzoom=14 \
            --minzoom=0 \
            --simplify-tolerance-at-max-zoom=0 \
            --building_merge_z13=true \
            --exclude-layers=poi,housenumber \
            --nodemap-type=sparsearray \
            --storage=mmap \
            --nodemap-storage=mmap \
            --osm_lazy_reads=false \
            --tmpdir="$TEMP_DIR"; then

            if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
                SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
                log_success "$STATE_KEY generated (${SIZE} MB)"
                SUCCEEDED+=("Tenant $T_ID ($T_NAME): $STATE_KEY combined")
                GENERATED_STATES[$STATE_KEY]=1
            else
                log_error "No output for $STATE_KEY"
                FAILED+=("Tenant $T_ID ($T_NAME): empty output")
            fi
        else
            log_error "Failed for tenant $T_ID"
            FAILED+=("Tenant $T_ID ($T_NAME): Planetiler failed")
        fi

    # -- SINGLE STATE --
    else
        IFS=',' read -ra STATE_ARRAY <<< "$T_STATES"
        for STATE in "${STATE_ARRAY[@]}"; do
            SLUG=$(echo "$STATE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
            OUTPUT_FILE="$BASE_DIR/pmtiles/${T_COUNTRY}-${SLUG}.pmtiles"
            mkdir -p "$(dirname "$OUTPUT_FILE")" "$DATA_SOURCES_DIR" "$TEMP_DIR"

            STATE_KEY="${T_COUNTRY}-${SLUG}"
            if [ "${GENERATED_STATES[$STATE_KEY]+x}" ]; then
                log_info "$STATE_KEY already generated this run - skipping"
                SKIPPED+=("Tenant $T_ID ($T_NAME): $STATE_KEY (already done)")
                continue
            fi

            if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
                SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
                log_info "$STATE_KEY already exists (${SIZE} MB) - skipping"
                SKIPPED+=("Tenant $T_ID ($T_NAME): $STATE_KEY (exists)")
                GENERATED_STATES[$STATE_KEY]=1
                continue
            fi

            GEOJSON_FILE="$STATES_BASE/${T_COUNTRY}-states/${SLUG}.json"
            if [ ! -f "$GEOJSON_FILE" ]; then
                log_error "GeoJSON file missing: $GEOJSON_FILE - run bounds-from-hdx.py or generate-nigeria-tenants.sh first"
                FAILED+=("Tenant $T_ID ($T_NAME): missing GeoJSON file")
                continue
            fi

            # Convert GeoJSON to .poly format
            POLY_FILE="$TEMP_DIR/${SLUG}.poly"
            mkdir -p "$TEMP_DIR"
            python3 -c "
import json
with open('$GEOJSON_FILE') as f:
    data = json.load(f)
with open('$POLY_FILE', 'w') as out:
    out.write('polygon\n')
    idx = 1
    for feat in data['features']:
        geom = feat['geometry']
        polys = geom['coordinates'] if geom['type'] == 'MultiPolygon' else [geom['coordinates']]
        for poly in polys:
            for i, ring in enumerate(poly):
                prefix = '!' if i > 0 else ''
                out.write(f'{prefix}{idx}\n')
                for lon, lat in ring:
                    out.write(f'   {lon:.6E}   {lat:.6E}\n')
                out.write('END\n')
                idx += 1
    out.write('END\n')
"

            log_info "Generating $STATE polygon: $POLY_FILE"

            if java "-Xmx${MEMORY}g" -jar "$PLANETILER_JAR" \
                --osm-path="$OSM_FILE" \
                --output="$OUTPUT_FILE" \
                --download \
                --download_dir="$DATA_SOURCES_DIR" \
                --force \
                --polygon="$POLY_FILE" \
                --maxzoom=14 \
                --minzoom=0 \
                --simplify-tolerance-at-max-zoom=0 \
                --building_merge_z13=true \
                --exclude-layers=poi,housenumber \
                --nodemap-type=sparsearray \
                --storage=mmap \
                --nodemap-storage=mmap \
                --osm_lazy_reads=false \
                --tmpdir="$TEMP_DIR"; then

                if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
                    SIZE=$(du -m "$OUTPUT_FILE" | cut -f1)
                    log_success "$STATE_KEY generated (${SIZE} MB)"
                    SUCCEEDED+=("Tenant $T_ID ($T_NAME): $STATE_KEY")
                    GENERATED_STATES[$STATE_KEY]=1
                else
                    log_error "No output for $STATE_KEY"
                    FAILED+=("Tenant $T_ID ($T_NAME): empty output")
                fi
            else
                log_error "Failed for $STATE"
                FAILED+=("Tenant $T_ID ($T_NAME): Planetiler failed")
            fi
        done
    fi
done

# Summary
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))
HOURS=$((TOTAL_ELAPSED / 3600))
MINUTES=$(( (TOTAL_ELAPSED % 3600) / 60 ))
SECS=$((TOTAL_ELAPSED % 60))

echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m  Tenant Tile Generation Complete!\033[0m"
echo -e "\033[32m================================================================\033[0m"
echo ""
echo "  Total time: ${HOURS}h ${MINUTES}m ${SECS}s"

if [ ${#SUCCEEDED[@]} -gt 0 ]; then
    echo ""
    echo -e "  \033[32mGenerated (${#SUCCEEDED[@]}):\033[0m"
    for s in "${SUCCEEDED[@]}"; do
        echo -e "    \033[32m+ $s\033[0m"
    done
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo ""
    echo -e "  \033[33mSkipped (${#SKIPPED[@]}):\033[0m"
    for s in "${SKIPPED[@]}"; do
        echo -e "    \033[33m~ $s\033[0m"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo -e "  \033[31mFailed (${#FAILED[@]}):\033[0m"
    for f in "${FAILED[@]}"; do
        echo -e "    \033[31m- $f\033[0m"
    done
fi

# Cleanup temp
rm -rf "$TEMP_DIR" 2>/dev/null || true
