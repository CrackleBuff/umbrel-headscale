#!/bin/sh
# Status JSON for the app page. Makes no network requests: it only reads the
# validated state file written by init and the result file written by the
# probe service, and passes on values that match strict patterns. A probe
# result counts only if it is for the current domain and under 5 minutes old.
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
get() { sed -n "s/^$1=\([a-z0-9._-]*\)\$/\1/p" /status/state 2>/dev/null | head -n 1; }
STATE=$(get STATE); REASON=$(get REASON); DOMAIN=$(get DOMAIN); TSDERP=$(get TSDERP); MAGIC=$(get MAGIC)
HEALTH=false; KEY=""; CHECKED=false
if [ "$STATE" = configured ] && [ -f /probe/result ]; then
  R=$(head -c 1024 /probe/result)   # one snapshot per request
  PD=$(printf '%s\n' "$R" | sed -n 's/^DOMAIN=\([a-z0-9._-]*\)$/\1/p' | head -n 1)
  PT=$(printf '%s\n' "$R" | sed -n 's/^TIME=\([0-9]\{1,12\}\)$/\1/p' | head -n 1)
  NOW=$(date +%s)
  if [ -n "$PD" ] && [ "$PD" = "$DOMAIN" ] && [ -n "$PT" ] && [ "$NOW" -ge "$PT" ] && [ $((NOW - PT)) -le 300 ]; then
    CHECKED=true
    printf '%s\n' "$R" | grep -qx 'HEALTH=true' && HEALTH=true
    KEY=$(printf '%s\n' "$R" | sed -n 's/^KEY=\(mkey:[0-9a-f]\{64\}\)$/\1/p' | head -n 1)
  fi
fi
# No "\" line continuation: umbrelOS's compose rewrite would break it.
FMT='{"state":"%s","reason":"%s","domain":"%s","magicdns":"%s","tailscaleDerp":"%s","checked":%s,"publicHealth":%s,"noiseKey":"%s"}\n'
printf "$FMT" "$STATE" "$REASON" "$DOMAIN" "$MAGIC" "$TSDERP" "$CHECKED" "$HEALTH" "$KEY"
