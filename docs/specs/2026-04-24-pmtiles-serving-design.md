# Design — Servir `planet.pmtiles` offline via Traefik (LXC 511)

- **Date** : 2026-04-24
- **Auteur** : Claude Code (Général) + Stéphane (arbitrage)
- **Contexte** : suite du pipeline `raw-sources-collector` (LXC 511). Le fichier `planet.pmtiles` (77 GB, schéma OpenMapTiles via planetiler) est présent sur NFS TrueNAS depuis 2026-04-24 09:52 UTC. Objectif : le consommer via browser LAN avec un viewer MapLibre complet.
- **Status** : design approuvé par Stéphane, en attente council Art.15 bis + writing-plans.

## 1. Objectif

Rendre `planet.pmtiles` consultable via browser depuis le LAN, sur `https://maps.lab.mymomot.ovh`, avec rendu vectoriel complet (style OpenMapTiles + fonts + sprites) sans dépendance Internet au moment du rendu.

**Non-objectifs (YAGNI)** :
- Pas d'exposition Internet publique (LAN only — DNS rewrite local uniquement)
- Pas de SSO Authentik (accès LAN = confiance implicite réseau)
- Pas de multi-user / ACL / quotas
- Pas de génération tiles à la volée (planet.pmtiles statique, régénération manuelle via `generate-pmtiles.sh`)
- Pas de basemap Protomaps style NOMAD (schéma incompatible — TODO différé, régénération PMTiles requise)

## 2. Contraintes figées

| Paramètre | Valeur | Justification |
|---|---|---|
| Host backend | LXC 511 `192.168.10.98` | Déjà hôte du pipeline raw-sources-collector + NFS monté |
| Host reverse-proxy | LXC 410 `192.168.10.10` (Traefik existant) | Pattern homelab établi |
| Domaine | `maps.lab.mymomot.ovh` | Convention `*.lab.mymomot.ovh` homelab |
| Accès | LAN only | Confiance réseau, pas de SSO overhead |
| TLS | Traefik Let's Encrypt wildcard | Déjà en place |
| Stockage | NFS `/mnt/truenas/scanlib/rawsources/maps/pmtiles/planet.pmtiles` | Déjà monté LXC 511 |
| Offline rendering | Oui | Bundle MapLibre local, pas de CDN |
| Schéma tiles | OpenMapTiles (via planetiler) | Schéma déjà généré, non négociable sans régénération 13h |

## 3. Architecture

```
Browser LAN
    │
    ▼  DNS AdGuard LXC 411/118 → 192.168.10.10
┌─────────────────────────────────┐
│ Traefik LXC 410  :443 TLS       │
│ router maps.lab.mymomot.ovh     │
└───────────────┬─────────────────┘
                │ HTTP LAN only (pas de SSO)
       ┌────────┴─────────┐
       │                  │
       ▼ PathPrefix       ▼ default /
       │ /tiles/          │
┌──────────────┐   ┌──────────────┐
│ LXC 511      │   │ LXC 511      │
│ go-pmtiles   │   │ caddy v2     │
│ systemd      │   │ systemd      │
│ :8080        │   │ :8081        │
└──────┬───────┘   └──────┬───────┘
       │                  │
       ▼                  ▼
  planet.pmtiles      /var/www/maps/
  (NFS 77 GB,          ├── index.html
   byte-range read)    ├── style.json  (OSM-liberty OpenMapTiles)
                       ├── vendor/
                       │   ├── maplibre-gl.js     (pinné v3.x)
                       │   └── maplibre-gl.css
                       ├── fonts/      (OpenMapTiles fontstack)
                       └── sprites/    (OSM liberty sprites)
```

## 4. Composants détaillés

### 4.1 — `go-pmtiles serve` (backend tiles)

- **Binaire** : `go-pmtiles` (release officielle GitHub protomaps/go-pmtiles, v1.x)
- **Install** : `/usr/local/bin/go-pmtiles` (root:root 0755)
- **User runtime** : `pmtiles` (system user, home `/var/lib/pmtiles`, pas de login shell)
- **Commande** : `go-pmtiles serve /mnt/truenas/scanlib/rawsources/maps/pmtiles --port 8080 --interface 192.168.10.98 --public-url https://maps.lab.mymomot.ovh/tiles --cors https://maps.lab.mymomot.ovh`
- **Binding** : `192.168.10.98:8080` (cohérent §4.3 décision LAN trusté — pas de firewall applicatif)
- **Routes exposées** :
  - `/tiles/planet/metadata.json` → TileJSON (minzoom, maxzoom, bounds, tile template, vector_layers)
  - `/tiles/planet/{z}/{x}/{y}.mvt` → byte-range read `planet.pmtiles` → MVT binary
