#!/usr/bin/env python3
import sys
def mangle(s):
    """Model of how umbrelOS (umbreld) rewrites a multi-line compose string (observed Oct 2026).
    It re-dumps the compose file with block scalars in folded style, and every line that starts
    with whitespace and follows (ignoring blank lines) a line that does not, gains an extra
    line break before it."""
    out = []; last = ""
    for line in s.split("\n"):
        if line[:1] in (" ", "\t") and last and last[0] not in " \t":
            out.append("")
        out.append(line)
        if line:
            last = line
    return "\n".join(out)
if __name__ == "__main__":
    sys.stdout.write(mangle(sys.stdin.read()))
