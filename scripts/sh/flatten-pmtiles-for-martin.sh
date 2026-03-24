#!/usr/bin/env bash
#
# Copy *.pmtiles from profile subdirs into data/pmtiles/ (and boundaries) top level
# so Martin discovers them without listing every subdir in martin-config.yaml.
# Skips if the same basename already exists at top (top-level wins).
#
# Usage (repo root):
#   ./scripts/sh/flatten-pmtiles-for-martin.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

flatten_dir() {
  local subdir="$1"
  local ext="$2"
  local top="$3"
  [ -d "$subdir" ] || return 0
  shopt -s nullglob
  local f
  for f in "$subdir"/*."$ext"; do
    [ -f "$f" ] || continue
    local base dest
    base=$(basename "$f")
    dest="$top/$base"
    if [ -f "$dest" ]; then
      echo "[skip] $base already in $(basename "$top")"
    else
      cp -n "$f" "$dest"
      echo "[ok]   $base -> $(basename "$top")/"
    fi
  done
  shopt -u nullglob
}

flatten_dir "$ROOT/data/pmtiles/full" pmtiles "$ROOT/data/pmtiles"
flatten_dir "$ROOT/data/pmtiles/z6" pmtiles "$ROOT/data/pmtiles"
flatten_dir "$ROOT/data/pmtiles/terrain" pmtiles "$ROOT/data/pmtiles"
flatten_dir "$ROOT/data/boundaries/full" pmtiles "$ROOT/data/boundaries"
flatten_dir "$ROOT/data/boundaries/z6" pmtiles "$ROOT/data/boundaries"

echo "Done. Restart Martin: docker compose -f tileserver/docker-compose.tenant.yml restart martin"
