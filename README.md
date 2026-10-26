# Headscale for umbrelOS (community app store)

This repository is an [umbrelOS community app store](https://github.com/getumbrel/umbrel-community-app-store)
with one app: **[Headscale](https://headscale.net) v0.29.6**, the open-source, self-hosted Tailscale control server.
You keep using the official Tailscale apps on your devices. Only the coordination server (who is in your
network, their public keys, and your access rules) runs on your Umbrel instead of Tailscale's cloud.

> **This app is a public-facing server.** It needs a public DNS name and two router port forwards. Read
> [Before you install](#before-you-install) and the [threat model](#threat-model) first.

Packaging only. Headscale is made by the [Headscale authors](https://github.com/juanfont/headscale) and is not
affiliated with Tailscale Inc. or Umbrel.

## Contents

- [Before you install](#before-you-install)
- [Install](#install)
- [Connect devices](#connect-devices)
- [Access policy](#access-policy)
- [Admin commands](#admin-commands)
- [Settings](#settings)
- [Ports](#ports)
- [Backup and restore](#backup-and-restore)
- [Upgrades](#upgrades)
- [Migrating an existing Headscale](#migrating-an-existing-headscale)
- [Threat model](#threat-model)
- [Hardening notes](#hardening-notes)
- [How the app is built](#how-the-app-is-built)
- [Reporting security issues](#reporting-security-issues)

## Before you install

1. **A public DNS name** that points at your home's public IP, e.g. `hs.example.com` or a free
   [DuckDNS](https://www.duckdns.org) name. If your IP changes, keep the name updated (most routers and DuckDNS
   have a dynamic DNS client).
2. **Two port forwards** on your router to your Umbrel's LAN IP:
   - TCP **443** (public) → TCP **30443** on the Umbrel (control server + HTTPS relay). Let's Encrypt validates the
     certificate over this port (TLS-ALPN-01), so it must be **public port 443**.
   - UDP **3478** → UDP **3478** on the Umbrel (STUN, helps devices find direct paths).
3. Nothing else on the Umbrel may use host port 30443/tcp or 3478/udp.
4. **No CGNAT.** If your ISP shares one public IP between customers (carrier-grade NAT), port forwarding will not
   work. Check that the WAN IP in your router matches what <https://ifconfig.me> shows.
5. **NAT loopback (hairpinning).** Devices at home also connect to the public name. Most routers handle this;
   if devices at home cannot connect while devices on mobile data can, enable NAT loopback / hairpin NAT on the
   router. A local DNS override that points the name at the Umbrel does **not** work on its own: on the Umbrel,
   port 443 belongs to umbrelOS, and Headscale listens on 30443.

## Install

1. umbrelOS → App Store → ⋯ → **Community App Stores** → add
   `https://github.com/CrackleBuff/umbrel-headscale` → open **CrackleBuff** → install **Headscale**.
2. The app starts in a safe **inert** mode: Headscale answers nothing on the published ports (Docker still reserves
   30443/tcp and 3478/udp) and no keys or database are created.
3. Open the app's **Settings** in umbrelOS, set **HS_SERVER_DOMAIN** to your public name (and optionally the other
   settings), and save. The app restarts and becomes active. The first HTTPS request obtains the certificate.
4. Open the app. The status page shows the configuration and whether `https://<your-domain>/health` answers
   (checked from the Umbrel once a minute).

## Connect devices

On each device, install Tailscale, then:

```sh
# macOS / Linux / Windows CLI
tailscale up --login-server https://hs.example.com
```

iOS / Android / macOS app: Settings → *Accounts* → *Use a custom coordination server*. The device shows a
registration command. Approve it from the Umbrel terminal (umbrelOS → Settings → Advanced → Terminal, or SSH):

```sh
HS="sudo docker exec cracklebuff-headscale_headscale_1 headscale"
# if that container name is not found: sudo docker ps --format '{{.Names}}' | grep headscale
$HS users create alice
$HS auth register --user alice --auth-id <id shown on the device>
$HS nodes list
```

Anyone who knows your server's name can start a join request. It does nothing until you approve it, so only
approve an ID that is shown on a device in your hands, never one someone sends you.

## Access policy

New installs **deny all traffic between devices**. Devices can join, but cannot reach each other until you
add rules. The policy file is `~/umbrel/app-data/cracklebuff-headscale/data/policy/policy.hujson`
(or your apps data folder if you moved it). Edit it with `sudo`, check it, then restart the **whole app** from
the umbrelOS menu. On each app start the setup helper checks the file and gives Headscale a checked copy
(`config/policy.hujson`); Headscale never reads your working file directly. So an edit only takes effect after an
app restart, and a crash-restart of Headscale alone keeps using the last checked copy:

```sh
sudo nano ~/umbrel/app-data/cracklebuff-headscale/data/policy/policy.hujson
$HS policy check -f /etc/headscale-policy/policy.hujson
# then restart the app from the umbrelOS app menu
```

See [`examples/policy.example.hujson`](examples/policy.example.hujson) and the
[policy reference](https://headscale.net/stable/ref/policy/).

**Important:** in Headscale a policy without an `acls` or `grants` list (an empty file, `{}`, or `"acls": null`)
means **allow all**. To prevent that by accident, the app refuses to start (status `implicit_allow_all`) unless the
file's top level has an `"acls"` or `"grants"` key whose value is a list (`[]` is fine and denies everything).
Lists that are commented out or nested inside another key do not count, and files containing control characters
(other than tab and line breaks) are refused. If you really want
everyone to reach everything, say so explicitly:
`{"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]}`.

## Admin commands

```sh
HS="sudo docker exec cracklebuff-headscale_headscale_1 headscale"
$HS nodes list                         # devices
$HS nodes approve-routes -i <id> -r 192.168.1.0/24   # subnet route: exposes that LAN to devices your policy allows
$HS nodes expire -i <id>               # force re-login
$HS nodes delete -i <id>
$HS users list
$HS preauthkeys create --user <user ID from "users list"> --expiration 1h  # only for unattended joins; avoid --reusable
```

Use `--expiration` on anything you create. Admin access is via the Docker socket on the Umbrel, so anyone
with a shell on the Umbrel can administer Headscale.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `HS_SERVER_DOMAIN` | *(empty)* | Required. Public DNS name. Until set, the app stays inert. |
| `HS_ACME_EMAIL` | *(empty)* | Optional Let's Encrypt account contact. Let's Encrypt no longer sends expiry reminder e-mails (since June 2025); renewal is automatic. |
| `HS_MAGICDNS_DOMAIN` | `tailnet.internal` | Base domain for device names. The public domain must not be the same as it or inside it (e.g. not `example.com` when the public name is `hs.example.com`). Do not use a real domain you or others use on the internet: your devices would resolve names under it via Headscale instead. |
| `HS_TAILSCALE_DERP` | `false` | `true` adds Tailscale Inc.'s public relays to the relay map. Devices then pick whichever relay is fastest for them, which is often Tailscale's, not just when yours fails. Traffic stays end-to-end encrypted, but Tailscale's relays see device IPs and traffic volume. |
| `HS_NODE_EXPIRY` | `180d` | Key expiry for new user devices (Tailscale's default). `0` = never. Tagged devices never expire; for an always-on server use a tag or `$HS nodes expire -i <id> --disable`. |
| `HS_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. `debug` logs much more detail about devices and requests; use it briefly for troubleshooting only. |

Invalid values never produce a half-working server. The app goes inert and the status page says what is wrong.

## Ports

| Host port | Container | Public? | Purpose |
| --- | --- | --- | --- |
| 30443/tcp | headscale 8443 | **Yes**, via router 443 → 30443 | Tailscale control protocol (Noise), HTTPS DERP relay, `/register`, `/health`, REST API (API key required), ACME TLS-ALPN-01 |
| 3478/udp | headscale 3478 | **Yes**, via router | STUN |
| 8487/tcp | Umbrel app proxy → web 8080 | LAN only, behind umbrelOS login | Status page |
| — | 127.0.0.1:9090 inside container | No | Metrics and `/debug/*` (exposes config and node data, so never publish it) |
| — | 127.0.0.1:50443 inside container | No | gRPC admin API |

Do **not** forward the status page port (8487) or any other Umbrel port to the internet.

**IPv6:** Docker also publishes 30443/tcp and 3478/udp on IPv6. If your Umbrel has a public IPv6 address and your
router allows inbound IPv6, the server can be reached that way without any IPv4 forward. That is the same
service you are exposing anyway, but check your router's IPv6 firewall so you know what is open.

## Backup and restore

Everything lives in `~/umbrel/app-data/cracklebuff-headscale/data/`:

| Path | Contents | Secret? |
| --- | --- | --- |
| `lib/noise_private.key` | Server identity. If lost, **every device must re-login**. | **Yes** |
| `lib/derp_server_private.key` | Embedded relay identity | **Yes** |
| `lib/db.sqlite*` | Users, devices, routes, keys and key hashes | **Yes** |
| `lib/cache/` | Let's Encrypt account key and certificate | Yes |
| `policy/policy.hujson` | Your access policy | No (but private) |
| `config/`, `www/`, `status/`, `probe/` | Regenerated on every start | No |

Backup (consistent copy of the database):

```sh
# stop the app in umbrelOS first, then:
sudo sh -c 'umask 077; tar -C ~umbrel/umbrel/app-data/cracklebuff-headscale/data -czf headscale-backup-$(date +%F).tgz lib policy'
ls -l headscale-backup-*.tgz   # should show -rw------- root
```

Treat the archive like a password. Encrypt it before putting it in the cloud. umbrelOS's own backups also
contain these keys, so protect that destination too.

Restore: install the app (leave it unconfigured), stop it, extract the archive into
`~/umbrel/app-data/cracklebuff-headscale/data/` with `sudo tar -xzf ...`, set the same `HS_SERVER_DOMAIN`, and
start it. On start the app fixes ownership (uid 65532) and modes (dirs 0700, files 0600). It refuses to start if
it finds symlinks or device files there.

**Uninstalling the app deletes this folder**, including the server keys. Make a backup first if you might come back.

## Upgrades

App updates replace only the compose file and manifest. Your `data/` folder, keys, database and policy are
kept, and the config is re-rendered from settings on every start. umbrelOS never updates apps on its own. The
new compose file runs with access to your keys, so an update is only as trustworthy as this repository: glance at
the changes before you click Update.

Each release pins the Headscale image by **version and digest**. Before bumping, maintainers read the
[upgrade notes](https://github.com/juanfont/headscale/blob/main/CHANGELOG.md), test on a copy of real data, and
verify the image as described in [Hardening notes](#hardening-notes). Headscale migrates its database
automatically and does not support downgrades, so **back up before every update**.

## Migrating an existing Headscale

1. Back up the old server's state directory (normally `/var/lib/headscale`) and its policy file.
2. Stop the old server (keep it, in case you need to roll back).
3. Install this app unconfigured, stop it, then copy the old `db.sqlite` (with `-wal`/`-shm` if present, or
   after a clean stop), `noise_private.key`, `derp_server_private.key` and `cache/` into `data/lib/`, and the
   policy into `data/policy/policy.hujson`.
4. Set `HS_SERVER_DOMAIN` (and `HS_MAGICDNS_DOMAIN` if you used a different one) to the **same values** as
   before, then start. Keeping the domain and noise key means devices reconnect without re-login.
5. Point the router forward at port 30443. If it fails, stop the app and start the old server again.

## Threat model

**Assets:** the noise and DERP private keys (impersonating your server), the database (device list, IPs,
routes, keys), your access policy, and your home LAN reachable through subnet routes or exit nodes.

**What the control server can do:** Headscale decides which devices exist and which may talk to each other.
Whoever controls it can add a rogue device to your network and give it access (Tailscale has a
"tailnet lock" feature for this, which **Headscale does not support**). Traffic between devices is end-to-end
encrypted with WireGuard, and the server never sees it, but it can steer who you encrypt to, and push DNS
settings and routes to your devices. Protect it like the keys to your home network.

| Attacker | Exposure | Mitigations in this app |
| --- | --- | --- |
| Internet (anyone) | TCP 443 and UDP 3478 | Only Headscale is exposed, as a non-root user with a read-only filesystem, no capabilities, `no-new-privileges` and a PID limit. TLS 1.2+ only (Go). Metrics/debug/gRPC on localhost only. Joining needs an admin approval (no pre-auth keys are created). REST API needs an API key (none are created). Embedded DERP requires clients known to this server (`verify_clients`). |
| Internet → relay abuse | DERP/STUN | `verify_clients: true`; STUN is stateless. |
| A device in your tailnet | Other devices, LAN | Default-deny policy; fail-closed check against a policy with no top-level `acls`/`grants` list (empty, `{}`, `null`); subnet routes and exit nodes need explicit approval. |
| LAN users, other apps | Status page | Browsers reach it through the umbrelOS login (app proxy). Other containers on `umbrel_main_network` can read the same status JSON directly (domain, settings, health flag and the server's *public* key; nothing secret). It cannot change anything and makes no network requests itself: the health check runs in a separate `probe` container on the `edge` network, and the page only shows strictly-formatted values from it. |
| Other Umbrel apps | Docker network | Headscale runs on its own private bridge network (`edge`), not `umbrel_main_network`, so a compromised Headscale cannot reach other apps' internal ports. It does not mount the Docker socket or other apps' data. The init helper has no network at all. Residual: like any Docker container it can still open connections to your LAN, the internet and ports the Umbrel publishes on the host; filtering that needs host firewall rules an app cannot set. |
| Umbrel admin / shell | Everything | Full trust: can read keys and run `headscale` commands. Use a strong umbrelOS password and keep SSH off the internet. |
| Other apps with host access | Everything | Apps that mount the Docker socket or host folders (Portainer, file managers, some backup apps) can read the keys or take over this app. Install those only if you trust them as much as the Umbrel admin. |
| Supply chain | Images, this repo | Images pinned by digest; CI checks that the pinned image's final binary, entrypoint and environment match the upstream release (`tools/verify_image.py`), and that the app adds no host hooks, privileges, Docker socket or mounts outside its data folder (`tools/check_compose.py`). These checks catch mistakes, not a malicious maintainer. **Installing or updating any community app is root-level trust in its author**: an app update can run commands as root on the Umbrel. umbrelOS does not auto-update community apps, so review the changes before you click Update. |

**Out of scope / residual risks:** a compromise of Headscale itself (keep it updated), **DNS hijacking of your
name** (whoever controls the name can get a valid Let's Encrypt certificate for it and impersonate your server to
your devices, so protect your DNS/DuckDNS account like the server itself), your router's security, physical access to the Umbrel,
and denial-of-service against your home connection.

## Hardening notes

- **Keep the app updated.** Watch [Headscale releases](https://github.com/juanfont/headscale/releases) and
  [security advisories](https://github.com/juanfont/headscale/security/advisories).
- **Keep the default-deny policy** and add narrow rules. Prefer groups and tags over `*`.
- **Keep `HS_NODE_EXPIRY`** at `180d` (or shorter) so lost or stolen devices stop working on their own; expire or delete them as
  soon as you notice (`$HS nodes expire -i <id>`, `$HS nodes delete -i <id>`).
- **Avoid long-lived credentials.** Do not create reusable pre-auth keys or API keys unless needed. Give them
  short expiry, and expire them after use (`headscale apikeys expire`, `headscale preauthkeys expire`).
- **Leave `HS_TAILSCALE_DERP=false`** unless relaying is unreliable. With it on, devices may use Tailscale's relays
  whenever those are faster, not only as a fallback.
- **Forward only 443/tcp and 3478/udp.** The REST API (`/api/v1`, `/swagger`) is served on the public port by
  upstream Headscale and cannot be turned off; it rejects requests without a valid API key.
- **HSTS** is not sent by Headscale. Browsers are only used for the `/register` and `/apple`/`/windows` help
  pages, so this has little impact.
- **Certificate rate limits.** Scanners that only offer RSA can make Headscale request a second (RSA)
  certificate. Let's Encrypt allows 5 identical certificates per week, which is normally plenty.
- **Verify images yourself** before trusting an update. `python3 tools/verify_image.py` (also run in CI) downloads
  the pinned image by digest, applies its layers in order (so a later layer cannot swap the binary for a link or
  delete it), and checks the final binary, entrypoint and environment against the release. By hand (simpler, it
  only reads the binary):

  ```sh
  crane digest ghcr.io/juanfont/headscale:v0.29.6
  # compare the binary inside the image with the release checksums
  crane export --platform linux/arm64 ghcr.io/juanfont/headscale:v0.29.6 - | tar -xO ko-app/headscale | sha256sum
  curl -sL https://github.com/juanfont/headscale/releases/download/v0.29.6/checksums.txt | grep linux_arm64
  # x86 Umbrel: use linux/amd64 and linux_amd64; or run python3 tools/verify_image.py for both
  ```

  Upstream images are not cosign-signed. This proves the pinned image matches the published release binary; it
  cannot prove who built either one.

### Container layout and lint justifications

| Service | Image | User | Notes |
| --- | --- | --- | --- |
| `init` | busybox 1.38.0 (digest) | root | Runs once before Headscale, with **no network**, read-only root, `cap_drop: ALL` plus only `CHOWN`, `DAC_OVERRIDE`, `FOWNER` (needed to fix ownership of files copied in by users or restores), `no-new-privileges`. Validates settings, renders the config, creates the default-deny policy if missing, fixes modes, refuses symlinks/devices, and writes the status files. `restart: on-failure`. |
| `headscale` | headscale v0.29.6 (digest) | 65532 | Own `edge` network, read-only root, `cap_drop: ALL`, `no-new-privileges`, `pids_limit`, `mem_limit: 512m`, tmpfs (`noexec,nosuid,nodev`) for `/tmp` and the socket dir, config and policy mounted read-only. Healthcheck `headscale health`. |
| `web` | busybox 1.38.0 (digest) | 65534 | Static status page + a tiny CGI reading the status files (no network requests). Read-only, `cap_drop: ALL`, `no-new-privileges`. |
| `probe` | busybox 1.38.0 (digest) | 65534 | Once a minute sends one HTTPS GET each for `https://<your-domain>/health` and `/key` (no redirects followed, 8 s timeout, 4 KB cap; busybox does not verify the certificate, so the result is only a hint) and writes the result for the status page. On `edge` only, read-only, `cap_drop: ALL`, `no-new-privileges`, small PID and memory limits. |

The Umbrel linter warns about `cap_add`, `security_opt` and top-level `networks`. All are intentional:
`security_opt` only adds `no-new-privileges:true`, the init capabilities are the minimum needed to `chown`/`chmod`
app data, and the extra `edge` network isolates the internet-facing service from other apps.

## How the app is built

`cracklebuff-headscale/docker-compose.yml` is generated. Edit `src/` and run:

```sh
python3 tools/build.py          # regenerate
python3 tools/build.py --check  # CI: fail if stale
python3 tools/check_compose.py  # CI: no host hooks, privileges or extra mounts
python3 tests/test_verify_image.py   # image-check logic
python3 tests/test_check_compose.py  # guard rails reject forbidden changes
tools/fetch-busybox.sh /tmp/bb && sudo BUSYBOX=/tmp/bb/bin/busybox tests/test-init.sh   # init tests (pinned busybox)
```

See [`tests/README.md`](tests/README.md).

## Reporting security issues

See [SECURITY.md](SECURITY.md). The reviews done so far, and what they did not cover, are listed in
[docs/SECURITY-REVIEWS.md](docs/SECURITY-REVIEWS.md). Vulnerabilities in Headscale itself go to the
[Headscale project](https://github.com/juanfont/headscale/security).

## License

Packaging: MIT, see [LICENSE](LICENSE). Headscale: BSD-3-Clause, © the Headscale authors.
