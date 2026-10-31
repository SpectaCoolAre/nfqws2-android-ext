#!/bin/sh
# End-to-end tests for bin/nfqws2-ctl, run against a sandbox copy of the module
# with stub Android tools. This is the interface the WebUI talks to, so the
# shape of its output is a contract, not an implementation detail.
#
# Note on style: ctl() stores its result in $ctl_out/$ctl_rc rather than
# printing, so assertions read the variable instead of `$(ctl ...)` — a command
# substitution would run ctl in a subshell and capture nothing.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
# The test shell needs the same paths and helpers the module uses ($CONFFILE,
# $LISTS_DIR, list_count…) to inspect what the ctl did. The ctl itself sources
# its own copy from the sandbox, so this is purely for the assertions.
load_common
conf_reset
printf 'WATCHDOG=0\n' >> "$CONFFILE"

# ── json-status: the WebUI's only data source ─────────────────────────────────
section "json-status: stopped service"

ctl json-status
assert_rc 0 "$ctl_rc" "exits 0"
assert_contains "$ctl_out" '"running":false' "reports running=false"
assert_contains "$ctl_out" '"pid":""' "reports an empty pid"
assert_contains "$ctl_out" '"uptime":0' "reports uptime 0"

for key in running pid uptime strategy version mode pkt_limit_out pkt_limit_in \
           block_quic app_mode autostart ipv6 log_level qdrop queue \
           app_uids counts; do
  assert_contains "$ctl_out" "\"$key\":" "json-status exposes $key"
done
for key in user auto exclude ipset ipset_exclude apps; do
  assert_contains "$ctl_out" "\"$key\":" "counts exposes $key"
done

section "json-status: strings keep their hyphens"

# The extended build has «v1.9.6-extended»; tr from toybox used to eat the «-».
cp "$MODDIR/module.prop" "$SANDBOX/module.prop.keep"
sed -i 's/^version=.*/version=v9.9.9-extended/' "$MODDIR/module.prop"
ctl json-status
assert_contains "$ctl_out" '"version":"v9.9.9-extended"' "the version keeps its hyphen"
cp "$SANDBOX/module.prop.keep" "$MODDIR/module.prop"

section "json-status: numeric fields stay numeric"

# These are spliced into the JSON without quotes; a non-numeric value would make
# the whole document unparseable and take the WebUI down with it.
for key in pkt_limit_out pkt_limit_in block_quic autostart ipv6 log_level qdrop queue app_uids; do
  assert_match "$ctl_out" "\"$key\":[0-9]+" "$key is emitted as a bare number"
done

section "json-status: garbage in the config cannot break the JSON"

conf_reset
printf 'PKT_LIMIT_OUT=abc\nNFQUEUE_NUM=\nLOG_LEVEL=none\n' >> "$CONFFILE"
ctl json-status
assert_rc 0 "$ctl_rc" "still exits 0 with a corrupt config"
assert_match "$ctl_out" '"pkt_limit_out":[0-9]+' "corrupt PKT_LIMIT_OUT degrades to a number"
assert_match "$ctl_out" '"queue":[0-9]+' "empty NFQUEUE_NUM degrades to a number"
assert_match "$ctl_out" '"log_level":[0-9]+' "non-numeric LOG_LEVEL degrades to a number"
assert_no_match "$ctl_out" '"pkt_limit_out":"' "no numeric field is ever quoted"

section "json-status: running service"

conf_reset
# A live PID in the pidfile is enough for the running branch; actually starting
# the service would build ~260 iptables rules through the stub, which costs
# minutes on this machine and is covered by test_service.sh instead.
sleep 300 &
FAKE_PID=$!
printf '%s\n' "$FAKE_PID" > "$CONFDIR/state/nfqws2.pid"
date +%s > "$CONFDIR/state/started_at"

ctl is-running
assert_rc 0 "$ctl_rc" "is-running returns 0 for a live pid"
ctl json-status
assert_contains "$ctl_out" '"running":true' "reports running=true"
assert_contains "$ctl_out" "\"pid\":\"$FAKE_PID\"" "pid matches the pidfile"
assert_match "$ctl_out" '"uptime":[0-9]+' "uptime is reported"

kill "$FAKE_PID" 2>/dev/null
wait "$FAKE_PID" 2>/dev/null
rm -f "$CONFDIR/state/nfqws2.pid" "$CONFDIR/state/started_at"
ctl is-running
assert_rc 1 "$ctl_rc" "is-running returns 1 without a pidfile"

section "json-status: a broken started_at never reaches the arithmetic"

# A value the arithmetic cannot take ("12x", "1+", "(") makes `$((now - st))`
# fail, and the variable is left empty after a failed assignment — the payload
# then carries `"uptime":` with no number, which is not valid JSON, and
# json-status is the contract the whole WebUI parses. An empty or non-numeric
# word is worse still in a quieter way: arithmetic reads it as 0, so uptime comes
# out as `now`, i.e. "57 years". Both have to degrade to a plain 0.
sleep 300 &
BROKEN_PID=$!
printf '%s\n' "$BROKEN_PID" > "$CONFDIR/state/nfqws2.pid"
for bad in '' 'garbage' '-5' '12x' '1+' '(' '2 2'; do
  printf '%s' "$bad" > "$CONFDIR/state/started_at"
  ctl json-status
  assert_rc 0 "$ctl_rc" "started_at=[$bad] still exits 0"
  assert_no_match "$ctl_out" 'arithmetic|Syntax error|not found' \
    "started_at=[$bad] produces no arithmetic error"
  assert_contains "$ctl_out" '"uptime":0' "started_at=[$bad] degrades to uptime 0"
