# VPS CA-1 — 3 Patches Sécu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Durcir VPS CA-1 via 3 patches indépendants (CrowdSec parser SSH, rkhunter/chkrootkit baseline, msg-relay bind VPN-only) après audit SAIN du 2026-04-24.

**Architecture:** 3 tasks séquentielles, ordre croissant de risque (P2 install one-shot → P3 bind localisé → P1 diagnostic+fix). Chaque task = backup config → diagnostic/action → validation → rollback en cas d'échec. Délégation Clouds pour exécution SSH (accès VPS, sudo NOPASSWD).

**Tech Stack:** Debian 12/13 VPS, systemd, CrowdSec v1.x (cscli), rkhunter/chkrootkit, msg-relay (service Rust homelab), SSH :49222, tun0 VPN IP 10.77.0.2.

**Spec source:** `docs/specs/2026-04-24-vps-ca1-security-hardening-3patches.md`

**Exécutant:** agent **Clouds** (délégation obligatoire — Art.7 Général ne code pas). Tester valide après chaque task. Auditeur review finale. Archiviste consolide.

---

## Task 0: Pré-flight — regression-guard + snapshot état VPS

**Objectif:** Produire le SCOPE LOCK regression-guard (services LIVE : CrowdSec, msg-relay) + capturer l'état initial VPS pour diff post-patch.

**Files:**
- Create: `~/tmp/scratch/vps-ca1-preflight-2026-04-24.txt` (snapshot état initial)

- [ ] **Step 0.1: Invoquer skill regression-guard**

Depuis la session Général, invoquer `regression-guard` avec le scope :
- Services LIVE impactés : `crowdsec.service` (P1), `msg-relay.service` (P3)
- Services LIVE non impactés mais adjacents : `ssh.service` (P1 dépend de ses logs), `wazuh-agent.service` (observe journald), `endlessh.service`, `endlessh-port22.service`
- Actions planifiées : modifier `/etc/crowdsec/acquis.yaml`, créer `/etc/cron.d/rkhunter-weekly`, modifier binding msg-relay, restart 2 services
- Rollback path : backup `.bak` horodatés + commandes `systemctl restart` de retour

Livrable attendu : SCOPE LOCK écrit (texte court, copié dans le plan ici avant exécution).

- [ ] **Step 0.2: Snapshot état initial VPS (depuis Clouds)**

Délégation Clouds : exécuter sur VPS CA-1 et capturer dans `~/tmp/scratch/vps-ca1-preflight-2026-04-24.txt` :

```bash
ssh vps-ca1 'bash -s' <<'REMOTE'
echo "=== DATE ===" ; date -u
echo "=== UPTIME ===" ; uptime
echo "=== SERVICES LIVE ===" ; systemctl is-active crowdsec msg-relay ssh wazuh-agent endlessh endlessh-port22
echo "=== PORTS LISTEN ===" ; sudo ss -tlnp
echo "=== CROWDSEC METRICS (parsers) ===" ; sudo cscli metrics | grep -A 30 "Parsers"
echo "=== CROWDSEC DECISIONS LOCAL ===" ; sudo cscli decisions list --origin crowdsec 2>&1 | head -20
echo "=== ACQUIS.YAML ===" ; sudo cat /etc/crowdsec/acquis.yaml
echo "=== MSG-RELAY UNIT ===" ; systemctl cat msg-relay
echo "=== TUN0 IP ===" ; ip -4 addr show tun0 | grep inet
echo "=== CRON.D ===" ; ls -la /etc/cron.d/
echo "=== RKHUNTER/CHKROOTKIT PRESENCE ===" ; dpkg -l | grep -iE "rkhunter|chkrootkit" || echo "NOT INSTALLED"
REMOTE
```

- [ ] **Step 0.3: Vérifier snapshot capturé + committer dans worktree temporaire**

Expected: fichier existe, ≥ 100 lignes, services tous `active`, IP tun0 confirmée (doit être `10.77.0.2` selon spec — si différente, ajuster plan P3).

