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

## Historique

| Date | Action |
|------|--------|
| 2026-04-24 | Création repo, import script adguard-hardening Session 1 |
