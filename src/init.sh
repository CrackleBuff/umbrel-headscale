# Runs as root in a throwaway busybox container with no network, a read-only
# root filesystem and only CHOWN, DAC_OVERRIDE and FOWNER. It:
#   1. validates the user's settings,
#   2. renders /etc/headscale/config.yaml,
#   3. creates a default-deny policy if none exists,
#   4. fixes ownership and permissions of Headscale's state (uid 65532, 0700/0600),
#   5. writes the status page.
# It never reads or prints key material. Re-run on every app start.
set -eu
umask 077

HS_UID=65532
HS_GID=65532
CFG=/out/config
LIB=/out/lib
POL=/out/policy
WWW=/out/www
ST=/out/status
PR=/out/probe

DOMAIN=$(printf '%s' "${HS_SERVER_DOMAIN:-}" | tr 'A-Z' 'a-z' | tr -d ' ')
EMAIL=$(printf '%s' "${HS_ACME_EMAIL:-}" | tr -d ' ')
MAGIC=$(printf '%s' "${HS_MAGICDNS_DOMAIN:-tailnet.internal}" | tr 'A-Z' 'a-z' | tr -d ' ')
TSDERP=$(printf '%s' "${HS_TAILSCALE_DERP:-false}" | tr 'A-Z' 'a-z')
LOGLEVEL=$(printf '%s' "${HS_LOG_LEVEL:-info}" | tr 'A-Z' 'a-z')
EXPIRY=$(printf '%s' "${HS_NODE_EXPIRY:-180d}" | tr 'A-Z' 'a-z')

HOSTRE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
STATE=configured
REASON=ok

fail() { STATE=unconfigured; REASON=$1; }

# Settings must be single-line printable ASCII. grep tests each line on its
# own, so a newline (or tab) could otherwise smuggle extra lines into the
# generated config.yaml. Reject such values instead of stripping them.
BADCHARS=
# One line on purpose: umbrelOS rewrites the compose file and adds a line break
# before indented lines, which breaks "\" line continuations (see
# tools/umbreld_rewrite.py). Never continue a line with a backslash here.
for v in "${HS_SERVER_DOMAIN:-}" "${HS_ACME_EMAIL:-}" "${HS_MAGICDNS_DOMAIN:-}" "${HS_TAILSCALE_DERP:-}" "${HS_LOG_LEVEL:-}" "${HS_NODE_EXPIRY:-}"; do
  case "$v" in *[![:print:]]*) BADCHARS=1;; esac
done

if [ -n "$BADCHARS" ]; then fail bad_characters
elif [ -z "$DOMAIN" ]; then fail no_domain
elif ! printf '%s' "$DOMAIN" | grep -Eq "$HOSTRE" || [ ${#DOMAIN} -gt 253 ]; then fail bad_domain
fi
if [ "$STATE" = configured ]; then
  if [ -n "$EMAIL" ] && ! printf '%s' "$EMAIL" | grep -Eq '^[A-Za-z0-9._%+-]{1,64}@([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$'; then fail bad_email
  elif ! printf '%s' "$MAGIC" | grep -Eq "$HOSTRE"; then fail bad_magicdns
  elif [ "$MAGIC" = "$DOMAIN" ] || case "$DOMAIN" in *."$MAGIC") true;; *) false;; esac; then fail magicdns_contains_server
  elif [ "$TSDERP" != true ] && [ "$TSDERP" != false ]; then fail bad_derp
  elif ! printf '%s' "$LOGLEVEL" | grep -Eq '^(debug|info|warn|error)$'; then fail bad_loglevel
  elif ! printf '%s' "$EXPIRY" | grep -Eq '^(0|[1-9][0-9]{0,4}(h|d))$'; then fail bad_expiry
  fi
fi
# Headscale accepts Go durations; convert days to hours.
# Only do arithmetic on a value the regex above accepted (digits + d); never on raw input.
if [ "$STATE" = configured ]; then
  case "$EXPIRY" in [1-9]*d) EXPIRY="$(( ${EXPIRY%d} * 24 ))h";; esac
fi

# Refuse symlinks, devices, FIFOs and sockets anywhere in the data folder.
# This script runs as root and writes or chowns files there, so a planted
# symlink must never be followed.
# A find error (unreadable entry, I/O error) also counts as unsafe.
unsafe() {
  _u=$(find "$1" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print 2>&1) || return 0
  [ -n "$_u" ]
}
# config/, www/, status/ and probe/ are written even when Headscale stays
# inert, so stop here without writing anything (the app will not start; see
# its logs).
for d in "$CFG" "$WWW" "$ST" "$PR"; do
  if unsafe "$d"; then
    echo "init: refusing to start: $d contains a symlink, device, FIFO or socket" >&2
    exit 1
  fi
