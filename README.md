# homelab-scripts

Scripts d'ops homelab motreffs — capitalisation, backup, réutilisation.

## Scope

Scripts utilitaires pour le homelab (primaire : MinisForum N5 Pro Proxmox + llmcore GMKTEC Evo X-2).
Couvre : DNS, LXC/Proxmox, monitoring, déploiements cross-LXC.

## Structure

- `dns/` — scripts AdGuard Home, DNS config, failover
- `lxc/` — scripts Proxmox pct (provisionnement, maintenance)
- `monitoring/` — scripts BigBrother/Wazuh custom
- `deploy/` — scripts cross-LXC deploy patterns

## Scripts majeurs

| Script | Description |
|--------|-------------|
| `dns/adguard-hardening-session1-2026-04-24.py` | Hardening AdGuard Home : 24 upstreams → 16 (8 DoT + 8 clair), fastest_addr, DNSSEC, cache 64 MB. Idempotent. |

## Usage

Chaque script documente ses préconditions et cibles en en-tête. Lire avant exécution.
Tous les scripts touchant un service LIVE créent un backup horodaté avant modif.

## Runbook exécution

Scripts DNS : voir `dns/README.md`

## Conventions

- Idempotence obligatoire — ré-exécution sans effet si déjà appliqué
- Backup horodaté automatique avant toute modification de config LIVE
- En-tête script : date, auteur, cible, prérequis, revert

## Origine

Scripts issus de sessions homelab LXC 500 Forge. Repo dédié arbitré 2026-04-24 (option B : repo Forgejo primary + mirror GitHub). Trace Art.2 Constitution.
