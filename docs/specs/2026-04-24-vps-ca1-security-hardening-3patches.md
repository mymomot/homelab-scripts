# VPS CA-1 — Security Hardening : 3 Patches

**Date** : 2026-04-24
**Cible** : VPS CA-1 (cloud, hardening baseline 2026-04-11)
**Origine** : audit Clouds + forensic 2026-04-24 → verdict SAIN, 3 points d'attention non critiques
**Scope** : 3 correctifs indépendants exécutés en séquence. Read-only audits OK, patches mutent config.

## Contexte

Deux audits successifs (sécurité + forensic) le 2026-04-24 ont conclu à un VPS **sain**, zéro indicateur de compromission. Trois points d'amélioration ont été identifiés — aucun critique, tous préventifs/renforcement :

1. **Parser CrowdSec SSH dégradé** — 2/4270 lignes parsées → détection locale quasi-KO, protection repose 100% sur la CAPI communautaire. Les top attaquants (123.58.212.100 = 437 conn/7j, etc.) ne sont pas bannis localement.
2. **rkhunter + chkrootkit absents** — pas de détection rootkit IoC en local. Établir la baseline maintenant sur serveur propre.
3. **msg-relay exposé 0.0.0.0:9480** — aucune raison légitime d'être joignable hors VPN homelab.

## Objectifs

- Restaurer la détection locale CrowdSec SSH (bans automatiques sur brute-force)
- Déployer un IDS rootkit (rkhunter scan hebdo + chkrootkit baseline)
- Réduire la surface d'attaque Internet en restreignant msg-relay au tunnel VPN

## Non-objectifs

- Pas de refonte hardening générale (déjà fait 2026-04-11)
- Pas d'ajout d'alertes Wazuh custom (les events journald remontent déjà)
- Pas d'audit code msg-relay (choix A user : binding restreint, pas de hardening auth applicatif)
- Pas de cron chkrootkit (bruit/obsolescence — scan one-shot suffit pour baseline)

## Architecture des 3 patches

### P1 — Fix parser CrowdSec SSH

**Problème** : `cscli metrics` montre `crowdsecurity/sshd-logs` avec `hits=4270, parsed=2, unparsed=4270`. Les buckets ssh-bf/ssh-slow-bf sont instanciés mais ne débordent jamais localement.

**Hypothèse principale** : mismatch entre `/etc/crowdsec/acquis.yaml` et les logs journald actuels. Cause probable : nom d'unité systemd `ssh.service` vs `sshd.service` (Debian 12+ utilise `ssh.service`), ou absence du filtre `_SYSTEMD_UNIT` correct.

**Démarche** :
1. Inspecter `/etc/crowdsec/acquis.yaml` — vérifier bloc source journalctl ciblant SSH
2. `cscli collections list` — confirmer `crowdsecurity/sshd` installé + version
3. `cscli parsers list` — confirmer `crowdsecurity/sshd-logs` actif
4. `journalctl -u ssh.service --since "1h ago"` — valider format + nom unité réel
5. Corriger `acquis.yaml` si mismatch (sauvegarde `.bak` avant)
6. `cscli collections upgrade crowdsecurity/sshd` si version stale
7. `systemctl restart crowdsec`

**Validation** :
- `cscli metrics` → `parsed > 0` sur sshd-logs après 15min de trafic honeypot
- Test déclencheur : depuis IP de test (via tor ou VPS jetable), 10 tentatives SSH échouées sur `:49222` → vérifier `cscli decisions list` pour ban local (bucket `crowdsecurity/ssh-bf` overflow)

**Rollback** : `cp /etc/crowdsec/acquis.yaml.bak /etc/crowdsec/acquis.yaml && systemctl restart crowdsec`

### P2 — rkhunter + chkrootkit

**Démarche** :
1. `apt-get update && apt-get install -y rkhunter chkrootkit`
2. Config `/etc/rkhunter.conf` — laisser défauts Debian, vérifier :
   - `UPDATE_MIRRORS=1`
   - `MIRRORS_MODE=0`
   - `WEB_CMD=""` (neutralise curl fetcher problématique)
3. `rkhunter --update` — mise à jour base de signatures
4. `rkhunter --propupd` — **baseline établie sur serveur propre confirmé sain**
5. `rkhunter --check --sk --rwo` — premier scan, doit retourner 0 warning
6. `chkrootkit` — scan manuel one-shot, doit être clean
7. Créer `/etc/cron.d/rkhunter-weekly` :
   ```
   0 3 * * 0 root /usr/bin/rkhunter --cronjob --update --quiet --report-warnings-only 2>&1 | /usr/bin/logger -t rkhunter -p daemon.warning
   ```
   → Dimanche 03:00 UTC, warnings vers journald (Wazuh agent remontera)

**Validation** :
- `rkhunter --check --sk --rwo` retourne 0 warning
- `chkrootkit` retourne 0 INFECTED
- Cron file présent + exécutable
- Log journald `rkhunter` visible après premier run

**Rollback** : `apt purge -y rkhunter chkrootkit && rm -f /etc/cron.d/rkhunter-weekly`

### P3 — msg-relay bind 10.77.0.2

**Problème** : msg-relay écoute `0.0.0.0:9480` — surface Internet inutile, protégée uniquement par UFW (défense unique).

**Démarche** :
1. `systemctl cat msg-relay` — identifier mode de binding (env var, flag CLI, fichier config)
2. `ip -4 addr show tun0` — confirmer IP VPN côté VPS (attendu 10.77.0.2)
3. Vérifier ordering systemd :
   - Unit doit avoir `After=<vpn-service>.service`
   - Si pas présent : ajouter via drop-in `/etc/systemd/system/msg-relay.service.d/bind-vpn.conf`