**Gate:** Ne pas passer à Task 1 si :
- Un service LIVE ci-dessus est `failed` ou `inactive` (→ anomaly-solver d'abord)
- IP tun0 différente de 10.77.0.2 (→ ajuster P3 ou confirmer avec user)
- CrowdSec metrics parseurs inaccessibles (→ diagnostic préalable)

---

## Task 1: P2 — rkhunter + chkrootkit baseline + cron hebdo

**Files:**
- Create VPS: `/etc/cron.d/rkhunter-weekly`
- Modify VPS: `/etc/rkhunter.conf` (whitelist si faux positifs)
- Backup: `/etc/rkhunter.conf.bak-20260424`

**Délégation:** Clouds

- [ ] **Step 1.1: Installer les paquets**

Commande sur VPS (via Clouds) :
```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y rkhunter chkrootkit
```

Expected: 2 paquets installés, retour code 0.
Validation: `dpkg -l | grep -E "^ii  (rkhunter|chkrootkit)"` retourne 2 lignes.

- [ ] **Step 1.2: Backup config rkhunter + vérifier défauts Debian**

```bash
sudo cp /etc/rkhunter.conf /etc/rkhunter.conf.bak-20260424
sudo grep -E "^(UPDATE_MIRRORS|MIRRORS_MODE|WEB_CMD|MAIL-ON-WARNING)" /etc/default/rkhunter /etc/rkhunter.conf 2>/dev/null | sort
```

Expected: `UPDATE_MIRRORS=1`, `MIRRORS_MODE=0`, `WEB_CMD=""` présents (ajouter si absents via `sudo tee -a /etc/rkhunter.conf`). **Attention** : Debian définit certaines valeurs dans `/etc/default/rkhunter` → prioritaire si `DISABLE_TESTS` y est défini.

- [ ] **Step 1.3: Mise à jour signatures + establish baseline**

```bash
sudo rkhunter --update
sudo rkhunter --propupd
```

Expected: `--update` retourne "System checks summary" sans erreur mirror. `--propupd` écrit `/var/lib/rkhunter/db/rkhunter.dat` et affiche "File created: /var/lib/rkhunter/db/rkhunter.dat".

**Gate:** baseline établie SUR SERVEUR CONFIRMÉ SAIN (audit forensic 2026-04-24 verdict SAIN — c'est le bon moment).

- [ ] **Step 1.4: Premier scan rkhunter — doit être clean**

```bash
sudo rkhunter --check --sk --rwo 2>&1 | tee /tmp/rkhunter-first-scan.log
```

Expected: sortie vide OU uniquement des warnings connus Debian (ex: "Checking for prerequisites... [ Warning ]" sur certaines versions). 0 ligne contenant "INFECTED", "SUSPECT", "Rootkit:".

Si warnings non triviaux détectés :
- Lire `/var/log/rkhunter.log` pour détail
- Identifier faux positifs (endlessh, custom bins VPN relay)
- Ajouter whitelist dans `/etc/rkhunter.conf` : `SCRIPTWHITELIST=/path/to/script` ou `ALLOWHIDDENDIR=/path`
- Relancer `sudo rkhunter --propupd` après whitelist
- Relancer scan — doit être clean

- [ ] **Step 1.5: Scan chkrootkit one-shot — doit être clean**

```bash
sudo chkrootkit 2>&1 | tee /tmp/chkrootkit-first-scan.log | grep -E "INFECTED|found"
```

Expected: aucune ligne retournée par grep (ou uniquement "nothing found"). Si "INFECTED" apparaît : STOP, analyse obligatoire (probable faux positif OS, voir https://bugs.debian.org recherche chkrootkit).

- [ ] **Step 1.6: Créer cron hebdomadaire**

```bash
sudo tee /etc/cron.d/rkhunter-weekly > /dev/null <<'EOF'
# rkhunter weekly scan — dim 03:00 UTC, warnings -> journald (Wazuh pickup)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root /usr/bin/rkhunter --cronjob --update --quiet --report-warnings-only 2>&1 | /usr/bin/logger -t rkhunter -p daemon.warning
EOF
sudo chmod 644 /etc/cron.d/rkhunter-weekly
```

- [ ] **Step 1.7: Valider cron parsable**

```bash
sudo cat /etc/cron.d/rkhunter-weekly
sudo systemctl reload cron 2>/dev/null || sudo systemctl restart cron
sudo systemctl status cron --no-pager | head -5
journalctl -u cron --since "1 min ago" | grep -iE "error|warning" || echo "cron reload clean"
```

Expected: fichier présent, cron reload sans erreur, pas de "bad minute" ou "Error parsing" dans journald.

- [ ] **Step 1.8: Test manual trigger cron**

```bash
sudo /usr/bin/rkhunter --cronjob --update --quiet --report-warnings-only 2>&1 | /usr/bin/logger -t rkhunter -p daemon.warning
journalctl -t rkhunter --since "1 min ago"
```

Expected: au moins une ligne `rkhunter[...]` dans journald (ou aucune si 0 warning — dans ce cas vérifier `journalctl -t rkhunter -n 5` sur plus longue fenêtre).

- [ ] **Step 1.9: Tester — délégation Tester**

Tester lance :
- `dpkg -l rkhunter chkrootkit` → 2 paquets installés
- `test -f /etc/cron.d/rkhunter-weekly && test -r /var/lib/rkhunter/db/rkhunter.dat` → 0
- Re-run scan rkhunter → 0 warning non whitelisté
- Journald rkhunter accessible → oui

Rouge : STOP, rollback Step 1.10. Vert : passer Task 2.

- [ ] **Step 1.10: [Rollback si besoin uniquement] Purge rkhunter/chkrootkit**

```bash
sudo rm -f /etc/cron.d/rkhunter-weekly
sudo apt-get purge -y rkhunter chkrootkit
sudo apt-get autoremove -y
sudo cp /etc/rkhunter.conf.bak-20260424 /etc/rkhunter.conf 2>/dev/null || true
```

- [ ] **Step 1.11: Commit artefacts éventuels**

Si un script d'install a été extrait (ex: `security/vps-ca1/install-rkhunter.sh`) → commit dans homelab-scripts :
```bash
cd ~/projects/homelab-scripts
git add security/vps-ca1/
git commit -m "feat(security): rkhunter+chkrootkit install script VPS CA-1"
```

Sinon : pas de commit script, patch réalisé en direct sur VPS. Documenter dans retrospective vault-mem (Task 4).

---

## Task 2: P3 — msg-relay bind 10.77.0.2 (VPN tun0)

**Files:**
- Modify VPS: config msg-relay (unit systemd OU `/etc/msg-relay/config.toml` OU env file — à confirmer Step 2.1)
- Create VPS (si applicable): `/etc/systemd/system/msg-relay.service.d/bind-vpn.conf`
- Backup: `<config-file>.bak-20260424`

**Délégation:** Clouds

- [ ] **Step 2.1: Identifier méthode de binding msg-relay**

```bash
ssh vps-ca1 'bash -s' <<'REMOTE'
echo "=== UNIT FILE ===" ; systemctl cat msg-relay
echo "=== PROCESS ARGS ===" ; sudo ps -ef | grep -v grep | grep msg-relay
echo "=== CONFIG FILES ===" ; sudo ls -la /etc/msg-relay/ 2>/dev/null ; sudo ls -la /etc/default/msg-relay 2>/dev/null
echo "=== ENV FROM UNIT ===" ; systemctl show msg-relay -p Environment -p EnvironmentFile -p ExecStart
REMOTE
```

Expected: identifier une des trois :
- **Flag CLI** dans `ExecStart=... --bind 0.0.0.0:9480` → modifier l'unit via drop-in
- **Env var** `MSG_RELAY_BIND=0.0.0.0:9480` → modifier `EnvironmentFile` ou drop-in env
- **Fichier config** `/etc/msg-relay/config.toml` → modifier directement

**Gate:** Si binding n'est ni l'un ni l'autre (ex: hardcoded dans le binaire) → STOP, escalader à Stéphane.

- [ ] **Step 2.2: Confirmer IP tun0 côté VPS**

```bash
ssh vps-ca1 'ip -4 addr show tun0 | grep inet'
```

Expected: `inet 10.77.0.2/24 ...` (ou mask selon config). **Si IP ≠ 10.77.0.2** → utiliser la vraie IP dans Step 2.4 (pas 10.77.0.2 aveuglément).

- [ ] **Step 2.3: Backup config actuelle**

Selon méthode identifiée Step 2.1 :

**Cas A — Unit file** :
```bash
sudo cp /etc/systemd/system/msg-relay.service /etc/systemd/system/msg-relay.service.bak-20260424 2>/dev/null || sudo systemctl cat msg-relay | sudo tee /root/msg-relay-unit.bak-20260424 > /dev/null
```

**Cas B — Env file** :
```bash
sudo cp /etc/default/msg-relay /etc/default/msg-relay.bak-20260424
```

**Cas C — Config file** :
```bash
sudo cp /etc/msg-relay/config.toml /etc/msg-relay/config.toml.bak-20260424
```

- [ ] **Step 2.4: Vérifier ordering systemd (After=vpn)**

```bash
systemctl show msg-relay -p After -p Requires -p BindsTo
systemctl list-dependencies msg-relay | head -20
```

Expected: `After=` contient un service VPN (ex: `openvpn@client.service`, `wg-quick@wg0.service`, `vpn-relay.service`). **Si absent** : créer drop-in :

```bash
sudo mkdir -p /etc/systemd/system/msg-relay.service.d
sudo tee /etc/systemd/system/msg-relay.service.d/vpn-ordering.conf > /dev/null <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
# Ajouter ici le service VPN spécifique si identifié, ex:
# After=openvpn-client@client.service
# Requires=openvpn-client@client.service
EOF
```

**Note** : si le service VPN exact est incertain, `network-online.target` est le minimum acceptable (tun0 doit être UP avant bind).

- [ ] **Step 2.5: Modifier binding → 10.77.0.2:9480**

**Cas A — Flag CLI via drop-in** :
```bash
sudo tee /etc/systemd/system/msg-relay.service.d/bind-vpn.conf > /dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/msg-relay --bind 10.77.0.2:9480
EOF
```
(la ligne `ExecStart=` vide reset le ExecStart hérité — systemd syntaxe correcte pour override)

**Cas B — Env var via drop-in** :
```bash
sudo tee /etc/systemd/system/msg-relay.service.d/bind-vpn.conf > /dev/null <<'EOF'
[Service]
Environment=MSG_RELAY_BIND=10.77.0.2:9480
EOF
```

**Cas C — Fichier config** : éditer `/etc/msg-relay/config.toml` via `sed` ciblé :
```bash
sudo sed -i.pre-edit 's|bind\s*=\s*"0\.0\.0\.0:9480"|bind = "10.77.0.2:9480"|' /etc/msg-relay/config.toml
sudo grep -E "^bind" /etc/msg-relay/config.toml
```
Expected: ligne modifiée contient `10.77.0.2:9480`.

- [ ] **Step 2.6: Reload systemd + restart msg-relay**

```bash
sudo systemctl daemon-reload
sudo systemctl restart msg-relay
sleep 2
sudo systemctl status msg-relay --no-pager | head -15
```

Expected: `Active: active (running)`, pas d'erreur récente dans journal.

**Si service fail à bind** (tun0 down, IP fausse) : STOP, rollback Step 2.10.

- [ ] **Step 2.7: Vérifier binding effectif**

```bash
sudo ss -tlnp | grep 9480
```

Expected: **une seule ligne**, bind `10.77.0.2:9480` (PAS `0.0.0.0:9480`, PAS `*:9480`).

- [ ] **Step 2.8: Test depuis LXC 500 (client homelab)**

Depuis LXC 500 (côté Général / délégué Clouds) :

```bash
msg-relay-cli health
msg-relay-cli check
```

Expected :
- `health` → `200 OK` (JSON avec status up)
- `check` → soit 0 message soit N messages listés, pas d'erreur de connexion

- [ ] **Step 2.9: Test exposition Internet bloquée**

Depuis un host externe (LXC sans VPN, ou utiliser `curl` via proxy externe si dispo) :

```bash
# Via proxy tinyproxy LXC 414 (contourne VPN homelab pour simuler externe) :
# Non applicable — cela passerait aussi par VPN. Test alternatif :
# Depuis llmcore (192.168.10.118 — pas dans 10.77.0.0/24) :
ssh llmcore 'curl -sS --max-time 5 http://<IP-PUBLIQUE-VPS-CA-1>:9480/ 2>&1 | head -3'
```

Expected: `Connection refused` ou `Connection timed out`. **IP publique VPS** : à récupérer via `ssh vps-ca1 'curl -sS https://ifconfig.me'` si pas mémorisée.

Alternative plus simple : `sudo iptables -L INPUT -v` sur VPS doit montrer UFW ne permit pas 9480 en input Internet (doit déjà être le cas).

- [ ] **Step 2.10: Monitoring polling /loop 1m ≥ 5min**

Depuis LXC 500, vérifier que le polling `/loop 1m msg-relay-cli check` continue à tourner sans erreur pendant ≥ 5min.

```bash
# Dans la session Claude Code LXC 500 (déjà actif selon séquence démarrage étape 3)
# Simplement observer : pas d'erreur en sortie pendant 5min.
# Alternative manuelle :
for i in 1 2 3 4 5; do msg-relay-cli check ; sleep 60 ; done
```

Expected: 5 invocations, 0 erreur de connexion.

- [ ] **Step 2.11: Tester — délégation Tester**

Tester vérifie :
- `ss -tlnp | grep 9480` → bind 10.77.0.2 unique
- `msg-relay-cli health` PASS
- Service `active (running)` depuis ≥ 5 min sans restart
- 0 erreur dans `journalctl -u msg-relay --since "10 min ago"`

Rouge : STOP, rollback Step 2.12. Vert : passer Task 3.

- [ ] **Step 2.12: [Rollback si besoin uniquement]**

**Cas A/B (drop-in)** :
```bash
sudo rm -f /etc/systemd/system/msg-relay.service.d/bind-vpn.conf
sudo rmdir /etc/systemd/system/msg-relay.service.d 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl restart msg-relay
```

**Cas C (config file)** :
```bash
sudo cp /etc/msg-relay/config.toml.bak-20260424 /etc/msg-relay/config.toml
sudo systemctl restart msg-relay
```

Vérifier `ss -tlnp | grep 9480` → `0.0.0.0:9480` rétabli.

---

## Task 3: P1 — Fix parser CrowdSec SSH

**Files:**
- Modify VPS: `/etc/crowdsec/acquis.yaml`
- Backup: `/etc/crowdsec/acquis.yaml.bak-20260424`

**Délégation:** Clouds (diagnostic + fix). Art.17 diagnostic avant correction.

- [ ] **Step 3.1: Diagnostic — relever l'état actuel parseur**

```bash
ssh vps-ca1 'bash -s' <<'REMOTE'
echo "=== CSCLI METRICS (parsers) ===" ; sudo cscli metrics 2>/dev/null | awk '/Parsers/,/^$/'
echo "=== ACQUIS.YAML ===" ; sudo cat /etc/crowdsec/acquis.yaml
echo "=== ACQUIS.D/ ===" ; sudo ls -la /etc/crowdsec/acquis.d/ 2>/dev/null && sudo cat /etc/crowdsec/acquis.d/*.yaml 2>/dev/null
echo "=== COLLECTIONS ===" ; sudo cscli collections list
echo "=== PARSERS ===" ; sudo cscli parsers list
echo "=== SSH UNIT NAME ===" ; sudo systemctl list-units --type=service | grep -iE "ssh|sshd"
echo "=== JOURNALCTL SSH SAMPLE ===" ; sudo journalctl -u ssh.service -u sshd.service --since "1 hour ago" -n 5 --output=short 2>&1 | head -20
REMOTE
```

Capturer sortie dans `~/tmp/scratch/vps-ca1-crowdsec-diag-2026-04-24.txt`.

**Hypothèses à vérifier** :
1. Nom d'unité systemd → Debian 12/13 utilise `ssh.service` (pas `sshd.service`). Vérifier acquis.yaml pointe sur le bon.
2. Source `journalctl` vs `file` : acquis.yaml doit utiliser `source: journalctl` avec `journalctl_filter` si logs via journald (cas Debian moderne sans rsyslog).
3. Labels: `labels: { type: syslog }` présent (requis par parser `crowdsecurity/syslog-logs` en amont).
4. Collection `crowdsecurity/sshd` installée et à jour.

- [ ] **Step 3.2: Déterminer le correctif exact (branches par diagnostic)**

**Branche A — acquis.yaml référence `sshd.service` au lieu de `ssh.service`** :
Correctif = remplacer `sshd.service` → `ssh.service` dans `journalctl_filter`.

**Branche B — acquis.yaml lit `/var/log/auth.log` mais rsyslog absent (Debian 12+ journald only)** :
Correctif = remplacer bloc par source `journalctl` avec filtre `_SYSTEMD_UNIT=ssh.service`.

**Branche C — label `type: syslog` manquant** :
Correctif = ajouter `labels: { type: syslog }` au bloc SSH.

**Branche D — collection `crowdsecurity/sshd` absente ou stale** :
Correctif = `sudo cscli collections install crowdsecurity/sshd` OU `sudo cscli collections upgrade crowdsecurity/sshd`.

**Branche E — parser séparé désactivé/non chargé** :
Vérifier `sudo cscli parsers list` montre `crowdsecurity/sshd-logs` ENABLED. Sinon : `sudo cscli parsers install crowdsecurity/sshd-logs`.

Documenter la branche identifiée dans le log diag.

- [ ] **Step 3.3: Backup acquis.yaml**

```bash
sudo cp /etc/crowdsec/acquis.yaml /etc/crowdsec/acquis.yaml.bak-20260424
```

- [ ] **Step 3.4: Appliquer correctif selon branche identifiée**

**Exemple Branche B (le plus probable sur Debian 12/13)** — remplacer bloc SSH existant par :

```yaml
---
source: journalctl
journalctl_filter:
  - _SYSTEMD_UNIT=ssh.service
labels:
  type: syslog
```

Édition guidée :
```bash
# 1. Ouvrir en éditeur avec diff preview
sudo cp /etc/crowdsec/acquis.yaml /tmp/acquis-new.yaml
sudo $EDITOR /tmp/acquis-new.yaml
# 2. Diff
diff /etc/crowdsec/acquis.yaml /tmp/acquis-new.yaml
# 3. Appliquer
sudo cp /tmp/acquis-new.yaml /etc/crowdsec/acquis.yaml
```

- [ ] **Step 3.5: Valider config avant restart**

```bash
sudo crowdsec -c /etc/crowdsec/config.yaml -t
```

Expected: exit code 0, sortie contient `INFO config is valid` ou équivalent.
**Si erreur** : corriger acquis.yaml (typo YAML ? indentation ?) avant restart.

- [ ] **Step 3.6: Si branche D/E — installer/upgrader collection/parser**

```bash
sudo cscli hub update
sudo cscli collections upgrade crowdsecurity/sshd 2>&1 | tee /tmp/cscli-upgrade.log
# ou install si absent :
# sudo cscli collections install crowdsecurity/sshd
```

- [ ] **Step 3.7: Restart CrowdSec**

```bash
sudo systemctl restart crowdsec
sleep 3
sudo systemctl status crowdsec --no-pager | head -15
journalctl -u crowdsec --since "30 sec ago" | grep -iE "error|fail" | head -10
```

Expected: service `active (running)`, 0 erreur critique dans les logs post-restart.

- [ ] **Step 3.8: Observer parser pendant 15 min — vérifier parsed > 0**

```bash
# Snapshot avant observation
sudo cscli metrics 2>/dev/null | awk '/Parsers/,/^$/' > /tmp/metrics-t0.txt
sleep 900  # 15 min — pendant ce temps, le honeypot :22 capture 20-50 bots en moyenne
sudo cscli metrics 2>/dev/null | awk '/Parsers/,/^$/' > /tmp/metrics-t15.txt
diff /tmp/metrics-t0.txt /tmp/metrics-t15.txt
```

Expected: delta `crowdsecurity/sshd-logs` entre t0 et t15 :
- `hits` augmente (normal — bots arrivent)
- **`parsed` augmente aussi** (avant : stagnait à 2 ; maintenant : croît)
- `unparsed` stable ou faible croissance relative

**Si `parsed` reste à 0 ou quasi-stagnant** : le correctif n'a pas pris. Revenir Step 3.2, autre branche.

- [ ] **Step 3.9: Test déclencheur bucket overflow local (optionnel mais recommandé)**

Depuis une IP jetable (VPS externe, Tor, ou IP whitelist retirée temporairement) :

```bash
# Depuis host externe (ne pas utiliser VPN !) — 10 tentatives SSH échouées sur port 49222
for i in $(seq 1 10); do
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o PubkeyAuthentication=no \
      -o PasswordAuthentication=yes -o NumberOfPasswordPrompts=1 \
      notauser@<IP-VPS-CA-1> -p 49222 2>/dev/null
done
```

Puis sur VPS :
```bash
sudo cscli decisions list --origin crowdsec
sudo cscli alerts list --since 5m
```

Expected: l'IP jetable apparaît dans `decisions list` avec scenario `crowdsecurity/ssh-bf` (brute-force local détecté).

**Note** : ce test est optionnel car il requiert une IP externe non-whitelistée. Si pas faisable, `parsed > 0` au Step 3.8 + bucket instanciés valide l'essentiel.

- [ ] **Step 3.10: Tester — délégation Tester**

Tester vérifie :
- `sudo cscli metrics` → parsed sshd-logs > 0 avec delta croissant sur 15 min
- `sudo cscli collections list` → `crowdsecurity/sshd` ENABLED à jour
- Service `crowdsec` active sans restart depuis correctif
- Diff acquis.yaml pre/post documenté

Rouge : STOP, rollback Step 3.11. Vert : passer Task 4.

- [ ] **Step 3.11: [Rollback si besoin uniquement]**

```bash
sudo cp /etc/crowdsec/acquis.yaml.bak-20260424 /etc/crowdsec/acquis.yaml
sudo crowdsec -c /etc/crowdsec/config.yaml -t
sudo systemctl restart crowdsec
```

Vérifier retour à l'état initial via `cscli metrics`.

---

## Task 4: Review + Audit + Archivage

**Files:**
- Create: rétrospective vault-mem `retrospectives/[RETRO][HOMELAB] VPS CA-1 security 3 patches 2026-04-24.md`
- Modify: `MEMORY.md` (section "Travail en cours 2026-04-24", +1 ligne)
- Modify (si applicable): `INTER-SERVICE-DEPS.md` (msg-relay bind change)
- Commit: homelab-scripts si scripts extraits

**Délégation:** Auditeur (review) puis Archiviste (consolidation).

- [ ] **Step 4.1: Auditeur — review post-3-patches**

Prompt pour Auditeur :
> Revue post-implémentation VPS CA-1 security hardening 3 patches (P1 CrowdSec parser SSH, P2 rkhunter/chkrootkit, P3 msg-relay bind VPN).
> Contexte : audit sécu+forensic 2026-04-24 verdict SAIN, 3 correctifs préventifs appliqués aujourd'hui.
> Spec : `docs/specs/2026-04-24-vps-ca1-security-hardening-3patches.md`
> Plan : `docs/plans/2026-04-24-vps-ca1-security-hardening-3patches.md`
> Valider :
> 1. Chaque patch produit les critères PASS définis dans les tests d'acceptation du spec
> 2. Aucune régression sur services LIVE adjacents (ssh.service, wazuh-agent, endlessh, crowdsec hors SSH parser)
> 3. Rollback paths documentés + backups `.bak-20260424` présents sur VPS
> 4. Pas de secret leaked dans les logs/commits
> 5. Conformité Art.7 (délégation Clouds respectée, Général n'a pas codé) + Art.17 (diagnostic P1 fait avant fix)
> Produire verdict : GO archivage / NOGO (liste actions correctives).

Rouge : appliquer les corrections listées, repasser Auditeur. Vert : Step 4.2.

- [ ] **Step 4.2: Archiviste — consolidation documentaire**

Prompt pour Archiviste :
> Consolidation post-3-patches VPS CA-1 sécu (P1 CrowdSec SSH parser + P2 rkhunter/chkrootkit + P3 msg-relay bind VPN).
> Respecter NOMENCLATURE §10 (section canonique = `retrospectives`, pas `milestones/delivered` car pas de release tagguée).
> Titre strict : `[RETRO][HOMELAB] VPS CA-1 security 3 patches 2026-04-24`
> Contenu attendu :
> - Résumé 50 mots max : motivation, 3 patches, résultat
> - Avant/Après : metrics clés (CrowdSec parsed 2 → N, msg-relay bind 0.0.0.0 → 10.77.0.2, rkhunter absent → installed+baselined)
> - Dettes résiduelles (si faux positifs whitelistés rkhunter, ou tests déclencheur P1 non exécutés)
> - Commits artefacts (spec + plan + scripts éventuels)
> Checklist §10c pré-write : composant LIVE concerné = OUI (CrowdSec, msg-relay), date ISO = OUI, tag processus = OUI ([RETRO][HOMELAB])
> Puis MAJ MEMORY.md : 1 ligne dans "Travail en cours 2026-04-24" (pointeur vers vault-mem retrospective)
> Si msg-relay bind change modifie les dépendances inter-services : MAJ `~/projects/INTER-SERVICE-DEPS.md`
> Commit final dans repo `~` (CLAUDE user space) : `memo(sec): VPS CA-1 3 patches sécu DONE — N2 hardening consolidé`

- [ ] **Step 4.3: Vérifier commits**

```bash
cd ~/projects/homelab-scripts && git log --oneline -5
cd ~ && git log --oneline -5  # repo user MEMORY.md
```

Expected: commits récents présents (spec, plan, retrospective vault-mem, memo MEMORY).

- [ ] **Step 4.4: TaskUpdate — marquer toutes les tasks completed**

Dans la session Général : `TaskUpdate` status=completed pour tasks 1-6.

- [ ] **Step 4.5: Livrable final utilisateur**

Résumé court à Stéphane :
- 3 patches appliqués : statut de chaque
- Régressions : 0 attendu / N détectées par Auditeur
- Dettes résiduelles : liste si présente
- Pointeur retrospective vault-mem

---

## Self-Review (interne, avant exécution)

**1. Spec coverage** :
- Spec §P1 → Task 3 ✓
- Spec §P2 → Task 1 ✓
- Spec §P3 → Task 2 ✓
- Spec §Ordre d'exécution → P2→P3→P1 respecté ✓
- Spec §Pipeline → regression-guard (Task 0) + Clouds délégué + Tester entre tasks + Auditeur/Archiviste (Task 4) ✓
- Spec §Tests d'acceptation → dupliqués dans chaque Task (Steps X.7-X.10) ✓
- Spec §Risques/mitigations → intégrés dans Steps (Gates + Rollback) ✓

**2. Placeholder scan** :
- Aucun "TBD"/"TODO"/"implement later"
- Commandes complètes avec expected output
- Cas conditionnels (Branches A-E Task 3) explicités avec correctif exact pour chacun
- Rollback = commandes concrètes, pas description

**3. Type consistency** :
- Noms de services cohérents : `crowdsec`, `msg-relay`, `ssh.service`, `endlessh`, `wazuh-agent` — même orthographe partout
- IP `10.77.0.2` utilisée partout (avec caveat Step 2.2 si différente)
- Paths backup `.bak-20260424` identiques sur les 3 patches
- Scenarios CrowdSec `crowdsecurity/ssh-bf` cohérent

Plan prêt.

---

## Execution Handoff

Plan complet sauvegardé dans `docs/plans/2026-04-24-vps-ca1-security-hardening-3patches.md`.

**Mode d'exécution suggéré pour ce plan** : **Subagent-Driven** (délégation Clouds par task, Tester entre tasks, Auditeur final).