- **Limits systemd** : `MemoryHigh=512M`, `MemoryMax=1G`, `Nice=10` (LXC 511 a 12 GB total, ne pas étrangler)

### 4.2 — `caddy` (static serving)

- **Package** : `caddy` apt (v2.x depuis repo officiel Caddy, setup via `apt-add-repository`)
- **User runtime** : `caddy` (créé par le package)
- **Config** : `/etc/caddy/Caddyfile` simple :
  ```
  192.168.10.98:8081 {
      root * /var/www/maps
      encode gzip zstd
      file_server
      header Cache-Control "public, max-age=86400"
  }
  ```
- **Binding** : `192.168.10.98:8081` (cohérent §4.3 décision LAN trusté)
- **Limits systemd** : `MemoryMax=256M` (file_server léger)

### 4.3 — Traefik LXC 410 — nouvelles entrées

Pattern existant : append à `/opt/traefik/dynamic/routers.yml` et `services.yml` (backup préalable obligatoire, géré par regression-guard Étape Plan).

**routers.yml** (ajout) :
```yaml
http:
  routers:
    maps-pmtiles:
      rule: "Host(`maps.lab.mymomot.ovh`) && PathPrefix(`/tiles/`)"
      service: maps-pmtiles
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
    maps-static:
      rule: "Host(`maps.lab.mymomot.ovh`)"
      service: maps-static
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
      priority: 10  # inférieur à maps-pmtiles (plus spécifique gagne)
```

**services.yml** (ajout) :
```yaml
http:
  services:
    maps-pmtiles:
      loadBalancer:
        servers:
          - url: "http://192.168.10.98:8080"
    maps-static:
      loadBalancer:
        servers:
          - url: "http://192.168.10.98:8081"
```

**Point critique** : `127.0.0.1:8080/8081` sur LXC 511 est NON accessible depuis LXC 410. Il faut soit :
- **(X)** binder sur `0.0.0.0:8080/8081` + firewall LXC 511 restrict source à `192.168.10.10`
- **(Y)** binder sur `192.168.10.98:8080/8081` + pas de firewall (LAN trusté)

**Décision** : option **(Y)** — pattern cohérent avec les autres services LXC (nexus :11460, etc.). Pas de firewall applicatif sur LXC 511 (réseau LAN déjà filtré en amont QHora). Le `--interface 127.0.0.1` dans 4.1 devient **`--interface 192.168.10.98`**.

### 4.4 — DNS AdGuard (LXC 411 primary + LXC 118 secondary)

Ajouter rewrite DNS :
- `maps.lab.mymomot.ovh → 192.168.10.10`

Sur LXC 411 : éditer `/opt/AdGuardHome/AdGuardHome.yaml` section `filtering.rewrites` (pattern déjà utilisé pour les autres `*.lab.mymomot.ovh`). Reload AdGuard service.
Sur LXC 118 (llmcore AdGuard secondaire) : idem — **impératif** sinon failover DNS → résolution publique → 502 Traefik.

### 4.5 — Content statique `/var/www/maps/`

**Layout** :
```
/var/www/maps/
├── index.html          # 1 page MapLibre fullscreen + attribution obligatoire OpenMapTiles + OpenStreetMap
├── style.json          # OSM Liberty (OpenMapTiles schema compatible planetiler)
├── vendor/
│   ├── maplibre-gl.js   # pinné v3.x, téléchargé depuis unpkg.com au install
│   └── maplibre-gl.css
├── fonts/              # OpenMapTiles fontstack (~10 MB téléchargé depuis openmaptiles/fonts)
│   └── <fontstack>/<range>.pbf
└── sprites/            # OSM liberty sprites (~1 MB)
    ├── sprite.json
    ├── sprite.png
    ├── sprite@2x.json
    └── sprite@2x.png
```

**style.json** : téléchargé depuis le dépôt public `maputnik/osm-liberty` (MIT), patcher la section `sources` pour pointer vers `/tiles/planet/metadata.json` (URL relative au domaine `maps.lab.mymomot.ovh`).

**index.html** : ~50 lignes, charge `vendor/maplibre-gl.js`, init map avec `style: 'style.json'`, centre Europe par défaut (lat 48, lon 2, zoom 4).

### 4.6 — Owner + permissions

