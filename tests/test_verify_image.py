#!/usr/bin/env python3
"""Offline tests for tools/verify_image.py's layer logic (no network)."""
import hashlib, io, pathlib, sys, tarfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tools"))
from verify_image import final_binary  # noqa: E402

GOOD = b"genuine headscale"
EVIL = b"payload"


def layer(*entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, kind, arg in entries:
            ti = tarfile.TarInfo(name)
            if kind == "dir":
                ti.type = tarfile.DIRTYPE; t.addfile(ti)
            elif kind == "file":
                ti.size = len(arg); t.addfile(ti, io.BytesIO(arg))
            elif kind == "sym":
                ti.type = tarfile.SYMTYPE; ti.linkname = arg; t.addfile(ti)
            elif kind == "hard":
                ti.type = tarfile.LNKTYPE; ti.linkname = arg; t.addfile(ti)
    buf.seek(0)
    return tarfile.open(fileobj=buf)


base = lambda: layer(("ko-app", "dir", None), ("ko-app/headscale", "file", GOOD))
good = ("file", hashlib.sha256(GOOD).hexdigest())
cases = [
    ("genuine", [base()], good),
    ("./ prefix", [layer(("./ko-app/", "dir", None), ("./ko-app/headscale", "file", GOOD))], good),
    ("later symlink", [base(), layer(("payload", "file", EVIL), ("ko-app/headscale", "sym", "/payload"))], ("link", None)),
    ("later hard link", [base(), layer(("payload", "file", EVIL), ("ko-app/headscale", "hard", "payload"))], ("link", None)),
    ("later replaced", [base(), layer(("ko-app/headscale", "file", EVIL))], ("file", hashlib.sha256(EVIL).hexdigest())),
    ("whiteout", [base(), layer(("ko-app/.wh.headscale", "file", b""))], ("missing", None)),
    ("opaque dir", [base(), layer(("ko-app", "dir", None), ("ko-app/.wh..wh..opq", "file", b""))], ("missing", None)),
    ("opaque then genuine", [base(), layer(("ko-app/.wh..wh..opq", "file", b""), ("ko-app/headscale", "file", GOOD))], good),
    ("parent symlink", [base(), layer(("evil", "dir", None), ("evil/headscale", "file", EVIL), ("ko-app", "sym", "evil"))], ("bad-parent", None)),
    ("parent whiteout", [base(), layer((".wh.ko-app", "file", b""))], ("bad-parent", None)),
    ("binary is a dir", [base(), layer(("ko-app/headscale", "dir", None), ("ko-app/headscale/x", "file", EVIL))], ("other", None)),
    ("missing", [layer(("ko-app", "dir", None))], ("missing", None)),
    ("alias ./", [base(), layer(("ko-app/./headscale", "file", EVIL))], ("file", hashlib.sha256(EVIL).hexdigest())),
    ("alias //", [base(), layer(("ko-app//headscale", "file", EVIL))], ("file", hashlib.sha256(EVIL).hexdigest())),
    ("alias ..", [base(), layer(("x/../ko-app/headscale", "sym", "/payload"))], ("link", None)),
    ("escape ..", [base(), layer(("../../ko-app/headscale", "sym", "/payload"))], ("link", None)),
    ("alias whiteout", [base(), layer(("./ko-app/./.wh.headscale", "file", b""))], ("missing", None)),
    ("alias parent", [base(), layer(("ko-app/../.wh.ko-app", "file", b""))], ("bad-parent", None)),
]
fails = 0
for name, layers, want in cases:
    got = final_binary(layers)
    ok = got == want
    fails += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {got[0]}")
print(f"passed={len(cases) - fails} failed={fails}")
sys.exit(1 if fails else 0)
