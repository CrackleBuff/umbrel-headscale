#!/bin/sh
# Status JSON for the app page. Reads only the validated state file written by
# init and checks the public URL. Never echoes remote content: results are
# reduced to booleans or a strictly matched public key.
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
get() { sed -n "s/^$1=\([a-z0-9._-]*\)\$/\1/p" /status/state 2>/dev/null | head -n 1; }
STATE=$(get STATE); REASON=$(get REASON); DOMAIN=$(get DOMAIN); TSDERP=$(get TSDERP); MAGIC=$(get MAGIC)
HEALTH=false; KEY=""
if [ "$STATE" = configured ] && [ -n "$DOMAIN" ]; then
  if timeout 8 wget -q -T 6 -O - "https://$DOMAIN/health" 2>/dev/null | grep -q '"status":"pass"'; then HEALTH=true; fi
  KEY=$(timeout 8 wget -q -T 6 -O - "https://$DOMAIN/key?v=130" 2>/dev/null | grep -o 'mkey:[0-9a-f]\{64\}' | head -n 1)
fi
printf '{"state":"%s","reason":"%s","domain":"%s","magicdns":"%s","tailscaleDerp":"%s","publicHealth":%s,"noiseKey":"%s"}\n' \
  "$STATE" "$REASON" "$DOMAIN" "$MAGIC" "$TSDERP" "$HEALTH" "$KEY"
