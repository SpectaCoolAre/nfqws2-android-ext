#!/bin/sh
# Умный режим: сеть для оркестратора, состояние, сброс, обучение (bin/nfqws2-ctl,
# lib/common.sh). Логика самого оркестратора — tests/lua/test_smart.lua: он
# идёт внутри nfqws2 и запускается здесь, если есть настоящий бинарник
# (NFQWS2_TEST_BIN).

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
cp -f "$MODDIR/strategies/smart.conf" "$CONFFILE"
echo smart > "$ACTIVE_FILE"
reload_conf
NFQWS_SYSNET="$SANDBOX/sysnet"; export NFQWS_SYSNET
mkdir -p "$NFQWS_SYSNET/rmnet_data0"
cat > "$MOCKBIN/ip" <<'X'
#!/bin/sh
[ "$1 $2" = "route get" ] || exit 0
[ -n "$MOCK_DEV" ] || { echo "RTNETLINK answers: Network is unreachable" >&2; exit 2; }
echo "1.1.1.1 via 10.0.0.1 dev $MOCK_DEV src 10.0.0.2 uid 0"
X
cat > "$MOCKBIN/cmd" <<'X'
#!/bin/sh
printf 'Wifi is enabled\n'
case "$MOCK_WIFI" in '') printf 'Wifi is not connected\n' ;; *) printf 'Wifi is connected to "%s"\n' "$MOCK_WIFI" ;; esac
X
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/dumpsys"
chmod 0755 "$MOCKBIN/ip" "$MOCKBIN/cmd" "$MOCKBIN/dumpsys"
export MOCK_DEV MOCK_WIFI MOCK_OPERATOR MOCK_OPERATOR_NAME

section "the smart strategy is recognised"
smart_active; assert_rc 0 $? "smart.conf loads the smart orchestrator"

# конфиг прежней раскладки умного режима пересобирается сам, с настройками пользователя
grep -v '^SMART_CONF_VER=' "$MODDIR/strategies/smart.conf" | sed 's/slot=tls_16:/slot=tls:/; s/^LOG_LEVEL=.*/LOG_LEVEL=2/' > "$CONFFILE"
load_conf >/dev/null 2>&1
assert_contains "$(cat "$CONFFILE")" "slot=tls_16:" "an old smart config is rebuilt from the module's smart.conf"
assert_contains "$(cat "$CONFFILE")" "LOG_LEVEL=2" "keeping the user's settings"
assert_contains "$(cat "$SERVICE_LOG" 2>/dev/null)" "конфиг обновлён" "and says so in the log"
# конфиг тестовой сборки с той же версией раскладки, но прежней (ipset_geoproxy)
sed 's/^SMART_CONF_VER=.*/SMART_CONF_VER=6/; s|^ARGS_BLOCK16="|ARGS_BLOCK16="--ipset=$LISTS_DIR/ipset_geoproxy.list |' "$MODDIR/strategies/smart.conf" > "$CONFFILE"
load_conf >/dev/null 2>&1
assert_not_contains "$(cat "$CONFFILE")" "ipset_geoproxy" "a config of the previous layout (2.2.4 test builds) is rebuilt"
before=$(cksum < "$CONFFILE")
load_conf >/dev/null 2>&1
assert_eq "$before" "$(cksum < "$CONFFILE")" "an up-to-date one is left alone"
echo hardcorp74 > "$ACTIVE_FILE"
grep -v '^SMART_CONF_VER=' "$MODDIR/strategies/smart.conf" > "$CONFFILE"
load_conf >/dev/null 2>&1
assert_not_contains "$(cat "$CONFFILE")" "SMART_CONF_VER" "another active strategy is never touched"
echo smart > "$ACTIVE_FILE"
cp -f "$MODDIR/strategies/smart.conf" "$CONFFILE"; load_conf >/dev/null 2>&1
conf_reset; reload_conf
smart_active; assert_rc 1 $? "an ordinary strategy does not"
cp -f "$MODDIR/strategies/smart.conf" "$CONFFILE"; reload_conf

