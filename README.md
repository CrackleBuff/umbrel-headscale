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
   if devices at home cannot connect while devices on mobile data can, enable NAT loopback / hairpin NAT or add
   a local DNS override for the name pointing at the Umbrel **and** forward 443 → 30443 for LAN traffic too.

## Install

1. umbrelOS → App Store → ⋯ → **Community App Stores** → add
   `https://github.com/CrackleBuff/umbrel-headscale` → open **CrackleBuff** → install **Headscale**.
2. The app starts in a safe **inert** mode: nothing listens publicly and no keys or database are created.
3. Open the app's **Settings** in umbrelOS, set **HS_SERVER_DOMAIN** to your public name (and optionally the other
   settings), and save. The app restarts and becomes active. The first HTTPS request obtains the certificate.
4. Open the app. The status page shows the configuration and whether `https://<your-domain>/health` answers.

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
$HS users create alice
$HS auth register --user alice --auth-id <id shown on the device>
$HS nodes list
```

## Access policy

New installs **deny all traffic between devices**. Devices can join, but cannot reach each other until you
add rules. The policy file is `~/umbrel/app-data/cracklebuff-headscale/data/policy/policy.hujson`
(or your apps data folder if you moved it). Edit it with `sudo`, check it, then restart the app:

```sh
sudo nano ~/umbrel/app-data/cracklebuff-headscale/data/policy/policy.hujson
$HS policy check -f /etc/headscale-policy/policy.hujson
# then restart the app from the umbrelOS app menu
```

See [`examples/policy.example.hujson`](examples/policy.example.hujson) and the
[policy reference](https://headscale.net/stable/ref/policy/).

**Important:** in Headscale an empty policy, or `{}`, means **allow all**. To prevent that by accident, the app
refuses to start (status `implicit_allow_all`) if the file has no `"acls"` or `"grants"` list. If you really want
everyone to reach everything, say so explicitly:
`{"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]}`.

## Admin commands

```sh
HS="sudo docker exec cracklebuff-headscale_headscale_1 headscale"
$HS nodes list                         # devices
$HS nodes approve-routes -i <id> -r 192.168.1.0/24   # subnet route
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
| `HS_ACME_EMAIL` | *(empty)* | Optional Let's Encrypt contact e-mail. |
| `HS_MAGICDNS_DOMAIN` | `tailnet.internal` | Base domain for device names. Must not equal or contain the public domain. |
| `HS_TAILSCALE_DERP` | `false` | `true` adds Tailscale Inc.'s public relays as a fallback. Traffic stays end-to-end encrypted, but Tailscale's relays see device IPs and traffic volume. |
| `HS_NODE_EXPIRY` | `0` | Key expiry for new user devices, e.g. `180d`. `0` = never. |
| `HS_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. |

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

## Backup and restore

Everything lives in `~/umbrel/app-data/cracklebuff-headscale/data/`:

| Path | Contents | Secret? |
| --- | --- | --- |
| `lib/noise_private.key` | Server identity. If lost, **every device must re-login**. | **Yes** |
| `lib/derp_server_private.key` | Embedded relay identity | **Yes** |
| `lib/db.sqlite*` | Users, devices, routes, API key hashes | Yes (sensitive) |
| `lib/cache/` | Let's Encrypt account key and certificate | Yes |
| `policy/policy.hujson` | Your access policy | No (but private) |
| `config/`, `www/`, `status/` | Regenerated on every start | No |

Backup (consistent copy of the database):

```sh
# stop the app in umbrelOS first, then:
sudo tar -C ~/umbrel/app-data/cracklebuff-headscale/data -czf headscale-backup-$(date +%F).tgz lib policy
sudo chmod 600 headscale-backup-*.tgz
```

Treat the archive like a password. Encrypt it before putting it in the cloud. umbrelOS's own backups also
contain these keys, so protect that destination too.

Restore: install the app (leave it unconfigured), stop it, extract the archive into
`~/umbrel/app-data/cracklebuff-headscale/data/` with `sudo tar -xzf ...`, set the same `HS_SERVER_DOMAIN`, and
start it. On start the app fixes ownership (uid 65532) and modes (dirs 0700, files 0600). It refuses to start if
it finds symlinks or device files there.

## Upgrades

App updates replace only the compose file and manifest. Your `data/` folder, keys, database and policy are
kept, and the config is re-rendered from settings on every start.

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
routes, API key hashes), your access policy, and your home LAN reachable through subnet routes or exit nodes.

**What the control server can do:** Headscale decides which devices exist and which may talk to each other.
Whoever controls it can add a rogue device to your network and give it access (Tailscale has a
"tailnet lock" feature for this, which **Headscale does not support**). Traffic between devices is end-to-end
encrypted with WireGuard, and the server never sees it, but it can steer who you encrypt to. Protect
it like the keys to your home network.

