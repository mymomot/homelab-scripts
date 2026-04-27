#!/bin/bash
# dns-sync-rewrites-to-llmcore.sh
# Synchronise filtering.rewrites depuis LXC 411 (primary) vers llmcore (secondary).
# Complément de dns-sync-to-llmcore.sh qui couvre upstream/fallback/cache mais
# pas les rewrites (section filtering: top-level, items multi-lignes).
#
# Déployer sur : LXC 411 (primary AdGuard)
# Chemin cible : /usr/local/bin/dns-sync-rewrites-to-llmcore.sh (chmod 700, owned root)
# Déclenché par : dns-sync-rewrites-to-llmcore.timer (toutes les 5 min)
#
# Prérequis :
#   - Même clé SSH que dns-sync-to-llmcore.sh : /root/.ssh/id_ed25519_rsync_dns
#   - Script dns-apply-rewrites-sync.py présent sur llmcore dans /usr/local/bin/
#     (déployer via : sudo install -m 755 dns-apply-rewrites-sync.py llmcore:/usr/local/bin/)

set -euo pipefail

LLMCORE_HOST="llmuser@192.168.10.118"
SSH_KEY="/root/.ssh/id_ed25519_rsync_dns"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10"
LOG_TAG="dns-rewrites-sync"

log() { logger -t "${LOG_TAG}" "${1}"; }

log "Debut synchronisation rewrites LXC411 -> llmcore"

# Copier le YAML source vers llmcore pour traitement partiel
rsync -az --checksum \
    -e "ssh ${SSH_OPTS}" \
    /root/AdGuardHome/AdGuardHome.yaml \
    "${LLMCORE_HOST}:/tmp/dns-sync-agh-rewrites-source.yaml"

# Appliquer uniquement filtering.rewrites (pas les autres sections)
ssh ${SSH_OPTS} "${LLMCORE_HOST}" \
    'sudo python3 /usr/local/bin/dns-apply-rewrites-sync.py /tmp/dns-sync-agh-rewrites-source.yaml /opt/AdGuardHome/AdGuardHome.yaml && rm -f /tmp/dns-sync-agh-rewrites-source.yaml && sudo systemctl reload-or-restart AdGuardHome'

log "Synchronisation rewrites terminee avec succes"