section "the network id: mobile by operator, Wi‑Fi by SSID, none without a route"
MOCK_DEV=rmnet_data0 MOCK_OPERATOR=25001 MOCK_OPERATOR_NAME=MTS
assert_eq "mobile-25001	MTS" "$(smart_net_id)" "mobile data: the operator code and name"
MOCK_OPERATOR="25002,25099"
assert_eq "mobile-25002	MTS" "$(smart_net_id)" "two SIMs and the data SIM is unknown: the first one"
MOCK_OPERATOR_NAME="MTS,Beeline" MOCK_DATA_SUB=3 MOCK_SIMINFO="2:0 3:1"; export MOCK_DATA_SUB MOCK_SIMINFO MOCK_OPERATOR_NAME
assert_eq "mobile-25099	Beeline" "$(smart_net_id)" "two SIMs, mobile data on the second: its operator, not the first one"
MOCK_DATA_SUB=2
assert_eq "mobile-25002	MTS" "$(smart_net_id)" "data switched back to the first SIM: the first operator again"
MOCK_SIMINFO=""
assert_eq "mobile-25002	MTS" "$(smart_net_id)" "the slot of a subscription is remembered (the SIM table is a separate process)"
MOCK_DATA_SUB="" MOCK_SIMINFO="" MOCK_OPERATOR_NAME=MTS; rm -f "$STATE_DIR/sim_slot"
MOCK_OPERATOR=""
assert_eq "mobile	MTS" "$(smart_net_id)" "no operator code — just mobile"
mkdir -p "$NFQWS_SYSNET/wlan0"; echo up > "$NFQWS_SYSNET/wlan0/operstate"
MOCK_DEV=wlan0 MOCK_WIFI=Home
id=$(smart_net_id)
assert_contains "$id" "wifi-" "Wi‑Fi: by SSID"
assert_contains "$id" "	Home" "with the SSID as its label"
MOCK_WIFI=Office
[ "$id" != "$(smart_net_id)" ]; assert_rc 0 $? "another SSID is another network"
MOCK_DEV=""
assert_eq "offline	" "$(smart_net_id)" "no route at all — offline"

section "the module tells the orchestrator where it is"
MOCK_DEV=rmnet_data0 MOCK_OPERATOR=25001 MOCK_WIFI=""
echo down > "$NFQWS_SYSNET/wlan0/operstate"
smart_net_update
assert_eq "mobile-25001" "$(cat "$SMART_NET_FILE")" "state/smart_net holds the id"
assert_contains "$(cat "$SMART_DIR/nets.tsv")" "mobile-25001	MTS" "and the label is kept for the WebUI"
smart_net_update
assert_eq "1" "$(grep -c mobile-25001 "$SMART_DIR/nets.tsv")" "once"
MOCK_DEV=""
smart_net_update
assert_eq "offline" "$(cat "$SMART_NET_FILE")" "offline is written too"
assert_eq "1" "$(grep -c . "$SMART_DIR/nets.tsv")" "but is not a network"

