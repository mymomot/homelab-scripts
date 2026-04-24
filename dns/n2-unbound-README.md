# N2 Unbound — Documentation de déploiement

Déployé le 2026-04-24. Architecture N2 validée par council Art.15 bis (conditions C1–C6).

## Architecture

```
                    LAN 192.168.10.0/24
                           |
        ┌──────────────────┴──────────────────┐
        │                                     │
   LXC 411 (primary)                   llmcore (secondary)
   192.168.10.11                       192.168.10.118
        │                                     │
   AdGuard :53                          AdGuard :53
   upstream = 127.0.0.1:5335            upstream = 127.0.0.1:5335
   fallback = 8 DoT publics             fallback = 8 DoT publics
        │                                     │
   Unbound :5335 loopback              Unbound :5335 loopback
        │                                     │
   récursion root  ←── sync 5min ───▶  (reçoit config depuis primary)
   QNAME-min strict
   DNSSEC
   cache 64MB/128MB rrset
   serve-expired
        │
   fallback DoT :
     9.9.9.9@853 (Quad9)
     194.242.2.2@853 (Mullvad)
```

**Flux normal** : client → AdGuard :53 → Unbound :5335 → récursion root
**Flux fallback DoT** : si récursion échoue → Unbound forward vers Quad9/Mullvad DoT
**Flux fallback AdGuard** : si Unbound KO → AdGuard bascule sur 8 DoT publics directs

**Sync 5min** : LXC 411 → llmcore (rsync + diff partiel YAML, clé SSH restreinte)

## Prérequis

- AdGuard déjà installé et actif sur la cible
- Accès SSH avec `sudo NOPASSWD` pour l'utilisateur déployeur
- Python 3.9+ sur la machine appelante (LXC 500 ou toute machine LAN)
- Ce repo cloné sur la machine appelante
- Connectivité SSH depuis la machine appelante vers les cibles

## Fichiers dans ce répertoire

| Fichier | Rôle |
|---|---|
| `n2-unbound-deploy-2026-04-24.py` | Script de déploiement unifié (idempotent) |
| `unbound-adguard.conf` | Config Unbound à déployer (`/etc/unbound/unbound.conf.d/adguard.conf`) |
| `unbound-hardening-lxc.conf` | Drop-in systemd hardening pour LXC non-privilégié |
| `unbound-hardening-baremetal.conf` | Drop-in systemd hardening pour bare-metal |
| `adguard-unbound-dep.conf` | Drop-in `Requires=unbound.service` pour AdGuard |
| `adguard-upstream-migrate.py` | Migration YAML AdGuard (upstreams → Unbound + fallback DoT) |
| `adguard-hardening-session1-2026-04-24.py` | Hardening AdGuard initial (session 1) |
| `dns-sync-to-llmcore.sh` | Script sync LXC 411 → llmcore (oneshot, lancé par timer) |
| `dns-sync-timer.service` | Unité systemd oneshot pour la sync |
| `dns-sync-timer.timer` | Timer systemd 5min déclenclant la sync |
| `dns-apply-upstream-sync.py` | Script Python diff partiel YAML (côté llmcore) |
| `n2-unbound-README.md` | Ce fichier |

## Usage — déploiement initial

### Primary (LXC 411)

```bash
cd ~/projects/homelab-scripts/dns

python3 n2-unbound-deploy-2026-04-24.py \
    --host 192.168.10.11 \
    --user motreffs \
    --role primary \
    --dry-run        # simulation d'abord

python3 n2-unbound-deploy-2026-04-24.py \
    --host 192.168.10.11 \
    --user motreffs \
    --role primary   # déploiement réel
```

### Secondary (llmcore)

```bash
python3 n2-unbound-deploy-2026-04-24.py \
    --host 192.168.10.118 \
    --user llmuser \
    --role secondary
```

### Skip AdGuard (Unbound seul)

```bash
python3 n2-unbound-deploy-2026-04-24.py \
    --host 192.168.10.11 \
    --user motreffs \
    --role primary \
    --skip-adguard
```

Le script est idempotent : le relancer sur une machine déjà configurée
affiche `Idempotent: no changes needed` sans modifier quoi que ce soit.

## Déploiement sync (après primary)

Après le déploiement primary, installer la sync 5min sur LXC 411 :

