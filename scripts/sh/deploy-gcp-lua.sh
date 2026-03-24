#!/usr/bin/env bash
#
# deploy-gcp-lua.sh - Upload OpenResty Lua modules to GCE (same set as CLAUDE.md manual deploy).
# After upload: sudo docker restart tileserver_nginx_1  (on the VM) to load Lua + clear ngx.shared caches.
#
# Usage (from repo root):
#   ./scripts/sh/deploy-gcp-lua.sh
#
# Environment (optional):
#   GCP_VM           Instance name (default: martin-tileserver)
#   GCP_ZONE         Zone (default: us-central1-a)
#   GCP_REMOTE_BASE  Path to rust-map-server on the VM (default: /home/$USER/rust-map-server)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LUA_DIR="$REPO_ROOT/tileserver/lua"

GCP_VM="${GCP_VM:-martin-tileserver}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
GCP_REMOTE_BASE="${GCP_REMOTE_BASE:-/home/omarlakhdhar_gmail_com/rust-map-server}"

log() { echo "[deploy-gcp-lua] $*"; }

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI not found." >&2
  exit 1
fi

FILES=(
  boundary-db.lua
  serve-hierarchy.lua
  region-lookup.lua
  admin-zones.lua
  admin-tenants.lua
  tenant-router.lua
  tile-source-normalize.lua
  resolve-tenant.lua
  validate-tenant.lua
  access-validate-and-origin.lua
  serve-geojson.lua
  search-boundaries.lua
)

REMOTE_LUA="${GCP_VM}:${GCP_REMOTE_BASE}/tileserver/lua/"

log "Uploading Lua files to ${REMOTE_LUA}"
for f in "${FILES[@]}"; do
  if [ ! -f "$LUA_DIR/$f" ]; then
    echo "Missing $LUA_DIR/$f" >&2
    exit 1
  fi
  gcloud compute scp --zone="$GCP_ZONE" "$LUA_DIR/$f" "$REMOTE_LUA"
done

log "Done. On the VM run: sudo docker restart tileserver_nginx_1"
