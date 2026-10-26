#!/bin/bash
# tests/test-init.sh -- assertion tests for the init script (run as root; BUSYBOX=/path/to/busybox).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
base=$(mktemp -d); pass=0; failn=0
st() { sed -n "s/^$2=//p" "$1/status/state"; }
# init_run DIR [VAR=value ...]: run init once; its output goes to $base/last.log and is shown on failures.
init_run() { "$here/run-init.sh" "$@" >"$base/last.log" 2>&1; }
ok() {
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1: got '$2' want '$3'"
    if [ -s "$base/last.log" ]; then echo "     output of the last init run:"; awk '{l[NR]=$0} END {for (i=1;i<=NR;i++) if (i<=8 || i>NR-12) print "     | " l[i]; else if (i==9) print "     | ..."}' "$base/last.log"; fi
  fi
}
run() { local d=$base/$1; shift; rm -rf "$d"; mkdir -p "$d"; init_run "$d" "$@"; echo "$d"; }

# The init script only ever runs in the pinned busybox image. A busybox built
# with different options (e.g. Ubuntu's busybox-static has no `find -delete`)
# makes init fail closed and every test fail, so check the applets first.
bb=${BUSYBOX:-$(command -v busybox)}
pre=$(mktemp -d); mkdir "$pre/x"
if ! "$bb" find "$pre" -mindepth 1 -delete 2>/dev/null || [ -e "$pre/x" ]; then
  echo "busybox at $bb lacks 'find -delete'. Use the busybox from the pinned image (tools/fetch-busybox.sh)." >&2
  rm -rf "$pre"; exit 2
fi
applets=$("$bb" --list)
for a in awk sed grep find stat chown chmod mv cmp tr timeout ssl_client date; do
  printf '%s\n' "$applets" | grep -qx "$a" || { echo "busybox at $bb lacks the '$a' applet" >&2; rm -rf "$pre"; exit 2; }
done
rm -rf "$pre"

d=$(run unconf);                                   ok unconfigured "$(st $d REASON)" no_domain
ok unconfigured-lib-untouched "$(ls -A $d/lib | wc -l)" 0
ok unconfigured-inert-listen "$(grep -c '^listen_addr: 127.0.0.1:8443' $d/config/config.yaml)" 1
d=$(run baddom HS_SERVER_DOMAIN='$(id)');           ok injection "$(st $d REASON)" bad_domain
d=$(run baddom2 HS_SERVER_DOMAIN='a..b');           ok bad_domain "$(st $d REASON)" bad_domain
d=$(run email HS_SERVER_DOMAIN=hs.example.com HS_ACME_EMAIL='x"y@z');  ok bad_email "$(st $d REASON)" bad_email
d=$(run magic HS_SERVER_DOMAIN=hs.example.com HS_MAGICDNS_DOMAIN=example.com); ok magicdns "$(st $d REASON)" magicdns_contains_server
d=$(run derp HS_SERVER_DOMAIN=hs.example.com HS_TAILSCALE_DERP=yes); ok bad_derp "$(st $d REASON)" bad_derp
d=$(run ll HS_SERVER_DOMAIN=hs.example.com HS_LOG_LEVEL=trace); ok bad_loglevel "$(st $d REASON)" bad_loglevel
d=$(run exp HS_SERVER_DOMAIN=hs.example.com HS_NODE_EXPIRY=1y); ok bad_expiry "$(st $d REASON)" bad_expiry
# rejected expiry must never reach shell arithmetic (crash / variable overwrite / command text)
d=$(run exp2 HS_SERVER_DOMAIN=hs.example.com HS_NODE_EXPIRY=abcd); ok bad_expiry-no-crash "$(st $d REASON)" bad_expiry
d=$(run exp3 HS_SERVER_DOMAIN=hs.example.com HS_NODE_EXPIRY='HS_GID=0d'); ok bad_expiry-assign "$(st $d REASON)" bad_expiry
ok bad_expiry-gid-kept "$(stat -c %g $d/config/config.yaml)" 65532
rm -f "$base/pwned"; d=$(run exp4 HS_SERVER_DOMAIN=hs.example.com HS_NODE_EXPIRY="\$(touch $base/pwned)d"); ok bad_expiry-subst "$(st $d REASON)" bad_expiry
ok bad_expiry-no-exec "$([ -e "$base/pwned" ] && echo ran || echo no)" no

