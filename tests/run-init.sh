#!/bin/bash
# tests/run-init.sh OUTDIR [VAR=value ...]
# Extracts the init script from the built compose file and runs it with busybox
# against OUTDIR (instead of /out). Needs root for chown; uses a busybox binary
# given in $BUSYBOX (default: busybox on PATH).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
out=$1; shift
bb=${BUSYBOX:-$(command -v busybox)}
bin=$(mktemp -d); "$bb" --install -s "$bin"
script=$(python3 - "$here/cracklebuff-headscale/docker-compose.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d["services"]["init"]["command"][2].replace("$$", "$"))
PY
)
script=${script//\/out\//$out/}
mkdir -p "$out"/{lib,config,policy,www,status}
env -i PATH="$bin" "$@" "$bb" sh -c "$script"
rm -rf "$bin"
