#!/usr/bin/env bash
#
# deploy-gcp-view.sh - Production build + upload View/dist to GCE (vue-app static files).
#
# Prerequisites: gcloud auth, SSH to VM, repo path on VM already exists.
#
# Usage (from repo root):
#   ./scripts/sh/deploy-gcp-view.sh
#
# Environment (optional):
#   GCP_VM           Instance name (default: martin-tileserver)
#   GCP_ZONE         Zone (default: us-central1-a)
#   GCP_REMOTE_BASE  Absolute path to rust-map-server on the VM (default: /home/$USER/rust-map-server).
#                    GCE often uses a sanitized account dir, e.g. /home/omarlakhdhar_gmail_com/rust-map-server
#   PROD_IP          Baked into VITE_* — MUST match VM external IP (gcloud compute instances describe ... natIP).
#                    Default below tracks current martin-tileserver; change if IP changes.
#   SKIP_BUILD       If set to 1, skip npm run build (upload existing dist only)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VIEW_DIR="$REPO_ROOT/View"

GCP_VM="${GCP_VM:-martin-tileserver}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
PROD_IP="${PROD_IP:-35.224.96.155}"
GCP_REMOTE_BASE="${GCP_REMOTE_BASE:-/home/omarlakhdhar_gmail_com/rust-map-server}"

log() { echo "[deploy-gcp-view] $*"; }

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI not found. Install Google Cloud SDK." >&2
  exit 1
fi

if [ ! -d "$VIEW_DIR" ]; then
  echo "View directory not found: $VIEW_DIR" >&2
  exit 1
fi

cd "$VIEW_DIR"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "Installing dependencies (if needed)..."
  if [ ! -d node_modules ]; then
    npm install
  fi
  export VITE_PROXY_URL="http://${PROD_IP}:8080"
  export VITE_MARTIN_URL="http://${PROD_IP}:3000"
  log "Building with VITE_PROXY_URL=$VITE_PROXY_URL VITE_MARTIN_URL=$VITE_MARTIN_URL"
  npm run build
else
  log "SKIP_BUILD=1 — using existing View/dist"
fi

if [ ! -f dist/index.html ]; then
  echo "Missing View/dist/index.html — build failed or dist not present." >&2
  exit 1
fi

log "Verifying built bundle does not reference localhost:8080 / localhost:3000 (grep)"
if [ -d dist/assets ] && grep -rE "localhost:8080|localhost:3000" dist/assets --include='*.js' >/dev/null 2>&1; then
  log "WARNING: localhost still present in dist/assets — check env and rebuild."
else
  log "OK: no localhost:8080/3000 in main JS assets (or no JS to scan)."
fi

REMOTE_DEST="${GCP_VM}:${GCP_REMOTE_BASE}/View/dist/"
log "Uploading dist to ${REMOTE_DEST}"
gcloud compute scp --zone="$GCP_ZONE" --recurse \
  dist/index.html \
  dist/assets \
  "$REMOTE_DEST"

log "Done. On the VM, vue-app mounts this path; if containers were already running, refresh browser (hard reload)."
log "If this was a first-time deploy of dist, ensure docker compose maps ../View/dist (see tileserver/docker-compose.tenant.yml)."