d=$(run conf HS_SERVER_DOMAIN=HS.Example.com HS_NODE_EXPIRY=180d)
ok configured "$(st $d REASON)" ok
ok domain-lowercased "$(st $d DOMAIN)" hs.example.com
ok expiry-days "$(grep -c 'expiry: 4320h' $d/config/config.yaml)" 1
ok metrics-localhost "$(grep -c '^metrics_listen_addr: 127.0.0.1:9090' $d/config/config.yaml)" 1
ok grpc-localhost "$(grep -c '^grpc_listen_addr: 127.0.0.1:50443' $d/config/config.yaml)" 1
ok no-ts-derp "$(grep -c '^  urls: \[\]' $d/config/config.yaml)" 1
# Parsed as YAML (not grep), so blank lines from the umbrelOS rewrite do not matter.
cfgval() { python3 -c 'import sys,yaml;c=yaml.safe_load(open(sys.argv[1]));[c:=c[k] for k in sys.argv[2:]];print(c)' "$d/config/config.yaml" "$@"; }
ok logtail-off "$(cfgval logtail enabled)" False
ok policy-file-mode "$(cfgval policy mode)" file
ok default-deny "$(grep -c '"acls": \[\]' $d/policy/policy.hujson)" 1
ok lib-perm "$(stat -c '%a %u' $d/lib)" "700 65532"
ok cfg-perm "$(stat -c '%a %u:%g' $d/config/config.yaml)" "640 0:65532"
ok pol-perm "$(stat -c '%a %u:%g' $d/policy/policy.hujson)" "640 0:65532"
# Headscale reads only the checked copy of the policy (so restarts/SIGHUP cannot load an unchecked edit)
ok policy-path-snapshot "$(grep -c '^  path: /etc/headscale/policy.hujson$' $d/config/config.yaml)" 1
ok policy-snapshot-same "$(cmp -s $d/policy/policy.hujson $d/config/policy.hujson && echo same)" same
ok policy-snapshot-perm "$(stat -c '%a %u:%g' $d/config/policy.hujson)" "640 0:65532"
ok probe-dir-owner "$(stat -c '%u:%g %a' $d/probe)" "65534:65534 755"
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok default-policy-restart "$(st $d REASON)" ok
ok expiry-default "$(d2=$(run expdef HS_SERVER_DOMAIN=hs.example.com); grep -c 'expiry: 4320h' $d2/config/config.yaml)" 1
ok inert-derp-removed "$(ls $d/config | grep -c derp-inert)" 0

# migrated root-owned files are fixed; user policy is preserved
echo x > $d/lib/db.sqlite; chmod 644 $d/lib/db.sqlite; chown 0:0 $d/lib/db.sqlite
printf '{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}]}\n' > $d/policy/policy.hujson
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok migrated-perm "$(stat -c '%a %u' $d/lib/db.sqlite)" "600 65532"
ok policy-preserved "$(grep -c '"accept"' $d/policy/policy.hujson)" 1
ok policy-snapshot-updated "$(grep -c '"accept"' $d/config/policy.hujson)" 1