section "a home Wi‑Fi gets no smart profile"
echo up > "$NFQWS_SYSNET/wlan0/operstate"
printf 'Home\n' > "$HOME_FILE"
MOCK_DEV=rmnet_data0; echo down > "$NFQWS_SYSNET/wlan0/operstate"; smart_net_update
echo up > "$NFQWS_SYSNET/wlan0/operstate"; MOCK_DEV=wlan0 MOCK_WIFI=Home HOME_WIFI=1
smart_net_update
assert_eq "mobile-25001" "$(cat "$SMART_NET_FILE")" "added as home beforehand: the last active network stays current"
assert_not_contains "$(cat "$SMART_DIR/nets.tsv")" "	Home" "and no profile is created for it"
printf 'Home' > "$HOME_OVERRIDE_FILE"
smart_net_update
assert_contains "$(cat "$SMART_NET_FILE")" "wifi-" "started by hand at home: the bypass works there, so it learns there"
rm -f "$HOME_OVERRIDE_FILE"
MOCK_DEV=rmnet_data0; echo down > "$NFQWS_SYSNET/wlan0/operstate"; smart_net_update
echo up > "$NFQWS_SYSNET/wlan0/operstate"; MOCK_DEV=wlan0
smart_net_update
assert_eq "mobile-25001" "$(cat "$SMART_NET_FILE")" "a profile made before it became home goes inactive"
( export HOME_WIFI; ctl smart-status; printf '%s' "$ctl_out" > "$SANDBOX/home.json" )
assert_contains "$(cat "$SANDBOX/home.json")" '"label":"Home","home":1' "and the WebUI is told so"
HOME_WIFI=0
smart_net_update
assert_contains "$(cat "$SMART_NET_FILE")" "wifi-" "home pause off: the profile is active again"
assert_eq "1" "$(grep -c '	Home$' "$SMART_DIR/nets.tsv")" "the same one, not a new copy"
HOME_WIFI=1; printf 'Other\n' > "$HOME_FILE"
smart_net_update
assert_contains "$(cat "$SMART_NET_FILE")" "wifi-" "removed from home networks: active too"
rm -f "$HOME_FILE"; HOME_WIFI=0; MOCK_WIFI=""; echo down > "$NFQWS_SYSNET/wlan0/operstate"
MOCK_DEV=rmnet_data0; smart_net_update
grep -v '	Home$' "$SMART_DIR/nets.tsv" > "$SMART_DIR/nets.tmp"; mv -f "$SMART_DIR/nets.tmp" "$SMART_DIR/nets.tsv"
conf_reset; reload_conf
rm -f "$SMART_NET_FILE"; MOCK_DEV=rmnet_data0
smart_net_update
assert_file "$SMART_NET_FILE" "the network is tracked for strategies too (their stats skip offline)"
cp -f "$MODDIR/strategies/smart.conf" "$CONFFILE"; reload_conf

