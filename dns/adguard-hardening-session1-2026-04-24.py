#!/usr/bin/env python3
"""
adguard-hardening-session1-2026-04-24.py
=========================================
Date    : 2026-04-24
Auteur  : Jarvis (ZeroClaw) — Session 1 Hardening AdGuard LXC 411
Contexte: Hardening DNS AdGuardHome sur LXC 411 (192.168.10.11).
          Script idempotent : ré-exécutable sans effet si déjà appliqué.
          Ne relancer qu'en cas de restauration d'une config vanilla.

6 modifications appliquées (M1→M6)
------------------------------------
M1 — upstream_dns        : remplace la liste par 24 resolvers multi-régions
                           (Google, Cloudflare, Quad9, FDN, Mullvad, DNS.SB,
                            DNS.Watch, Telsy, Twnic, Alibaba, Yandex)
M2 — upstream_mode       : parallel → fastest_addr
                           (sélection du resolver le plus rapide)
M3 — cache_ttl_max       : 60 → 3600 (réduire les re-résolutions)
M4 — cache_size          : 4194304 (4 MB) → 67108864 (64 MB)
M5 — enable_dnssec       : false → true
M6 — upstream_timeout    : 3s → 5s (ou insertion si champ absent)

Méthode de rechargement
------------------------
AdGuardHome se recharge via signal SIGHUP après écriture du fichier :
    kill -HUP $(pgrep AdGuardHome)
Ce script N'envoie PAS SIGHUP — rechargement manuel ou systemd restart.

Revert
-------
Un backup est créé automatiquement avant écriture :
    /root/AdGuardHome/AdGuardHome.yaml.bak-<timestamp>
Pour revenir : cp /root/AdGuardHome/AdGuardHome.yaml.bak-<timestamp> \\
                   /root/AdGuardHome/AdGuardHome.yaml
"""

import re
import sys
import shutil
from datetime import datetime

YAML_PATH = "/root/AdGuardHome/AdGuardHome.yaml"

# ── Lecture ───────────────────────────────────────────────────────────────────
try:
    with open(YAML_PATH, "r") as f:
        content = f.read()
except FileNotFoundError:
    print(f"ERREUR : {YAML_PATH} introuvable")
    sys.exit(1)

original = content
modified = False

# ── M1 : upstream_dns (bloc liste YAML) ──────────────────────────────────────
NEW_UPSTREAM_IPS = [
    "8.8.8.8", "8.8.4.4",          # Google
    "1.1.1.1", "1.0.0.1",          # Cloudflare
    "149.112.121.10", "149.112.122.10",  # Quad9 ECS
    "9.9.9.9", "149.112.112.112",   # Quad9
    "80.67.169.12", "80.67.169.40", # FDN (France)
    "194.242.2.2", "194.242.2.3",   # Mullvad
    "84.200.69.80", "84.200.70.40", # DNS.Watch
    "5.11.11.5", "5.11.11.11",      # Telsy
    "101.101.101.101", "101.102.103.104",  # Twnic (TW)
    "223.5.5.5", "223.6.6.6",       # Alibaba
    "77.88.8.8", "77.88.8.1",       # Yandex
    "95.85.95.85", "2.56.220.2",    # DNS.SB
]

NEW_UPSTREAM = "  upstream_dns:\n" + "".join(
    f"    - {ip}\n" for ip in NEW_UPSTREAM_IPS
)

pattern_upstream = r'  upstream_dns:\n(?:    - [^\n]+\n)+'
match = re.search(pattern_upstream, content)
if not match:
    print("ERREUR M1 : bloc upstream_dns non trouvé")
    sys.exit(1)

current_ips = re.findall(r'    - ([^\n]+)', match.group())
target_ips = NEW_UPSTREAM_IPS
if set(current_ips) == set(target_ips) and len(current_ips) == len(target_ips):
    print(f"M1 SKIP : upstream_dns déjà configuré ({len(current_ips)} IPs)")
else:
    content = content[:match.start()] + NEW_UPSTREAM + content[match.end():]
    print(f"M1 OK : upstream_dns remplacé ({len(current_ips)} IPs → {len(target_ips)} IPs)")
    modified = True

