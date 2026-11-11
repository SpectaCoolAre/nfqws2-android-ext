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
FAKE_PID=$(fake_daemon "$CONFDIR/state/nfqws2.pid")
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
BROKEN_PID=$(fake_daemon "$CONFDIR/state/nfqws2.pid")
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
assert_contains "$ctl_out" '"dns_rss":0,' "no dnsproxy running: its memory is 0"
# dnsproxy (основной и для CDN): своя память в отдельном поле; мёртвый pid и
# мусор в файле не считаются
sleep 30 & dp1=$!
sleep 30 & dp2=$!
# память читать после exec: до него у процесса память оболочки, и она другая
i=0; while [ $i -lt 50 ]; do
  case "$(tr '\0' ' ' < "/proc/$dp1/cmdline")$(tr '\0' ' ' < "/proc/$dp2/cmdline")" in "sleep 30 sleep 30 ") break ;; esac
  sleep 0.1; i=$((i + 1))
done
echo "$dp1" > "$STATE_DIR/dnsproxy.pid"
echo "$dp2" > "$STATE_DIR/dnsproxy-cdn.pid"
ctl live-status
r1=$(awk '/^VmRSS:/ { print $2 }' "/proc/$dp1/status"); r2=$(awk '/^VmRSS:/ { print $2 }' "/proc/$dp2/status")
assert_contains "$ctl_out" "\"dns_rss\":$((r1 + r2))," "the memory of both dnsproxy processes is added up"
kill "$dp2" 2>/dev/null; wait "$dp2" 2>/dev/null
echo 'x1' > "$STATE_DIR/dnsproxy-cdn.pid"
ctl live-status
r1=$(awk '/^VmRSS:/ { print $2 }' "/proc/$dp1/status")
assert_contains "$ctl_out" "\"dns_rss\":$r1," "a dead or broken pid is not counted"
kill "$dp1" 2>/dev/null; wait "$dp1" 2>/dev/null
rm -f "$STATE_DIR/dnsproxy.pid" "$STATE_DIR/dnsproxy-cdn.pid"
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
assert_eq "1" "$(grep -c . "$CONFDIR/logs/service.log")" "service.log is truncated"
assert_contains "$(cat "$CONFDIR/logs/service.log")" "действие пользователя: журналы очищены" "keeping one line: who cleared it"
assert_eq "0" "$(wc -c < "$CONFDIR/logs/smart.log" | tr -d ' ')" "and the smart mode log too"

# Действия пользователя — в журнал службы: кто остановил, что забыто, что
# отключено. Чтение (состояние, списки) — нет
section "user actions are logged"
: > "$CONFDIR/logs/service.log"
ctl status >/dev/null; ctl get-list user >/dev/null; ctl smart-status >/dev/null; ctl dns-state >/dev/null
assert_eq "0" "$(grep -c 'действие пользователя' "$CONFDIR/logs/service.log")" "reading the state is not an action"
ctl set SMART_LEARN 0
assert_contains "$(cat "$CONFDIR/logs/service.log")" "действие пользователя: настройка SMART_LEARN=0" "a setting change is logged with its value"
ctl smart-reset all
assert_contains "$(cat "$CONFDIR/logs/service.log")" "действие пользователя: умный режим: забыто всё выученное (все сети)" "forgetting everything learned is logged"
assert_contains "$(cat "$CONFDIR/logs/smart.log")" "действие пользователя: умный режим: забыто всё выученное" "in the smart mode log too, where it will be looked for"
ctl smart-reset mobile-25001
assert_contains "$(cat "$CONFDIR/logs/service.log")" "забыто выученное сети mobile-25001" "forgetting one network names it"
ctl add-domain example.org
assert_contains "$(cat "$CONFDIR/logs/service.log")" "действие пользователя: добавлен домен example.org" "a domain added by hand"
ctl dns-geo-off dns.example 1
assert_contains "$(cat "$CONFDIR/logs/service.log")" "сервер обхода геоблока dns.example: отключён" "a bypass DNS switched off by hand"
ctl dns-geo-off dns.example 0
ctl set SMART_LEARN 1

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
# журнал DNS — вместе с итогами проверок серверов обхода и маршрутами: по ним
# видно, какой сервер у сайта и что меняется между проверками
mkdir -p "$DNS_GEO_SCAN_DIR"; printf '#time=1\n' > "$DNS_GEO_SCAN_DIR/wifi-test.tsv"; printf 'claude.ai dns.example\n' > "$DNS_GEO_SCAN_DIR/wifi-test.tsv.pin"
ctl export-logs path dns
assert_match "$ctl_out" "^nfqws2-logs-.*\.tar	" "with the geo server checks the DNS log goes into an archive"
assert_contains "$(tar -tf "$(printf '%s' "$ctl_out" | cut -f2)")" "dns/wifi-test.tsv.pin" "with the checks and the servers pinned to sites"
rm -rf "$DNS_GEO_SCAN_DIR"
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
# все списки модуля для экрана «Все списки»: имя и число записей без комментариев
printf '# мой список\na.example\n\nb.example\n' > "$LISTS_DIR/mine.list"
ctl list-all
assert_contains "$ctl_out" "$(printf 'mine\t2')" "every list with its entries, comments and blank lines not counted"
assert_contains "$ctl_out" "$(printf 'user\t')" "the main ones too"
rm -f "$LISTS_DIR/mine.list"

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