done

# And a real timestamp must still be used as one.
printf '%s' "$(( $(date +%s) - 42 ))" > "$CONFDIR/state/started_at"
ctl json-status
assert_match "$ctl_out" '"uptime":4[0-9]' "a valid started_at still yields the real uptime"

# Часы с загрузки важнее date: перевод часов время работы не трогает
printf '%s' "$(( $(date +%s) + 7200 ))" > "$CONFDIR/state/started_at"
awk '{ printf "%d\n", $1 * 100 - 4250 }' /proc/uptime > "$CONFDIR/state/started_cs"
ctl json-status
assert_match "$ctl_out" '"uptime":4[0-9],' "the boot clock wins over a moved wall clock"
assert_match "$ctl_out" '"uptime_ms":4[0-9]{4},' "and gives milliseconds for an even tick"
printf 'x' > "$CONFDIR/state/started_cs"
ctl json-status
assert_contains "$ctl_out" '"uptime_ms":0' "a broken mark degrades to the wall clock (here: in the future, so 0)"

kill "$BROKEN_PID" 2>/dev/null
wait "$BROKEN_PID" 2>/dev/null
rm -f "$CONFDIR/state/nfqws2.pid" "$CONFDIR/state/started_at" "$CONFDIR/state/started_cs"

# ── set ───────────────────────────────────────────────────────────────────────
section "set: value validation"

ctl set BLOCK_QUIC 1
assert_rc 0 "$ctl_rc" "BLOCK_QUIC accepts 1"
ctl get-conf
assert_contains "$ctl_out" 'BLOCK_QUIC="1"' "the value is written to the config"

ctl set BLOCK_QUIC 2
assert_rc 1 "$ctl_rc" "BLOCK_QUIC rejects 2"

ctl set PKT_LIMIT_OUT 15
assert_rc 0 "$ctl_rc" "PKT_LIMIT_OUT accepts 15"
ctl set PKT_LIMIT_OUT 0
assert_rc 1 "$ctl_rc" "PKT_LIMIT_OUT rejects 0"
ctl set PKT_LIMIT_OUT 16
assert_rc 1 "$ctl_rc" "PKT_LIMIT_OUT rejects 16"

printf 'com.termux\n' > "$CONFDIR/apps.list"
ctl set APP_MODE include
assert_rc 0 "$ctl_rc" "APP_MODE accepts include"
ctl set APP_MODE whatever
assert_rc 1 "$ctl_rc" "APP_MODE rejects an unknown mode"

ctl set NFQWS_ARGS "--lua-desync=fake"
assert_rc 1 "$ctl_rc" "set refuses parameters outside the allow-list"

ctl set BLOCK_QUIC
assert_rc 1 "$ctl_rc" "set without a value fails"

section "set-mode"

ctl set-mode list
assert_rc 0 "$ctl_rc" "set-mode list is accepted"
ctl get-conf
assert_contains "$ctl_out" 'NFQWS_EXTRA_ARGS="$MODE_LIST"' "mode is stored as a MODE_ reference"

ctl set-mode nonsense
assert_rc 1 "$ctl_rc" "set-mode rejects an unknown mode"

# ── lists ─────────────────────────────────────────────────────────────────────
section "get-list / save-list-b64"

ctl get-list user
assert_rc 0 "$ctl_rc" "get-list user works"
assert_contains "$ctl_out" "$(head -n 1 "$REPO_DIR/lists/user.list")" "get-list returns the seeded contents"

ctl save-list-b64 user "$(b64 'one.example.com
two.example.com')"
assert_rc 0 "$ctl_rc" "save-list-b64 works"
assert_eq "2" "$(list_count "$CONFDIR/lists/user.list")" "the list is replaced"

# редактор присылает текст без перевода строки в конце; nfqws2 дописывает
# в auto.list «домен\n» — без перевода в конце домены склеивались
ctl save-list-b64 auto "$(b64 'one.example.com
two.example.com')"
assert_rc 0 "$ctl_rc" "auto.list is saved from the editor"
printf '%s\n' three.example.com >> "$CONFDIR/lists/auto.list"   # как дописывает nfqws2
assert_eq "one.example.com
two.example.com
three.example.com" "$(cat "$CONFDIR/lists/auto.list")" "a domain nfqws2 appends after an edit gets its own line"
ctl save-list-b64 auto "$(b64 '')"
assert_eq "0" "$(wc -c < "$CONFDIR/lists/auto.list" | tr -d ' ')" "an emptied list stays empty, without a stray blank line"

ctl get-list nosuchlist
assert_rc 1 "$ctl_rc" "an unknown list name is rejected"

section "add-domain"

printf 'first.example.com' > "$CONFDIR/lists/user.list"   # deliberately no trailing newline
ctl add-domain "https://WWW.Example.COM/some/path"
assert_rc 0 "$ctl_rc" "add-domain accepts a URL"
assert_contains "$ctl_out" "example.com" "the domain is lowercased and normalised"
assert_eq "2" "$(list_count "$CONFDIR/lists/user.list")" "the previous entry survives the append"

ctl add-domain "https://www.example.com/"
assert_eq "2" "$(list_count "$CONFDIR/lists/user.list")" "an existing domain is not duplicated"

ctl add-domain "not a domain"
assert_rc 1 "$ctl_rc" "add-domain rejects garbage"

ctl clear-auto
assert_rc 0 "$ctl_rc" "clear-auto works"
assert_eq "0" "$(list_count "$CONFDIR/lists/auto.list")" "auto.list is emptied"

