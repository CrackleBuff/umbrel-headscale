# Security policy

## Reporting

Please report vulnerabilities in **this packaging** (compose file, init script, status page, documentation)
privately via GitHub: **Security → Report a vulnerability** on
<https://github.com/CrackleBuff/umbrel-headscale>. Do not open a public issue.

Vulnerabilities in **Headscale itself** go to <https://github.com/juanfont/headscale/security>.
Vulnerabilities in **umbrelOS** go to Umbrel.

Please include the app version, umbrelOS version, and steps to reproduce. You should get a reply within a week.

## Supported versions

Only the latest app version in this store is supported. It tracks the latest stable Headscale release.

## What this package promises

- Images pinned by version and digest; no `latest` tags. CI checks that the pinned image's final Headscale binary,
  entrypoint and environment match the upstream release (`tools/verify_image.py`); this proves consistency with
  the release, not who built it.
- CI fails if the app gains host hooks, `exports.sh`, privileged mode, the Docker socket, host namespaces, extra
  capabilities or mounts outside its data folder (`tools/check_compose.py`). This catches mistakes; it cannot
  protect you from a malicious maintainer. Installing or updating any community app means trusting its author
  with root on your Umbrel, so review updates before applying them.
- No secrets or host-specific values in the repository. All keys are generated on the device.
- Headscale runs as uid 65532 with a read-only filesystem, no capabilities, `no-new-privileges`, and no Docker socket.
- Headscale runs on its own Docker network, so it cannot reach other apps' internal (unpublished) ports. It can
  still reach your LAN and the internet like any container.
- Fails closed: missing or invalid settings, symlinks or device files in the data folder, or a policy without a
  top-level `acls`/`grants` list keep the server inert (or stop the app) instead of starting it in an unsafe state.
  Headscale only ever reads a checked copy of the policy, so restarts and reloads cannot pick up an unchecked edit.
- The status page makes no network requests; a separate unprivileged `probe` container on Headscale's network does
  the health check (one request per path, no redirects followed).
- Only TCP 443 (→30443) and UDP 3478 need to be reachable from the internet.

See the threat model and hardening notes in the [README](README.md#threat-model).