# Не открылся ни разу — чем мешают (nfqws2-helper -sniprobe): по имени или адрес
printf '#!/bin/sh\nexit 35\n' > "$MOCKBIN/curl"
mkdir -p "${HELPER_BIN%/*}"
printf '#!/bin/sh\necho "$@" > "%s/sni.args"\nprintf "name\\ttcp=ok sni=reset other=ok none=ok case=reset http=-\\n"\n' "$MOCK_DIR" > "$HELPER_BIN"
chmod 0755 "$HELPER_BIN"
ctl domain-check blocked.example
assert_contains "$ctl_out" "$(printf 'B\tname\ttcp=ok sni=reset')" "a site that never opened gets the cause probes"
assert_contains "$(cat "$MOCK_DIR/sni.args")" "-sniprobe blocked.example -ip 203.0.113.7" "on its own address"
rm -f "$MOCK_DIR/sni.args"
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/curl"
ctl domain-check fine.example
assert_not_contains "$ctl_out" "$(printf '\nB\t')" "a site that opens needs no cause"
assert_no_file "$MOCK_DIR/sni.args" "and the probes are not run"
rm -f "$HELPER_BIN"

# Видеосервер YouTube этой сети: redirector …/report_mapping → «=> muc12s10»
# → rr1---sn-h0jelne7.googlevideo.com (подстановка GoodCheck и zapretgui)
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
for a; do case "$a" in *report_mapping*) echo "$a" >> "$MOCK_DIR/rm.calls"; printf '5.18.1.2 => muc12s10 : router: "ae1.muc12"\n'; exit 0 ;; esac; done
exit 0
X
chmod 0755 "$MOCKBIN/curl"
rm -f "$STATE_DIR/ggc_host" "$MOCK_DIR/rm.calls"
ctl domain-check www.youtube.com
assert_contains "$ctl_out" "$(printf 'Y\trr1---sn-h0jelne7.googlevideo.com\tok')" "YouTube: the video server of this network is found and checked"
ctl domain-check m.youtube.com
assert_eq "1" "$(grep -c . "$MOCK_DIR/rm.calls")" "it is remembered, not asked every time"
ctl domain-check example.org
assert_not_contains "$ctl_out" "$(printf '\nY\t')" "not for other sites"

# Место фильтра (nfqws2-helper -ttltrace) — для фейков умного режима этой сети
mkdir -p "${HELPER_BIN%/*}"
printf '#!/bin/sh\necho "$@" > "%s/ttl.args"\nprintf "9\\t3\\tфильтр — на 3-м узле\\n"\n' "$MOCK_DIR" > "$HELPER_BIN"
chmod 0755 "$HELPER_BIN"
echo mobile-1 > "$SMART_NET_FILE"
ctl dpi-distance
assert_contains "$ctl_out" "$(printf '9\t3\t')" "the helper measures hops to the server and to the filter"
assert_contains "$(cat "$MOCK_DIR/ttl.args")" "-blocked $BLOBS_DIR/quic_my_youtube_initial.bin" "with a QUIC Initial of a name blocked by the filter"
assert_eq "mobile-1 9 3" "$(cut -d' ' -f1-3 "$STATE_DIR/dpi_ttl")" "per network"
assert_eq "3" "$(. "$MODDIR/lib/common.sh"; dpi_ttl)" "the fake TTL for this network is the filter's hop"
assert_contains "$(. "$MODDIR/lib/common.sh"; echo "a --lua-desync=$DPI_TTL_VARIANT:strategy=7 b" | ttl_inject)" "repeats=4:ip_ttl=3:ip6_ttl=3:strategy=7" "the smart variant with a fixed TTL takes it"
echo wifi-2 > "$SMART_NET_FILE"
assert_eq "" "$(. "$MODDIR/lib/common.sh"; dpi_ttl)" "not on another network"
rm -f "$HELPER_BIN" "$STATE_DIR/dpi_ttl" "$SMART_NET_FILE"

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
# dpi-detector v5.0.0-alpha.21: переадресация без имени узла (https:///…) —
# заглушка промежуточного устройства; не-HTTP вместо ответа сайта — подмена
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
o=""; for a; do [ "$p" = "-o" ] && o="$a"; p="$a"; done
case "$a" in
  *hostless.example*) : > "$o"; printf '\nREDIRECT_URL:https:///block\n'; exit 47 ;;
  *nothttp.example*) : > "$o"; echo "curl: (56) Received HTTP/0.9 when not allowed: Invalid HTTP header" >&2; exit 56 ;;
