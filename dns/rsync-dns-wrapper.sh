#!/usr/bin/env bash
# rsync-dns-wrapper.sh
# Wrapper SSH pour la clé rsync DNS (id_ed25519_rsync_dns).
# Restreint les commandes autorisées via la directive command= dans authorized_keys.
#
# Commandes whitelistées (provenant de dns-sync-to-llmcore.sh sur LXC 411) :
#   1. rsync --server  (transfert fichiers → /tmp/dns-sync-*.*)
#   2. install + unbound-checkconf + systemctl reload unbound (appliquer conf Unbound)
#   3. python3 dns-apply-upstream-sync.py + systemctl reload AdGuardHome (appliquer YAML)
#
# Toute autre commande est rejetée et loguée.
#
# Déployer sur llmcore :
#   sudo cp rsync-dns-wrapper.sh /home/llmuser/.ssh/rsync-dns-wrapper.sh
#   sudo chmod 755 /home/llmuser/.ssh/rsync-dns-wrapper.sh
#   sudo chown llmuser:llmuser /home/llmuser/.ssh/rsync-dns-wrapper.sh
#
# Puis dans ~llmuser/.ssh/authorized_keys, remplacer la ligne de la clé rsync par :
#   command="/home/llmuser/.ssh/rsync-dns-wrapper.sh",no-port-forwarding,\
#   no-X11-forwarding,no-agent-forwarding,no-pty \
#   ssh-ed25519 AAAA... rsync-dns-lxc411-to-llmcore

set -euo pipefail

LOG_FILE="/var/log/rsync-dns.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Fonction de log : écrit dans le journal et sur stderr (visible journalctl)
log() {
    local level="$1"
    local msg="$2"
    # Création du log si absent (première invocation)
    if [[ ! -f "${LOG_FILE}" ]]; then
        sudo touch "${LOG_FILE}" 2>/dev/null || true
        sudo chmod 640 "${LOG_FILE}" 2>/dev/null || true
    fi
    echo "[${TIMESTAMP}] [${level}] from=${SSH_CLIENT:-unknown} cmd=${SSH_ORIGINAL_COMMAND:0:120} msg=${msg}" \
        | sudo tee -a "${LOG_FILE}" > /dev/null 2>&1 || \
        echo "[${TIMESTAMP}] [${level}] ${msg}" >&2
}

# Commande reçue (vide si shell interactif tenté)
ORIGINAL_CMD="${SSH_ORIGINAL_COMMAND:-}"

if [[ -z "${ORIGINAL_CMD}" ]]; then
    log "REJECT" "tentative shell interactif"
    echo "ERREUR: shell interactif non autorisé sur cette clé." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Whitelist des commandes autorisées
# Pattern 1 : rsync --server (transfert fichier entrant)
#   Exemple : rsync --server -az --checksum . /tmp/dns-sync-unbound.conf
#             rsync --server -az --checksum . /tmp/dns-sync-agh-source.yaml
#   Contrainte : destination doit être /tmp/dns-sync-* uniquement
# ---------------------------------------------------------------------------
if [[ "${ORIGINAL_CMD}" == rsync\ --server* ]]; then
    # Vérifier que la destination est bien /tmp/dns-sync-*
    if echo "${ORIGINAL_CMD}" | grep -qE '/tmp/dns-sync-[a-zA-Z0-9._-]+$'; then
        log "ALLOW" "rsync --server vers /tmp/dns-sync-*"
        exec ${ORIGINAL_CMD}
    else
        log "REJECT" "rsync destination hors whitelist"
        echo "ERREUR: rsync destination non autorisée." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Pattern 2 : application config Unbound
#   sudo install ... /tmp/dns-sync-unbound.conf → /etc/unbound/...
#   && sudo unbound-checkconf ...
#   && sudo systemctl reload unbound
#   && rm -f /tmp/dns-sync-unbound.conf
# ---------------------------------------------------------------------------
if echo "${ORIGINAL_CMD}" | grep -qE '^sudo install.*dns-sync-unbound\.conf.*unbound.*&&.*unbound-checkconf.*&&.*systemctl (reload|restart) unbound'; then
    log "ALLOW" "appliquer config Unbound"
    exec bash -c "${ORIGINAL_CMD}"
fi

# ---------------------------------------------------------------------------
# Pattern 3 : application YAML AdGuard via dns-apply-upstream-sync.py
#   sudo python3 /usr/local/bin/dns-apply-upstream-sync.py /tmp/dns-sync-agh-source.yaml ...
#   && rm -f /tmp/dns-sync-agh-source.yaml
#   && sudo systemctl reload-or-restart AdGuardHome
# ---------------------------------------------------------------------------
if echo "${ORIGINAL_CMD}" | grep -qE '^sudo python3 /usr/local/bin/dns-apply-upstream-sync\.py.*dns-sync-agh-source\.yaml.*&&.*systemctl (reload|reload-or-restart) AdGuardHome'; then
    log "ALLOW" "appliquer config AdGuard"
    exec bash -c "${ORIGINAL_CMD}"
fi

# ---------------------------------------------------------------------------
# Tout autre commande : REJETER
# ---------------------------------------------------------------------------
log "REJECT" "commande non whitelistée"
echo "ERREUR: commande non autorisée sur cette clé SSH restreinte." >&2
echo "  Commande reçue: ${ORIGINAL_CMD:0:200}" >&2
exit 1