ctl reset-lists
assert_rc 0 "$ctl_rc" "reset-lists works"
assert_eq "$(list_count "$MODDIR/defaults/lists/user.list")" "$(list_count "$CONFDIR/lists/user.list")" \
  "user.list is back to the shipped default"

# ── config ────────────────────────────────────────────────────────────────────
section "save-conf-b64"

ctl save-conf-b64 "$(b64 'A=1
B="x"')"
assert_rc 0 "$ctl_rc" "a valid config is accepted"
ctl get-conf
assert_contains "$ctl_out" 'A=1' "the new config is in place"

ctl save-conf-b64 "$(b64 'A=`id`')"
assert_rc 1 "$ctl_rc" "a config with a backtick is rejected"

ctl save-conf-b64 "$(b64 'A=$(id)')"
assert_rc 1 "$ctl_rc" "a config with command substitution is rejected"

ctl save-conf-b64 "$(b64 '')"
assert_rc 1 "$ctl_rc" "an empty config is rejected"

assert_file "$CONFFILE.bak" "a backup of the previous config is kept"

# ── check / dry-run ───────────────────────────────────────────────────────────
section "check and dry-run"

ctl check
assert_rc 0 "$ctl_rc" "check succeeds on valid config"
assert_contains "$ctl_out" "OK" "check reports OK"

ctl dry-run
assert_rc 0 "$ctl_rc" "dry-run alias succeeds"

MOCK_NFQWS_DRY_RUN_FAIL=1
export MOCK_NFQWS_DRY_RUN_FAIL
ctl check
assert_rc 1 "$ctl_rc" "check reports failure when dry-run fails"
assert_contains "$ctl_out" "Ошибка проверки" "failure is announced"

ctl save-conf-b64 "$(b64 'NFQWS_BASE_ARGS="--invalid"')"
assert_rc 1 "$ctl_rc" "save-conf-b64 rejects config failing dry-run"
unset MOCK_NFQWS_DRY_RUN_FAIL

# ── strategies ────────────────────────────────────────────────────────────────
section "strategies"

ctl list-strategies
assert_rc 0 "$ctl_rc" "list-strategies works"
assert_contains "$ctl_out" "alt13" "a shipped strategy is listed"
# "default" is not a file — it means "use the shipped nfqws2.conf" — so the ctl
# deliberately does not list it; the WebUI prepends it itself.
assert_not_contains "$ctl_out" "default" "default is not a real strategy file"
assert_eq "$(printf '%s\n' "$ctl_out" | sort -u | wc -l | tr -d ' ')" \
          "$(printf '%s\n' "$ctl_out" | wc -l | tr -d ' ')" "the list has no duplicates"

mkdir -p "$CONFDIR/strategies"
printf 'NFQWS_ARGS="--filter-tcp=443"\n' > "$CONFDIR/strategies/mine.conf"
ctl list-strategies
assert_contains "$ctl_out" "mine" "user strategies are listed too"

ctl get-strategy
assert_rc 0 "$ctl_rc" "get-strategy works"

ctl set-strategy alt13
assert_rc 0 "$ctl_rc" "set-strategy applies a shipped strategy"
ctl get-conf
# Shipped strategies already reference $LUA_DIR/$BLOBS_DIR, exactly like the
# default config does — the config is sourced by the module, so the reference
# form is what should end up in it. What must NOT survive is a keenetic path.
assert_contains "$ctl_out" '@$LUA_DIR/' "the strategy keeps \$LUA_DIR references"
assert_not_contains "$ctl_out" "/opt/etc/nfqws2" "no keenetic paths survive the rewrite"
ctl get-strategy
assert_eq "alt13" "$ctl_out" "the active strategy is recorded"

ctl set-strategy nosuchstrategy
assert_rc 1 "$ctl_rc" "an unknown strategy is rejected"

ctl set-strategy default
assert_rc 0 "$ctl_rc" "set-strategy default works"
ctl get-strategy
assert_eq "default" "$ctl_out" "the active strategy is back to default"

# ── два режима: стратегии и умный режим ───────────────────────────────────────
section "strategies mode and smart mode"
ctl set-strategy alt13
ctl set-strategy smart
ctl last-strategy
assert_eq "alt13" "$ctl_out" "smart mode remembers the strategy to go back to"
ctl bypass-info
printf '%s' "$ctl_out" > "$SANDBOX/byp.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$SANDBOX/byp.json" 2>/dev/null
assert_rc 0 $? "bypass-info is valid JSON"
assert_contains "$ctl_out" '"strategy":"smart","last":"alt13","modified":0' "with the strategy, the one to go back to and whether the config was edited"
printf 'alt13\t42\t5\t1700000000\n' > "$STATE_DIR/strat_stat"
echo alt13 > "$ACTIVE_FILE"
ctl bypass-info
assert_contains "$ctl_out" '"stat":{"ok":42,"err":5,"since":1700000000}' "the strategy's connection statistics"
assert_contains "$ctl_out" '"meta":{"author":"Flowseal","repo":"rndnaame/nfqws-menu","date":"' "and where it comes from"
assert_contains "$ctl_out" '"edited":""' "not edited by the user"
ctl live-status
printf '%s' "$ctl_out" > "$SANDBOX/live.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$SANDBOX/live.json" 2>/dev/null
assert_rc 0 $? "live-status is valid JSON"
assert_contains "$ctl_out" '"conn":{"ok":42,"err":5}' "the status screen gets this strategy's connections"
rm -f "$LAST_STRATEGY_FILE"
echo smart > "$ACTIVE_FILE"
ctl last-strategy
assert_eq "hardcorp74" "$ctl_out" "nothing remembered: the first-install strategy"
ctl set-strategy default

