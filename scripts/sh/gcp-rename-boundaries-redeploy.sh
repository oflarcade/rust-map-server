#!/usr/bin/env bash
#
# On GCE: rename legacy *-admin.pmtiles -> *-boundaries.pmtiles in data/boundaries,
# upload tileserver Lua + nginx config, restart martin + nginx.
#
# Usage (from repo root, gcloud auth):
#   ./scripts/sh/gcp-rename-boundaries-redeploy.sh
#
# Environment:
#   GCP_VM           (default: martin-tileserver)
#   GCP_ZONE         (default: us-central1-a)
#   GCP_REMOTE_BASE  (default: /home/$USER/rust-map-server) — set to your VM home, e.g.
#                    /home/omarlakhdhar_gmail_com/rust-map-server
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LUA_DIR="$REPO_ROOT/tileserver/lua"
NGINX_CONF="$REPO_ROOT/tileserver/nginx-tenant-proxy.conf"

GCP_VM="${GCP_VM:-martin-tileserver}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
# GCE home is usually not your laptop user — override if needed.
GCP_REMOTE_BASE="${GCP_REMOTE_BASE:-/home/omarlakhdhar_gmail_com/rust-map-server}"

log() { echo "[gcp-rename-redeploy] $*"; }

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI not found." >&2
  exit 1
fi

REMOTE_BASE="${GCP_REMOTE_BASE}"
BOUNDARIES_DIR="${REMOTE_BASE}/data/boundaries"
COMPOSE_DIR="${REMOTE_BASE}/tileserver"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.tenant.yml"

log "Remote: $GCP_VM ($GCP_ZONE) base=$REMOTE_BASE"

log "Renaming *-admin.pmtiles -> *-boundaries.pmtiles in data/boundaries (skip if target exists)"
gcloud compute ssh "$GCP_VM" --zone="$GCP_ZONE" --command="
set -e
DIR='${BOUNDARIES_DIR}'
if [ ! -d \"\$DIR\" ]; then
  echo \"ERROR: missing directory: \$DIR\" >&2
  exit 1
fi
cd \"\$DIR\"
for f in *-admin.pmtiles; do
  [ -f \"\$f\" ] || continue
  base=\"\${f%-admin.pmtiles}\"
  target=\"\${base}-boundaries.pmtiles\"
  if [ -f \"\$target\" ]; then
    echo \"skip (exists): \$target\"
    continue
  fi
  echo \"mv \$f -> \$target\"
  mv \"\$f\" \"\$target\"
done
echo \"Done. Listing nigeria-*.pmtiles (sample):\"
ls -la nigeria-*.pmtiles 2>/dev/null | head -20 || true
"

log "Uploading nginx-tenant-proxy.conf"
gcloud compute scp --zone="$GCP_ZONE" "$NGINX_CONF" "${GCP_VM}:${COMPOSE_DIR}/"

log "Uploading Lua modules (same set as deploy-gcp-lua.sh)"
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
  serve-geojson.lua
  search-boundaries.lua
)
for f in "${FILES[@]}"; do
  gcloud compute scp --zone="$GCP_ZONE" "$LUA_DIR/$f" "${GCP_VM}:${GCP_REMOTE_BASE}/tileserver/lua/"
done

log "Restarting martin + nginx (reloads PMTiles catalog + Lua + clears ngx.shared)"
gcloud compute ssh "$GCP_VM" --zone="$GCP_ZONE" --command="
set -e
cd '${COMPOSE_DIR}'
if [ ! -f docker-compose.tenant.yml ]; then
  echo \"ERROR: missing docker-compose.tenant.yml in ${COMPOSE_DIR}\" >&2
  exit 1
fi
if command -v docker-compose >/dev/null 2>&1; then
  sudo docker-compose -f docker-compose.tenant.yml restart martin nginx
elif sudo docker compose version >/dev/null 2>&1; then
  sudo docker compose -f docker-compose.tenant.yml restart martin nginx
else
  echo \"ERROR: neither docker-compose nor docker compose plugin found\" >&2
  exit 1
fi
"

log "Done. Verify: curl -s http://localhost:3000/catalog | grep -E 'nigeria-delta|boundaries' (on VM)"
log "If GCP_REMOTE_BASE was wrong, set it and re-run: export GCP_REMOTE_BASE=/home/YOUR_USER/rust-map-server"
