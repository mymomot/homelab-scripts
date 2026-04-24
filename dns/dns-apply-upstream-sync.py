#!/usr/bin/env python3
"""
dns-apply-upstream-sync.py
Applique les sections DNS (upstream_dns, fallback_dns, upstream_mode,
fastest_timeout, bootstrap_dns, enable_dnssec) depuis un YAML source (LXC 411)
vers le YAML destination (llmcore), sans toucher aux sections réseau
(bind_host, bind_port, http_proxy, users, tls, etc.).

Ce script est idempotent : relancer 10 fois sans changement source/dest
ne modifie pas le fichier destination.

Usage:
    python3 dns-apply-upstream-sync.py <source.yaml> <dest.yaml>

Déployer sur : llmcore (secondary AdGuard)
Chemin cible : /usr/local/bin/dns-apply-upstream-sync.py (chmod 755, owned root)

Invoqué par : dns-sync-to-llmcore.sh (depuis LXC 411 via SSH)
"""
import sys
import re

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <source.yaml> <dest.yaml>")
    sys.exit(1)

SRC_PATH = sys.argv[1]
DST_PATH = sys.argv[2]

# Sections à synchroniser (sous dns_config dans AdGuard >= 0.107)
# Ces clés sont relatives au YAML AdGuard (sous-section dns)
SYNC_KEYS = [
    "upstream_dns",
    "fallback_dns",
    "bootstrap_dns",
    "upstream_mode",
    "fastest_timeout",
    "enable_dnssec",
    "aaaa_disabled",
    "cache_enabled",
    "cache_size",
    "cache_ttl_min",
    "cache_ttl_max",
    "cache_optimistic",
    "cache_optimistic_answer_ttl",
    "cache_optimistic_max_age",
]


def extract_block(content: str, key: str) -> str | None:
    """Extrait le bloc YAML (clé + valeurs) depuis le contenu."""
    # Bloc liste
    list_pattern = rf"(  {re.escape(key)}:\n(?:    - [^\n]*\n)*)"
    m = re.search(list_pattern, content)
    if m:
        return m.group(0)
    # Valeur scalaire
    scalar_pattern = rf"  {re.escape(key)}: [^\n]*\n"
    m = re.search(scalar_pattern, content)
    if m:
        return m.group(0)
    # Liste vide
    empty_pattern = rf"  {re.escape(key)}: \[\]\n"
    m = re.search(empty_pattern, content)
    if m:
        return m.group(0)
    return None


def replace_block(content: str, key: str, new_block: str) -> tuple[str, bool]:
    """Remplace le bloc d'une clé dans le contenu destination."""
    # Bloc liste
    list_pattern = rf"  {re.escape(key)}:\n(?:    - [^\n]*\n)*"
    m = re.search(list_pattern, content)
    if m:
        if content[m.start():m.end()] == new_block:
            return content, False
        result = content[:m.start()] + new_block + content[m.end():]
        return result, True
    # Valeur scalaire
    scalar_pattern = rf"  {re.escape(key)}: [^\n]*\n"
    m = re.search(scalar_pattern, content)
    if m:
        if content[m.start():m.end()] == new_block:
            return content, False
        result = content[:m.start()] + new_block + content[m.end():]
        return result, True
    # Liste vide -> bloc liste
    empty_pattern = rf"  {re.escape(key)}: \[\]\n"
    m = re.search(empty_pattern, content)
    if m:
        result = content[:m.start()] + new_block + content[m.end():]
        return result, True
    return content, False


def main() -> None:
    with open(SRC_PATH, "r") as f:
        src = f.read()
    with open(DST_PATH, "r") as f:
        dst = f.read()

    changed = False
    for key in SYNC_KEYS:
        src_block = extract_block(src, key)
        if src_block is None:
            print(f"SKIP {key}: absent dans source")
            continue
        dst_new, mod = replace_block(dst, key, src_block)
        if mod:
            print(f"SYNC {key}: mis a jour")
            dst = dst_new
            changed = True
        else:
            print(f"OK   {key}: deja a jour")

    if not changed:
        print("Aucune modification necessaire.")
        sys.exit(0)

    with open(DST_PATH, "w") as f:
        f.write(dst)
    print("YAML destination ecrit avec succes.")


if __name__ == "__main__":
    main()
