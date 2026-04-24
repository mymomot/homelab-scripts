#!/usr/bin/env python3
"""
n2-unbound-deploy-2026-04-24.py
Déploiement idempotent de N2 Unbound sur une machine cible (primary ou secondary).

Architecture N2 :
    AdGuard → Unbound :5335 loopback → récursion root (QNAME-min strict + DNSSEC)
    Fallback AdGuard : 8 DoT publics (Quad9 + Mullvad) si Unbound KO
    2 instances symétriques : LXC 411 (primary) + llmcore (secondary)
    Sync 5min : dns-sync-to-llmcore.sh (LXC 411 → llmcore)

Usage :
    python3 n2-unbound-deploy-2026-04-24.py \\
        --host 192.168.10.11 --user motreffs --role primary

    python3 n2-unbound-deploy-2026-04-24.py \\
        --host 192.168.10.118 --user llmuser --role secondary

    python3 n2-unbound-deploy-2026-04-24.py \\
        --host 192.168.10.11 --user motreffs --role primary --dry-run

    python3 n2-unbound-deploy-2026-04-24.py \\
        --host 192.168.10.11 --user motreffs --role primary --skip-adguard

Prérequis :
    - Accès SSH avec sudo NOPASSWD sur la cible
    - AdGuard déjà installé et actif sur la cible (sauf --skip-adguard)
    - Python 3.9+ sur la machine appelante
    - Ce repo cloné localement (les fichiers conf sont lus depuis ./dns/)

Idempotent : rejouable 10 fois sans side-effect.
Logs : stdout structuré. Exit 0 = OK, 1 = FAIL.
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).parent

# Fichiers config embarqués dans ce repo
UNBOUND_CONF_SRC = SCRIPT_DIR / "unbound-adguard.conf"
HARDENING_LXC_SRC = SCRIPT_DIR / "unbound-hardening-lxc.conf"
HARDENING_BM_SRC = SCRIPT_DIR / "unbound-hardening-baremetal.conf"
ADGUARD_DEP_SRC = SCRIPT_DIR / "adguard-unbound-dep.conf"
ADGUARD_MIGRATE_SRC = SCRIPT_DIR / "adguard-upstream-migrate.py"

# Chemins cibles selon rôle
ADGUARD_PATHS = {
    "primary": "/root/AdGuardHome/AdGuardHome.yaml",
    "secondary": "/opt/AdGuardHome/AdGuardHome.yaml",
}

ADGUARD_SERVICE_DIRS = {
    "primary": "/etc/systemd/system/AdGuardHome.service.d",
    "secondary": "/etc/systemd/system/AdGuardHome.service.d",
}

# Timeouts SSH
SSH_CONNECT_TIMEOUT = 15
SSH_CMD_TIMEOUT = 120

# Nombre de health checks post-déploiement
HEALTH_CHECKS_COUNT = 10
HEALTH_EXTERNAL_HOST = "debian.org"
HEALTH_CHECK_PORT = 5335


# ---------------------------------------------------------------------------
# Parsing arguments
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Déploie Unbound N2 sur une machine cible (idempotent).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage :")[0].strip(),
    )
    parser.add_argument("--host", required=True, help="IP ou hostname cible")
    parser.add_argument(
        "--user",
        required=True,
        help="Utilisateur SSH (doit avoir sudo NOPASSWD)",
    )
    parser.add_argument(
        "--role",
        required=True,
        choices=["primary", "secondary"],
        help="primary=LXC 411 (LXC non-privilégié) | secondary=llmcore (bare-metal)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulation : ne modifie rien sur la cible",
    )
    parser.add_argument(
        "--skip-adguard",
        action="store_true",
        help="Saute la configuration AdGuard (Unbound seul)",
    )
    parser.add_argument(
        "--ssh-key",
        default=None,
        help="Clé SSH privée (optionnel, utilise la config SSH par défaut si absent)",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------
class SSHRunner:
    """Exécute des commandes SSH sur la cible. Loggue chaque étape."""

    def __init__(
        self,
        host: str,
        user: str,
        dry_run: bool = False,
        ssh_key: str | None = None,
    ) -> None:
        self.host = host
        self.user = user
        self.dry_run = dry_run
        self.target = f"{user}@{host}"
        self.ssh_base = [
            "ssh",
            "-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT}",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
        ]
        if ssh_key:
            self.ssh_base += ["-i", ssh_key]

    def run(
        self,
        cmd: str,
        check: bool = True,
        timeout: int = SSH_CMD_TIMEOUT,
        label: str = "",
    ) -> subprocess.CompletedProcess:
        """Exécute cmd sur la cible via SSH."""
        if label:
            print(f"  [{label}] {cmd[:100]}{'...' if len(cmd) > 100 else ''}")
        if self.dry_run:
            print(f"  DRY-RUN: {cmd}")
            return subprocess.CompletedProcess([], 0, stdout="", stderr="")
        result = subprocess.run(
            self.ssh_base + [self.target, cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.stdout.strip():
            for line in result.stdout.strip().splitlines():
                print(f"    {line}")
        if result.stderr.strip():
            for line in result.stderr.strip().splitlines():
                print(f"    STDERR: {line}")
        if check and result.returncode != 0:
            print(f"  ERREUR (code {result.returncode})", file=sys.stderr)
            raise RuntimeError(
                f"Commande SSH échouée (code={result.returncode}): {cmd[:80]}"
            )
        return result

    def upload(self, local_path: Path, remote_path: str) -> None:
        """Upload un fichier local vers la cible via scp."""
        print(f"  [upload] {local_path.name} → {self.target}:{remote_path}")
        if self.dry_run:
            print(f"  DRY-RUN: scp {local_path} {self.target}:{remote_path}")
            return
        scp_cmd = ["scp"]
        if self.ssh_key_flag():
            scp_cmd += self.ssh_key_flag()
        scp_cmd += [
            "-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT}",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            str(local_path),
            f"{self.target}:{remote_path}",
        ]
        result = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            raise RuntimeError(
                f"SCP échoué pour {local_path.name}: {result.stderr}"
            )

    def ssh_key_flag(self) -> list[str]:
        """Retourne le flag -i si une clé est configurée."""
        for i, part in enumerate(self.ssh_base):
            if part == "-i" and i + 1 < len(self.ssh_base):
                return ["-i", self.ssh_base[i + 1]]
        return []


# ---------------------------------------------------------------------------
# Étapes de déploiement
# ---------------------------------------------------------------------------
def step_check_prereqs(ssh: SSHRunner) -> None:
    """Vérifie que les prérequis sont présents sur la cible."""
    print("\n[1/6] Vérification prérequis...")
    ssh.run("which apt-get > /dev/null", label="apt-get disponible")
    ssh.run("sudo -n true", label="sudo NOPASSWD")
    result = ssh.run("uname -r", label="kernel", check=False)
    print(f"    kernel: {result.stdout.strip()}")


def step_install_unbound(ssh: SSHRunner) -> None:
    """Installe Unbound si absent."""
    print("\n[2/6] Installation Unbound...")
    result = ssh.run(
        "dpkg -l unbound 2>/dev/null | grep -q '^ii' && echo INSTALLED || echo ABSENT",
        label="statut paquet",
        check=False,
    )
    if "INSTALLED" in result.stdout:
        print("    Unbound déjà installé — SKIP install")
    else:
        print("    Installation apt...")
        ssh.run(
            "sudo apt-get update -qq && sudo apt-get install -y unbound",
            label="apt install",
            timeout=300,
        )


def step_deploy_unbound_config(ssh: SSHRunner, role: str) -> None:
    """Déploie la config Unbound et le hardening systemd."""
    print("\n[3/6] Déploiement config Unbound...")

    # Vérifier que les fichiers sources existent
    if not UNBOUND_CONF_SRC.exists():
        raise FileNotFoundError(f"Fichier source absent : {UNBOUND_CONF_SRC}")

    hardening_src = (
        HARDENING_LXC_SRC if role == "primary" else HARDENING_BM_SRC
    )
    if not hardening_src.exists():
        raise FileNotFoundError(f"Fichier source absent : {hardening_src}")

    # Upload vers /tmp puis déplacer avec install (préserve les permissions)
    ssh.upload(UNBOUND_CONF_SRC, "/tmp/n2-unbound-adguard.conf")
    ssh.run(
        "sudo install -D -m 644 -o root -g root "
        "/tmp/n2-unbound-adguard.conf "
        "/etc/unbound/unbound.conf.d/adguard.conf && "
        "rm -f /tmp/n2-unbound-adguard.conf",
        label="install unbound conf",
    )

    # Drop-in hardening systemd
    ssh.run(
        "sudo mkdir -p /etc/systemd/system/unbound.service.d",
        label="mkdir hardening.d",
    )
    ssh.upload(hardening_src, "/tmp/n2-unbound-hardening.conf")
    ssh.run(
        "sudo install -m 644 -o root -g root "
        "/tmp/n2-unbound-hardening.conf "
        "/etc/systemd/system/unbound.service.d/hardening.conf && "
        "rm -f /tmp/n2-unbound-hardening.conf",
        label="install hardening drop-in",
    )

    # Validation config avant redémarrage
    ssh.run(
        "sudo /usr/sbin/unbound-checkconf /etc/unbound/unbound.conf",
        label="unbound-checkconf",
    )

    # Activer + démarrer
    ssh.run("sudo systemctl daemon-reload", label="daemon-reload")
    ssh.run(
        "sudo systemctl enable unbound && sudo systemctl restart unbound",
        label="enable + restart",
    )

    # Vérifier statut (skip en dry-run : rien n'a été redémarré)
    if ssh.dry_run:
        print("    Unbound : DRY-RUN (état non vérifié)")
    else:
        result = ssh.run(
            "sudo systemctl is-active unbound",
            label="is-active",
            check=False,
        )
        state = result.stdout.strip()
        if state != "active":
            raise RuntimeError(f"Unbound n'est pas actif après démarrage (état={state})")
        print(f"    Unbound : {state}")


def step_configure_adguard(ssh: SSHRunner, role: str) -> None:
    """Configure AdGuard : upstream Unbound + fallback DoT + drop-in systemd."""
    print("\n[4/6] Configuration AdGuard...")

    if not ADGUARD_MIGRATE_SRC.exists():
        raise FileNotFoundError(f"Script migration absent : {ADGUARD_MIGRATE_SRC}")
    if not ADGUARD_DEP_SRC.exists():
        raise FileNotFoundError(f"Drop-in AdGuard absent : {ADGUARD_DEP_SRC}")

    yaml_path = ADGUARD_PATHS[role]

    # Vérifier que AdGuard est installé
    result = ssh.run(
        f"test -f '{yaml_path}' && echo EXISTS || echo ABSENT",
        label=f"AdGuard YAML {yaml_path}",
        check=False,
    )
    if "ABSENT" in result.stdout:
        print(
            f"    WARN: AdGuardHome.yaml absent à {yaml_path} — "
            "migration AdGuard SKIP"
        )
        return

    # Upload + exécuter le script de migration
    ssh.upload(ADGUARD_MIGRATE_SRC, "/tmp/adguard-upstream-migrate.py")
    ssh.run(
        f"sudo python3 /tmp/adguard-upstream-migrate.py "
        f"--yaml '{yaml_path}' --role {role} && "
        "rm -f /tmp/adguard-upstream-migrate.py",
        label="migration YAML AdGuard",
    )

    # Drop-in Requires=unbound.service
    service_dir = ADGUARD_SERVICE_DIRS[role]
    ssh.run(
        f"sudo mkdir -p '{service_dir}'",
        label="mkdir AdGuard service.d",
    )
    ssh.upload(ADGUARD_DEP_SRC, "/tmp/n2-adguard-unbound-dep.conf")
    ssh.run(
        f"sudo install -m 644 -o root -g root "
        f"/tmp/n2-adguard-unbound-dep.conf "
        f"'{service_dir}/unbound-dep.conf' && "
        "rm -f /tmp/n2-adguard-unbound-dep.conf",
        label="install drop-in Requires=unbound",
    )

    # Reload systemd + restart AdGuard
    ssh.run("sudo systemctl daemon-reload", label="daemon-reload")
    ssh.run(
        "sudo systemctl reload-or-restart AdGuardHome",
        label="reload AdGuardHome",
    )

    if ssh.dry_run:
        print("    AdGuardHome : DRY-RUN (état non vérifié)")
    else:
        result = ssh.run(
            "sudo systemctl is-active AdGuardHome",
            label="AdGuardHome is-active",
            check=False,
        )
        state = result.stdout.strip()
        if state != "active":
            raise RuntimeError(
                f"AdGuardHome n'est pas actif après reconfiguration (état={state})"
            )
        print(f"    AdGuardHome : {state}")


def step_health_checks(ssh: SSHRunner) -> int:
    """Lance 10 health checks de résolution sur :5335. Retourne le nb de succès."""
    print(f"\n[5/6] Health checks ({HEALTH_CHECKS_COUNT}x résolution sur :5335)...")
    successes = 0
    for i in range(1, HEALTH_CHECKS_COUNT + 1):
        result = ssh.run(
            f"dig @127.0.0.1 -p {HEALTH_CHECK_PORT} {HEALTH_EXTERNAL_HOST} "
            f"+short +time=5 +tries=1 2>/dev/null | grep -E '^[0-9]' | head -1 || true",
            label=f"check {i}/{HEALTH_CHECKS_COUNT}",
            check=False,
        )
        resolved = result.stdout.strip()
        if resolved:
            successes += 1
            print(f"    [{i:02d}] OK  — {HEALTH_EXTERNAL_HOST} → {resolved}")
        else:
            print(f"    [{i:02d}] FAIL — résolution vide (Unbound peut encore chauffer)")
        if i < HEALTH_CHECKS_COUNT:
            time.sleep(1)

    print(f"\n  Résultat : {successes}/{HEALTH_CHECKS_COUNT} checks OK")
    return successes


def step_summary(role: str, host: str, successes: int, dry_run: bool) -> None:
    """Affiche le résumé de déploiement."""
    print("\n[6/6] Résumé...")
    print(f"  Rôle   : {role}")
    print(f"  Hôte   : {host}")
    print(f"  Mode   : {'DRY-RUN' if dry_run else 'PRODUCTION'}")
    print(f"  Santé  : {successes}/{HEALTH_CHECKS_COUNT} checks OK")

    if dry_run:
        print("\n  DRY-RUN terminé — aucune modification appliquée.")
        print("  Idempotent: no changes needed (dry-run mode)")
        return

    if successes >= 8:
        print("\n  DEPLOYEMENT N2 UNBOUND : SUCCES")
    elif successes >= 5:
        print(
            "\n  AVERTISSEMENT : certains checks échoués. "
            "Unbound peut encore être en warmup DoT (~60s)."
        )
    else:
        print(
            "\n  ECHEC : trop de checks négatifs. Vérifier :",
            file=sys.stderr,
        )
        print("    sudo systemctl status unbound", file=sys.stderr)
        print("    sudo journalctl -u unbound -n 30", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
def main() -> None:
    args = parse_args()

    print("=" * 60)
    print("n2-unbound-deploy-2026-04-24.py")
    print(f"  Cible : {args.user}@{args.host}  Rôle : {args.role}")
    if args.dry_run:
        print("  Mode  : DRY-RUN (aucune modification)")
    print("=" * 60)

    ssh = SSHRunner(
        host=args.host,
        user=args.user,
        dry_run=args.dry_run,
        ssh_key=args.ssh_key,
    )

    try:
        step_check_prereqs(ssh)
        step_install_unbound(ssh)
        step_deploy_unbound_config(ssh, args.role)

        if not args.skip_adguard:
            step_configure_adguard(ssh, args.role)
        else:
            print("\n[4/6] Configuration AdGuard : SKIP (--skip-adguard)")

        successes = step_health_checks(ssh)
        step_summary(args.role, args.host, successes, args.dry_run)

    except FileNotFoundError as exc:
        print(f"\nERREUR fichier source manquant : {exc}", file=sys.stderr)
        print(
            "  Assurez-vous de lancer le script depuis le répertoire homelab-scripts/dns/",
            file=sys.stderr,
        )
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("\nERREUR : timeout SSH dépassé.", file=sys.stderr)
        sys.exit(1)
    except RuntimeError as exc:
        print(f"\nERREUR : {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrompu par l'utilisateur.", file=sys.stderr)
        sys.exit(130)


if __name__ == "__main__":
    main()
