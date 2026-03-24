#!/usr/bin/env bash
#
# Upload one Nigerian state's PMTiles from local generate-states output to GCE.
#
# Local layout (generate-states.sh):
#   pmtiles/<profile>/nigeria-<slug>.pmtiles
#   boundaries/<profile>/nigeria-<slug>-boundaries.pmtiles   (current scripts)
#   boundaries/<profile>/nigeria-<slug>-admin.pmtiles       (legacy; uploaded as *-boundaries)
#
# Remote (Martin docker-compose): data/pmtiles/ and data/boundaries/ (flat, no profile subdir).
#
# Usage (from repo root):
#   ./scripts/sh/gcp-upload-nigeria-state-pmtiles.sh delta
#   ./scripts/sh/gcp-upload-nigeria-state-pmtiles.sh nigeria-delta
#   PROFILE=minimal ./scripts/sh/gcp-upload-nigeria-state-pmtiles.sh lagos
#
# Env:
#   GCP_VM, GCP_ZONE, GCP_REMOTE_BASE (same as other gcp-*.sh scripts)
#   PROFILE (default: full)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GCP_VM="${GCP_VM:-martin-tileserver}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
GCP_REMOTE_BASE="${GCP_REMOTE_BASE:-/home/omarlakhdhar_gmail_com/rust-map-server}"
PROFILE="${PROFILE:-full}"

log() { echo "[gcp-upload-state] $*"; }

if [ $# -lt 1 ]; then
  echo "Usage: $0 <state-slug|nigeria-state-slug>" >&2
  echo "Example: $0 delta" >&2
  exit 1
fi

RAW="$1"
SLUG="$RAW"
if [[ "$SLUG" == nigeria-* ]]; then
  SLUG="${SLUG#nigeria-}"
fi

BASE_LOCAL="$REPO_ROOT/pmtiles/${PROFILE}/nigeria-${SLUG}.pmtiles"
BOUND_DIR="$REPO_ROOT/boundaries/${PROFILE}"
BOUND_NEW="${BOUND_DIR}/nigeria-${SLUG}-boundaries.pmtiles"
BOUND_LEGACY="${BOUND_DIR}/nigeria-${SLUG}-admin.pmtiles"

REMOTE_PMTILES="${GCP_REMOTE_BASE}/data/pmtiles/nigeria-${SLUG}.pmtiles"
REMOTE_BOUNDS="${GCP_REMOTE_BASE}/data/boundaries/nigeria-${SLUG}-boundaries.pmtiles"

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI not found." >&2
  exit 1
fi

if [ ! -f "$BASE_LOCAL" ]; then
  log "ERROR: missing base map: $BASE_LOCAL"
  log "Hint: PROFILE=${PROFILE} — try PROFILE=full or generate with: ./scripts/sh/generate-states.sh ${PROFILE} nigeria <StateName>"
  exit 1
fi

if [ -f "$BOUND_NEW" ]; then
  BOUND_LOCAL="$BOUND_NEW"
elif [ -f "$BOUND_LEGACY" ]; then
  BOUND_LOCAL="$BOUND_LEGACY"
  log "Using legacy boundary file: nigeria-${SLUG}-admin.pmtiles → remote nigeria-${SLUG}-boundaries.pmtiles"
else
  log "ERROR: missing boundary file. Tried:"
  log "  $BOUND_NEW"
  log "  $BOUND_LEGACY"
  exit 1
fi

log "Uploading nigeria-${SLUG} (profile=${PROFILE}) → ${GCP_VM}"
gcloud compute scp --zone="$GCP_ZONE" "$BASE_LOCAL" "${GCP_VM}:${REMOTE_PMTILES}"
gcloud compute scp --zone="$GCP_ZONE" "$BOUND_LOCAL" "${GCP_VM}:${REMOTE_BOUNDS}"

log "Restarting Martin on VM (reload catalog)"
gcloud compute ssh "$GCP_VM" --zone="$GCP_ZONE" --command="
set -e
cd '${GCP_REMOTE_BASE}/tileserver'
sudo docker-compose -f docker-compose.tenant.yml restart martin
"

log "Done. On VM: curl -s http://127.0.0.1:3000/catalog | grep nigeria-${SLUG}"
log "Tenant DB should use tile_source=nigeria-${SLUG} boundary_source=nigeria-${SLUG}-boundaries"
