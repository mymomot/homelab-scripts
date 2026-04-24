# Rollback Procedure — pmtiles Phase 6

**Version** : 1.0 (2026-04-24)  
**Scope** : maps.lab.mymomot.ovh outage recovery  
**Estimated downtime** : 5-10 seconds

## Step 1 — Traefik Router Disable (Primary gate)

Pause the maps router configuration — Traefik reloads automatically (~1-3s).

```bash
ssh motreffs@192.168.10.10 "sudo -n mv /opt/traefik/dynamic/routers-maps.yml /opt/traefik/dynamic/routers-maps.yml.disabled"
sleep 5
```

**Expected result** : HTTP 404 for all maps.lab.mymomot.ovh requests. Access to other services (forgejo, vault, wazuh, kellnr) unaffected (separate routers).

**Monitoring** : 
```bash
curl -I https://maps.lab.mymomot.ovh/ 2>&1 | grep -E "HTTP|404"
```

## Step 2 — DNS Rollback (if needed)

If Traefik routing alone is insufficient, modify DNS at AdGuard to point maps.lab.mymomot.ovh to a standby IP or remove the record.

### Option A — Remove rewrite (preferred, cleanest recovery)

**Primary AdGuard LXC 411** :
```bash
ssh motreffs@192.168.10.11 "sudo cp /root/AdGuardHome/AdGuardHome.yaml /root/AdGuardHome/AdGuardHome.yaml.bak-rollback-$(date -u +%Y%m%dT%H%M%SZ)"
ssh motreffs@192.168.10.11 "sudo sed -i '/- domain: maps.lab.mymomot.ovh/,+2d' /root/AdGuardHome/AdGuardHome.yaml && sudo systemctl reload AdGuardHome || sudo systemctl restart AdGuardHome"
```

**Secondary AdGuard llmcore** :
```bash
ssh llmcore "sudo cp /opt/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml.bak-rollback-$(date -u +%Y%m%dT%H%M%SZ)"
ssh llmcore "sudo sed -i '/- domain: maps.lab.mymomot.ovh/,+2d' /opt/AdGuardHome/AdGuardHome.yaml && sudo systemctl reload AdGuardHome || sudo systemctl restart AdGuardHome"
```

**Verify** :
```bash
dig maps.lab.mymomot.ovh @192.168.10.11 +short
# Expected : empty (no rewrite) or NXDOMAIN
```

### Option B — Restore config from backup (robust recovery)

If YAML corruption is suspected:

```bash
# Primary LXC 411
ssh motreffs@192.168.10.11 "sudo python3 -c \"
import yaml
import sys

# Load config
with open('/root/AdGuardHome/AdGuardHome.yaml') as f:
    cfg = yaml.safe_load(f)

# Remove maps rewrite entry
rewrites = cfg.get('filtering', {}).get('rewrites', [])
cfg['filtering']['rewrites'] = [r for r in rewrites if r.get('domain') != 'maps.lab.mymomot.ovh']

# Write back
with open('/root/AdGuardHome/AdGuardHome.yaml', 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
\""

ssh motreffs@192.168.10.11 "sudo systemctl reload AdGuardHome || sudo systemctl restart AdGuardHome"
```

Same for **secondary llmcore** :
```bash
ssh llmcore "sudo python3 -c \"
import yaml
import sys

with open('/opt/AdGuardHome/AdGuardHome.yaml') as f:
    cfg = yaml.safe_load(f)

rewrites = cfg.get('filtering', {}).get('rewrites', [])
cfg['filtering']['rewrites'] = [r for r in rewrites if r.get('domain') != 'maps.lab.mymomot.ovh']

with open('/opt/AdGuardHome/AdGuardHome.yaml', 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
\""

ssh llmcore "sudo systemctl reload AdGuardHome || sudo systemctl restart AdGuardHome"
```

**Default** : use **Option A** (sed + fast). Fall back to **Option B** if YAML edit fails.

## Step 3 — Stop Backend Services (optional, lowest priority)

If Step 1 + Step 2 insufficient, gracefully stop pmtiles and Caddy on LXC 511:

```bash
ssh motreffs@192.168.10.98 "sudo -n systemctl stop pmtiles.service caddy.service"
sleep 2
```

**Undo** :
```bash
ssh motreffs@192.168.10.98 "sudo -n systemctl start pmtiles.service caddy.service"
```

---

## Recovery — Full restore

### Option A — Restore Traefik config (primary)

```bash
ssh motreffs@192.168.10.10 "sudo -n mv /opt/traefik/dynamic/routers-maps.yml.disabled /opt/traefik/dynamic/routers-maps.yml"
sleep 3
curl -I https://maps.lab.mymomot.ovh/ | grep "HTTP"
```

Expected : `HTTP/2 200`.

### Option B — Verify all health checks

After restoring, confirm:

- **Traefik logs** : `sudo journalctl -u traefik.service --since '5 min ago' | grep -iE 'level=err|maps'` → empty
- **Services LXC 511** : `systemctl is-active pmtiles.service caddy.service` → `active active`
- **Other consumer health** : 
  - forgejo : `curl -I https://forgejo.lab.mymomot.ovh/`
  - vault-mem : `curl -I https://vault.lab.mymomot.ovh/`
  - wazuh : `curl -I https://wazuh.lab.mymomot.ovh/`

---

## Lessons learned

- **Traefik-first recovery** : config disable/enable faster than service restart
- **Isolation** : maps router isolated in `routers-maps.yml` prevents cascading failures
- **No IP modification required** : DNS/nftables unchanged, only Traefik layer affected

---

**Last updated** : 2026-04-24 23:22 UTC
**Tested** : 2026-04-24 Phase 6 rollback simulation PASS
