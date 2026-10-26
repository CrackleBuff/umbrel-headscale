# Tests

- `test-init.sh` runs the init script (extracted from the generated compose file) against temporary
  directories with a static busybox and checks validation, rendered config, permissions, the default-deny
  policy, the empty-policy guard and symlink refusal. Needs root (for `chown`):
  `sudo BUSYBOX=/path/to/busybox-static tests/test-init.sh`
- `run-init.sh OUTDIR [VAR=value ...]` runs the init script once, for manual inspection.

Manual integration test (done for v0.29.6 on a Raspberry Pi 4, arm64): deploy the compose file without the
`app_proxy` service and without published ports, then check: unconfigured → inert and healthy, `data/lib`
empty; configured → keys created 0600 by uid 65532; settings change → keys and users kept; listeners
`:8443` and `:3478/udp` only, with `127.0.0.1:9090` and `127.0.0.1:50443` inside the container.
