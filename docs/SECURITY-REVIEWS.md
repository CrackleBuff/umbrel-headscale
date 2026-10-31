# Security reviews

This file records which security reviews this packaging has had.

**These were AI-assisted reviews, not a professional human audit.** Several AI models reviewed the code. A
person, working with an AI agent, then checked every claim by hand against the code, the Headscale and
umbrelOS source, and test runs. Real issues were fixed, with regression tests where code changed. Claims that
did not hold up are listed below with the reason. AI reviewers miss things and sometimes invent them, so treat
this as a record of what was checked, not as a guarantee.

"Blind" means the reviewer got only the repository and a review prompt, without earlier findings. All prompts
were scrubbed of secrets and deployment details.

## Reviews

| Date | Reviewer | Blind | Commit reviewed | Findings | Real / rejected | Fixed in |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-26 | Security-audit workflow (AI agent, first pass, incl. TLS scan and image CVE scan of a test deployment) | n/a (first review) | 5f834a1 | 2 low + 2 needing validation | 2 / 0 (2 still open, see below) | 5fbb08b |
| 2026-10-26 | qwen3.5-122b-a10b (local, repo split into 5 parts) | yes | 5fbb08b | 24 | 5 / 19 | 8c62da0, 62e6cf4 |
| 2026-10-26 | grok-4.7 | yes | 5fbb08b | 12 | 10 / 2 | 8c62da0 |
| 2026-10-26 | grok-4.6 | yes | 5fbb08b | 13 | 11 / 2 | 8c62da0, 62e6cf4 |
| 2026-10-26 | grok-4.20-multi-agent | yes | 5fbb08b | 5 | 3 / 2 | 8c62da0 |
| 2026-10-26 | anthropic/claude-opus-5.5 | yes | 8c62da0 | 14 + 4 info | 11 / 3 (+4 info notes added) | 62e6cf4 |
| 2026-10-26 | openai/gpt-6.1-sol | yes | 8c62da0 | 10 | 6 / 4 | 62e6cf4 |
| 2026-10-26 | openai/gpt-6.1-sol, critique pass | no: saw the first-pass audit, the earlier verdicts and the fixed tree | 62e6cf4 (before commit) | 5 | 5 / 0 (2 only partly) | 62e6cf4 |

Counts are per numbered finding and are approximate for the qwen, grok-4.6 and grok-4.20-multi-agent rows, where some calls were judgement calls. "Real" includes partly-correct findings and documentation-only issues. One
low-risk item was accepted rather than fixed (see below). Several models often reported the same issue.

## Round 1: first-pass audit (5f834a1 → 5fbb08b)

- **Real:** Headscale creates its database 0644 (init resets it to 0600; the 0700 folder blocks access
  anyway). The REST API and Swagger page are reachable from the internet (upstream cannot turn them off; they
  need an API key and none is created; documented).
- **Fixed during the audit:** an empty or `{}` policy (allow-all in Headscale) now keeps the app inert;
  Headscale moved to its own Docker network; memory limits; init restarts on failure.
- **Still open:** no outside port scan of a real deployment; `govulncheck` not run on the binary.

## Round 2: four blind reviews (5fbb08b → 8c62da0)

Real issues found and fixed:

- A line break inside a setting could inject extra lines into `config.yaml`. All settings now reject
  non-printable characters (tests added).
- The allow-all guard was a text search. `"acls": null`, a list inside a comment, or a nested key would pass,
  and Headscale reads all of those as allow-all. Replaced with a scanner that needs a top-level `acls` or
  `grants` list (13 tests).
- Init followed symlinks in `www/` and `status/`, and kept writing after finding unsafe files. Now it refuses
  and writes nothing.
- An invalid expiry setting reached shell arithmetic and could crash init. Arithmetic now only runs on
  validated values (tests added).
- Nothing checked the pinned image against the upstream release. Added `tools/verify_image.py` to CI.
- Docs overstated network isolation, the DNS-hijack risk, and the status page's login protection; IPv6
  exposure and the open join queue were not mentioned. All corrected.
- Default device expiry changed from never to 180 days. tmpfs mounts are now `noexec,nosuid,nodev`. The
  example policy now warns about auto-approved routes.

Notable rejected claims:

- **Root command execution through the expiry setting (grok-4.7):** tested on busybox. No command runs; it was
  a crash bug (fixed).
