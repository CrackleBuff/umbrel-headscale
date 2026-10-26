#!/usr/bin/env python3
"""Check that the pinned Headscale image contains the official release binary.

Reads the headscale image reference (tag + digest) from the generated compose
file, downloads the image index BY DIGEST from ghcr.io, extracts
/ko-app/headscale for linux/amd64 and linux/arm64, and compares its SHA-256
with the release's checksums.txt on GitHub. Exits 1 on any mismatch.
Upstream images are not signed, so this is the provenance check. stdlib only.

  tools/verify_image.py
"""
import gzip, hashlib, io, json, pathlib, re, sys, tarfile, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "cracklebuff-headscale" / "docker-compose.yml"
REG = "https://ghcr.io/v2/juanfont/headscale"
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


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
        got = None
        man = manifest(token, entry[0]["digest"])
        # The binary only counts if it is what the container actually runs.
        cfg = json.loads(blob(token, man["config"]["digest"])).get("config", {})
        if cfg.get("Entrypoint") != ["/ko-app/headscale"]:
            print(f"{arch}: unexpected entrypoint {cfg.get('Entrypoint')!r}"); failed = True; continue
        for layer in man["layers"]:
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(blob(token, layer["digest"])))) as t:
                for member in t.getmembers():
                    if member.isfile() and member.name.lstrip("./") == "ko-app/headscale":
                        got = hashlib.sha256(t.extractfile(member).read()).hexdigest()
        ok = got == want
        failed |= not ok
        print(f"{arch}: {'OK' if ok else 'MISMATCH'} image={got} release={want}")
    if failed:
        sys.exit(1)
    print(f"headscale v{version} @ {digest}: binaries match the release checksums")


if __name__ == "__main__":
    main()
