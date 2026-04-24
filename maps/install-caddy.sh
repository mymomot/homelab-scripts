#!/usr/bin/env bash
# install-caddy.sh — Install Caddy 2.x via official Cloudsmith APT repo
# Council Art.15 bis C6 — apt verifies GPG signature de Cloudsmith
set -euo pipefail

if dpkg -l caddy >/dev/null 2>&1; then
    echo "[install] Caddy already installed: $(caddy version | head -1)"
    exit 0
fi

# Add Cloudsmith repo (méthode officielle Caddy)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list

sudo apt update
sudo apt install -y caddy

caddy version