- **"busybox wget cannot do HTTPS" (grok-4.7, multi-agent):** tested, it can. The real gap was that it does not
  verify certificates (documented, later moved out of the status page).
- **Symlink race in init, SSRF via the domain setting, API exposure in inert mode, XSS on the status page
  (qwen):** the domain is validated by regex, inert mode listens on localhost only, and the page uses
  `textContent` on allow-listed values.
- **Database filled by pending joins (grok-4.6):** pending joins are held in memory, not in the database.
- **Install alpine and `apk` at runtime (multi-agent):** that would weaken supply-chain pinning.

## Round 3: two blind reviews and a critique pass (8c62da0 → 62e6cf4)

Real issues found and fixed:

- **Policy guard bypass on reload (both blind reviews):** a Headscale-only restart or SIGHUP read the policy
  file directly, skipping the guard. Headscale now reads only a checked copy written by init.
- **Hidden control characters (critique pass):** a `\001` byte inside a comment could hide an allow-all policy
  from the scanner. Reproduced; Headscale reads such a file as allow-all. Files with control characters are
  now refused.
- **Image check gaps (both blind reviews, critique):** a later image layer could swap the binary for a link,
  delete it, or use path aliases such as `ko-app/./headscale`, and the image environment was not checked.
  `verify_image.py` now applies layers in order and checks the entrypoint and environment (18 offline tests).
  The docs say this proves consistency with the release, not who built it.
- **Status page made outbound requests (both blind reviews, critique):** it sat on the shared app network and
  followed redirects. A separate unprivileged `probe` container now sends one request per path and never
  follows redirects. The status page makes no requests, and ignores old or mismatched results.
- **Find errors counted as safe (Opus):** the symlink/device check now fails closed if `find` errors.
- **Updates have root-level trust (Opus):** documented. `tools/check_compose.py` blocks host hooks,
  privileges, the Docker socket, extra mounts, networks or ports in CI. The critique pass found gaps in the
  first version, so it is now an allow-list (20 negative tests).
- **Documentation:** backup command now uses `umask 077`; Tailscale relays are chosen by speed, not only as a
  fallback; Let's Encrypt no longer sends expiry e-mails; NAT-loopback advice corrected; warnings for
  Docker-socket apps, debug logging and a real domain as MagicDNS base; uninstall deletes data; a compromised
  server can push DNS settings and routes.

Notable rejected claims:

- **Duplicate, case-variant or escaped `acls` keys bypass the guard (both blind reviews):** tested against
  Headscale v0.29.6's parser, which rejects such files.
- **File sharing between devices bypasses deny-all (gpt-6.1-sol):** tested; with `"acls": []` devices are not
  peers at all.
- **No log rotation (gpt-6.1-sol):** umbrelOS's Docker config already rotates logs.
- **Config keys and the umbrelOS settings feature unverified (Opus):** checked against Headscale's
  `config-example.yaml` and umbrelOS's app schema.
- **Accepted, not fixed:** a brief permission race while Headscale is running only lets you break your own
  install. Symlinked host folders need host admin access, which already means full control.

## First real umbrelOS install (0.29.6 → 0.29.6-1)

Not a security review; recorded because the fixes touch the setup script that runs as root.

