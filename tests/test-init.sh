#!/bin/bash
# tests/test-init.sh -- assertion tests for the init script (run as root; BUSYBOX=/path/to/busybox).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
base=$(mktemp -d); pass=0; failn=0
st() { sed -n "s/^$2=//p" "$1/status/state"; }
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else failn=$((failn+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
run() { local d=$base/$1; shift; rm -rf "$d"; mkdir -p "$d"; "$here/run-init.sh" "$d" "$@" >/dev/null 2>&1; echo "$d"; }

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
ok logtail-off "$(grep -A1 '^logtail:' $d/config/config.yaml | grep -c 'enabled: false')" 1
ok policy-file-mode "$(grep -A1 '^policy:' $d/config/config.yaml | grep -c 'mode: file')" 1
ok default-deny "$(grep -c '"acls": \[\]' $d/policy/policy.hujson)" 1
ok lib-perm "$(stat -c '%a %u' $d/lib)" "700 65532"
ok cfg-perm "$(stat -c '%a %u:%g' $d/config/config.yaml)" "640 0:65532"
ok pol-perm "$(stat -c '%a %u:%g' $d/policy/policy.hujson)" "640 0:65532"
"$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1
ok default-policy-restart "$(st $d REASON)" ok
ok expiry-default "$(d2=$(run expdef HS_SERVER_DOMAIN=hs.example.com); grep -c 'expiry: 4320h' $d2/config/config.yaml)" 1
ok inert-derp-removed "$(ls $d/config | grep -c derp-inert)" 0

# migrated root-owned files are fixed; user policy is preserved
echo x > $d/lib/db.sqlite; chmod 644 $d/lib/db.sqlite; chown 0:0 $d/lib/db.sqlite
printf '{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}]}\n' > $d/policy/policy.hujson
"$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1
ok migrated-perm "$(stat -c '%a %u' $d/lib/db.sqlite)" "600 65532"
ok policy-preserved "$(grep -c '"accept"' $d/policy/policy.hujson)" 1

# fail-closed guards
printf '{}\n' > $d/policy/policy.hujson
"$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1
ok implicit-allow-all "$(st $d REASON)" implicit_allow_all
ok implicit-allow-all-inert "$(grep -c '^listen_addr: 127.0.0.1:8443' $d/config/config.yaml)" 1
: > $d/policy/policy.hujson
"$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1
ok empty-policy "$(st $d REASON)" implicit_allow_all
printf '{"grants":[]}\n' > $d/policy/policy.hujson
ln -s /etc/shadow $d/lib/evil
"$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1
ok symlink "$(st $d REASON)" unsafe_files
ok symlink-not-followed "$(stat -c '%u' /etc/shadow)" 0
rm $d/lib/evil
"$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1
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
  "$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1; st $d REASON; }
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
for sub in config/config.yaml.new www/index.html www/cgi-bin status/state.new; do
  d=$(run sl-${sub//\//-}); mkdir -p $d/$(dirname $sub); rm -rf $d/$sub; ln -s $victim $d/$sub
  "$here/run-init.sh" $d HS_SERVER_DOMAIN=hs.example.com >/dev/null 2>&1; rc=$?
  ok "symlink-$sub-refused" "$rc" 1
  ok "symlink-$sub-not-followed" "$(cat $victim)" keep
done
d=$(run stray); echo x > $d/www/stray.html; "$here/run-init.sh" $d >/dev/null 2>&1
ok www-stray-removed "$(ls $d/www | grep -c stray)" 0
ok status-owner "$(stat -c '%u %a' $d/status)" "0 755"

rm -rf "$base"
echo "passed=$pass failed=$failn"; [ $failn -eq 0 ]