esac
exit 0
X
chmod 0755 "$MOCKBIN/curl"
ctl domain-check hostless.example
assert_match "$ctl_out" "R	[123]	fail isp_redir" "a redirect with no host (https:///…) is the ISP's box, not the site"
ctl domain-check nothttp.example
assert_match "$ctl_out" "R	[123]	fail not_http" "an answer that is not HTTP at all is the ISP's box too"

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
fakesvc=$(fake_daemon "$PIDFILE")
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
# Блокировка серверов обхода по IP (geo-ipcheck): без обхода — по правилу
# RETURN, причина — nfqws2-helper -sniprobe, через обход — та же проба без него
section "geo-ipcheck: bypass servers and proxies blocked by IP"
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
ip=""; o=""
for a; do [ "$p" = "-o" ] && o="$a"; [ "$p" = "--resolve" ] && ip="${a##*:}"; p="$a"; done
[ -n "$o" ] && printf 'ok' > "$o"
[ -n "$ip" ] || exit 0
if iptables -w -t mangle -S nfqws_post 2>/dev/null | grep -q "uid-owner 0 -d $ip "; then
  exit "$(cat "$MOCK_DIR/nb.$ip" 2>/dev/null || echo 28)"
fi
exit "$(cat "$MOCK_DIR/via.$ip" 2>/dev/null || echo 0)"
X
# -ask <сервер> -samples <домен>: что сервер отвечает (ask.<сервер>), иначе ничего
printf '#!/bin/sh\nif [ "$1" = -ask ]; then [ -f "$MOCK_DIR/ask.$2" ] && printf "%%s\\t%%s\\n" "$4" "$(cat "$MOCK_DIR/ask.$2")"; exit 0; fi\nfor a; do [ "$p" = -ip ] && ip="$a"; p="$a"; done\nprintf "%%s\\ttcp=x\\n" "$(cat "$MOCK_DIR/cause.$ip" 2>/dev/null || echo tls)"\n' > "$HELPER_BIN"
chmod 0755 "$MOCKBIN/curl" "$HELPER_BIN"
iptables -w -t mangle -N nfqws_post 2>/dev/null
f=$(dns_geo_scan_file); mkdir -p "${f%/*}"
{ printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t2\t2\t0\ttls\n'; printf 'b.example\tfail\t0\t0\t2\t0\t-\tDoT: i/o timeout\n'; printf 'c.example\tok\t30\t1\t2\t0\ttls\n'
  printf '!a.example\t3/3\t0\t198.51.100.1\n!b.example\t0/3\t0\t198.51.100.2\n!c.example\t3/3\t0\t198.51.100.3\n'
  printf '+a.example\t203.0.113.10\t50\n'
  printf '=chatgpt.com\ta.example\n=claude.ai\tc.example\n'
} > "$f"
echo 0 > "$MOCK_DIR/nb.198.51.100.1"
echo addr > "$MOCK_DIR/cause.198.51.100.2"
echo 35 > "$MOCK_DIR/via.198.51.100.3"
rm -f "$IPSET_AUTO"
fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck
assert_rc 0 "$ctl_rc" "the check runs"
r=$(cat "$f.ipcheck")
assert_contains "$r" "198.51.100.1	server	a.example	a.example	ok" "a server open without the bypass is not blocked"
assert_contains "$r" "203.0.113.10	proxy	a.example	chatgpt.com	fail_timeout	tls	ok" "the SNI proxy of a server is checked too, with a site it serves"
assert_contains "$r" "198.51.100.2	server	b.example	b.example	fail_timeout	addr	-	closed" "an address closed entirely: the bypass cannot help"
assert_match "$r" "198.51.100.3	server	c.example	c.example	fail_timeout	tls	fail_[a-z]*	nobypass" "blocked, and the bypass does not help yet"
assert_eq "203.0.113.10" "$(cat "$IPSET_AUTO")" "blocked but not entirely and the bypass helps — into ipset_auto.list; it does not help — not kept (a Cloudflare address would drag thousands of sites through the strategy)"
assert_contains "$(tail -n 8 "$DNS_LOG")" "ipset_auto.list: убраны (обход не помогает) 198.51.100.3" "the DNS log says what was dropped"
l=$(tail -n 8 "$DNS_LOG")
assert_contains "$l" "203.0.113.10 — SNI-прокси a.example (chatgpt.com): без обхода — timeout, причина — tls; в ipset_auto.list, через обход — открывается" "the DNS log says what helped"
assert_contains "$l" "198.51.100.2 — DNS-сервер b.example: адрес закрыт целиком" "and what cannot be helped"
assert_contains "$ctl_out" "обход помогает: 1" "a summary for the caller"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck
assert_rc 0 "$ctl_rc" "a second run runs"
assert_eq "1" "$(grep -c . "$IPSET_AUTO")" "a second run does not duplicate the list"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
echo 198.51.100.3 >> "$IPSET_AUTO"; ctl geo-ipcheck
assert_rc 0 "$ctl_rc" "and a third"
assert_eq "203.0.113.10" "$(cat "$IPSET_AUTO")" "an address left by an earlier version, where the bypass does not help, is dropped too"
assert_contains "$(_startup_args)" "--ipset=$IPSET_AUTO" "nfqws2 gets the list as an IP list of the strategy"
# прокси проверяется тот, что сервер даёт для домена сейчас (-ask), а не самый
# частый: тот мог быть прокси других сайтов (игровой у NullsProxy)
echo 203.0.113.77 > "$MOCK_DIR/ask.a.example"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck
assert_contains "$(cat "$f.ipcheck")" "203.0.113.77	proxy	a.example	chatgpt.com" "the proxy is the address the server gives for that domain now"
rm -f "$MOCK_DIR/ask.a.example" "$IPSET_AUTO"
# игровые серверы — не по HTTPS: на них прокси не проверяется
cp "$f" "$f.keep"; sed -i 's/^=chatgpt.com\ta.example$/=gamea.clashofclans.com\ta.example/' "$f"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck
assert_not_contains "$(cat "$f.ipcheck")" "proxy	a.example" "a server whose only domain is a game server is not probed over HTTPS"
mv -f "$f.keep" "$f"; rm -f "$f.down" "$IPSET_AUTO"
# метка прерванной проверки (старше 15 минут) не мешает следующей
mkdir -p "$STATE_DIR/geo-ipcheck.lock"; touch -d '@'"$(( $(date +%s) - 1200 ))" "$STATE_DIR/geo-ipcheck.lock"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck
assert_rc 0 "$ctl_rc" "a lock left by an interrupted check does not block the next one forever"
mkdir -p "$STATE_DIR/geo-ipcheck.lock"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck
assert_rc 3 "$ctl_rc" "a fresh one still means a check is running"
rmdir "$STATE_DIR/geo-ipcheck.lock"
# Пауза: прокси сервера здесь не открывается и через обход — сервер на паузе
# в этой сети (11.11: wlrus и bezmezhau в одном районе, дома открываются)
echo 35 > "$MOCK_DIR/via.203.0.113.10"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck
assert_rc 0 "$ctl_rc" "a check with a dead proxy runs"
assert_match "$(cat "$f.down" 2>/dev/null)" "^a.example	203.0.113.10	[0-9]*	[0-9]*	1$" "the server whose proxy does not open even through the bypass is paused on this network"
nx=$(cut -f4 "$f.down"); nw=$(date +%s)
assert_ge "$((nx - nw))" 1700 "it is checked again in half an hour"
assert_contains "$(tail -n 6 "$DNS_LOG")" "на паузе в этой сети (прокси не открывается и через обход): a.example" "the DNS log says so"
assert_contains "$(cat "$(dns_geo_off_eff)")" "a.example" "and the server is left out of the choice"
assert_contains "$(dns_state)" "geo_down_a.example=203.0.113.10," "the screen gets the pause"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; fakesvc=$(fake_daemon "$PIDFILE")
ctl geo-ipcheck quick
assert_rc 0 "$ctl_rc" "a quick check before the time is quiet"
assert_no_file "$f.ipquick" "and checks nothing: the paused proxy is not due yet, the others are not in use"
# срок подошёл, прокси снова открывается (вернулись из того района)
awk -F'\t' 'BEGIN { OFS = "\t" } { $4 = 1; print }' "$f.down" > "$f.down.t" && mv "$f.down.t" "$f.down"
echo 0 > "$MOCK_DIR/via.203.0.113.10"
ctl geo-ipcheck quick
assert_contains "$(cut -f1,2 "$f.ipquick" 2>/dev/null)" "203.0.113.10	proxy" "a quick check probes the paused proxy when it is due"
assert_no_file "$f.down" "the proxy opens again — the pause is over"
assert_contains "$(tail -n 6 "$DNS_LOG")" "снова в работе (прокси открывается): a.example" "and the log says the server is back"
rm -f "$f.ipquick"
kill "$fakesvc" 2>/dev/null; wait "$fakesvc" 2>/dev/null; rm -f "$PIDFILE" "$IPSET_AUTO" "$f.ipcheck"

