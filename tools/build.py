#!/usr/bin/env python3
"""Build cracklebuff-headscale/docker-compose.yml from src/.

The init script (with the status page files embedded as heredocs) and the
probe script are inlined into the compose file so that it is updated together with the compose file on
app updates (umbrelOS only copies docker-compose.yml, *.template, exports.sh
and hooks on update). Compose interpolates "$", so every "$" is escaped "$$".

  tools/build.py          write the compose file
  tools/build.py --check  exit 1 if the committed compose file is stale
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "cracklebuff-headscale" / "docker-compose.yml"


def heredoc(path, dest, tag):
    body = (SRC / path).read_text()
    assert tag not in body
    return f"cat > {dest} <<'{tag}'\n{body.rstrip()}\n{tag}\n"


def build():
    www = heredoc("index.html", '"$WWW/index.html"', "HSWWWINDEX") + heredoc(
        "status.cgi", '"$WWW/cgi-bin/status"', "HSWWWCGI")
    script = (SRC / "init.sh").read_text().replace("@@WWW_FILES@@\n", www)
    assert "@@" not in script
    # umbrelOS rewrites the compose file and adds a line break before indented
    # lines (tools/umbreld_rewrite.py), which silently breaks "\" continuations.
    for name, text in (("init.sh/www files", script), ("probe.sh", (SRC / "probe.sh").read_text())):
        for n, line in enumerate(text.split("\n"), 1):
            if line.rstrip().endswith("\\"):
                sys.exit(f"{name} line {n}: no backslash line continuations (umbrelOS breaks them)")
    escaped = script.replace("$", "$$")
    # JSON string == valid YAML double-quoted scalar.
    probe = (SRC / "probe.sh").read_text().replace("$", "$$")
    base = (SRC / "compose.base.yml").read_text()
    out = base.replace('"@@INIT_SCRIPT@@"', json.dumps(escaped))
    out = out.replace('"@@PROBE_SCRIPT@@"', json.dumps(probe))
    assert "@@" not in out
    return out


if __name__ == "__main__":
    text = build()
    if "--check" in sys.argv:
        if OUT.read_text() != text:
            print("docker-compose.yml is stale; run tools/build.py", file=sys.stderr)
            sys.exit(1)
        print("docker-compose.yml is up to date")
    else:
        OUT.write_text(text)
        print(f"wrote {OUT.relative_to(ROOT)}")
