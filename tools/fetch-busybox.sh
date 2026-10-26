#!/bin/sh
# tools/fetch-busybox.sh DEST
# Unpacks the exact busybox image the app runs (pinned by digest in the
# generated compose file) into DEST, so tests use the same busybox build as
# production. Distribution packages differ: Ubuntu's busybox-static, for
# example, is built without `find -delete`. Needs Docker.
set -eu
dest=${1:?usage: tools/fetch-busybox.sh DEST}
here=$(cd "$(dirname "$0")/.." && pwd)
img=$(sed -n 's/^ *image: \(busybox:[0-9.]*@sha256:[0-9a-f]\{64\}\)$/\1/p' "$here/cracklebuff-headscale/docker-compose.yml" | sort -u)
[ "$(printf '%s\n' "$img" | wc -l)" -eq 1 ] && [ -n "$img" ] || { echo "expected exactly one pinned busybox image, got: $img" >&2; exit 1; }
docker pull -q --platform linux/amd64 "$img" >/dev/null
cid=$(docker create --platform linux/amd64 "$img")
mkdir -p "$dest"
docker export "$cid" | tar -x -C "$dest"
docker rm "$cid" >/dev/null
"$dest/bin/busybox" | head -n 1