rm -f "$MOCKBIN/ping" "$MOCKBIN/curl"

# ── поделиться файлом ─────────────────────────────────────────────────────────
section "share"
printf '#!/bin/sh\necho "$*" >> "$MOCK_DIR/am.log"; echo "Starting: Intent"\n' > "$MOCKBIN/am"
chmod 0755 "$MOCKBIN/am"; : > "$MOCK_DIR/am.log"
# content: scan_file отвечает ссылкой — как MediaProvider на устройстве
printf '#!/bin/sh\necho "$*" >> "$MOCK_DIR/content.log"\ncase "$*" in *scan_file*) [ -f "$MOCK_DIR/noscan" ] || echo "Result: Bundle[{android.intent.extra.STREAM=content://media/external_primary/file/42}]" ;; esac\n' > "$MOCKBIN/content"
chmod 0755 "$MOCKBIN/content"; : > "$MOCK_DIR/content.log"
# su, не умеющий сменить uid (по умолчанию): am — от root, как раньше
printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/su"; chmod 0755 "$MOCKBIN/su"
EXP_OLD2="${NFQWS_BACKUP_DIR:-}"; export NFQWS_BACKUP_DIR="$SANDBOX/shared"
ctl share file "$CONFFILE"
assert_rc 0 "$ctl_rc" "the config is shared as a file"
assert_eq "$(cat "$CONFFILE")" "$(cat "$SANDBOX/shared/.share/nfqws2.conf" 2>/dev/null)" "a copy goes to shared storage: apps cannot read /data/adb"
assert_contains "$(cat "$MOCK_DIR/content.log")" "--method scan_file --arg $SANDBOX/shared/.share/nfqws2.conf" "MediaStore scans the copy at once"
assert_match "$(cat "$MOCK_DIR/am.log")" "SEND --user 0 -d content://media/external_primary/file/42 -t text/plain" "and the link it answers with is shared, as plain text"
assert_not_contains "$(cat "$MOCK_DIR/am.log")" "file://" "no file:// link: other apps (Telegram, ChatGPT, Quick Share) cannot read it"
assert_contains "$(cat "$LOG_DIR/service.log")" "поделиться: nfqws2.conf — content://media/external_primary/file/42 (scan, от root)" "which link was shared goes to the log"
# Право читать ссылку от root Android не выдаёт («the system cannot issue a
# Uri permission grant») — am запускается от shell (uid 2000)
printf '#!/bin/sh\n[ "$1" = 2000 ] && [ "$2" = -c ] || exit 1\n[ "$3" = "id -u" ] && { echo 2000; exit 0; }\necho "$3" >> "$MOCK_DIR/su.log"; eval "$3"\n' > "$MOCKBIN/su"
: > "$MOCK_DIR/am.log"; : > "$MOCK_DIR/su.log"
ctl share file "$CONFFILE"
assert_rc 0 "$ctl_rc" "shared through shell"
assert_contains "$(cat "$MOCK_DIR/su.log")" "'am' 'start' '-a' 'android.intent.action.SEND'" "am runs as shell: root's Uri grants are dropped by Android"
assert_match "$(cat "$MOCK_DIR/am.log")" "SEND --user 0 -d content://media/external_primary/file/42 -t text/plain .*SUBJECT nfqws2.conf .*-f 0x10000001" "with the same arguments"
assert_contains "$(tail -n 1 "$LOG_DIR/service.log")" "(scan, от shell)" "the log says who shared it"
printf '#!/bin/sh\necho "$*" >> "$MOCK_DIR/am.log"\nif [ -n "$AS_SHELL" ]; then echo "java.lang.SecurityException: UID 2000 does not have permission"; else echo "Starting: Intent"; fi\n' > "$MOCKBIN/am"
sed -i 's|eval "$3"|export AS_SHELL=1; eval "$3"|' "$MOCKBIN/su"; : > "$MOCK_DIR/am.log"
ctl share file "$CONFFILE"
assert_rc 0 "$ctl_rc" "shell refused — tried again as root"
assert_eq "2" "$(grep -c SEND "$MOCK_DIR/am.log")" "twice"
assert_contains "$(cat "$LOG_DIR/service.log")" "am от shell: java.lang.SecurityException" "and the refusal is logged"
printf '#!/bin/sh\necho "$*" >> "$MOCK_DIR/am.log"; echo "Starting: Intent"\n' > "$MOCKBIN/am"
printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/su"
# без ответа scan_file и MediaStore — ссылка DocumentsProvider на файл в общей памяти
touch "$MOCK_DIR/noscan"; : > "$MOCK_DIR/am.log"
mkdir -p "$SANDBOX/sd"
echo "a	b" > "$SANDBOX/sd/learn.tsv"
ctl share-saved "$SANDBOX/sd/learn.tsv"
assert_rc 1 "$ctl_rc" "share-saved takes only files in shared storage"
ctl share-saved /storage/emulated/0/Download/../../../etc/passwd
assert_rc 1 "$ctl_rc" "and no path that climbs out of it"
# запасные пути share_uri: поиск в MediaStore по пути, затем ссылка DocumentsProvider
sed -n '/^share_uri() {/,/^}/p' "$MODDIR/bin/nfqws2-ctl" > "$SANDBOX/share_uri.sh"
printf '#!/bin/sh\ncase "$*" in *query*) echo "Row: 0 _id=7" ;; esac\n' > "$MOCKBIN/content"
uri=$(sh -c '. "$1"; share_uri /storage/emulated/0/Download/nfqws2/learn-wifi.tsv text/plain' _ "$SANDBOX/share_uri.sh")
assert_eq "content://media/external/file/7	query" "$uri" "no answer from scan_file: the file is looked up in MediaStore by its path"
printf '#!/bin/sh\ntrue\n' > "$MOCKBIN/content"
uri=$(sh -c '. "$1"; share_uri /storage/emulated/0/Download/nfqws2/learn-wifi.tsv text/plain' _ "$SANDBOX/share_uri.sh")
assert_eq "content://com.android.externalstorage.documents/document/primary%3ADownload%2Fnfqws2%2Flearn-wifi.tsv	documents" "$uri" "MediaStore silent: a DocumentsProvider link to the same file"
rm -f "$MOCK_DIR/noscan" "$MOCKBIN/content"
if [ -n "$EXP_OLD2" ]; then NFQWS_BACKUP_DIR="$EXP_OLD2"; else unset NFQWS_BACKUP_DIR; fi
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
# генератор отработал с ошибкой и выдал пустой «[]» — рабочий кэш остаётся
# (оригинал, 529c5e2): раньше приложения пропадали до следующей установки
touch "$BIN_DIR/pkglist.jar"
cat > "$MOCKBIN/app_process" <<'AP'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "--out" ] && out="$2"; shift; done
[ -n "$out" ] && printf '[]\n' > "$out"
printf '[]\n'
AP
chmod 0755 "$MOCKBIN/app_process"
ctl list-apps refresh
assert_contains "$ctl_out" "com.example.test" "an empty [] from a failed generator run does not replace the cache"
assert_contains "$(cat "$STATE_DIR/apps_cache.json")" "com.example.test" "the cache file keeps the apps"
cat > "$MOCKBIN/app_process" <<'AP'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "--out" ] && out="$2"; shift; done
j='[{"pkg":"com.new.app","name":"New","icon":"","system":false,"userId":0,"isWork":false}]'
[ -n "$out" ] && printf '%s\n' "$j" > "$out"
printf '%s\n' "$j"
AP
ctl list-apps refresh
assert_contains "$ctl_out" "com.new.app" "a real list from the generator replaces the cache"
assert_eq "2" "$(cat "$STATE_DIR/apps_cache.json.version" 2>/dev/null)" "and records the cache schema version (profiles)"
rm -f "$MOCKBIN/app_process" "$BIN_DIR/pkglist.jar" "$STATE_DIR/apps_cache.json.version"
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