4. Sauvegarder config actuelle
5. Modifier binding : `0.0.0.0:9480` → `10.77.0.2:9480`
6. `systemctl daemon-reload && systemctl restart msg-relay`
7. **Avant validation** : vérifier tun0 is UP (si VPN down, msg-relay échoue à bind — c'est le comportement voulu, mais il faut que le VPN soit up au moment du restart)

**Validation** :
- `ss -tlnp | grep 9480` → bind `10.77.0.2:9480` uniquement, pas `0.0.0.0`
- Depuis LXC 500 : `msg-relay-cli health` → 200 OK
- Depuis LXC 500 : `msg-relay-cli check` → fonctionne (polling /loop 1m ne casse pas)
- Depuis Internet externe (si testable) : `curl http://<ip-publique-vps>:9480` → connection refused

**Rollback** : restaurer config + `systemctl daemon-reload && systemctl restart msg-relay`

## Ordre d'exécution

1. **P2** (rkhunter/chkrootkit) — moins risqué, pas de service LIVE muté, baseline établie
2. **P3** (msg-relay bind) — risque localisé, rollback instant, test via CLI depuis LXC 500
3. **P1** (CrowdSec parser) — diagnostic d'abord, fix après, test déclencheur final

Raison ordre : ordre croissant de risque/complexité. P2 ne peut rien casser de LIVE. P3 est binaire et testable en <1min. P1 requiert diagnostic préalable + test validation plus long.

## Pipeline d'exécution

```
regression-guard (P1+P3 services LIVE) → SCOPE LOCK
  ↓
pipeline-check → validation plan + conformité Art.17 diagnostic avant action
  ↓
Délégation Clouds (SSH VPS, patches, configs) — 3 patches séquentiels
  ↓
Tester (validation entre chaque patch, bloquant si rouge)
  ↓
Auditeur (review post-3 patches)
  ↓
Archiviste (MEMORY.md + vault-mem retrospective + commit homelab-scripts)
```

## Tests d'acceptation

| Patch | Critère PASS (tous requis) |
|---|---|
| P1 | `cscli metrics` → parsed sshd-logs > 0 ; test brute-force externe déclenche bucket overflow `ssh-bf` local ; `cscli decisions list` affiche IP de test bannie |
| P2 | `rkhunter --check --sk --rwo` → 0 warning ; `chkrootkit` → 0 INFECTED ; `/etc/cron.d/rkhunter-weekly` présent ; logger journald fonctionne |
| P3 | `ss -tlnp \| grep 9480` → bind `10.77.0.2` uniquement ; `msg-relay-cli health` PASS depuis LXC 500 ; polling `/loop 1m msg-relay-cli check` continue à fonctionner ≥ 5min |

Si **un seul** critère échoue sur un patch : STOP, rollback patch, analyse, correction, relance. Pas de continuation sur patch suivant.

## Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| P1 : fix acquis.yaml casse CrowdSec entier | CAPI bans perdus, redémarrage boucle | Sauvegarde `.bak` avant modif + test `crowdsec -c /etc/crowdsec/config.yaml -t` avant restart |
| P1 : test déclencheur externe manque / bloqué UFW | Validation incomplète | Accepter validation par `parsed > 0` + observer 1-2h trafic honeypot réel |
| P2 : rkhunter remonte faux positifs baseline | Warning dès le jour 0 | Documenter les faux positifs connus (services custom : endlessh, wazuh-agent, crowdsec) dans `/etc/rkhunter.conf` whitelist |
| P3 : tun0 down au restart msg-relay | Service fail à bind, polling LXC 500 casse | Ordering systemd `After=vpn-service` ; drop-in `Restart=on-failure RestartSec=10s` ; monitoring /loop continuera à retry |
| P3 : IP tun0 différente de 10.77.0.2 | Bind échoue | Confirmer via `ip addr` avant config ; si IP change : paramétrer via `IPAddressAllow` systemd ou binding dynamique |

## Dépendances / prérequis

- Accès SSH VPS CA-1 via VPN (port :49222)
- Sudo NOPASSWD sur compte admin VPS
- Repo `homelab-scripts` accessible pour commit scripts/docs éventuels
- Wazuh agent actif sur VPS (déjà confirmé par audit)
- Tunnel VPN stable (nécessaire P3)

## Artefacts livrés

- Fichiers modifiés VPS : `/etc/crowdsec/acquis.yaml`, `/etc/cron.d/rkhunter-weekly`, config msg-relay (unit ou env)
- Backups : `*.bak` de chaque fichier modifié, horodatés
- Scripts éventuels → `homelab-scripts/security/vps-ca1/` (si extraits en scripts réutilisables)
- Rétrospective vault-mem `retrospectives/[RETRO][HOMELAB] VPS CA-1 security 3 patches 2026-04-24`
- MEMORY.md entry : 1 ligne dans "Travail en cours (2026-04-24)"
- INTER-SERVICE-DEPS.md : update si msg-relay change de binding

## Questions ouvertes

Aucune — les 2 choix ouverts tranchés (A msg-relay binding strict, B rkhunter cron hebdo).

## Gouvernance

- **Art.7** pipeline Général → agents : respecté (Général planifie, Clouds exécute)
- **Art.17** diagnostic avant action : P1 inclut phase diagnostic explicite avant modif
- **regression-guard** invoqué avant P1 et P3 (services LIVE)
- **Art.19** : ce spec n'est PAS un document structurant (pas CLAUDE.md/agent/skill/hook/settings/NOMENCLATURE/CLAUDE-PROJET). Pas de council Phase 0bis requis. C'est un plan opérationnel one-shot.
- **Council Art.15 bis** : non applicable (pas de choix transversal homelab — patches locaux VPS uniquement, aucun impact 3+ projets)