section "smart-status: successes and errors, per network and variant"
printf 'mobile-25001\n' > "$SMART_NET_FILE"
printf 'wifi-1\tHome\n' >> "$SMART_DIR/nets.tsv"
printf '#v4 header\ntls\tyoutube.com\t1\t1:3.0\t\t\t1\ntls\tx.com\t8\t1:1.0,8:2.0\t1:2.0,8:3.0\t1:1999999999\t1\ngoogle\tgooglevideo.com\t1\t1:5.0\t\t\t1\ntls\tnew.example\t1\t\t1:1.0\t\t1\ntls\tdown.example\t3\t\t1:2.0,2:2.0,3:2.0,4:2.0\t0:4999999999\t1\n' > "$SMART_DIR/mobile-25001.tsv"
ctl smart-status
assert_rc 0 "$ctl_rc" "smart-status runs"
printf '%s' "$ctl_out" > "$SANDBOX/st.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$SANDBOX/st.json" 2>/dev/null
assert_rc 0 $? "and prints valid JSON"
assert_contains "$ctl_out" '"active":1' "the smart strategy is active"
assert_contains "$ctl_out" '"id":"mobile-25001","label":"MTS","home":0,"sites":3,"ok":11,"err":14,"current":1' "a network: sites with successes, successes and errors in total"
assert_contains "$ctl_out" '"nodpi":["down.example"]' "a site that is not a DPI problem is listed apart"
assert_not_contains "$ctl_out" '"host":"down.example"' "and not among the sites with errors"
sed -i '1s/^#v4/#v3/' "$SMART_DIR/mobile-25001.tsv"
ctl smart-status
assert_contains "$ctl_out" '"nodpi":[]' "a «not DPI» mark from an older file is not shown (it came from false errors)"
sed -i '1s/^#v3/#v4/' "$SMART_DIR/mobile-25001.tsv"
assert_contains "$ctl_out" '"id":"wifi-1","label":"Home","home":0,"sites":0,"ok":0,"err":0,"current":0' "a network without data shows zeros"
assert_contains "$ctl_out" '{"n":8,"name":"hardcorp74 #1","ok":2,"err":3,"sites":1}' "variants come with names, successes, errors and sites on them"
assert_contains "$ctl_out" '{"n":1,"name":"MartinBacker #1","ok":4,"err":5,"sites":2}' "they add up across sites"
assert_contains "$ctl_out" '"google":[{"n":1,"name":"hardcorp74: Google","ok":5,"err":0,"sites":1}]' "slots are separate"
assert_contains "$ctl_out" '{"host":"x.com","slot":"tls","n":8,"name":"hardcorp74 #1","ok":2,"err":3}' "a site with more errors than successes on its variant is a problem"
assert_contains "$ctl_out" '{"host":"new.example","slot":"tls","n":1,"name":"MartinBacker #1","ok":0,"err":1}' "so is one that never worked"
assert_not_contains "$ctl_out" '"host":"youtube.com"' "a working one is not"
# профили со своими наборами (tls_cf, tls_16…) и подстройки
printf '#m\ttls_16\t101\t7\t1.repeats=6;4.host=ozon.ru\t1000\ntls_16\tsoundcloud.com\t101\t7:2.0,101:6.0\t7:1.0\t\t1\te\ntls_cf\tcf.example\t6\t6:2.0\t\t\t1\te\n' >> "$SMART_DIR/mobile-25001.tsv"
ctl smart-status
printf '%s' "$ctl_out" > "$SANDBOX/st.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$SANDBOX/st.json" 2>/dev/null
assert_rc 0 $? "with tunings it is still valid JSON"
assert_contains "$ctl_out" '"tls_16":[' "a profile with its own set has its own list"
assert_contains "$ctl_out" '{"n":101,"name":"MartinBacker: хостинги (16 КБ) · подстройка: repeats=6, host=ozon.ru","ok":6,"err":0,"sites":1}' "a tuning is named after its base and what is changed"
assert_contains "$ctl_out" '{"n":6,"name":"MartinBacker: Cloudflare","ok":2,"err":0,"sites":1}' "tls_cf takes the names of tls"
assert_contains "$ctl_out" '"id":"mobile-25001","label":"MTS","home":0,"sites":5,' "a tuning line is not a site"
ctl smart-status wifi-1
assert_contains "$ctl_out" '"view":"wifi-1"' "statistics of another network can be asked for"
assert_contains "$ctl_out" '"top":{},"problems":[],"nodpi":[],"acc":{"ok":0,"err":0}' "and an empty one shows nothing"
ctl smart-status
assert_contains "$ctl_out" '"acc":{"ok":21,"err":7}' "accuracy leaves out «not DPI» sites"

section "smart-sites lists the learned sites of a group"
ctl smart-sites mobile-25001 tls
printf '%s' "$ctl_out" > "$SANDBOX/sites.json"
node -e 'const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (!Array.isArray(a)) process.exit(1)' "$SANDBOX/sites.json" 2>/dev/null
assert_rc 0 $? "a JSON array"
assert_contains "$ctl_out" '{"host":"soundcloud.com","slot":"tls_16","n":101,"name":"MartinBacker: хостинги (16 КБ) · подстройка: repeats=6, host=ozon.ru","ok":6,"err":0,"e":1}' "with the variant's name, tunings too"
assert_not_contains "$ctl_out" 'googlevideo.com' "only the asked group"
assert_not_contains "$ctl_out" 'down.example' "without «not DPI» sites"
ctl smart-sites mobile-25001 problems
assert_contains "$ctl_out" '"host":"x.com"' "problems: more errors than successes"
assert_not_contains "$ctl_out" 'youtube.com' "a working site is not a problem"
ctl smart-sites mobile-25001 nodpi
assert_contains "$ctl_out" '"host":"down.example"' "«not DPI» on its own"
ctl smart-sites 'bad;id' all
assert_rc 1 "$ctl_rc" "a bad network id is refused"