# ── imports ───────────────────────────────────────────────────────────────────
section "imports"

imp=$(b64 'NFQWS_ARGS="--filter-tcp=443"
ISP_INTERFACE="eth0"
PKT_LIMIT_OUT=3')
ctl import-add-b64 "$(b64 'my-config')" "$imp"
assert_rc 0 "$ctl_rc" "a keenetic config is imported"
assert_contains "$ctl_out" "my-config" "the import is stored under its name"

ctl list-imports
assert_contains "$ctl_out" "my-config" "the import is listed"

ctl get-import-merged-b64 "my-config"
assert_rc 0 "$ctl_rc" "the merged preview is produced"
preview=$(printf '%s' "$ctl_out" | base64 -d 2>/dev/null)
assert_not_contains "$preview" "ISP_INTERFACE=" "the preview drops ISP_INTERFACE"
assert_contains "$preview" "AUTOSTART=" "the preview fills in Android settings"

# Списки стратегии в MODE_LIST (hardcorp74 из nfqws-menu: user.list + user_extra.list) переносятся
imp=$(b64 'NFQWS_ARGS="--filter-tcp=443"
MODE_LIST="--hostlist=/opt/etc/nfqws2/lists/user.list --hostlist=/opt/etc/nfqws2/lists/user_extra.list"
NFQWS_EXTRA_ARGS="$MODE_LIST"
IPV6_ENABLED=0')
ctl import-add-b64 "$(b64 'with-extra')" "$imp"
ctl get-import-merged-b64 "with-extra"
preview=$(printf '%s' "$ctl_out" | base64 -d 2>/dev/null)
assert_contains "$preview" 'MODE_LIST="--hostlist=$LISTS_DIR/user.list --hostlist=$LISTS_DIR/user_extra.list"' "the imported MODE_LIST with its extra list is kept"
assert_contains "$preview" 'IPV6_ENABLED=1' "IPv6 of a router config (off there) does not carry over to the phone"

# strategies written for other nfqws2 builds may carry options this binary doesnt know
imp=$(b64 '# e.g. NFQWS_ARGS_CUSTOM="--made-up-option=auto"
NFQWS_BASE_ARGS="--made-up-option=auto
                 --lua-init=@/opt/etc/nfqws2/lua/zapret-lib.lua"
NFQWS_ARGS="--filter-tcp=443 --made-up-option --payload=tls_client_hello
            --lua-desync=fake:blob=tls_clienthello
            --made-up-option=auto"
ISP_INTERFACE="eth0"')
ctl import-add-b64 "$(b64 'foreign')" "$imp"
assert_rc 0 "$ctl_rc" "a config with a foreign option is still imported"
assert_contains "$ctl_out" "removed	--made-up-option" "the removed option is reported"
f=$(cat "$CONFDIR/imports/foreign.conf")
assert_not_contains "$f" "made-up" "the foreign option is gone from every line"
assert_contains "$f" 'NFQWS_BASE_ARGS="--lua-init=@$LUA_DIR/zapret-lib.lua"' "a value left empty on its first line joins the next one"
assert_contains "$f" '--filter-tcp=443 --payload=tls_client_hello' "a mid-line option leaves no gap"
assert_contains "$f" '--lua-desync=fake:blob=tls_clienthello"' "a closing quote moves up to the last argument"
ctl import-add-b64 "$(b64 'clean')" "$(b64 'NFQWS_ARGS="--filter-tcp=443"
TCP_PORTS=443')"
assert_not_contains "$ctl_out" "removed" "a clean config reports nothing"

ctl import-add-b64 "$(b64 'not-a-config')" "$(b64 'just some text')"
assert_rc 1 "$ctl_rc" "a non-keenetic file is rejected"

ctl get-import-merged-b64 "../etc/passwd"
assert_rc 1 "$ctl_rc" "path traversal in get-import-merged is rejected"
ctl delete-import "../etc/passwd"
assert_rc 1 "$ctl_rc" "path traversal in delete-import is rejected"
ctl rename-import "../etc/passwd" "x"
assert_rc 1 "$ctl_rc" "path traversal in rename-import is rejected"

ctl rename-import "my-config" "renamed-import"
assert_rc 0 "$ctl_rc" "an import can be renamed"
assert_contains "$ctl_out" "renamed-import" "the new name is reported"
assert_no_file "$CONFDIR/imports/my-config.conf" "the old file is gone"

ctl delete-import "renamed-import"
assert_rc 0 "$ctl_rc" "an import can be deleted"
assert_no_file "$CONFDIR/imports/renamed-import.conf" "the file is really gone"

# ── logs ──────────────────────────────────────────────────────────────────────
section "logs"

printf 'line one\nline two\nline three\n' > "$CONFDIR/logs/service.log"
ctl get-logs service 2
assert_rc 0 "$ctl_rc" "get-logs works"
assert_contains "$ctl_out" "line three" "the tail includes the newest line"
assert_not_contains "$ctl_out" "line one" "the tail respects the requested count"

ctl get-logs service abc
assert_rc 0 "$ctl_rc" "a non-numeric line count falls back instead of failing"
assert_contains "$ctl_out" "line one" "the fallback keeps everything"

ctl get-logs nfqws 5
assert_contains "$ctl_out" "пусто" "an empty log reports (пусто) rather than nothing"

printf 'learned something\n' > "$CONFDIR/logs/smart.log"
ctl clear-logs
assert_rc 0 "$ctl_rc" "clear-logs works"
assert_eq "0" "$(wc -c < "$CONFDIR/logs/service.log" | tr -d ' ')" "service.log is truncated"
assert_eq "0" "$(wc -c < "$CONFDIR/logs/smart.log" | tr -d ' ')" "and the smart mode log too"

# ── backup & export ───────────────────────────────────────────────────────────
section "backup and export"

# Списки nfqws-menu маленькие — архив раздуваем сами: проверяется путь
# большого архива (по частям через upload)
awk 'BEGIN { srand(7); for (i = 0; i < 6000; i++) printf "%08x%08x.example\n", rand() * 4294967295, rand() * 4294967295 }' >> "$LISTS_DIR/user.list"
ctl backup-create "$(b64 '{"m3_monochrome":"true"}')"
assert_rc 0 "$ctl_rc" "backup-create works"
b64_bak="$(printf '%s' "$ctl_out" | cut -f3)"
assert_match "$ctl_out" "nfqws2-backup-.*\.tar" "backup-create outputs archive name"

ctl backup-list
assert_rc 0 "$ctl_rc" "backup-list works"
assert_match "$ctl_out" "nfqws2-backup-.*\.tar" "backup-list lists created archive"

if [ -n "$b64_bak" ]; then
  # Как WebUI: большой архив не влезает в один аргумент — кусками через upload
  assert_ge "${#b64_bak}" 131072 "the test archive is bigger than one argument may be"
  printf '%s' "$b64_bak" | fold -w 48000 > "$SANDBOX/chunks"
  up_ok=0
  while IFS= read -r chunk || [ -n "$chunk" ]; do ctl upload tk1 "$chunk"; [ "$ctl_rc" = 0 ] || up_ok=1; done < "$SANDBOX/chunks"
  assert_rc 0 "$up_ok" "the archive is uploaded in pieces"
  ctl upload '../x' abc
  assert_rc 1 "$ctl_rc" "an upload tag with a path is refused"
  ctl backup-restore-b64 "@up:tk1"
  assert_rc 0 "$ctl_rc" "backup-restore-b64 works"
  assert_contains "$ctl_out" "$(b64 '{"m3_monochrome":"true"}')" "backup-restore-b64 returns ui state"
  assert_no_file "$CONFDIR/state/upload/tk1" "the uploaded file is removed after use"
fi

ctl export-logs
assert_rc 0 "$ctl_rc" "export-logs works"
assert_match "$ctl_out" "^nfqws2-logs-[0-9]{8}-[0-9]{6}\.tar	" "everything goes into an archive with the date and time"
EXP_OLD="${NFQWS_BACKUP_DIR:-}"; NFQWS_BACKUP_DIR="$SANDBOX/exp"; export NFQWS_BACKUP_DIR
printf 'dns line\n' > "$CONFDIR/logs/dns.log"
ctl export-logs path dns
assert_rc 0 "$ctl_rc" "one log can be exported"
assert_match "$ctl_out" "^nfqws2-dns-[0-9]{8}-[0-9]{6}\.log	$SANDBOX/exp/nfqws2-dns-" "as a file, with the date and time in its name"
assert_eq "dns line" "$(cat "$(printf '%s' "$ctl_out" | cut -f2)")" "holding that log"
ctl export-logs path dns,service
assert_match "$ctl_out" "^nfqws2-logs-.*\.tar	" "two of them — an archive"
assert_contains "$(tar -tf "$(printf '%s' "$ctl_out" | cut -f2)")" "dns.log" "with what was chosen"
assert_not_contains "$(tar -tf "$(printf '%s' "$ctl_out" | cut -f2)")" "doctor.txt" "and nothing else"
assert_eq "" "$(tar -tf "$(printf '%s' "$ctl_out" | cut -f2)" | grep '^\./')" "entries are plain names: no «.» folder when a file manager opens the archive"
ctl export-logs path nosuch
assert_rc 1 "$ctl_rc" "an unknown log is refused"
rm -f "$LOG_DIR/nfqws2-debug.log" "$CONFDIR/logs/nfqws2-debug.log"
ctl export-logs path debug
assert_rc 1 "$ctl_rc" "an empty choice says there is nothing to export"
printf '#!/bin/sh\necho "$*" >> "$MOCK_DIR/am.log"; echo "Starting: Intent"\n' > "$MOCKBIN/am"
chmod 0755 "$MOCKBIN/am"; : > "$MOCK_DIR/am.log"
ctl export-logs share dns,smart
assert_rc 0 "$ctl_rc" "share builds a temporary archive"
assert_match "$ctl_out" "$SANDBOX/exp/.share/nfqws2-logs-" "in its own folder"
assert_contains "$(cat "$MOCK_DIR/am.log")" "android.intent.action.SEND" "and opens the share sheet"
assert_match "$(cat "$MOCK_DIR/am.log")" "SEND --user 0 -d [^ ]+ -t application/x-tar" "the link is also the intent data, so the read grant reaches the app (Telegram), and the type is tar"
rm -f "$MOCKBIN/am"
if [ -n "$EXP_OLD" ]; then NFQWS_BACKUP_DIR="$EXP_OLD"; else unset NFQWS_BACKUP_DIR; fi

# ── любой существующий список читается по имени ───────────────────────────────
section "get-list: other lists by name"
printf 'blocked.example\n' > "$LISTS_DIR/rkn.list"
ctl get-list rkn
assert_contains "$ctl_out" "blocked.example" "a list outside the fixed set opens by its name"
ctl get-list '../../etc/passwd'
assert_rc 1 "$ctl_rc" "a path is refused"
ctl get-list nosuchlist
assert_rc 1 "$ctl_rc" "a missing list is refused"

# ── проверка одного домена ────────────────────────────────────────────────────
section "domain-check"

printf 'youtube.com\n' >> "$LISTS_DIR/user.list"
printf 'www.googlevideo.com\n' >> "$LISTS_DIR/exclude.list"
printf '203.0.113.0/24\n' >> "$LISTS_DIR/ipset.list"
printf 'nothing-else.org\n' > "$LISTS_DIR/roblox.list"
printf '#!/bin/sh\necho "PING $4 (203.0.113.7) 56(84) bytes of data."\n' > "$MOCKBIN/ping"
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/curl"
chmod 0755 "$MOCKBIN/ping" "$MOCKBIN/curl"
ctl domain-check 'https://M.YouTube.com/watch?v=1'
assert_rc 0 "$ctl_rc" "domain-check runs"
assert_contains "$ctl_out" "$(printf 'LIST\tuser.list\thost\tyoutube.com')" "a subdomain is found by its parent entry, as nfqws2 matches it"
assert_contains "$ctl_out" "$(printf 'IP\t203.0.113.7')" "the resolved IP is reported"
assert_contains "$ctl_out" "$(printf 'LIST\tipset.list\tipset\t203.0.113.0/24')" "and matched against the ipset subnets"
assert_match "$ctl_out" "R	[123]	ok" "the site is opened through the bypass"
assert_contains "$ctl_out" "done" "the output ends with done"
ctl domain-check www.googlevideo.com
assert_contains "$ctl_out" "$(printf 'LIST\texclude.list\texclude')" "an exclusion is reported as such"
printf '^exact.example\n' >> "$LISTS_DIR/user.list"
ctl domain-check exact.example
assert_contains "$ctl_out" "$(printf 'LIST\tuser.list\thost\t^exact.example')" "a ^entry (nfqws-menu lists) matches the domain itself"
ctl domain-check sub.exact.example
assert_not_contains "$ctl_out" "^exact.example" "but not its subdomains, as nfqws2 matches it"
ctl domain-check 'bad host'
assert_rc 1 "$ctl_rc" "a malformed domain is refused"

# Сайт с защитой от ботов: без куки — переадресация по кругу (curl: 47),
# с хранилищем куки (-b/-c одного файла) — открывается
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
b=""; c=""
while [ $# -gt 0 ]; do case "$1" in -b) b="$2"; shift 2 ;; -c) c="$2"; shift 2 ;; *) shift ;; esac; done
echo "$b" >> "$MOCK_DIR/curl.jars"
[ -n "$b" ] && [ "$b" = "$c" ] && exit 0
exit 47
X
chmod 0755 "$MOCKBIN/curl"
: > "$MOCK_DIR/curl.jars"
ctl domain-check cookie.example
assert_match "$ctl_out" "R	[123]	ok" "a site that sets a cookie by redirecting to itself opens: curl keeps cookies like a browser"
jar=$(head -n 1 "$MOCK_DIR/curl.jars")
assert_contains "$jar" "$STATE_DIR/probe.ck." "the cookie jar lives in the module state"
assert_no_file "$jar" "and is removed after the attempt"
printf '#!/bin/sh\nexit 47\n' > "$MOCKBIN/curl"
ctl domain-check loop.example
assert_match "$ctl_out" "R	[123]	ok" "endless redirects still mean the server answered — not a DPI block"

# Заглушка провайдера вместо сайта: тело ответа (-o файл) — страница блокировки
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
o=""; for a; do [ "$p" = "-o" ] && o="$a"; p="$a"; done
case "$a" in *stub.example*) printf '<html><head><title>Доступ ограничен</title></head><body>Ресурс включён в единый реестр</body></html>' > "$o" ;;
  *rich.example*) printf '<html><head><title>News</title></head><body>статья о том, что сайт был заблокирован в 2024</body>%s</html>' "$(head -c 20000 /dev/zero | tr '\0' x)" > "$o" ;;
  *) printf '<html><head><title>OK</title></head></html>' > "$o" ;; esac
exit 0
X
chmod 0755 "$MOCKBIN/curl"
ctl domain-check stub.example
assert_match "$ctl_out" "R	[123]	fail isp_redir" "a block page of the ISP instead of the site is a block, not «opens»"
ctl domain-check rich.example
assert_match "$ctl_out" "R	[123]	ok" "a big page that only mentions blocking is the site itself"
assert_eq "" "$(ls "$STATE_DIR"/probe.body.* 2>/dev/null)" "page bodies are removed after the attempt"

# Повторный запрос по тому же соединению: curl с двумя адресами, по строке
# «код соединений» на каждый. Второй без ответа по старому соединению — заморожено
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
n=0; for a; do case "$a" in https://*) n=$((n + 1)) ;; esac; done
[ "$n" = 2 ] || { o=""; for a; do [ "$p" = "-o" ] && o="$a"; p="$a"; done; printf 'ok' > "$o"; exit 0; }
case "$a" in *frozen.example*) printf '200 1\n000 0\n'; exit 28 ;;
  *down.example*) printf '000 0\n000 0\n'; exit 28 ;;
  *) printf '200 1\n200 0\n' ;; esac