| Chemin | Owner | Mode |
|---|---|---|
| `/usr/local/bin/go-pmtiles` | root:root | 0755 |
| `/mnt/truenas/scanlib/rawsources/maps/pmtiles/planet.pmtiles` | motreffs:motreffs (actuel) | 0664 (lecture pour groupe) |
| User `pmtiles` appartient au groupe `motreffs` | — | — |
| `/var/www/maps/` | caddy:caddy | 0755, fichiers 0644 |
| `/etc/caddy/Caddyfile` | root:caddy | 0640 |
| `/etc/systemd/system/pmtiles.service` | root:root | 0644 |

## 5. Data flow

1. Browser → `GET https://maps.lab.mymomot.ovh/` → DNS AdGuard → `192.168.10.10`
2. Traefik `:443` termine TLS, match `Host(maps.lab.mymomot.ovh)` default → service `maps-static` → Caddy `:8081` → `index.html`
3. `index.html` charge `vendor/maplibre-gl.js` (~200 KB, servi par Caddy)
4. `maplibre.Map({ style: 'style.json' })` → Caddy sert `style.json` (patché avec `sources.openmaptiles.url = '/tiles/planet/metadata.json'`)
5. MapLibre → `GET /tiles/planet/metadata.json` → Traefik match `PathPrefix(/tiles/)` → service `maps-pmtiles` → go-pmtiles → retourne TileJSON
6. MapLibre → `GET /tiles/planet/{z}/{x}/{y}.mvt` (50-100 requêtes pour viewport) → go-pmtiles → byte-range read NFS → MVT
7. MapLibre → `GET /fonts/<fontstack>/{range}.pbf` → Caddy → pbf fonts
8. MapLibre → `GET /sprites/sprite.json` + `/sprites/sprite.png` → Caddy
9. Rendering vectoriel complet dans le browser

## 6. Error handling

| Cas | Comportement attendu | Détection |
|---|---|---|
| NFS down (TrueNAS freeze) | go-pmtiles retourne 503, MapLibre affiche fond gris fallback | BigBrother alerte NFS already en place |
| `planet.pmtiles` corrompu | go-pmtiles retourne 404 sur tiles, TileJSON répond peut-être encore | health check custom (tile 0/0/0.mvt sanity) |
| LXC 511 down | Traefik 502 Bad Gateway (déjà loggé dashboard) | Traefik dashboard `health=down` |
| Caddy crash | Traefik 502 sur `/` mais `/tiles/*` fonctionne encore | `systemctl status caddy` |
| go-pmtiles crash | Traefik 502 sur `/tiles/*` mais viewer charge (style échoue) | `systemctl status pmtiles` |
| Let's Encrypt cert expiré | Traefik sert cert expiré, browser bloque | cron Traefik déjà en place |

## 7. Testing — critères GO (post-implémentation)

| Test | Critère binaire |
|---|---|
| T1 | `curl -s http://192.168.10.98:8080/planet/metadata.json \| jq -r .vector_layers[0].id` → non vide |
| T2 | `curl -sI http://192.168.10.98:8080/planet/0/0/0.mvt` → 200 + `Content-Type: application/x-protobuf` |
| T3 | `curl -sI http://192.168.10.98:8081/` → 200 |
| T4 | `systemctl is-active pmtiles caddy` → `active active` |
| T5 | `curl -s https://maps.lab.mymomot.ovh/tiles/planet/metadata.json` → TileJSON valide (via Traefik) |
| T6 | `curl -sI https://maps.lab.mymomot.ovh/` → 200 + `Content-Type: text/html` |
| T7 | Browser Firefox/Chrome `https://maps.lab.mymomot.ovh/` → carte rendue < 5s cold, zoom pan OK |
| T8 | Traefik dashboard → routers `maps-pmtiles` et `maps-static` verts, services up |
| T9 | DNS failover : `dig @192.168.10.118 maps.lab.mymomot.ovh` → `192.168.10.10` (secondary OK) |
| T10 | Test LAN only : `curl --resolve maps.lab.mymomot.ovh:443:<IP-VPS-CA-1> https://maps.lab.mymomot.ovh/` depuis VPS CA-1 → timeout/refused (port 443 LXC 410 non exposé WAN via Box) |

**TNR 100% PASS requis** avant déclaration GO (règle Constitution Art.7).

## 8. Sécurité

- **LAN only garanti par DNS** : résolution `maps.lab.mymomot.ovh` uniquement via AdGuard LAN. Publique = NXDOMAIN (pas de record A dans DNS OVH).
- **TLS** : Let's Encrypt wildcard déjà en place Traefik (`*.lab.mymomot.ovh`).
- **Pas de SSO** : assumé LAN = trusté. Si exposition Internet future → council Art.15 bis requis pour ajout Authentik forwardAuth.
- **Lecture seule** : user `pmtiles` n'a pas d'écriture sur NFS. Caddy n'a pas d'accès NFS (bac à sable `/var/www/maps/` local).
- **Surface attaque backend** : `go-pmtiles serve` CORS restreint à `https://maps.lab.mymomot.ovh` → pas de scraping cross-origin.
- **Pas de dep vuln-exposure directe** : go-pmtiles + caddy sont 2 binaires statiques, peu de surface.

