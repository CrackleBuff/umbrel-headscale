#!/usr/bin/env python3
"""Guard rails for the generated app (run in CI).

Fails if the app directory or compose file gains anything that would give the
app more power on the Umbrel than it has today: host hooks or exports.sh
(these run as root on the host), privileged mode, host namespaces, devices,
the Docker socket, mounts outside the app's data folder, extra capabilities,
or a service without the usual hardening. This catches mistakes in review; it
cannot stop someone who controls the repository from removing the check.
"""
import pathlib, sys, yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "cracklebuff-headscale"
errors = []

for bad in ("hooks", "exports.sh", "torrc.template"):
    if (APP / bad).exists():
        errors.append(f"{bad}: runs on the host; not allowed")

compose = yaml.safe_load((APP / "docker-compose.yml").read_text())
# Allow-lists: anything not listed here fails, so new Compose features
# (configs, secrets, external networks, ...) need a deliberate review.
TOP = {"version", "services", "networks"}
SVC_KEYS = {"image", "user", "command", "entrypoint", "restart", "read_only", "cap_drop", "cap_add",
            "security_opt", "network_mode", "networks", "volumes", "ports", "depends_on", "healthcheck",
            "pids_limit", "mem_limit", "tmpfs", "stop_grace_period"}
EXPECTED_NETWORKS = {"init": None, "web": None, "headscale": ["edge"], "probe": ["edge"]}
if set(compose) - TOP:
    errors.append(f"top-level keys not allowed: {sorted(set(compose) - TOP)}")
if compose.get("networks") != {"edge": {}}:
    errors.append("networks: only a plain private 'edge' network is allowed")
if set(compose["services"]) != set(EXPECTED_NETWORKS) | {"app_proxy"}:
    errors.append(f"unexpected service list {sorted(compose['services'])}")
for name, svc in compose["services"].items():
    if name == "app_proxy":
        env = svc.get("environment") or {}
        if set(svc) != {"environment"} or set(env) != {"APP_HOST", "APP_PORT"}:
            errors.append("app_proxy: only APP_HOST and APP_PORT may be set (keeps the umbrelOS login)")
        continue
    where = f"service {name}"
    if set(svc) - SVC_KEYS:
        errors.append(f"{where}: keys not allowed: {sorted(set(svc) - SVC_KEYS)}")
    if svc.get("networks") != EXPECTED_NETWORKS.get(name, "?"):
        errors.append(f"{where}: unexpected networks {svc.get('networks')!r}")
    if name == "headscale" and (svc.get("entrypoint") != ["/ko-app/headscale"] or svc.get("command") != ["serve"]):
        errors.append("headscale: entrypoint/command must be /ko-app/headscale serve")
    if name != "headscale" and "entrypoint" in svc:
        errors.append(f"{where}: entrypoint not allowed")
    if svc.get("network_mode") not in (None, "none"):
        errors.append(f"{where}: network_mode {svc['network_mode']!r} not allowed")
    if "@sha256:" not in svc.get("image", ""):
        errors.append(f"{where}: image not pinned by digest")
    if svc.get("read_only") is not True:
        errors.append(f"{where}: read_only must be true")
    if svc.get("cap_drop") != ["ALL"]:
        errors.append(f"{where}: cap_drop must be [ALL]")
    if "no-new-privileges:true" not in (svc.get("security_opt") or []):
        errors.append(f"{where}: no-new-privileges required")
    caps = svc.get("cap_add") or []
    if name == "init":
        if svc.get("network_mode") != "none":
            errors.append("init: must have network_mode: none")
        if sorted(caps) != ["CHOWN", "DAC_OVERRIDE", "FOWNER"]:
            errors.append(f"init: unexpected cap_add {caps}")
    else:
        if caps:
            errors.append(f"{where}: cap_add not allowed")
        if str(svc.get("user", "")).split(":")[0] in ("", "0", "root"):
            errors.append(f"{where}: must run as a non-root user")
    for v in svc.get("volumes") or []:
        src = v.split(":")[0] if isinstance(v, str) else "<long syntax>"
        if not src.startswith("${APP_DATA_DIR}/data/") or ".." in src:
            errors.append(f"{where}: volume {v!r} outside the app's data folder")
    for p in svc.get("ports") or []:
        if str(p) not in ("30443:8443/tcp", "3478:3478/udp") or name != "headscale":
            errors.append(f"{where}: unexpected published port {p!r}")
    if "docker.sock" in yaml.safe_dump(svc):
        errors.append(f"{where}: Docker socket not allowed")

if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"compose guard rails OK ({len(compose['services'])} services)")