X
chmod 0755 "$MOCKBIN/curl"
ctl domain-check fine.example
assert_match "$ctl_out" "K	ok" "the second request on the same connection is answered: ok"
ctl domain-check frozen.example
assert_match "$ctl_out" "K	stall" "the first is answered, the second on the same connection is not: frozen after the first exchange"
ctl domain-check down.example
assert_match "$ctl_out" "K	skip" "the first request itself failed: nothing to say about the second"

# Discord: WebSocket gateway — удача только при ответе 101 (curl после него
# ждёт данных до тайм-аута и выходит с кодом 28)
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
ws=0; for a; do [ "$a" = "Upgrade: websocket" ] && ws=1; done
[ "$ws" = 1 ] || { echo "no upgrade" >> "$MOCK_DIR/ws.log"; exit 0; }
printf '\nHTTP_CODE:%s\n' "$(cat "$MOCK_DIR/ws.code")"
[ "$(cat "$MOCK_DIR/ws.code")" = 101 ] && exit 28
exit 0
X
chmod 0755 "$MOCKBIN/curl"
echo 101 > "$MOCK_DIR/ws.code"; : > "$MOCK_DIR/ws.log"
ctl domain-check gateway.discord.gg
assert_match "$ctl_out" "R	[123]	ok" "Discord gateway answers 101 to a WebSocket upgrade: works (curl's timeout after it does not matter)"
assert_eq "" "$(cat "$MOCK_DIR/ws.log")" "it is asked for WebSocket"
assert_no_match "$ctl_out" "K	" "and no repeat request: WebSocket is not request-response"
echo 403 > "$MOCK_DIR/ws.code"
ctl domain-check gateway.discord.gg
assert_match "$ctl_out" "R	[123]	fail ws_blocked" "the server answered but WebSocket did not go through: blocked"
# Почему не работает: та же попытка мимо обхода (curl --resolve на тот же
# адрес, правило RETURN для него) и скорость скачивания
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
nb=0; sp=0; o=""
for a; do
  [ "$p" = "-o" ] && o="$a"
  [ "$a" = "--resolve" ] && nb=1
  case "$a" in *size_download*) sp=1 ;; esac
  p="$a"