done
# lib/ and policy/ are only written once configured, so report it on the status page.
for d in "$LIB" "$POL"; do
  if unsafe "$d"; then fail unsafe_files; fi
done

# Headscale ALLOWS ALL traffic when the policy has neither an "acls" nor a
# "grants" list: an empty file, "{}", "acls": null, a list hidden in a
# /* comment */, or an "acls" key nested somewhere else. Refuse to start
# rather than fail open. This small HuJSON scanner skips strings and
# comments and prints "ok" only if the TOP-LEVEL object has an "acls" or
# "grants" member (any case, as Headscale matches names case-insensitively)
# whose value is a list. Anything it does not understand counts as unsafe.
has_rule_list() {
  # Control characters (other than tab/CR/LF) are refused: the scanner reads
  # the file as one awk record split on \001, and Headscale allows such bytes
  # inside comments, so they could hide a list from this check.
  tr -d '\000-\010\013\014\016-\037\177' < "$1" | cmp -s - "$1" || return 0
  awk '
BEGIN { RS = "\001"; ok = 0; bad = 0 }
{
  s = $0; n = length(s); depth = 0; i = 1; expect = ""; key = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "/" && substr(s, i + 1, 1) == "/") { j = index(substr(s, i), "\n"); if (j == 0) break; i += j; continue }
    if (c == "/" && substr(s, i + 1, 1) == "*") { j = index(substr(s, i + 2), "*/"); if (j == 0) { bad = 1; break }; i += j + 3; continue }
    if (c ~ /[ \t\r\n]/) { i++; continue }
    if (c == "\"") {
      str = ""; i++
      while (i <= n) { d = substr(s, i, 1); if (d == "\\") { str = str d substr(s, i + 1, 1); i += 2; continue }; if (d == "\"") break; str = str d; i++ }
      i++
      if (depth == 1 && expect == "") { key = tolower(str); expect = "colon"; continue }
      if (expect == "value") expect = ""
      continue
    }
    if (expect == "colon") { if (c == ":") { expect = "value"; i++; continue }; expect = "" }
    if (expect == "value") { if ((key == "acls" || key == "grants") && c == "[") ok = 1; expect = "" }
    if (c == "{" || c == "[") depth++
    else if (c == "}" || c == "]") depth--
    i++
  }
}
END { if (ok && !bad) print "ok" }
' "$1"
}
# Headscale never reads data/policy/ directly: it reads a copy in config/
# that passed this check. A Headscale-only restart, a crash restart or SIGHUP
# therefore reloads the last checked policy, never an unchecked edit. The
# copy is checked (not the original) so the file cannot change in between.
rm -f "$CFG/policy.hujson.new"
if [ "$STATE" = configured ] && [ -e "$POL/policy.hujson" ]; then
  if [ ! -f "$POL/policy.hujson" ]; then
    fail implicit_allow_all
  else
    cat "$POL/policy.hujson" > "$CFG/policy.hujson.new"
    if [ "$(has_rule_list "$CFG/policy.hujson.new")" != ok ]; then fail implicit_allow_all; fi
  fi
fi

# The status page is regenerated below; drop anything else that is in www/.
find "$WWW" -mindepth 1 -delete
mkdir -p "$CFG" "$WWW/cgi-bin" "$ST"

if [ "$STATE" = configured ]; then
  if [ "$TSDERP" = true ]; then DERPURLS='["https://controlplane.tailscale.com/derpmap/default"]'; else DERPURLS='[]'; fi
  cat > "$CFG/config.yaml.new" <<CONF
# Generated by the app on every start from the app's settings. Do not edit:
# changes are overwritten. Change settings in umbrelOS instead.
server_url: https://$DOMAIN
listen_addr: 0.0.0.0:8443
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
trusted_proxies: []
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: "umbrel"
    region_name: "Umbrel embedded DERP"
    verify_clients: true
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  urls: $DERPURLS
  paths: []
  auto_update_enabled: $TSDERP
  update_frequency: 24h
disable_check_updates: true
node:
  expiry: $EXPIRY
  ephemeral:
    inactivity_timeout: 30m
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true
    wal_autocheckpoint: 1000
acme_url: https://acme-v02.api.letsencrypt.org/directory
acme_email: "$EMAIL"
tls_letsencrypt_hostname: "$DOMAIN"
tls_letsencrypt_cache_dir: /var/lib/headscale/cache
tls_letsencrypt_challenge_type: TLS-ALPN-01
tls_cert_path: ""
tls_key_path: ""
log:
  level: $LOGLEVEL
  format: text
policy:
  mode: file
  path: /etc/headscale/policy.hujson
dns:
  magic_dns: true
  base_domain: $MAGIC
  override_local_dns: false
  nameservers:
    global: []
    split: {}
  search_domains: []
  extra_records: []
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
logtail:
  enabled: false