```bash
# Depuis LXC 411 (en tant que root ou via sudo)
sudo cp dns-sync-to-llmcore.sh /usr/local/bin/dns-sync-to-llmcore.sh
sudo chmod 700 /usr/local/bin/dns-sync-to-llmcore.sh
sudo chown root:root /usr/local/bin/dns-sync-to-llmcore.sh

sudo cp dns-sync-timer.service /etc/systemd/system/dns-sync-to-llmcore.service
sudo cp dns-sync-timer.timer /etc/systemd/system/dns-sync-to-llmcore.timer

sudo systemctl daemon-reload
sudo systemctl enable --now dns-sync-to-llmcore.timer

# Déployer le script Python côté llmcore
scp dns-apply-upstream-sync.py llmuser@192.168.10.118:/tmp/
ssh llmuser@192.168.10.118 "sudo install -m 755 /tmp/dns-apply-upstream-sync.py /usr/local/bin/"
```

## Rollback

### Revenir aux upstreams DoT directs (sans Unbound)

```bash
# Sur LXC 411 — restaurer le backup YAML créé automatiquement
ssh motreffs@192.168.10.11 \
  "sudo ls /root/AdGuardHome/AdGuardHome.yaml.bak-* | sort -r | head -1"
# copier le backup vers le YAML actif
ssh motreffs@192.168.10.11 \
  "BACKUP=\$(sudo ls /root/AdGuardHome/AdGuardHome.yaml.bak-* | sort -r | head -1) && \
   sudo cp \"\$BACKUP\" /root/AdGuardHome/AdGuardHome.yaml && \
   sudo systemctl reload-or-restart AdGuardHome"
```

### Désactiver Unbound (sans le supprimer)

```bash
ssh motreffs@192.168.10.11 "sudo systemctl stop unbound && sudo systemctl disable unbound"
```

### Désinstaller Unbound

```bash
ssh motreffs@192.168.10.11 "sudo apt-get remove -y unbound"
```

## Runbook hebdomadaire

Commandes de vérification (depuis LXC 500) :

```bash
# État services
ssh motreffs@192.168.10.11 "sudo systemctl status unbound AdGuardHome --no-pager"
ssh llmuser@192.168.10.118 "sudo systemctl status unbound AdGuardHome --no-pager"

# Résolution Unbound loopback
ssh motreffs@192.168.10.11 "dig @127.0.0.1 -p 5335 debian.org +short"
ssh llmuser@192.168.10.118 "dig @127.0.0.1 -p 5335 debian.org +short"

# Résolution AdGuard :53
dig @192.168.10.11 forgejo.lab.mymomot.ovh +short
dig @192.168.10.118 forgejo.lab.mymomot.ovh +short

# Statistiques Unbound (depuis LXC 411)
ssh motreffs@192.168.10.11 "sudo unbound-control stats_noreset | grep -E 'queries|cache|recursion'"

# Timer sync
ssh motreffs@192.168.10.11 "sudo systemctl status dns-sync-to-llmcore.timer --no-pager"

# Bilan hebdomadaire complet
~/scripts/dns-weekly-checkup.sh
```

## Limitations connues

- **LXC hardening** : score systemd-analyze security ~6.3 sur LXC 411 (namespaces mount
  indisponibles en LXC non-privilégié). Bare-metal llmcore : ~6.8 avec namespaces activés.
- **Latence récursion cold** : ~135ms avg juste après un redémarrage d'Unbound (cold DoT
  vers Quad9/Mullvad). Se résorbe en <15min au fil du warmup du cache. Le monitoring
  `dns-deep-health.sh` applique un seuil élargi (2000ms) pendant les 15 premières minutes.
- **Config Unbound** : une seule zone forward (`.`) vers Quad9 + Mullvad DoT en fallback.
  Pas de forward-zone par domaine (homelab simple). Les réponses root arrivent via récursion
  native quand `forward-first: yes` et que les forwarders ne répondent pas.
- **Versions** : Unbound 1.22.0 (LXC 411, Debian bookworm-backports) + 1.19.2 (llmcore,
  Ubuntu 24.04). Fonctionnellement identiques pour N2.
- **Sync YAML diff partiel** : `dns-apply-upstream-sync.py` utilise des regex YAML.
  Fonctionne sur la structure AdGuard 0.107+. Un changement de format majeur AdGuard
  peut casser le parsing — vérifier après upgrade AdGuard.

## Références

- Council Art.15 bis N2 Unbound — vault-mem `decisions/Arbitrage Stéphane N2 Unbound 2026-04-24`
- Architecture homelab DNS — `memory/infra-lan-services.md`
- Monitoring DNS — `~/scripts/dns-deep-health.sh` + `dns-weekly-checkup.sh`
- Hardening AdGuard initial — `adguard-hardening-session1-2026-04-24.py`