done
if [ "$sp" = 1 ]; then printf '%s' "$(cat "$MOCK_DIR/speed")"; exit 0; fi
if [ "$nb" = 1 ]; then
  iptables -w -t mangle -S nfqws_post 2>/dev/null | grep -q 'uid-owner 0 -d 203.0.113.7' && echo rule >> "$MOCK_DIR/nb.log"
  exit "$(cat "$MOCK_DIR/nb.rc")"
fi
[ -n "$o" ] && printf 'ok' > "$o"
exit "$(cat "$MOCK_DIR/via.rc")"
X
chmod 0755 "$MOCKBIN/curl"
iptables -w -t mangle -N nfqws_post 2>/dev/null
sleep 30 & fakesvc=$!; echo "$fakesvc" > "$PIDFILE"
echo 35 > "$MOCK_DIR/via.rc"; echo 0 > "$MOCK_DIR/nb.rc"; echo '900000 2500.000' > "$MOCK_DIR/speed"; : > "$MOCK_DIR/nb.log"
ctl domain-check blocked-by-bypass.example
assert_match "$ctl_out" "N	ok" "the same address without the bypass is tried too"
assert_eq "rule" "$(head -n 1 "$MOCK_DIR/nb.log")" "past nfqws2: a RETURN rule for that address only while it runs"
assert_not_contains "$(iptables -w -t mangle -S nfqws_post 2>/dev/null)" "uid-owner 0" "and the rule is removed afterwards"
assert_match "$ctl_out" "S	900000 2500" "the download speed through the bypass is measured"
echo 0 > "$MOCK_DIR/via.rc"; echo 35 > "$MOCK_DIR/nb.rc"
ctl domain-check needs-bypass.example
assert_match "$ctl_out" "N	fail tls" "a site that needs the bypass fails without it"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; rm -f "$PIDFILE"
ctl domain-check stopped.example
assert_match "$ctl_out" "N	skip" "with the service stopped there is nothing to compare"
rm -f "$MOCKBIN/ping" "$MOCKBIN/curl"