taildrop:
  enabled: true
auto_update:
  enabled: false
CONF

  # Default-deny policy, created only if the user has none yet. Never overwritten.
  if [ ! -e "$POL/policy.hujson" ]; then
    cat > "$POL/policy.hujson" <<'POLICY'
// Headscale access policy (HuJSON). Default: DENY ALL.
// Nodes can join, but cannot reach each other until you add rules.
// Edit this file, then restart the app. Examples:
// https://headscale.net/stable/ref/policy/  and the app's README.
//
// IMPORTANT: an empty file or "{}" means ALLOW ALL. Keep an "acls"
// (or "grants") list in this file, even if it is empty.
{
  "groups": {},
  "tagOwners": {},
  "hosts": {},
  "acls": []
}
POLICY
  fi
  mkdir -p "$LIB/cache"
  chown -R -h "$HS_UID:$HS_GID" "$LIB"
  find "$LIB" -type d -exec chmod 0700 {} +
  find "$LIB" -type f -exec chmod 0600 {} +
  chown -h "0:$HS_GID" "$POL" "$POL/policy.hujson"
  chmod 0750 "$POL"; chmod 0640 "$POL/policy.hujson"
  # New install: the copy is the default policy written just above.
  if [ ! -e "$CFG/policy.hujson.new" ]; then cat "$POL/policy.hujson" > "$CFG/policy.hujson.new"; fi
  chown -h "0:$HS_GID" "$CFG/policy.hujson.new"; chmod 0640 "$CFG/policy.hujson.new"
  mv -f "$CFG/policy.hujson.new" "$CFG/policy.hujson"
else
  # Not configured: run Headscale in an inert, localhost-only mode with state
  # in tmpfs, so nothing is created in the data folder (keys, db) and nothing
  # answers on the published ports. This keeps the data folder empty, which is
  # what the migration (copy existing state in) relies on.
  cat > "$CFG/config.yaml.new" <<'CONF'
# Not configured yet. Set "Public domain" in the app's settings.
server_url: http://127.0.0.1:8443
listen_addr: 127.0.0.1:8443
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
noise:
  private_key_path: /tmp/inert/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
derp:
  server:
    enabled: false
  urls: []
  paths: [/etc/headscale/derp-inert.yaml]
  auto_update_enabled: false
disable_check_updates: true
database:
  type: sqlite
  sqlite:
    path: /tmp/inert/db.sqlite
log:
  level: warn
policy:
  mode: file
  path: ""
dns:
  magic_dns: false
  override_local_dns: false
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
logtail:
  enabled: false
CONF
  # Headscale refuses to start without a DERP map; give it an unreachable one.
  cat > "$CFG/derp-inert.yaml" <<'DERP'
regions:
  900:
    regionid: 900
    regioncode: inert
    regionname: Not configured
    nodes:
      - name: 900a
        regionid: 900
        hostname: localhost
        ipv4: 127.0.0.1
        stunport: -1
        derpport: 1
DERP
  chown -h "0:$HS_GID" "$CFG/derp-inert.yaml"; chmod 0640 "$CFG/derp-inert.yaml"
fi
# Remove the inert DERP map once configured, and the checked policy copy when not.
if [ "$STATE" = configured ]; then rm -f "$CFG/derp-inert.yaml"; else rm -f "$CFG/policy.hujson" "$CFG/policy.hujson.new"; fi

chown -h "0:$HS_GID" "$CFG" "$CFG/config.yaml.new"
chmod 0750 "$CFG"; chmod 0640 "$CFG/config.yaml.new"
mv -f "$CFG/config.yaml.new" "$CFG/config.yaml"

# Status page state: only validated values, no secrets.
{
  echo "STATE=$STATE"
  echo "REASON=$REASON"
  if [ "$STATE" = configured ]; then echo "DOMAIN=$DOMAIN"; echo "TSDERP=$TSDERP"; echo "MAGIC=$MAGIC"; fi
} > "$ST/state.new"
chmod 0644 "$ST/state.new"; mv -f "$ST/state.new" "$ST/state"
chown -h 0:0 "$ST" "$ST/state"; chmod 0755 "$ST"

# Reachability results from the probe service (written as uid 65534). Start
# empty so an old result is never shown for a new domain.
find "$PR" -mindepth 1 -delete
chown -h 65534:65534 "$PR"; chmod 0755 "$PR"

# Status page files (static HTML + one CGI). Rewritten on every start.
@@WWW_FILES@@
chown -R -h 0:0 "$WWW"
find "$WWW" -type d -exec chmod 0755 {} +
find "$WWW" -type f -exec chmod 0644 {} +
chmod 0755 "$WWW/cgi-bin/status"

echo "init: state=$STATE reason=$REASON"
