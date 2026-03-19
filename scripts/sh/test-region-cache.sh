#!/usr/bin/env bash
# test-region-cache.sh — Tests worker-level GeoJSON cache (cold vs warm) and shared result cache for GET /region.
#
# Prereqs: docker compose -f tileserver/docker-compose.tenant.yml up; HDX data imported.
# Always uses Nigeria (heavy GeoJSON). Default tenant 3 (nigeria-lagos-osun); or use 9, 14, 16, 18.
#
# Dependencies: curl
#
# Usage:
#   ./scripts/sh/test-region-cache.sh
#   ./scripts/sh/test-region-cache.sh --base-url http://localhost:8080 --tenant 9

set -euo pipefail

BASE_URL="http://localhost:8080"
TENANT_ID="3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url) BASE_URL="$2"; shift 2 ;;
        --tenant)   TENANT_ID="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
    esac
done

REGION_URL="${BASE_URL}/region"
LAT1="6.4541"; LON1="3.3947"
LAT2="6.5244"; LON2="3.3792"

get_region_timed() {
    local lat="$1" lon="$2"
    local url="${REGION_URL}?lat=${lat}&lon=${lon}"
    # Output: body on first line(s), time_total on last line
    raw=$(curl -s -w $'\n%{time_total}' -H "X-Tenant-ID: ${TENANT_ID}" "${url}" 2>&1)
    time_val=$(echo "${raw}" | tail -1)
    body=$(echo "${raw}" | head -n -1)
    echo "${time_val}|${body}"
}

echo "=== Region cache test (BaseUrl=${BASE_URL}, X-Tenant-ID=${TENANT_ID}) ==="
echo ""

# 1) Cold worker + cold result cache
echo "1. First request (cold worker + cold result cache) lat=${LAT1} lon=${LON1}"
result=$(get_region_timed "${LAT1}" "${LON1}")
t1="${result%%|*}"; b1="${result#*|}"
echo "   time_total=${t1}s"
echo "   body: ${b1}"
if echo "${b1}" | grep -q '"found"'; then echo "   OK (JSON with found)"; else echo "   WARN: unexpected body"; fi

# 2) Same coords — result cache hit
echo "2. Second request same coords (result cache hit)"
result=$(get_region_timed "${LAT1}" "${LON1}")
t2="${result%%|*}"; b2="${result#*|}"
echo "   time_total=${t2}s"
if (( $(echo "${t2} < 0.05" | bc -l) )); then
    echo "   OK (fast, result cache)"
else
    echo "   (may still be fast; result cache shared)"
fi

# 3) Different coords — warm worker, result cache miss
echo "3. Different coords (warm worker, result cache miss) lat=${LAT2} lon=${LON2}"
result=$(get_region_timed "${LAT2}" "${LON2}")
t3="${result%%|*}"; b3="${result#*|}"
echo "   time_total=${t3}s"

# 4) Same coords again — result cache hit
echo "4. Same coords again (result cache hit)"
result=$(get_region_timed "${LAT2}" "${LON2}")
t4="${result%%|*}"; b4="${result#*|}"
echo "   time_total=${t4}s"
if (( $(echo "${t4} < 0.05" | bc -l) )); then echo "   OK (sub-50ms, result cache)"; fi

# 5) Result cache identity check
echo ""
echo "5. Result cache identity: two requests same coords -> same JSON"
result5=$(get_region_timed "${LAT1}" "${LON1}"); b5="${result5#*|}"
result6=$(get_region_timed "${LAT1}" "${LON1}"); b6="${result6#*|}"
if [[ "${b5}" == "${b6}" ]]; then
    echo "   OK (bodies identical)"
else
    echo "   FAIL (bodies differ)"
fi

echo ""
echo "Done. See tileserver/docs/testing-region-cache.md for full steps."