# ── M2 : upstream_mode parallel → fastest_addr ───────────────────────────────
OLD_MODE = "  upstream_mode: parallel"
NEW_MODE = "  upstream_mode: fastest_addr"
if NEW_MODE in content:
    print("M2 SKIP : upstream_mode déjà fastest_addr")
elif OLD_MODE in content:
    content = content.replace(OLD_MODE, NEW_MODE, 1)
    print("M2 OK : upstream_mode: parallel → fastest_addr")
    modified = True
else:
    print("ERREUR M2 : upstream_mode: parallel non trouvé et fastest_addr absent")
    sys.exit(1)

# ── M3 : cache_ttl_max 60 → 3600 ─────────────────────────────────────────────
OLD_TTL = "  cache_ttl_max: 60"
NEW_TTL = "  cache_ttl_max: 3600"
if NEW_TTL in content:
    print("M3 SKIP : cache_ttl_max déjà 3600")
elif OLD_TTL in content:
    content = content.replace(OLD_TTL, NEW_TTL, 1)
    print("M3 OK : cache_ttl_max: 60 → 3600")
    modified = True
else:
    print("ERREUR M3 : cache_ttl_max: 60 non trouvé et 3600 absent")
    sys.exit(1)

# ── M4 : cache_size 4194304 → 67108864 (64 MB) ───────────────────────────────
OLD_CACHE = "  cache_size: 4194304"
NEW_CACHE = "  cache_size: 67108864"
if NEW_CACHE in content:
    print("M4 SKIP : cache_size déjà 67108864")
elif OLD_CACHE in content:
    content = content.replace(OLD_CACHE, NEW_CACHE, 1)
    print("M4 OK : cache_size: 4194304 → 67108864")
    modified = True
else:
    print("ERREUR M4 : cache_size: 4194304 non trouvé et 67108864 absent")
    sys.exit(1)

# ── M5 : enable_dnssec false → true ──────────────────────────────────────────
OLD_DNSSEC = "  enable_dnssec: false"
NEW_DNSSEC = "  enable_dnssec: true"
if NEW_DNSSEC in content:
    print("M5 SKIP : enable_dnssec déjà true")
elif OLD_DNSSEC in content:
    content = content.replace(OLD_DNSSEC, NEW_DNSSEC, 1)
    print("M5 OK : enable_dnssec: false → true")
    modified = True
else:
    print("ERREUR M5 : enable_dnssec: false non trouvé et true absent")
    sys.exit(1)

# ── M6 : upstream_timeout 3s → 5s (ou insertion) ─────────────────────────────
OLD_TIMEOUT = "  upstream_timeout: 3s"
NEW_TIMEOUT = "  upstream_timeout: 5s"
if NEW_TIMEOUT in content:
    print("M6 SKIP : upstream_timeout déjà 5s")
elif OLD_TIMEOUT in content:
    content = content.replace(OLD_TIMEOUT, NEW_TIMEOUT, 1)
    print("M6 OK : upstream_timeout: 3s → 5s")
    modified = True
elif "  upstream_mode: fastest_addr" in content:
    content = content.replace(
        "  upstream_mode: fastest_addr\n",
        "  upstream_mode: fastest_addr\n  upstream_timeout: 5s\n",
        1
    )
    print("M6 OK : upstream_timeout: 5s inséré (champ absent)")
    modified = True
else:
    print("ERREUR M6 : impossible d'insérer upstream_timeout")
    sys.exit(1)

# ── Vérification private_networks non touché ──────────────────────────────────
if "  private_networks: []" in content:
    print("CHECK private_networks : [] conservé OK")
else:
    print("AVERTISSEMENT : private_networks a peut-être changé — vérifier manuellement")

# ── Écriture avec backup ──────────────────────────────────────────────────────
if not modified:
    print("\nRÉSULTAT : toutes les modifications sont déjà appliquées — fichier inchangé.")
    sys.exit(0)

ts = datetime.now().strftime("%Y%m%dT%H%M%S")
backup_path = f"{YAML_PATH}.bak-{ts}"
shutil.copy2(YAML_PATH, backup_path)
print(f"Backup créé : {backup_path}")

with open(YAML_PATH, "w") as f:
    f.write(content)

print("\nRÉSULTAT : fichier écrit OK")
print("ACTION REQUISE : recharger AdGuardHome (SIGHUP ou systemctl restart adguardhome)")
