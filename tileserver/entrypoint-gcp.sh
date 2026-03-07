#!/bin/sh
set -e

# Single-container mode: Nginx proxies to Martin on localhost
# Replace "server martin:3000" with "server 127.0.0.1:3000" in the generated conf
sed -i 's/server martin:3000/server 127.0.0.1:3000/' /etc/nginx/conf.d/default.conf

# Start Martin in background (PMTiles from /data/pmtiles and /data/boundaries)
martin --config /config/martin-config.yaml &
MARTIN_PID=$!

# Trap so we kill Martin on exit
trap "kill $MARTIN_PID 2>/dev/null || true" EXIT

# Give Martin a moment to bind
sleep 2

# Nginx as PID 1 (foreground) so container stays up and receives signals
exec openresty -g "daemon off;"