# ── поделиться файлом ─────────────────────────────────────────────────────────
section "share"
printf '#!/bin/sh\necho "$*" >> "$MOCK_DIR/am.log"; echo "Starting: Intent"\n' > "$MOCKBIN/am"
chmod 0755 "$MOCKBIN/am"; : > "$MOCK_DIR/am.log"
ctl share file "$CONFFILE"
assert_rc 0 "$ctl_rc" "the config is shared as a file"
assert_contains "$(cat "$MOCK_DIR/am.log")" "file://$CONFFILE" "by a link to its real path"
ctl share text "$CONFFILE"
assert_contains "$(cat "$MOCK_DIR/am.log")" "android.intent.extra.TEXT" "or as text"
ctl share file /etc/passwd
assert_rc 1 "$ctl_rc" "other files cannot be shared"
ctl strategy-path alt
sp=$ctl_out
assert_eq "$STRATEGIES_DIR/alt.conf" "$sp" "strategy-path gives the built-in file of a strategy"
ctl share text "$sp"
assert_rc 0 "$ctl_rc" "a strategy can be shared from its menu"
ctl strategy-path default
assert_eq "$MODDIR/defaults/nfqws2.conf" "$ctl_out" "and the default one"
ctl share file "$STRATEGIES_DIR/../service.sh"
assert_rc 1 "$ctl_rc" "but not a path that climbs out of the strategies"
ctl strategy-path nosuch
assert_rc 1 "$ctl_rc" "an unknown strategy has no path"
rm -f "$MOCKBIN/am"

# ── doctor / status ───────────────────────────────────────────────────────────
section "doctor"

