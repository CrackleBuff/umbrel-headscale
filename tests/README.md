# Tests

- `test-init.sh` runs the init script (extracted from the generated compose file) against temporary
  directories with a static busybox and checks validation, rendered config, permissions, the default-deny
  policy, the empty-policy guard and symlink refusal. Needs root (for `chown`):
  `sudo BUSYBOX=/path/to/busybox tests/test-init.sh`. Use the busybox from the pinned image
  (`tools/fetch-busybox.sh DEST`, needs Docker), as CI does: distribution builds differ (Ubuntu's
  `busybox-static` has no `find -delete`, so init fails closed there). The script checks for this first. When
  an assertion fails it prints the output of the last init run.
- `run-init.sh OUTDIR [VAR=value ...]` runs the init script once, for manual inspection.
- The same script also checks the checked policy copy Headscale reads (`config/policy.hujson`), the `probe/`
  folder, and that the status CGI makes no network requests and only shows strictly-formatted probe values.
- `test_verify_image.py` feeds `tools/verify_image.py` fake image layers (later symlink, hard link, whiteout,
  opaque directory, replaced parent, path aliases like `ko-app/./headscale`) and checks each is caught. No network.
- `test_check_compose.py` makes forbidden changes to the compose file (privileged, Docker socket, host mounts,
  configs, external networks, env overrides, extra ports, login removal, ...) and checks the guard rails reject each.

Manual integration test (done for v0.29.6 on a Raspberry Pi 4, arm64): deploy the compose file without the
`app_proxy` service and without published ports, then check: unconfigured → inert and healthy, `data/lib`
empty; configured → keys created 0600 by uid 65532; settings change → keys and users kept; listeners
`:8443` and `:3478/udp` only, with `127.0.0.1:9090` and `127.0.0.1:50443` inside the container.
The `probe` container and the checked policy copy were added later and have not yet been through this manual
test; they are covered by the automated tests above.
