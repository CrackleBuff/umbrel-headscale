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
import os, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = d["services"]["init"]["command"][2]
if os.environ.get("UMBRELD_REWRITE") == "1":
    # Run the script the way umbrelOS actually stores it (see tools/umbreld_rewrite.py).
    sys.path.insert(0, os.path.join(os.path.dirname(sys.argv[1]), "..", "tools"))
    from umbreld_rewrite import mangle
    s = mangle(s)
print(s.replace("$$", "$"))
PY
)
script=${script//\/out\//$out/}
mkdir -p "$out"/{lib,config,policy,www,status,probe}
env -i PATH="$bin" "$@" "$bb" sh -c "$script"
rm -rf "$bin"
