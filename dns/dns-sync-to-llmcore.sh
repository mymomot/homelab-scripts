#!/bin/bash
# dns-sync-to-llmcore.sh
# Synchronise la config DNS (sections upstream/fallback/cache + Unbound adguard.conf)
# depuis LXC 411 (primary) vers llmcore (secondary).
# NE COPIE PAS le YAML entier : applique uniquement les sections DNS via script Python.
# Exclut local-*.conf pour permettre des overrides machine-specifiques.
#
# Déployer sur : LXC 411 (primary AdGuard)
# Chemin cible : /usr/local/bin/dns-sync-to-llmcore.sh (chmod 700, owned root)
# Déclenché par : dns-sync-to-llmcore.timer (toutes les 5 min)
#
# Prérequis :
#   - Clé SSH /root/.ssh/id_ed25519_rsync_dns autorisée sur llmcore
#     (avec restriction command= — voir hardening Phase C)
#   - Script dns-apply-upstream-sync.py présent sur llmcore
#     dans /usr/local/bin/

set -euo pipefail

LLMCORE_HOST="llmuser@192.168.10.118"
SSH_KEY="/root/.ssh/id_ed25519_rsync_dns"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10"
LOG_TAG="dns-sync"

log() { logger -t "${LOG_TAG}" "${1}"; }

log "Debut synchronisation DNS LXC411 -> llmcore"

# --- Unbound adguard.conf ---
rsync -az --checksum \
    -e "ssh ${SSH_OPTS}" \
    /etc/unbound/unbound.conf.d/adguard.conf \
    "${LLMCORE_HOST}:/tmp/dns-sync-unbound.conf"

ssh ${SSH_OPTS} "${LLMCORE_HOST}" \
    'sudo install -m 644 -o root -g root /tmp/dns-sync-unbound.conf /etc/unbound/unbound.conf.d/adguard.conf && sudo /usr/sbin/unbound-checkconf /etc/unbound/unbound.conf && sudo systemctl reload unbound && rm -f /tmp/dns-sync-unbound.conf'

log "Unbound adguard.conf synchronise"

# --- AdGuardHome.yaml (sections DNS uniquement) ---
# Copier le YAML source vers llmcore pour diff partiel
rsync -az --checksum \
    -e "ssh ${SSH_OPTS}" \
    /root/AdGuardHome/AdGuardHome.yaml \
    "${LLMCORE_HOST}:/tmp/dns-sync-agh-source.yaml"

# Appliquer uniquement les sections DNS (pas reseau, pas TLS, pas users)
ssh ${SSH_OPTS} "${LLMCORE_HOST}" \
    'sudo python3 /usr/local/bin/dns-apply-upstream-sync.py /tmp/dns-sync-agh-source.yaml /opt/AdGuardHome/AdGuardHome.yaml && rm -f /tmp/dns-sync-agh-source.yaml && sudo systemctl reload-or-restart AdGuardHome'

log "AdGuardHome.yaml sections DNS synchronisees"
log "Synchronisation DNS terminee avec succes"
