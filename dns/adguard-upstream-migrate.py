#!/usr/bin/env python3
"""
adguard-upstream-migrate.py
Migration idempotente du YAML AdGuardHome pour le déploiement N2 Unbound :
  upstream_dns : [16 upstreams DoT] → [127.0.0.1:5335]
  fallback_dns : [...] → [8 DoT publics Quad9 + Mullvad]

Idempotent : relancer 10 fois sans side-effect.
Fait un backup YAML horodaté avant toute écriture.

Usage :
    python3 adguard-upstream-migrate.py [--yaml CHEMIN] [--role primary|secondary]
                                        [--dry-run]

Defaults :
    --yaml    /root/AdGuardHome/AdGuardHome.yaml (LXC 411)
              /opt/AdGuardHome/AdGuardHome.yaml  (llmcore)
    --role    primary (affecte uniquement le message log, pas le comportement)
    --dry-run Affiche les modifications sans écrire

Prérequis : AdGuardHome installé, fichier YAML présent.
"""
import argparse
import datetime
import re
import shutil
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Constantes cibles
# ---------------------------------------------------------------------------
# Upstream unique : Unbound loopback
UPSTREAM_DNS_TARGET = "  upstream_dns:\n    - 127.0.0.1:5335\n"

# Fallback : 8 DoT si Unbound KO
FALLBACK_DNS_TARGET = (
    "  fallback_dns:\n"
    "    - tls://9.9.9.9\n"
    "    - tls://149.112.112.112\n"
    "    - tls://194.242.2.2\n"
    "    - tls://194.242.2.3\n"
    "    - tls://45.90.28.0\n"
    "    - tls://45.90.30.0\n"
    "    - tls://194.242.2.9\n"
    "    - tls://194.242.2.10\n"
)

SYNC_KEYS_TARGET: dict[str, str] = {
    "upstream_dns": UPSTREAM_DNS_TARGET,
    "fallback_dns": FALLBACK_DNS_TARGET,
}


# ---------------------------------------------------------------------------
# Parsing regex (identique à dns-apply-upstream-sync.py pour cohérence)
# ---------------------------------------------------------------------------
def extract_block(content: str, key: str) -> str | None:
    """Extrait le bloc YAML d'une clé depuis le contenu."""
    list_pattern = rf"(  {re.escape(key)}:\n(?:    - [^\n]*\n)*)"
    m = re.search(list_pattern, content)
    if m:
        return m.group(0)
    scalar_pattern = rf"  {re.escape(key)}: [^\n]*\n"
    m = re.search(scalar_pattern, content)
    if m:
        return m.group(0)
    empty_pattern = rf"  {re.escape(key)}: \[\]\n"
    m = re.search(empty_pattern, content)
    if m:
        return m.group(0)
    return None


def replace_block(content: str, key: str, new_block: str) -> tuple[str, bool]:
    """Remplace le bloc d'une clé. Retourne (contenu_mis_a_jour, modifié)."""
    list_pattern = rf"  {re.escape(key)}:\n(?:    - [^\n]*\n)*"
    m = re.search(list_pattern, content)
    if m:
        if content[m.start():m.end()] == new_block:
            return content, False
        return content[:m.start()] + new_block + content[m.end():], True
    scalar_pattern = rf"  {re.escape(key)}: [^\n]*\n"
    m = re.search(scalar_pattern, content)
    if m:
        if content[m.start():m.end()] == new_block:
            return content, False
        return content[:m.start()] + new_block + content[m.end():], True
    empty_pattern = rf"  {re.escape(key)}: \[\]\n"
    m = re.search(empty_pattern, content)
    if m:
        return content[:m.start()] + new_block + content[m.end():], True
    return content, False


# ---------------------------------------------------------------------------
# Backup horodaté
# ---------------------------------------------------------------------------
def backup_yaml(path: Path) -> Path:
    """Copie le YAML original avec suffixe horodaté. Retourne le chemin backup."""
    ts = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    backup_path = path.with_suffix(f".yaml.bak-{ts}")
    shutil.copy2(path, backup_path)
    return backup_path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Migre AdGuardHome.yaml pour N2 Unbound (idempotent).",
    )
    parser.add_argument(
        "--yaml",
        default=None,
        help="Chemin vers AdGuardHome.yaml (auto-détecté si absent)",
    )
    parser.add_argument(
        "--role",
        choices=["primary", "secondary"],
        default="primary",
        help="Rôle de la machine (primary=LXC 411, secondary=llmcore)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Affiche les modifications sans écrire",
    )
    return parser.parse_args()


def resolve_yaml_path(explicit: str | None, role: str) -> Path:
    """Résout le chemin YAML selon le rôle si non spécifié."""
    if explicit:
        return Path(explicit)
    candidates = [
        Path("/root/AdGuardHome/AdGuardHome.yaml"),   # LXC 411 primary
        Path("/opt/AdGuardHome/AdGuardHome.yaml"),    # llmcore secondary
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    print("ERREUR: Impossible de localiser AdGuardHome.yaml.", file=sys.stderr)
    print("  Passer --yaml CHEMIN explicitement.", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    args = parse_args()
    yaml_path = resolve_yaml_path(args.yaml, args.role)

    print(f"=== adguard-upstream-migrate.py (role={args.role}) ===")
    print(f"Fichier : {yaml_path}")
    if args.dry_run:
        print("Mode : DRY-RUN (aucune écriture)")

    if not yaml_path.exists():
        print(f"ERREUR: {yaml_path} introuvable.", file=sys.stderr)
        sys.exit(1)

    content = yaml_path.read_text()
    changed = False
    any_modification = False

    for key, target_block in SYNC_KEYS_TARGET.items():
        current_block = extract_block(content, key)
        if current_block is None:
            print(f"SKIP {key}: clé absente du YAML (structure inattendue)")
            continue

        if current_block == target_block:
            print(f"OK   {key}: déjà à jour — idempotent, aucun changement")
            continue

        print(f"DIFF {key}:")
        print(f"  Avant : {repr(current_block[:80])}...")
        print(f"  Apres : {repr(target_block[:80])}...")

        if not args.dry_run:
            content, changed = replace_block(content, key, target_block)
            if changed:
                any_modification = True
                print(f"SYNC {key}: remplacé")
        else:
            print(f"DRY-RUN {key}: serait remplacé")

    if args.dry_run:
        print("\nDRY-RUN terminé — aucune écriture effectuée.")
        return

    if not any_modification:
        print("\nIdempotent: no changes needed")
        return

    # Backup avant écriture
    backup_path = backup_yaml(yaml_path)
    print(f"\nBackup créé : {backup_path}")

    yaml_path.write_text(content)
    print(f"YAML écrit : {yaml_path}")
    print("\nPost-migration : relancer AdGuardHome pour appliquer.")
    print("  systemctl reload-or-restart AdGuardHome")


if __name__ == "__main__":
    main()
