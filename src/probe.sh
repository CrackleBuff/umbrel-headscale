# Reachability probe. Runs in its own busybox container on the same private
# network as Headscale (not on umbrel_main_network), as an unprivileged user
# with a read-only filesystem. Every minute it sends one plain GET for /health
# and one for /key to the public name (the same path your devices use) and
# writes the reduced result to /probe/result for the status page.
# It sends exactly one request per path and never follows redirects, so a
# hijacked name or compromised server cannot point it at other addresses.
# busybox TLS does not verify certificates: the result is a hint for
# debugging port forwarding, not proof of identity.
set -u
get() { sed -n "s/^$1=\([a-z0-9._-]*\)\$/\1/p" /status/state 2>/dev/null | head -n 1; }
req() {  # req PATH -> first 4 KB of the raw response, or nothing unless HTTP 200
  _r=$(printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: umbrel-headscale-probe\r\nConnection: close\r\n\r\n' "$1" "$DOMAIN" |
    timeout 8 ssl_client -n "$DOMAIN" "$DOMAIN:443" 2>/dev/null | head -c 4096)
  case "$_r" in "HTTP/1.1 200 "*|"HTTP/1.0 200 "*) printf '%s\n' "$_r";; esac
}
# /key returns {"legacyPublicKey":"mkey:000...","publicKey":"mkey:..."}: take publicKey only.
pubkey() { grep -o '"publicKey":"mkey:[0-9a-f]\{64\}"' | grep -o 'mkey:[0-9a-f]\{64\}' | head -n 1; }
while :; do
  STATE=$(get STATE); DOMAIN=$(get DOMAIN)
  if [ "$STATE" = configured ] && [ -n "$DOMAIN" ]; then
    HEALTH=false
    if req /health | grep -q '"status":"pass"'; then HEALTH=true; fi
    KEY=$(req '/key?v=130' | pubkey)
    { echo "DOMAIN=$DOMAIN"; echo "TIME=$(date +%s)"; echo "HEALTH=$HEALTH"; echo "KEY=$KEY"; } > /probe/result.new &&
      mv -f /probe/result.new /probe/result
  fi
  sleep 60
done