- **Install hang (14ea675):** umbrelOS rewrites the compose file on install and breaks `\` line continuations
  in embedded scripts, so init failed and restarted forever. Scripts no longer use them; `tools/build.py`
  refuses them; CI also runs the init tests on the script as umbrelOS rewrites it
  (`tools/umbreld_rewrite.py`). No check or hardening was removed.
- **Status page key (de2827b):** the probe reported the all-zero `legacyPublicKey` from `/key`. It now parses
  `publicKey` only. Display only; nothing trusted the value.
- **Docs:** `HS_NODE_EXPIRY=0` (never expire) is documented as an opt-in trade-off. The default stays `180d`.

## Headscale 0.29.7 update review (2026-10-31)

AI-assisted review of the upstream bump from v0.29.6 to v0.29.7, checked against the public git
compare, the GitHub release, the GHCR index, and this repository's generated compose diff. Not a
professional audit, and not a re-review of the packaging beyond confirming the compose diff.

### Tag and release

- `v0.29.7` is a lightweight tag (the ref points at a commit, not an annotated tag object). The commit
  `c9cf210b8bc84d13177e18b91f555788a44b47b6` is **unsigned**, same as `v0.29.6`. There is no signed tag
  and no signed commit to verify.
- The committer is Kristoffer Dalby (`kradalby`, kristoffer@dalby.cc), who also committed `v0.29.6`.
  GitHub's collaborator-permission API was not available to this review (HTTP 403), so the maintainer
  role is inferred from that release history, not from a permission lookup.
- The tag sits on `release-branch/0.29` and is 42 commits ahead of `v0.29.6` with no commits behind it.
  It is not on `main`; that branch has moved on, which matches a stable release branch.
- The GitHub Release was published by `github-actions[bot]` on 2026-10-30. The Release workflow run
  [41034314476](https://github.com/juanfont/headscale/actions/runs/41034314476) was started by
  `kradalby` on the tag push and succeeded. That workflow only runs its publish job when
  `github.repository == 'juanfont/headscale'`, and it logs into `ghcr.io` as the repository owner.
  Goreleaser publishes `ghcr.io/juanfont/headscale` (and Docker Hub `headscale/headscale`) for
  `linux/amd64` and `linux/arm64`. The debug image is a separate `-debug` tag. This app pins the
  non-debug tag.
- `checksums.txt` was downloaded. Its SHA-256 matches the release asset digest, and every other asset's
  GitHub digest matches the line in `checksums.txt`, including `headscale_0.29.7_linux_arm64`
  (`4357b38ac63c1e425f190819fd2ee078f13e01a6d7559b15811154e2475df5e4`).

### Image

- Tag `v0.29.7` on `ghcr.io/juanfont/headscale` is an OCI index,
  `sha256:11f81665e842809db9fe3006a38c56a66e968baa5abd4bac498e86445572b970`. The registry
  `Docker-Content-Digest` matches the SHA-256 of the index body. The index lists `linux/amd64` and
  `linux/arm64` (`v8` variant). The arm64 manifest is
  `sha256:8f64e19972c001efa48be48a9d81a2f86c4f239767ee3ffd50de119b01fe96f1`.
- Both platform configs are the upstream ko defaults this repo already checks: entrypoint
  `/ko-app/headscale`, no cmd, workdir `/`, and the same three environment variables. The image label
  and annotation `org.opencontainers.image.source` are `https://github.com/juanfont/headscale`. History
  ends in `ko build github.com/juanfont/headscale/cmd/headscale`. The image default user is still `0`;
  the compose file still forces uid 65532.
- No GitHub artifact attestation for the index, the arm64 manifest, or the release commit (API 404).
  No cosign tag and no OCI referrers. That matches this repo's existing note that upstream images are
not cosign-signed. `tools/verify_image.py` then applied the layers and checked the final
`/ko-app/headscale`: amd64 `e827fc9b12d958bc95b081c4401dd63f8e0471d025b45b508535a920532150a8` and
arm64 `4357b38ac63c1e425f190819fd2ee078f13e01a6d7559b15811154e2475df5e4`, both equal to
`checksums.txt` and to the GitHub asset digests. The image config (entrypoint, command, workdir,
environment) matched on both architectures.
- Goreleaser in this release stopped pinning the distroless base by digest and uses the floating name
  `gcr.io/distroless/base-debian13`. The published image still records the base it was built from
  (arm64 base `sha256:39c7e3517bb0f9a3c27b4181d1b1ea3d47427c669240c06d97eadfccb2d7fe54`). Pinning our
  image digest freezes that build. The arm64 trust bundle
  `/etc/ssl/certs/ca-certificates.crt` (148 certificates) has no subject matching emSign or eMudhra.
  A dpkg `md5sums` file in the image still names `emSign_ECC_Root_CA_-_C3.crt`; that certificate file
  is not in the image and not in the trust bundle.

### Source diff v0.29.6...v0.29.7

95 files, 42 commits. 41 are by `kradalby`. One, `f20366b3`, is authored by `arkie` and
committed by `kradalby`: a cherry-pick of "emit SSH environment capability by default" so a policy
`acceptEnv` is actually sent to clients. It adds `nodecap.SSHEnvironmentVariables` next to the SSH
capability this server already advertised. It does not add an SSH rule. This app's default policy has
no SSH section. The changelog says to upgrade destination devices to Tailscale 1.104.4 before using
`acceptEnv`, because older clients can disclose forwarded values. `hscontrol/db/db.go`, `schema.sql` and `versioncheck.go` are
byte-identical, so there is no new schema migration. On startup Headscale still runs the existing
migration list and then writes its own version into `database_versions`. The version check allows any
patch change inside the same minor version, in either direction, and refuses a minor downgrade.

