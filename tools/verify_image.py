#!/usr/bin/env python3
"""Check that the pinned Headscale image contains the official release binary.

Reads the headscale image reference (tag + digest) from the generated compose
file, downloads the image index BY DIGEST from ghcr.io and, for linux/amd64
and linux/arm64:
  * applies the layers in order (including whiteouts, symlinks and hard links)
    and requires the FINAL /ko-app/headscale to be a regular file whose SHA-256
    matches the release's checksums.txt on GitHub;
  * requires the image config (entrypoint, cmd, workdir, environment) to be
    exactly what upstream ships, so no HEADSCALE_* variable can override the
    rendered config.
Exits 1 on any mismatch. Upstream images are not signed and checksums.txt
comes from the same release, so this proves the image matches the published
release, not that the release itself is trustworthy. stdlib only.

  tools/verify_image.py
"""
import gzip, hashlib, io, json, pathlib, posixpath, re, sys, tarfile, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "cracklebuff-headscale" / "docker-compose.yml"
REG = "https://ghcr.io/v2/juanfont/headscale"
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
# Exact upstream image config (ko defaults). Anything else fails the check.
EXPECTED_CONFIG = {
    "Entrypoint": ["/ko-app/headscale"],
    "Cmd": None,
    "WorkingDir": "/",
    "Env": [
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/ko-app",
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
        "KO_DATA_PATH=/var/run/ko",
    ],
}
TARGET = "ko-app/headscale"


def norm(m):
    # Same canonical form the container runtime uses when it unpacks a layer
    # (containerd/moby clean each path inside the image root), so that
    # "ko-app/./headscale", "ko-app//headscale" or "x/../ko-app/headscale"
    # are recognised as the binary too.
    n = posixpath.normpath("/" + m.name).lstrip("/")
    return "" if n == "." else n


def final_binary(layers):
    """Apply OCI layers in order and return ("file", sha256) for the final
    /ko-app/headscale, or (kind, None) if it is missing or not a regular file.
    layers: iterable of tarfile.TarFile objects, lowest layer first."""
    state = {"ko-app": None, TARGET: None}  # path -> (kind, sha256)
    for t in layers:
        members = t.getmembers()
        # Whiteouts in this layer hide entries from LOWER layers only.
        for m in members:
            n = norm(m)
            if n in (".wh.ko-app",):
                state = {"ko-app": None, TARGET: None}
            elif n == "ko-app/.wh..wh..opq" or n == "ko-app/.wh.headscale":
                state[TARGET] = None
            elif n.startswith(".wh.") and n != ".wh..wh..opq":
                pass
            elif n == ".wh..wh..opq":
                state = {"ko-app": None, TARGET: None}
        for m in members:
            n = norm(m)
            if n == "ko-app":
                kind = "dir" if m.isdir() else "other"
                state["ko-app"] = (kind, None)
                if kind != "dir":
                    state[TARGET] = None
            elif n == TARGET:
                if m.isfile() and not m.islnk():
                    state[TARGET] = ("file", hashlib.sha256(t.extractfile(m).read()).hexdigest())
                else:
                    state[TARGET] = ("link" if (m.issym() or m.islnk()) else "other", None)
            elif n.startswith(TARGET + "/"):
                state[TARGET] = ("other", None)
    if not state["ko-app"] or state["ko-app"][0] != "dir":
        return ("bad-parent", None)
    return state[TARGET] or ("missing", None)


def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def blob(token, digest):
    data = get(f"{REG}/blobs/{digest}", {"Authorization": f"Bearer {token}"})
    if "sha256:" + hashlib.sha256(data).hexdigest() != digest:
        sys.exit(f"blob {digest}: content does not match its digest")
    return data


def manifest(token, ref):
    data = get(f"{REG}/manifests/{ref}", {"Authorization": f"Bearer {token}", "Accept": ACCEPT})
    if ref.startswith("sha256:") and "sha256:" + hashlib.sha256(data).hexdigest() != ref:
        sys.exit(f"manifest {ref}: content does not match its digest")
    return json.loads(data)


def main():
    m = re.search(r"image: ghcr\.io/juanfont/headscale:v([0-9.]+)@(sha256:[0-9a-f]{64})", COMPOSE.read_text())
    if not m:
        sys.exit("headscale image (tag@digest) not found in compose file")
    version, digest = m.groups()
    sums = {}
    for line in get(f"https://github.com/juanfont/headscale/releases/download/v{version}/checksums.txt").decode().splitlines():
        h, _, name = line.partition("  ")
        sums[name.strip()] = h
    token = json.loads(get("https://ghcr.io/token?scope=repository:juanfont/headscale:pull"))["token"]
    index = manifest(token, digest)
    failed = False
    for arch in ("amd64", "arm64"):
        want = sums.get(f"headscale_{version}_linux_{arch}")
        entry = [x for x in index.get("manifests", [])
                 if x.get("platform", {}).get("os") == "linux" and x["platform"].get("architecture") == arch]
        if not want or len(entry) != 1:
            print(f"{arch}: missing checksum or platform manifest"); failed = True; continue
        man = manifest(token, entry[0]["digest"])
        # The binary only counts if it is what the container actually runs.
        cfg = json.loads(blob(token, man["config"]["digest"])).get("config", {})
        bad = {k: cfg.get(k) for k, v in EXPECTED_CONFIG.items() if cfg.get(k) != v}
        if bad:
            print(f"{arch}: unexpected image config {bad!r}"); failed = True; continue
        tars = [tarfile.open(fileobj=io.BytesIO(gzip.decompress(blob(token, layer["digest"]))))
                for layer in man["layers"]]
        kind, got = final_binary(tars)
        if kind != "file":
            print(f"{arch}: /{TARGET} in the final image is {kind}, not a regular file"); failed = True; continue
        ok = got == want
        failed |= not ok
        print(f"{arch}: {'OK' if ok else 'MISMATCH'} image={got} release={want}")
    if failed:
        sys.exit(1)
    print(f"headscale v{version} @ {digest}: binaries match the release checksums")


if __name__ == "__main__":
    main()
