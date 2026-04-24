#!/usr/bin/env bash
# bigbrother-analyze.sh — Invocation Monarch pour analyse monitoring transversale.
# Déclenché par systemd timer (bigbrother-analyze.timer, 1h).
#
# MIGRATION 2026-04-24 : Claude CLI → Monarch
# Raison : rate limit Claude Code (partagé avec session Stéphane) causait silence BigBrother
#         lors de runs intensifs (ex: Monarch M2b/M2c 2026-04-22 = 7h silence + spam watchdog).
# Monarch utilise Qwen3.6-35B-A3B via gateway v2 local :8435 — quota indépendant, zero coût.
# Backup ancien script : bigbrother-analyze.sh.bak-claude-2026-04-24

set -euo pipefail

WORKSPACE="$HOME/.bigbrother-agent/workspace"
LOG="$HOME/.bigbrother-agent/logs/analyze.log"
MONARCH_BIN="$(command -v monarch)"

mkdir -p "$(dirname "$LOG")"
echo "[$(date -Is)] START analyze (Monarch)" >> "$LOG"

if [[ -z "$MONARCH_BIN" ]]; then
    echo "[$(date -Is)] ERROR monarch binary introuvable dans PATH" >> "$LOG"
    exit 1
fi

cd "$WORKSPACE"

PROMPT=$(cat <<'PROMPT_EOF'
Tu es BigBrother, agent d'observabilité transversale homelab.

ÉTAPE 1 OBLIGATOIRE : lis ton charter complet avec le tool Read :
  ~/.bigbrother-agent/workspace/CLAUDE.md

Le charter contient ta mission, ton périmètre, tes interdits et les 8 étapes d'analyse détaillées.

Puis exécute les 8 étapes de mission (collecte NATS 3 streams 6h, corrélation, vault_search historique, jugement P0/P1/P2/RAS, publish si pertinent, vault_write analyse, heartbeat).

Rappels critiques (hors charter) :
- Section vault-mem canonique NOMENCLATURE §10a : utilise UNIQUEMENT `section="debug"` avec `tag="bigbrother-analysis"` (section "monitoring" legacy rejetée par gatekeeper).
- Silence = meilleur que bruit. Si analyse RAS (rien à signaler) → pas de vault_write, juste log RAS et heartbeat NATS.
- Écris la ligne finale dans le log `~/.bigbrother-agent/logs/analyze.log` : `<ISO8601> | severity=<P0|P1|P2|RAS> | publish=<oui|non> | events_analyzed=<N>`.
- Langue : français.
PROMPT_EOF
)

if ! "$MONARCH_BIN" --mode bypass_permissions "$PROMPT" >> "$LOG" 2>&1; then
    EXIT_CODE=$?
    echo "[$(date -Is)] ERROR monarch exit $EXIT_CODE" >> "$LOG"
    exit 1
fi

echo "[$(date -Is)] DONE" >> "$LOG"

# P4.1 — Heartbeat : signale que BigBrother vient de s'exécuter (consommé par watchdog).
# Severity P3 → dispatcher log_only (pas de DM à Stéphane).
NATS_SEED="$HOME/.bigbrother-agent/credentials/nats-hubmq-service.seed"
NATS_SERVER="nats://192.168.10.15:4222"
if command -v nats >/dev/null 2>&1; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    HEARTBEAT=$(printf '{"id":"%s","ts":"%s","source":"bigbrother","severity":"P3","title":"BigBrother heartbeat","body":"Run OK (Monarch)","tags":["heartbeat","monarch"]}' "$UUID" "$TS")
    nats --nkey "$NATS_SEED" --server "$NATS_SERVER" pub agent.bigbrother.heartbeat "$HEARTBEAT" >> "$LOG" 2>&1 || \
        echo "[$(date -Is)] WARN heartbeat publish failed" >> "$LOG"
fi
