#!/usr/bin/env bash
# check-pmtiles-tile-zero.sh — BigBrother health check #2
# Council Art.15 bis C8+C10
# Récupère tile 0/0/0.mvt et vérifie taille + content-type
# Path confirmé empiriquement : /tiles/planet/0/0/0.mvt → application/x-protobuf (200)

set -euo pipefail

URL="https://maps.lab.mymomot.ovh/tiles/planet/0/0/0.mvt"
TIMEOUT=10
NAME="pmtiles-tile-zero"
MIN_SIZE_BYTES=100

# Requête HEAD pour content-type, GET pour taille
ct=$(curl -sfI --max-time "${TIMEOUT}" "${URL}" | grep -i "^content-type:" | tr -d '\r' || echo "")
size=$(curl -sf --max-time "${TIMEOUT}" "${URL}" | wc -c)

if ! echo "${ct}" | grep -qiE "(mapbox-vector-tile|x-protobuf|octet-stream)"; then
    echo "CRIT ${NAME}: bad content-type '${ct}'"
    exit 2
fi

if [ "${size}" -lt "${MIN_SIZE_BYTES}" ]; then
    echo "CRIT ${NAME}: tile too small (${size} bytes)"
    exit 2
fi

echo "OK ${NAME}: ${size} bytes content-type=${ct}"