Nothing in the server code adds a new outbound call, telemetry sender, or log upload. `logtail` stays
a config flag and this app still sets it to `false`. OpenTelemetry appears only as an indirect module
bump pulled in with Tailscale. The new direct module `tailscale.com/client/tailscale/v2` is imported
by the test-capture types, not by the server command. `github.com/hashicorp/golang-lru/v2` is pinned
to a pseudo-version so the auth cache can be closed; that commit
(`235099c106fc`) is a verified dependabot workflow change on the library's main branch, not a new
network client.

`tailscale.com` moves from v1.102.0 to v1.104.4, which is the stated DERP read bound and the client
library those nodes need. `golang.org/x/net` stays at v0.60.0 and `google.golang.org/grpc` stays at
v1.83.2 (the versions pinned in 0.29.6). `golang.org/x/crypto` moves 0.57.0 to 0.58.0 and
`golang.org/x/text` 0.42.0 to 0.43.0. OSV reports nothing for `tailscale.com` v1.104.4. It still
reports CVE-2026-78661 and CVE-2026-97045 in `golang.org/x/net` v0.60.0 (HTML parser, fixed in
v0.62.0) and an unmaintained-package warning for `golang.org/x/crypto/openpgp`. Both already applied
to 0.29.6's module set. This release neither introduces nor clears them. The 0.29.7 server diff adds
no HTML parser and no OpenPGP use, and this packaging does not use either.

Auth changes tighten the public registration path: pending approvals are no longer evicted when the
cache is full, follow-ups from another machine are refused, and another user's login on a tagged
device creates a new device instead of taking over the tagged one. `/metrics` is removed from the
Noise handler. Noise request bodies and idle tunnels time out after 30 seconds. Client reports are
capped. No config key was added or removed. `config-example.yaml` only changes a comment.
`derp.server.region_id` is still a number; this app's `999` is unchanged.

### What this server was exposed to

Headscale published no CVE IDs and the GitHub security-advisory list for the repository is empty.
The release names twelve oss-scanner findings (ANT-2026-MLP8ZR5T, ANT-2026-LYVGXVSW,
ANT-2026-AWGRB7O1, ANT-2026-QMCAFJ1Q, ANT-2026-RQS7JAPP, ANT-2026-5B6KE87K, ANT-2026-KFCFFM34,
ANT-2026-K903ZEUA, ANT-2026-NM50ZP4N, ANT-2026-ZC18AF82, ANT-2026-NWTIBB02, ANT-2026-MX8FKG4K) and
the Tailworm report. Reports for those ANT IDs are not published. From the changelog, this
deployment was on the affected side of the server issues:

- Anyone who can open the public control port could start a registration. The old cache evicted
  pending approvals, and a stalled Noise body or idle tunnel was not timed out. This app publishes
  that port.
- `/metrics` was served inside the Noise connection, including to a device that had not registered.
  The separate metrics listener was already `127.0.0.1:9090` and was not published; that part was
  not exposed. No config change: leaving the listener on localhost is still what we want. An empty
  `metrics_listen_addr` would turn the listener off, which this app does not need.
- OIDC email checks and the PostgreSQL expiry bug do not apply: this app does not use OIDC or
  PostgreSQL.

Tailscale TS-2026-014, TS-2026-015, TS-2026-016 and TS-2026-017 are fixed in Tailscale 1.104.4 on
the device (`tailscaled`), not by replacing this server. They matter only for nodes that use
Tailscale SSH or Serve. This app's default policy has no SSH rules.

### Packaging diff

The only compose change is the Headscale image reference. Busybox digests, users, capabilities,
`no-new-privileges`, read-only roots, ports, networks, mounts and tmpfs flags are unchanged. The
rendered config is unchanged. 0.29.7 does not require a config change.

## Not covered

- No professional human security audit.
- Installed on one real umbrelOS device (with migrated data) only; no wider testing. The manual
  integration test in `tests/README.md` was done for v0.29.6, not for v0.29.7.
- No external TCP/UDP port scan of a real deployment.
- `govulncheck` not run against the pinned Headscale binary. The 0.29.7 review queried OSV for the
  module versions named above instead.
- Headscale itself was not audited beyond the v0.29.6 to v0.29.7 diff described above.

Found something? See [SECURITY.md](../SECURITY.md).