section "learned data can be shared and loaded into another network"
ctl smart-export mobile-25001 path
assert_rc 0 "$ctl_rc" "export runs"
exp_file=$(printf '%s' "$ctl_out" | cut -f2)
assert_file "$exp_file" "the file is saved"
assert_eq "" "$(printf '%s' "$ctl_out" | cut -f3)" "with path, no base64 in the output"
printf 'wifi-1\n' > "$SMART_NET_FILE"
printf '#v4 header\n#m\ttls_16\t101\t7\t1.repeats=2\t500\ntls\tyoutube.com\t2\t2:9.0\t\t\t1\te\ntls_16\tmine.example\t101\t101:3.0\t\t\t1\te\n' > "$SMART_DIR/wifi-1.tsv"
ctl smart-import-b64 "$(base64 < "$exp_file" | tr -d '\n')"
assert_rc 0 "$ctl_rc" "import runs"
assert_eq "6" "$ctl_out" "the sites that were not there are added"
w=$(cat "$SMART_DIR/wifi-1.tsv")
assert_contains "$w" "$(printf 'tls\tyoutube.com\t2\t2:9.0')" "a site that was already there keeps its own data"
assert_contains "$w" "$(printf '#m\ttls_16\t102\t7\t1.repeats=6;4.host=ozon.ru')" "a foreign tuning gets its own number"
assert_contains "$w" "$(printf 'tls_16\tsoundcloud.com\t102\t7:2.0,102:6.0\t7:1.0\t\t1\te')" "and the sites on it follow it"
assert_contains "$w" "$(printf 'tls_16\tmine.example\t101')" "the local tuning keeps its number"
assert_not_contains "$w" "0:4999999999" "«not DPI» of the other network is not carried over"
printf 'garbage\n' > "$SANDBOX/garbage"
ctl smart-import-b64 "$(base64 < "$SANDBOX/garbage" | tr -d '\n')"
assert_rc 1 "$ctl_rc" "a file that is not learned data is refused"
printf 'mobile-25001\n' > "$SMART_NET_FILE"

section "background learning opens one site at a time"
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
for a; do u="$a"; done
echo "$u" >> "$MOCK_DIR/curl.urls"
exit 0
X
chmod 0755 "$MOCKBIN/curl"
rm -f "$SMART_LEARN_FILE" "$MOCK_DIR/curl.urls"
ctl smart-learn-once
ctl smart-learn-once
assert_eq "2" "$(grep -c . "$MOCK_DIR/curl.urls" 2>/dev/null)" "one site per call"
assert_contains "$(cat "$SMART_LEARN_FILE")" "n=2" "counted"
assert_contains "$(cat "$SMART_LEARN_FILE")" "ok=2" "with successes"
last=$(sed -n 's/^last=//p' "$SMART_LEARN_FILE")
assert_contains "$(cat "$MODDIR/defaults/smart-learn.list" "$LISTS_DIR/probe_hosts.list" "$LISTS_DIR/user.list" "$LISTS_DIR/auto.list" 2>/dev/null)" "$last" "from the learning pool ($last)"
printf 'offline\n' > "$SMART_NET_FILE"
ctl smart-learn-once
assert_eq "2" "$(grep -c . "$MOCK_DIR/curl.urls" 2>/dev/null)" "nothing without a network"
printf 'mobile-25001\n' > "$SMART_NET_FILE"
ctl smart-status
assert_contains "$ctl_out" '"learn":1,"bg":{"n":"2","ok":"2"' "the screen sees it"
ctl set SMART_LEARN 0
assert_contains "$(cat "$CONFFILE")" 'SMART_LEARN="0"' "it can be turned off"
ctl set SMART_LEARN 1
rm -f "$MOCKBIN/curl"
printf '# slot\thost\tcur\twins\tfails\tflips\tfreeze\tseen\ntls\tz.example\t3\t3:5\t\t0\t0\t1\n' > "$SMART_DIR/mobile-25001.tsv"
ctl smart-status
assert_contains "$ctl_out" '"top":{},"problems":[]' "a file of an old test build is not shown"

section "smart-reset forgets one network or everything"
ctl smart-reset 'bad;id'
assert_rc 1 "$ctl_rc" "a strange id is refused"
ctl smart-reset wifi-1
assert_rc 0 "$ctl_rc" "one network"
assert_not_contains "$(cat "$SMART_DIR/nets.tsv")" "wifi-1" "is gone from the list"
assert_file "$SMART_DIR/mobile-25001.tsv" "others stay"
ctl smart-reset all
assert_no_file "$SMART_DIR/mobile-25001.tsv" "all: every network is forgotten"

