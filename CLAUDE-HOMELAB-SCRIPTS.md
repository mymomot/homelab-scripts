# CLAUDE-HOMELAB-SCRIPTS.md

## Projet : homelab-scripts

**Type** : Scripts d'ops infra (pas de binaire, pas de CI/CD complexe)
**Propriétaire** : motreffs
**Date création** : 2026-04-24
**Repo Forgejo** : http://localhost:3000/motreffs/homelab-scripts
**Repo GitHub** : https://github.com/mymomot/homelab-scripts (mirror)

## Objectif

Capitaliser et backup les scripts d'ops homelab produits lors des sessions de maintenance et hardening. Premier script : AdGuard hardening Session 1 (2026-04-24).

## Architecture

Python 3.11+ / Bash 5+ standalone. Pas de framework, pas de dépendances lourdes. Chaque script est autonome et lisible sans contexte externe.

## Dépendances

- Python 3.11+ (scripts DNS, parsing YAML/JSON config)
- Bash 5+ (scripts infra, deploy)
- SSH keys déjà déployées (pattern LXC existant)

## Services consommés

| Service | LXC | Port | Usage |
|---------|-----|------|-------|
| AdGuard Home primary | LXC 411 | — | Config DNS hardening |
| AdGuard Home secondary | llmcore | — | Config DNS hardening |

## Pipeline CI/CD

Aucun pour l'instant. À envisager : Forgejo Actions lint python (ruff) + shellcheck (bash).

## Conventions scripts

- En-tête obligatoire : date, auteur, cible, prérequis, revert
- Idempotence : ré-exécutable sans effet si déjà appliqué
- Backup horodaté automatique avant toute modification de config LIVE

## Projets externalisés

### mymaps (externalisation 2026-04-25)

Répertoire `maps/` + monitoring scripts `check-pmtiles-*` ont été extraits et packagés en projet dédié.

Voir : `~/projects/mymaps/CLAUDE-MYMAPS.md`

- Repo Forgejo : http://localhost:3000/motreffs/mymaps
- Repo GitHub mirror : https://github.com/mymomot/mymaps
- Statut Phase 6-9 LIVE 2026-04-24 : pmtiles serving LXC 511 `maps.lab.mymomot.ovh`
- Commit extraction homelab-scripts : `7b87056`
- Commit init mymaps : `dd4d420`

**Dépendances inter-services** (documentées dans mymaps) :
- Traefik LXC 410 → pmtiles LXC 511 :8080 (NFS RO `/mnt/truenas/scanlib/rawsources/maps/pmtiles/`)
- Traefik LXC 410 → caddy LXC 511 :8081 (local `/var/www/maps/`)
- AdGuard primary LXC 411 + secondary llmcore → DNS rewrite maps.lab.mymomot.ovh → 192.168.10.10
- **DETTE** : rewrites non auto-sync primary ↔ secondary (SYNC_KEYS incomplet, voir mymaps/docs/runbooks/ROLLBACK.md)

## Historique

| Date | Action |
|------|--------|
| 2026-04-25 | Externalisation mymaps : maps/ + monitoring/check-pmtiles-* déplacés vers projet dédié (commit `7b87056`). Annaire MAJ. |
| 2026-04-25 | Viewer browser-ready : fix CSP inline externalized + dépendance CDN externe supprimée (commit `bbe60ac`) — CV5 dettes POST-déploiement |
| 2026-04-24 | Phase 6-9 maps.lab.mymomot.ovh LIVE : 3 health checks + Traefik 3 YAML + ROLLBACK.md + E2E 5 PASS |
| 2026-04-24 | Création repo, import script adguard-hardening Session 1 |