| Attacker | Exposure | Mitigations in this app |
| --- | --- | --- |
| Internet (anyone) | TCP 443 and UDP 3478 | Only Headscale is exposed, as a non-root user with a read-only filesystem, no capabilities, `no-new-privileges` and a PID limit. TLS 1.2+ only (Go). Metrics/debug/gRPC on localhost only. Joining needs an admin approval (no pre-auth keys are created). REST API needs an API key (none are created). Embedded DERP requires clients known to this server (`verify_clients`). |
| Internet → relay abuse | DERP/STUN | `verify_clients: true`; STUN is stateless. |
| A device in your tailnet | Other devices, LAN | Default-deny policy; fail-closed check against an empty/`{}` policy; subnet routes and exit nodes need explicit approval. |
| LAN users | Status page | Behind the umbrelOS login (app proxy). It shows only domain, settings and a health boolean. |
| Other Umbrel apps | Docker network | Headscale runs on its own private bridge network (`edge`), not `umbrel_main_network`, so a compromised Headscale cannot reach other apps' internal ports. It does not mount the Docker socket or other apps' data. The init helper has no network at all. |
| Umbrel admin / shell | Everything | Full trust: can read keys and run `headscale` commands. Use a strong umbrelOS password and keep SSH off the internet. |
| Supply chain | Images | Images pinned by digest; Headscale binary checked against upstream `checksums.txt` at packaging time. |

**Out of scope / residual risks:** a compromise of Headscale itself (keep it updated), DNS hijacking of your
name (an attacker would also need a valid certificate), your router's security, physical access to the Umbrel,
and denial-of-service against your home connection.

## Hardening notes

- **Keep the app updated.** Watch [Headscale releases](https://github.com/juanfont/headscale/releases) and
  [security advisories](https://github.com/juanfont/headscale/security/advisories).
- **Keep the default-deny policy** and add narrow rules. Prefer groups and tags over `*`.
- **Set `HS_NODE_EXPIRY`** (e.g. `180d`) if devices can be lost or stolen; expire or delete lost devices.
- **Avoid long-lived credentials.** Do not create reusable pre-auth keys or API keys unless needed. Give them
  short expiry, and expire them after use (`headscale apikeys expire`, `headscale preauthkeys expire`).
- **Leave `HS_TAILSCALE_DERP=false`** unless relaying is unreliable. The embedded relay is used first either way.
- **Forward only 443/tcp and 3478/udp.** The REST API (`/api/v1`, `/swagger`) is served on the public port by
  upstream Headscale and cannot be turned off; it rejects requests without a valid API key.
- **HSTS** is not sent by Headscale. Browsers are only used for the `/register` and `/apple`/`/windows` help
  pages, so this has little impact.
- **Certificate rate limits.** Scanners that only offer RSA can make Headscale request a second (RSA)
  certificate. Let's Encrypt allows 5 identical certificates per week, which is normally plenty.
- **Verify images yourself** before trusting an update:

  ```sh
  crane digest ghcr.io/juanfont/headscale:v0.29.6
  # compare the binary inside the image with the release checksums
  crane export --platform linux/arm64 ghcr.io/juanfont/headscale:v0.29.6 - | tar -xO ko-app/headscale | sha256sum
  curl -sL https://github.com/juanfont/headscale/releases/download/v0.29.6/checksums.txt | grep linux_arm64
  ```

  Upstream images are not cosign-signed, so pinning by digest plus this checksum comparison is the provenance check.

### Container layout and lint justifications

| Service | Image | User | Notes |
| --- | --- | --- | --- |
| `init` | busybox 1.38.0 (digest) | root | Runs once before Headscale, with **no network**, read-only root, `cap_drop: ALL` plus only `CHOWN`, `DAC_OVERRIDE`, `FOWNER` (needed to fix ownership of files copied in by users or restores), `no-new-privileges`. Validates settings, renders the config, creates the default-deny policy if missing, fixes modes, refuses symlinks/devices, and writes the status files. `restart: on-failure`. |
| `headscale` | headscale v0.29.6 (digest) | 65532 | Own `edge` network, read-only root, `cap_drop: ALL`, `no-new-privileges`, `pids_limit`, `mem_limit: 512m`, tmpfs for `/tmp` and the socket dir, config and policy mounted read-only. Healthcheck `headscale health`. |
| `web` | busybox 1.38.0 (digest) | 65534 | Static status page + a tiny CGI reading the status file. Read-only, `cap_drop: ALL`, `no-new-privileges`. |

The Umbrel linter warns about `cap_add`, `security_opt` and top-level `networks`. All are intentional:
`security_opt` only adds `no-new-privileges:true`, the init capabilities are the minimum needed to `chown`/`chmod`
app data, and the extra `edge` network isolates the internet-facing service from other apps.

## How the app is built

`cracklebuff-headscale/docker-compose.yml` is generated. Edit `src/` and run:

```sh
python3 tools/build.py          # regenerate
python3 tools/build.py --check  # CI: fail if stale
sudo BUSYBOX=/path/to/busybox tests/test-init.sh   # init script tests
```

See [`tests/README.md`](tests/README.md).

## Reporting security issues

See [SECURITY.md](SECURITY.md). Vulnerabilities in Headscale itself go to the
[Headscale project](https://github.com/juanfont/headscale/security).

## License

Packaging: MIT, see [LICENSE](LICENSE). Headscale: BSD-3-Clause, © the Headscale authors.