# fail-closed guards
printf '{}\n' > $d/policy/policy.hujson
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok implicit-allow-all "$(st $d REASON)" implicit_allow_all
ok implicit-allow-all-inert "$(grep -c '^listen_addr: 127.0.0.1:8443' $d/config/config.yaml)" 1
ok implicit-allow-all-no-snapshot "$(ls $d/config | grep -c policy)" 0
: > $d/policy/policy.hujson
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok empty-policy "$(st $d REASON)" implicit_allow_all
# control bytes are refused: Headscale reads this as {} (allow all), the list is inside a // comment
printf '{//\001{"acls":[]}\001\n}\n' > $d/policy/policy.hujson
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok ctrl-byte-policy "$(st $d REASON)" implicit_allow_all
printf '{"acls":[]}\000\n' > $d/policy/policy.hujson
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok nul-byte-policy "$(st $d REASON)" implicit_allow_all
printf '{"acls":[] /* caf\303\251 */}\r\n' > $d/policy/policy.hujson
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok utf8-crlf-policy-ok "$(st $d REASON)" ok
printf '{"grants":[]}\n' > $d/policy/policy.hujson
ln -s /etc/shadow $d/lib/evil
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok symlink "$(st $d REASON)" unsafe_files
ok symlink-not-followed "$(stat -c '%u' /etc/shadow)" 0
rm $d/lib/evil
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok grants-policy-ok "$(st $d REASON)" ok

# settings with line breaks/tabs must not reach config.yaml (grep checks each line separately)
nl='
'
d=$(run nl1 "HS_SERVER_DOMAIN=hs.example.com${nl}grpc_allow_insecure: true"); ok newline-domain "$(st $d REASON)" bad_characters
ok newline-domain-inert "$(grep -c '^listen_addr: 127.0.0.1:8443' $d/config/config.yaml)" 1
ok newline-domain-no-inject "$(grep -c 'grpc_allow_insecure: true' $d/config/config.yaml)" 0
d=$(run nl2 HS_SERVER_DOMAIN=hs.example.com "HS_ACME_EMAIL=a@b.co${nl}x"); ok newline-email "$(st $d REASON)" bad_characters
d=$(run nl3 HS_SERVER_DOMAIN=hs.example.com "HS_LOG_LEVEL=info${nl}derp: {}"); ok newline-loglevel "$(st $d REASON)" bad_characters
d=$(run nl4 HS_SERVER_DOMAIN=hs.example.com "HS_NODE_EXPIRY=0${nl}x"); ok newline-expiry "$(st $d REASON)" bad_characters
d=$(run tab1 HS_SERVER_DOMAIN=hs.example.com "HS_MAGICDNS_DOMAIN=a.internal	"); ok tab-magic "$(st $d REASON)" bad_characters

# policy guard: only a TOP-LEVEL "acls"/"grants" LIST counts (Headscale: both nil => allow all)
pol() { d=$(run pol-$1); printf '%s' "$2" > $d/policy/policy.hujson
  init_run $d HS_SERVER_DOMAIN=hs.example.com; st $d REASON; }
ok policy-acls-null "$(pol null '{"acls": null}')" implicit_allow_all
ok policy-block-comment "$(pol block '{/* "acls": [] */ "groups": {}}')" implicit_allow_all
ok policy-line-comment "$(pol line '{
// "acls": [],
"groups": {}}')" implicit_allow_all
ok policy-nested-key "$(pol nested '{"hosts": {"acls": "10.0.0.0/8"}}')" implicit_allow_all
ok policy-in-string "$(pol str '{"tagOwners": {"tag:x": ["\"acls\": ["]}}')" implicit_allow_all
ok policy-hash-key "$(pol hash '{"#acls": []}')" implicit_allow_all
ok policy-unclosed-comment "$(pol unclosed '{"acls": [] /* x')" implicit_allow_all
ok policy-mixed-case "$(pol case '{"ACLs": []}')" ok
ok policy-comments-ok "$(pol cmt '// "x"
{ /* a */ "groups": {"group:a": ["a@"]}, // b
  "acls" /* c */ : [ {"action": "accept", "src": ["group:a"], "dst": ["*:*"]} ], }')" ok
ok policy-example-ok "$(pol example "$(cat "$here/../examples/policy.example.hujson")")" ok

