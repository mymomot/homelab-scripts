#!/usr/bin/env bash
# check-pmtiles-metadata.sh — BigBrother health check #1
# Council Art.15 bis C8+C10 — intégré dès deploy phase
# Vérifie que go-pmtiles serve répond et /planet.json (TileJSON) est valide
# Note v1.30.2 : pattern URL réel = /<name>.json (pas /<name>/metadata.json)

set -euo pipefail

URL="https://maps.lab.mymomot.ovh/tiles/planet.json"
TIMEOUT=5
NAME="pmtiles-metadata"

response=$(curl -sf --max-time "${TIMEOUT}" "${URL}" 2>&1) || {
    echo "CRIT ${NAME}: HTTP failure - ${response}"
    exit 2
}

# Valider JSON + champs minimaux
minzoom=$(echo "${response}" | jq -r '.minzoom // empty' 2>/dev/null)
maxzoom=$(echo "${response}" | jq -r '.maxzoom // empty' 2>/dev/null)

if [ -z "${minzoom}" ] || [ -z "${maxzoom}" ]; then
    echo "CRIT ${NAME}: invalid metadata (minzoom=${minzoom} maxzoom=${maxzoom})"
    exit 2
fi

echo "OK ${NAME}: minzoom=${minzoom} maxzoom=${maxzoom}"
