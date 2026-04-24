#!/usr/bin/env bash
# check-dns-failover-maps.sh — BigBrother health check #3
# Council Art.15 bis C8+C10
# Vérifie que les 2 résolveurs (primary 192.168.10.11 + secondary llmcore) résolvent maps.lab.mymomot.ovh

set -euo pipefail

EXPECTED="192.168.10.10"
NAME="dns-failover-maps"
PRIMARY="192.168.10.11"
SECONDARY="192.168.10.118"

primary_result=$(dig @"${PRIMARY}" maps.lab.mymomot.ovh +short +timeout=3 +tries=1 2>/dev/null | head -1 || echo "")
secondary_result=$(dig @"${SECONDARY}" maps.lab.mymomot.ovh +short +timeout=3 +tries=1 2>/dev/null | head -1 || echo "")

primary_ok="NO"
secondary_ok="NO"
[ "${primary_result}" = "${EXPECTED}" ] && primary_ok="YES"
[ "${secondary_result}" = "${EXPECTED}" ] && secondary_ok="YES"

if [ "${primary_ok}" = "NO" ] && [ "${secondary_ok}" = "NO" ]; then
    echo "CRIT ${NAME}: primary=${primary_result} secondary=${secondary_result} (both KO)"
    exit 2
fi

if [ "${primary_ok}" = "NO" ] || [ "${secondary_ok}" = "NO" ]; then
    echo "WARN ${NAME}: primary=${primary_ok}(${primary_result}) secondary=${secondary_ok}(${secondary_result})"
    exit 1
fi

echo "OK ${NAME}: primary=${primary_result} secondary=${secondary_result}"
