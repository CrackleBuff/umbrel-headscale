#!/usr/bin/env python3
"""Each forbidden change to the compose file must make tools/check_compose.py fail."""
import copy, pathlib, subprocess, sys, tempfile, shutil, yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
base = yaml.safe_load((ROOT / "cracklebuff-headscale/docker-compose.yml").read_text())


def mutate(fn):
    d = copy.deepcopy(base); fn(d); return d


cases = {
    "privileged": lambda d: d["services"]["web"].update(privileged=True),
    "docker socket": lambda d: d["services"]["web"]["volumes"].append("/var/run/docker.sock:/s"),
    "host path": lambda d: d["services"]["probe"]["volumes"].append("/:/host:ro"),
    "parent escape": lambda d: d["services"]["probe"]["volumes"].append("${APP_DATA_DIR}/data/../../x:/x"),
    "long mount": lambda d: d["services"]["probe"]["volumes"].append({"type": "bind", "source": "/", "target": "/h"}),
    "configs": lambda d: (d["services"]["init"].update(configs=["c"]), d.update(configs={"c": {"file": "/var/run/docker.sock"}})),
    "external net": lambda d: d["networks"].update(edge={"external": True, "name": "umbrel_main_network"}),
    "web on edge": lambda d: d["services"]["web"].update(networks=["edge"]),
    "host network": lambda d: d["services"]["probe"].update(network_mode="host"),
    "env override": lambda d: d["services"]["headscale"].update(environment={"HEADSCALE_POLICY_PATH": "/x"}),
    "entrypoint": lambda d: d["services"]["headscale"].update(entrypoint=["/bin/sh"]),
    "cap_add": lambda d: d["services"]["probe"].update(cap_add=["NET_RAW"]),
    "root user": lambda d: d["services"]["probe"].update(user="0:0"),
    "not read-only": lambda d: d["services"]["web"].update(read_only=False),
    "proxy auth off": lambda d: d["services"]["app_proxy"]["environment"].update(PROXY_AUTH_ADD="false"),
    "extra port": lambda d: d["services"]["headscale"]["ports"].append("8080:8080"),
    "unpinned": lambda d: d["services"]["web"].update(image="busybox:latest"),
    "pid host": lambda d: d["services"]["web"].update(pid="host"),
}
fails = 0
with tempfile.TemporaryDirectory() as t:
    tmp = pathlib.Path(t)
    shutil.copytree(ROOT / "tools", tmp / "tools")
    app = tmp / "cracklebuff-headscale"; app.mkdir()

    def run(d):
        (app / "docker-compose.yml").write_text(yaml.safe_dump(d))
        return subprocess.run([sys.executable, str(tmp / "tools/check_compose.py")], capture_output=True).returncode

    if run(base) != 0:
        print("FAIL unmodified compose rejected"); fails += 1
    (app / "hooks").mkdir()
    if run(base) == 0:
        print("FAIL hooks/ accepted"); fails += 1
    (app / "hooks").rmdir()
    for name, fn in cases.items():
        rc = run(mutate(fn))
        print(("ok  " if rc else "FAIL") + " rejects " + name); fails += rc == 0
print(f"passed={len(cases) + 2 - fails} failed={fails}")
sys.exit(1 if fails else 0)
