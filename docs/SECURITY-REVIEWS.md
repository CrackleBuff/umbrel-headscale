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

## Not covered

- No professional human security audit.
- Not yet installed and tested on a real umbrelOS device. An earlier version was tested on a Raspberry Pi via
  Portainer; the `probe` container and the checked policy copy were added after that.
- No external TCP/UDP port scan of a real deployment.
- `govulncheck` not run against the pinned Headscale binary.
- Headscale itself was not audited; only this packaging was.

Found something? See [SECURITY.md](../SECURITY.md).
