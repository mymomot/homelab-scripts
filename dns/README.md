# dns/

Scripts de configuration et hardening DNS pour le homelab.

## Scripts disponibles

| Script | Cible | Description |
|--------|-------|-------------|
| `adguard-hardening-session1-2026-04-24.py` | LXC 411 (192.168.10.11) | Hardening AdGuard Home Session 1 |

## adguard-hardening-session1-2026-04-24.py

**Prérequis** :
- SSH vers LXC 411 (`motreffs@192.168.10.11`, sudo NOPASSWD)
- Python 3.11+ sur la machine d'exécution
- AdGuard Home config : `/etc/adguardhome/AdGuardHome.yaml`

**Exécution** :
```bash
python3 dns/adguard-hardening-session1-2026-04-24.py
```

**Modifications appliquées (M1→M6)** :
- M1 : upstream_dns — 16 resolvers multi-régions (8 DoT + 8 clair)
- M2 : upstream_mode — parallel → fastest_addr
- M3 : cache_ttl_max — 60 → 3600
- M4 : cache_size — 4 MB → 64 MB
- M5 : enable_dnssec — false → true
- M6 : upstream_timeout — 3 s → 5 s

**Revert** : backup horodaté créé automatiquement en `/etc/adguardhome/AdGuardHome.yaml.backup.<timestamp>`

**Note** : Le script n'envoie pas SIGHUP — redémarrage manuel requis après exécution :
```bash
ssh motreffs@192.168.10.11 "sudo systemctl restart adguardhome"
```