## 9. Dépendances nouvelles

| Composant | Source | Taille | Licence |
|---|---|---|---|
| go-pmtiles v1.x | github.com/protomaps/go-pmtiles releases | ~15 MB binaire | BSD 3-clause |
| caddy v2.x | apt repo officiel | ~45 MB | Apache 2.0 |
| maplibre-gl.js v3.x | unpkg.com/maplibre-gl@3 (téléchargé une fois à l'install) | ~200 KB minified | BSD 3-clause |
| osm-liberty style | github.com/maputnik/osm-liberty | <50 KB | MIT |
| OpenMapTiles fonts | github.com/openmaptiles/fonts release | ~30 MB | OFL 1.1 |
| OSM liberty sprites | inclus dans osm-liberty repo | ~1 MB | MIT |

**Nouvelles dépendances externes permanentes** : AUCUNE (tout servi en local après l'install initial). Offline rendering garanti.

## 10. Observabilité

- `journalctl -u pmtiles` + `journalctl -u caddy` sur LXC 511
- Traefik dashboard `traefik.lab.mymomot.ovh` (SSO) → monitoring routers + services santé
- BigBrother : ajout éventuel d'un check HTTP tile 0/0/0 via `health-check-services.sh` (LXC 500) → alerte Telegram si KO (Phase 4 post-deploy)

## 11. Plan d'implémentation (high-level)

Détails fins → `writing-plans` skill en post-approbation council.

1. **Council Art.15 bis** — /homelab-gouvernance (nouveau service LIVE)
2. **regression-guard Traefik** — SCOPE LOCK + backups routers/services.yml
3. Install go-pmtiles sur LXC 511 + user `pmtiles`
4. Install caddy sur LXC 511 + user `caddy` (package)
5. Scaffold `/var/www/maps/` + download assets (maplibre, style, fonts, sprites)
6. Patcher `style.json` → pointer `/tiles/planet/metadata.json`
7. Writer systemd units `pmtiles.service` + `caddy.service`
8. Tests LXC 511 local (T1→T4)
9. Ajout entries Traefik routers/services (regression-guard gated)
10. Ajout DNS rewrite AdGuard LXC 411 + LXC 118
11. Tests E2E (T5→T10)
12. Documentation MEMORY.md + CLAUDE-HOMELAB-SCRIPTS.md + vault-mem `retrospectives`
13. Commit `homelab-scripts/maps/` scripts versionnés + Traefik config
14. Archiviste (council Art.19 CLAUDE-HOMELAB-SCRIPTS.md)

## 12. Rollback

- Suppression entrées `routers.yml` + `services.yml` Traefik → `systemctl reload traefik` (LXC 410)
- `systemctl disable --now pmtiles caddy` sur LXC 511
- Suppression rewrite DNS AdGuard (LXC 411 + LXC 118) → reload
- Backups préservés 30 jours minimum (regression-guard pattern)

## 13. TODOs différés (hors scope ce spec)

- [ ] Basemap Protomaps style NOMAD : régénérer `nomad.pmtiles` avec profil Protomaps basemap (au lieu de planetiler OpenMapTiles). Conserve `nomad-base-styles.json` + `base-assets.tar.gz` déjà présents. Sera un 2e fichier tile servi au même endpoint.
- [ ] Extraction régionale : `go-pmtiles extract` → `france.pmtiles` (<5 GB) pour usage mobile offline.
- [ ] Futur reverse routing OSRM/Valhalla basé sur `planet-latest.osm.pbf` (note vault-mem mentionne).
- [ ] Health check BigBrother dédié (ajout après stabilisation 1 semaine).
- [ ] Exposition Internet via SSO Authentik (si usage hors LAN se présente — council Art.15 bis requis).

## 14. Références

- Note vault-mem `constitution/claude-code-jarvis_20260421_a8c4_raw-sources-collector-pipeline-collecte.md`
- Pipeline `~/projects/homelab-scripts/dns/` (pattern scripts versionnés)
- Spec PMTiles : https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
- go-pmtiles : https://github.com/protomaps/go-pmtiles
- osm-liberty : https://github.com/maputnik/osm-liberty
- OpenMapTiles fonts : https://github.com/openmaptiles/fonts
