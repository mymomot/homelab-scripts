# maps/ — pmtiles serving LXC 511

Scripts d'installation et de configuration pour servir `planet.pmtiles` (OpenMapTiles) via `go-pmtiles` + `caddy` sur LXC 511, avec Traefik LXC 410 en terminaison TLS.

## C5 council Art.15 bis — Exception D (2026-04-24)

L'ACL POSIX `setfacl` prévue par C5 (« ACL POSIX read-only stricte uniquement sur pmtiles/ ») n'est pas appliquée. Constat 2026-04-24 :
- TrueNAS dataset `hdd_pool/scanlib` utilise ACL NFSv4 ZFS native (`nfsv4acls`), incompatible POSIX.1e draft
- `setfacl` côté client Linux retourne `Operation not supported` côté serveur
- Décision Stéphane : ne pas toucher TrueNAS

**Substitut adopté (équivalent fonctionnel C5)** :
1. Unix permissions natives `/mnt/truenas/scanlib/rawsources/maps/pmtiles/planet.pmtiles` :
   - `-rw-rw-r--` owner `motreffs:motreffs`
   - user `pmtiles` (uid=999) → bit `r` other = read OK
   - user `pmtiles` → no bit `w` other + pas owner + pas dans groupe motreffs = write DENIED
2. systemd hardening `pmtiles.service` :
   - `User=pmtiles` (process runtime isolé)
   - `ProtectSystem=strict` (filesystem read-only sauf /tmp privé)
   - `ReadOnlyPaths=/mnt/truenas/scanlib/rawsources/maps/pmtiles` (boundary explicite)

**Tests de validation** : Steps 1-2 ci-dessus (Task 2 du plan).

**Limite assumée** : tout user du LXC 511 (nexus, motreffs, root...) peut lire le fichier. Acceptable dans homelab perso où LXC = unité de confiance. Si exposition future au-delà du LAN trusté → re-évaluer (option NFSv4 ACL côté TrueNAS).
