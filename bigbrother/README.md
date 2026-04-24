# BigBrother — scripts d'ops monitoring transversal

Agent d'observabilité transversale homelab. Ingère 3 streams NATS (ALERTS / MONITOR / SYSTEM / CRON) via `nats` CLI, corrèle sur 6h, juge pertinence P0/P1/P2/RAS, publie uniquement des digests curés sur `agent.bigbrother.summary` (stream AGENTS) pour routage HubMQ → Telegram.

## Fichiers

| Fichier | Déployé vers | Rôle |
|---|---|---|
| `bigbrother-analyze.sh` | `~/.bigbrother-agent/wrapper/` | Invocation Monarch pour analyse hourly (timer `bigbrother-analyze.timer`) |
| `bigbrother-analyze.sh.bak-claude-2026-04-24` | idem | Backup version Claude CLI (rollback rapide si Monarch instable) |
| `bigbrother-watchdog.sh` | idem | Watchdog 30min, alerte Telegram si BigBrother silencieux + stream ALERTS non vide |
| `CLAUDE-charter.md` | `~/.bigbrother-agent/workspace/CLAUDE.md` | Charter complet BigBrother : mission, périmètre, interdictions, 8 étapes |
| `CLAUDE-charter.md.bak-claude-2026-04-24` | idem | Backup charter avant migration `section=monitoring → debug` |

## Historique

### 2026-04-24 — Migration Claude CLI → Monarch
- **Cause** : silence BigBrother 2026-04-21 22:40 → 2026-04-22 05:42 (~7h) — rate limit hebdomadaire Claude Code atteint pendant travaux Monarch M2b/M2c intensifs. Watchdog a spam Telegram ~14 alertes durant cette fenêtre.
- **Fix B** : `bigbrother-analyze.sh` invoque `monarch --mode bypass_permissions` au lieu de `claude --print --continue --max-turns 30 --permission-mode acceptEdits`. Monarch utilise Qwen3.6-35B-A3B via gateway v2 `:8435` (llmcore GPU), quota indépendant de la session Claude Code de Stéphane.
- **Fix D** : `bigbrother-watchdog.sh` cap dédup `MAX_ALERTS_PER_DAY=3` rolling 24h (avant : cap 1h seul). Spam Telegram réduit de 14/panne → 3/24h max.
- **PATH systemd fix** : `monarch-mcp-http-adapter` copié `/root/.cargo/bin/` → `/usr/local/bin/` (présent dans PATH systemd standard).
- **Charter** : section vault-mem `monitoring` (hors §10a canon) → `debug` (canon, accepté par gatekeeper Qwen3.6-35B-A3B).
- Gains : zero dépendance Anthropic, zero coût, -36% mem (245M vs 383M), test end-to-end systemd PASS.
- Rollback : `cp bigbrother-analyze.sh.bak-claude-2026-04-24 bigbrother-analyze.sh && kill -HUP $(pidof bigbrother-analyze)` + restore charter.

## Dépendances runtime

- **Monarch** `v0.4.2-phase2-closed+` (binaire `/home/motreffs/.local/bin/monarch` + adapter `/usr/local/bin/monarch-mcp-http-adapter`)
- **NATS CLI** (`nats` dans PATH, seed `~/.bigbrother-agent/credentials/nats-hubmq-service.seed`)
- **gateway v2** `:8435` (LXC 500) → llmcore Qwen3.6-35B-A3B
- **hubmq** LXC 415 NATS server `nats://192.168.10.15:4222`
- **Telegram** via `~/.hubmq-agent/wrapper/send-telegram.sh` (chat_id Stéphane `1451527482`)

## Déploiement

Les scripts sont déployés via copie manuelle vers `~/.bigbrother-agent/wrapper/` et `~/.bigbrother-agent/workspace/`. Pas d'automation cross-LXC pour l'instant (BigBrother tourne uniquement sur LXC 500 / host où est installé Monarch).

Services systemd associés (non inclus ici, configurés localement) :
- `bigbrother-analyze.service` + `.timer` (hourly)
- `bigbrother-watchdog.service` + `.timer` (30min)

Description service MAJ : "BigBrother — analyse monitoring transversale via Monarch (Qwen3.6-35B)".

## Non inclus dans ce repo

- `credentials/` (NATS seeds, secrets) — jamais versionnés
- `workspace/memory/` (données de session BigBrother) — volumineux, non pertinent
- `logs/` (runtime logs) — volumineux, rotatés
