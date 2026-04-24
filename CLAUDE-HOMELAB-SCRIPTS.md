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

## Sous-projets

### maps/

**Phase 6-9 LIVE (2026-04-24)** : pmtiles serving LXC 511 (`maps.lab.mymomot.ovh`)

| Composant | Fichier | Description |
|-----------|---------|-------------|
| Monitoring | `monitoring/check-pmtiles-metadata.sh` | Vérify TileJSON /planet.json 200 + minzoom/maxzoom |
| Monitoring | `monitoring/check-pmtiles-tile-zero.sh` | Vérify tile /planet/0/0/0.mvt 74937 B content-type |
| Monitoring | `monitoring/check-dns-failover-maps.sh` | Vérify DNS failover primary LXC 411 + secondary llmcore |
| Traefik config | `traefik/middlewares-maps.yml` | IP allowList LAN+VPN + headers securite |
| Traefik config | `traefik/services-maps.yml` | Backend routing pmtiles :8080 + caddy :8081 |
| Traefik config | `traefik/routers-maps.yml` | Path-based routing `/tiles/*` → pmtiles, `/` → caddy |
| Rollback | `maps/ROLLBACK.md` | Procédure Traefik-first → DNS (sed + python3 variantes) |

**Dépendances inter-services** :
- Traefik LXC 410 → pmtiles LXC 511 :8080 (NFS RO `/mnt/truenas/scanlib/rawsources/maps/pmtiles/`)
- Traefik LXC 410 → caddy LXC 511 :8081 (local `/var/www/maps/`)
- AdGuard primary LXC 411 + secondary llmcore → DNS rewrite maps.lab.mymomot.ovh → 192.168.10.10
- **DETTE** : rewrites non auto-sync primary ↔ secondary (SYNC_KEYS incomplet dans `dns-apply-upstream-sync.py`)

## Historique

| Date | Action |
|------|--------|
| 2026-04-24 | Phase 6-9 maps.lab.mymomot.ovh LIVE : 3 health checks + Traefik 3 YAML + ROLLBACK.md + E2E 5 PASS |
| 2026-04-24 | Création repo, import script adguard-hardening Session 1 |
