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

- Images pinned by version and digest; no `latest` tags.
- No secrets or host-specific values in the repository. All keys are generated on the device.
- Headscale runs as uid 65532 with a read-only filesystem, no capabilities, `no-new-privileges`, and no Docker socket.
- Fails closed: missing or invalid settings, symlinks in the data folder, or a policy without an `acls`/`grants`
  list keep the server inert instead of starting it in an unsafe state.
- Only TCP 443 (→30443) and UDP 3478 need to be reachable from the internet.

See the threat model and hardening notes in the [README](README.md#threat-model).