# root init must never write through symlinks in config/, www/ or status/
victim=$base/victim; echo keep > $victim
for sub in config/config.yaml.new config/policy.hujson.new www/index.html www/cgi-bin status/state.new probe/result; do
  d=$(run sl-${sub//\//-}); mkdir -p $d/$(dirname $sub); rm -rf $d/$sub; ln -s $victim $d/$sub
  init_run $d HS_SERVER_DOMAIN=hs.example.com; rc=$?
  ok "symlink-$sub-refused" "$rc" 1
  ok "symlink-$sub-not-followed" "$(cat $victim)" keep
done
d=$(run stray); echo x > $d/www/stray.html; init_run $d
ok www-stray-removed "$(ls $d/www | grep -c stray)" 0
ok status-owner "$(stat -c '%u %a' $d/status)" "0 755"
d=$(run probestale HS_SERVER_DOMAIN=hs.example.com); echo HEALTH=true > $d/probe/result
init_run $d HS_SERVER_DOMAIN=hs.example.com
ok probe-stale-removed "$(ls -A $d/probe | wc -l)" 0

# status CGI: no network, only strictly matching values from the probe result
cgi() {  # cgi DIR -> JSON (runs the generated CGI with /status and /probe pointing at DIR)
  sed -e "s#/status/state#$1/status/state#g" -e "s#/probe/result#$1/probe/result#g" "$1/www/cgi-bin/status" > "$1/cgi.sh"
  env -i PATH="$bbbin" "${BUSYBOX:-busybox}" sh "$1/cgi.sh" | tail -n 1
}
bbbin=$(mktemp -d); "${BUSYBOX:-$(command -v busybox)}" --install -s "$bbbin"
d=$(run cgi HS_SERVER_DOMAIN=hs.example.com)
ok cgi-no-network "$(grep -c wget $d/www/cgi-bin/status)" 0
ok cgi-unchecked "$(cgi $d | grep -o '"checked":[a-z]*')" '"checked":false'
k=mkey:$(printf '%064d' 0 | tr 0 a)
now=$(date +%s)
printf 'DOMAIN=hs.example.com\nTIME=%s\nHEALTH=true\nKEY=%s\n' "$now" "$k" > $d/probe/result
ok cgi-health "$(cgi $d | grep -o '"publicHealth":[a-z]*')" '"publicHealth":true'
ok cgi-key "$(cgi $d | grep -o '"noiseKey":"[^"]*"')" "\"noiseKey\":\"$k\""
printf 'DOMAIN=hs.example.com\nTIME=%s\nHEALTH=yes","x":"1\nKEY=%s","x":"1\n' "$now" "$k" > $d/probe/result
ok cgi-junk-health "$(cgi $d | grep -o '"publicHealth":[a-z]*')" '"publicHealth":false'
ok cgi-junk-key "$(cgi $d | grep -o '"noiseKey":"[^"]*"')" '"noiseKey":""'
printf 'DOMAIN=hs.example.com\nTIME=%s\nHEALTH=true\nKEY=%s\n' $((now - 600)) "$k" > $d/probe/result
ok cgi-stale "$(cgi $d | grep -o '"checked":[a-z]*,"publicHealth":[a-z]*')" '"checked":false,"publicHealth":false'
printf 'DOMAIN=old.example.com\nTIME=%s\nHEALTH=true\nKEY=%s\n' "$now" "$k" > $d/probe/result
ok cgi-other-domain "$(cgi $d | grep -o '"checked":[a-z]*,"publicHealth":[a-z]*')" '"checked":false,"publicHealth":false'
ok probe-no-wget "$(grep -c wget "$here/../src/probe.sh")" 0
# probe reports the real server key, not the all-zero legacyPublicKey that /key lists first
eval "$(grep '^pubkey()' "$here/../src/probe.sh")"
kz=$(printf 'mkey:%064d' 0); kr=mkey:$(printf 'ab%.0s' $(seq 32))
ok probe-pubkey "$(printf 'HTTP/1.1 200 OK\r\n\r\n{"legacyPublicKey":"%s","publicKey":"%s"}' "$kz" "$kr" | pubkey)" "$kr"
rm -rf "$bbbin"

rm -rf "$base"
echo "passed=$pass failed=$failn"; [ $failn -eq 0 ]