ctl doctor
assert_rc 0 "$ctl_rc" "doctor runs to completion"
assert_match "$ctl_out" "^(ok|warn|fail|info)	" "doctor emits tab-separated severity rows"
assert_contains "$ctl_out" "NFQUEUE" "doctor checks the NFQUEUE target"
assert_contains "$ctl_out" "limiter" "doctor reports the limiter in use"
assert_contains "$ctl_out" "ОЗУ" "doctor reports memory consumption"

section "doctor without kernel features"

MOCK_IPT_FEATURES="multiport NFQUEUE"
export MOCK_IPT_FEATURES
ctl doctor
assert_contains "$ctl_out" "нет connbytes" "a kernel without connbytes is reported as connmark_out"
MOCK_IPT_FEATURES="connbytes multiport owner NFQUEUE"
export MOCK_IPT_FEATURES

section "status"

ctl status
assert_rc 0 "$ctl_rc" "status works"
assert_contains "$ctl_out" "Служба NFQWS2" "status reports the service state"
assert_contains "$ctl_out" "Режим:" "status reports the mode line"

section "unknown command"

ctl definitely-not-a-command
assert_rc 1 "$ctl_rc" "an unknown command fails"
assert_contains "$ctl_out" "Команды:" "an unknown command prints the usage list"

section "save-list-b64: a failed write is reported instead of OK"

# The write was unchecked and followed by `echo OK`, so a failed mv — a full
# disk, no permission, a directory where the file should be — came back as
# success. The UI shows the output, so the user read "OK" and lost their edits.
# Making $f.tmp a directory is the portable way to fail the redirect.
rm -f "$LISTS_DIR/user.list.tmp"
mkdir -p "$LISTS_DIR/user.list.tmp"
ctl save-list-b64 user "$(b64 'one
two')"
assert_rc 1 "$ctl_rc" "a failed save exits non-zero"
assert_contains "$ctl_out" "Не удалось сохранить" "and says what failed"
assert_not_contains "$ctl_out" "OK" "and does not claim success"
rmdir "$LISTS_DIR/user.list.tmp" 2>/dev/null

ctl save-list-b64 user "$(b64 'one
two')"
assert_rc 0 "$ctl_rc" "a working save exits 0"
assert_contains "$ctl_out" "OK" "and reports OK"
assert_eq "one" "$(head -n 1 "$LISTS_DIR/user.list")" "the list really is written"
assert_eq "two" "$(tail -n 1 "$LISTS_DIR/user.list")" "with every line of it"

# ── system wrapper (/system/bin/nfqws2-ctl) ──────────────────────────────────
section "system wrapper (/system/bin/nfqws2-ctl)"

wrapper="$MODDIR/system/bin/nfqws2-ctl"
assert_file "$wrapper" "system wrapper exists in sandbox"

# Delegation to ctl
out=$(MODDIR="$MODDIR" sh "$wrapper" status)
assert_rc 0 $? "system wrapper executes status successfully"
assert_contains "$out" "Служба NFQWS2" "system wrapper returns status output"

out=$(MODDIR="$MODDIR" sh "$wrapper" check)
assert_rc 0 $? "system wrapper executes check command"
assert_contains "$out" "OK" "check returns OK through wrapper"

# Non-root notification
non_root_bin="$SANDBOX/non_root_bin"
mkdir -p "$non_root_bin"
printf '#!/bin/sh\necho 1000\n' > "$non_root_bin/id"
chmod 0755 "$non_root_bin/id"
out=$(MODDIR="" SANDBOX="" PATH="$non_root_bin:$PATH" sh "$wrapper" status 2>&1)
assert_rc 1 $? "system wrapper rejects non-root user"
assert_contains "$out" "требуется root" "wrapper prints root reminder"
rm -rf "$non_root_bin"

section "first install starts with hardcorp74"
rm -f "$CONFFILE" "$CONFDIR/state/active_strategy"
load_conf >/dev/null 2>&1
assert_eq "hardcorp74" "$(cat "$CONFDIR/state/active_strategy" 2>/dev/null)" "the first strategy is hardcorp74"
assert_eq "$(cat "$MODDIR/strategies/hardcorp74.conf")" "$(cat "$CONFFILE")" "and the config is that strategy"
ctl conf-modified
assert_eq "0" "$ctl_out" "which reads as unmodified"
conf_reset; rm -f "$CONFDIR/state/active_strategy"

# ── list-apps (из оригинала, 0badd3d) ──────────────────────────────────────────
section "list-apps"
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/apps_cache.json" <<'JSON'
[{"pkg":"com.example.test","name":"Test App","icon":"","system":false}]
JSON
ctl list-apps
assert_rc 0 "$ctl_rc" "list-apps answers from the cache"
assert_contains "$ctl_out" "com.example.test" "with the cached names and icons"
ctl list-apps refresh
assert_rc 0 "$ctl_rc" "a refresh without the generator still succeeds"
assert_contains "$ctl_out" "com.example.test" "and keeps the rich cache instead of bare package names"
rm -f "$STATE_DIR/apps_cache.json"
cat > "$MOCKBIN/pm" <<'PM'
#!/bin/sh
echo "package:com.fallback.one"
echo "package:com.fallback.two"
PM
chmod 0755 "$MOCKBIN/pm"
ctl list-apps
assert_rc 0 "$ctl_rc" "without a cache and generator pm is the fallback"
assert_contains "$ctl_out" "com.fallback.one" "package names without the prefix"
rm -f "$MOCKBIN/pm"

harness_finish