section "the old list training is gone"
ctl smart-train start
assert_rc 1 "$ctl_rc" "smart-train is no longer a command"
ctl smart-status
assert_not_contains "$ctl_out" '"train"' "and smart-status has no training state"
assert_contains "$ctl_out" '"paused":0' "it tells whether the service is paused (learning waits for it)"

section "stuck connections are cut so apps reconnect on another variant"
MOCK_DEV=rmnet_data0
svc start
assert_rc 0 "$svc_rc" "the smart strategy starts"
i=0; while [ "$i" -lt 40 ] && [ ! -f "$SK_PIDFILE" ]; do sleep 0.5; i=$((i + 1)); done
assert_file "$SK_PIDFILE" "the helper runs alongside it"
i=0; while [ "$i" -lt 40 ] && ! grep -q nfqws_smartkill "$MOCK_IPT_STORE/iptables/filter/OUTPUT" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
assert_contains "$(cat "$MOCK_IPT_STORE/iptables/filter/OUTPUT" 2>/dev/null)" "-j nfqws_smartkill" "its chain is hooked into OUTPUT"
printf '4 104.244.42.1 40001\n6 2a00:1450:4010:c05::64 40002\nx bad; line\n4 1.2.3.4 notaport\n' > "$SMART_KILL_FILE"
i=0; while [ "$i" -lt 40 ] && ! grep -q 40002 "$MOCK_IPT_STORE/ip6tables/filter/nfqws_smartkill" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
assert_contains "$(cat "$MOCK_IPT_STORE/iptables/filter/nfqws_smartkill" 2>/dev/null)" "-p tcp -d 104.244.42.1 --sport 40001 -j REJECT --reject-with tcp-reset" "an IPv4 connection is cut with a reset"
assert_contains "$(cat "$MOCK_IPT_STORE/ip6tables/filter/nfqws_smartkill" 2>/dev/null)" "-d 2a00:1450:4010:c05::64 --sport 40002" "an IPv6 one too"
assert_not_contains "$(cat "$MOCK_IPT_STORE/iptables/filter/nfqws_smartkill" 2>/dev/null)" "notaport" "garbage lines are skipped"
assert_not_contains "$(cat "$SERVICE_LOG")" "оборвано" "the service log is not flooded with cut connections (they are in the smart mode log)"
svc stop
# наблюдатели сети этого запуска песочнице больше не нужны: иначе netwatch с
# заглушкой ip крутился бы в фоне и мешал соседним наборам тестов
for p in "$WD_PIDFILE" "$WN_PIDFILE"; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
assert_no_file "$SK_PIDFILE" "stopping the service stops the helper"
assert_no_file "$MOCK_IPT_STORE/iptables/filter/nfqws_smartkill" "and removes its chain"
assert_not_contains "$(cat "$MOCK_IPT_STORE/iptables/filter/OUTPUT" 2>/dev/null)" "nfqws_smartkill" "and the hook"

section "the active strategy says whether smart mode is on"
ctl get-strategy
assert_eq "smart" "$ctl_out" "smart mode is the smart strategy (the WebUI reads the mode from it)"

if [ -x "${NFQWS2_TEST_BIN:-}" ]; then
  section "the orchestrator itself (inside nfqws2)"
  H="$SANDBOX/smarthome"; mkdir -p "$H/state" "$H/smart" "$H/logs"
  out=$(cd "$REPO_DIR/lua" && "$NFQWS2_TEST_BIN" --user=root --intercept=0 --lua-init=@zapret-lib.lua --lua-init=@zapret-antidpi.lua \
    --lua-init=@zapret-auto.lua --lua-init=@zapret-smart.lua "--lua-init=SMART_TEST_HOME='$H'" --lua-init=@"$TESTS_DIR/lua/test_smart.lua" 2>&1)
  assert_contains "$out" "PASS" "tests/lua/test_smart.lua passes"
  printf '%s\n' "$out" | grep -E '^   FAIL' || true
fi

harness_finish
