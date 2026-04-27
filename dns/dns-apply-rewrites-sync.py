#!/usr/bin/env python3
"""
dns-apply-rewrites-sync.py
Synchronise filtering.rewrites depuis un YAML source (LXC 411) vers un
YAML destination (llmcore), sans toucher à aucune autre section.

Script séparé de dns-apply-upstream-sync.py par conception (KISS) :
- Le script upstream/fallback/cache reste intact et fonctionnel.
- rewrites est sous filtering: (section top-level différente de dns:)
  avec items multi-lignes (- domain / answer / enabled) non gérés par
  le script existant.

Comportement :
- Idempotent : relancer sans changement source/dest ne modifie rien.
- Compare le bloc rewrites en entier (contenu exact, items dans l'ordre).
- Si différent : remplace le bloc dest + redémarre AdGuardHome.
- Si identique : exit 0, aucune écriture.

Usage :
    python3 dns-apply-rewrites-sync.py <source.yaml> <dest.yaml>

Déployer sur : llmcore (secondary AdGuard)
Chemin cible : /usr/local/bin/dns-apply-rewrites-sync.py (chmod 755, owned root)
Invoqué par  : dns-sync-rewrites-to-llmcore.sh (depuis LXC 411 via SSH)
"""
import re
import sys

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <source.yaml> <dest.yaml>")
    sys.exit(1)

SRC_PATH = sys.argv[1]
DST_PATH = sys.argv[2]


def extract_rewrites_block(content: str) -> str | None:
    """
    Extrait le bloc filtering.rewrites depuis le contenu YAML AdGuard.

    Structure attendue (2 espaces d'indent sous filtering:, items à 4) :
        filtering:
          ...
          rewrites:
            - domain: foo
              answer: bar
              enabled: true
            - domain: baz
              ...
          safe_fs_patterns:  (ou toute autre clé à 2 espaces = fin du bloc)

    Retourne le bloc entier y compris la ligne "  rewrites:\\n" initiale,
    ou None si la clé est absente.
    """
    # Correspondance : "  rewrites:\n" suivi de lignes à 4+ espaces ou lignes
    # contenant uniquement des espaces (lignes vides intra-bloc).
    # On s'arrête dès qu'une ligne commence par 2 espaces + caractère non-espace
    # (= nouvelle clé à même niveau) OU par un caractère non-espace (= section
    # top-level) OU par "  rewrites:" lui-même (garde-fou).
    pattern = r"(  rewrites:\n(?:(?:    [^\n]*|)\n)*)"
    m = re.search(pattern, content)
    if m:
        return m.group(0)
    # Cas rewrites vide : "  rewrites: []\n"
    empty_pattern = r"  rewrites: \[\]\n"
    m = re.search(empty_pattern, content)
    if m:
        return m.group(0)
    return None


def replace_rewrites_block(content: str, new_block: str) -> tuple[str, bool]:
    """
    Remplace le bloc rewrites existant dans content par new_block.
    Retourne (nouveau_contenu, modifié).
    """
    pattern = r"  rewrites:\n(?:(?:    [^\n]*|)\n)*"
    m = re.search(pattern, content)
    if m:
        existing = content[m.start():m.end()]
        if existing == new_block:
            return content, False
        return content[:m.start()] + new_block + content[m.end():], True
    # Cas rewrites vide
    empty_pattern = r"  rewrites: \[\]\n"
    m = re.search(empty_pattern, content)
    if m:
        return content[:m.start()] + new_block + content[m.end():], True
    return content, False


def main() -> None:
    with open(SRC_PATH, "r") as f:
        src = f.read()
    with open(DST_PATH, "r") as f:
        dst = f.read()

    src_block = extract_rewrites_block(src)
    if src_block is None:
        print("SKIP rewrites: absent dans source")
        sys.exit(0)

    dst_new, modified = replace_rewrites_block(dst, src_block)
    if not modified:
        print("OK   rewrites: deja a jour")
        sys.exit(0)

    # Backup implicite : le script appelant (dns-sync-rewrites-to-llmcore.sh)
    # passe par /tmp/ — le fichier dest original n'est pas le /tmp intermédiaire
    # mais le YAML AdGuard réel. L'appelant est responsable du backup si désiré.
    with open(DST_PATH, "w") as f:
        f.write(dst_new)
    print("SYNC rewrites: mis a jour — YAML destination ecrit avec succes.")


if __name__ == "__main__":
    main()
