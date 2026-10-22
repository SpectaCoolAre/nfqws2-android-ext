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
conf_reset; reload_conf
smart_active; assert_rc 1 $? "an ordinary strategy does not"
cp -f "$MODDIR/strategies/smart.conf" "$CONFFILE"; reload_conf

section "the network id: mobile by operator, Wi‑Fi by SSID, none without a route"
MOCK_DEV=rmnet_data0 MOCK_OPERATOR=25001 MOCK_OPERATOR_NAME=MTS
assert_eq "mobile-25001	MTS" "$(smart_net_id)" "mobile data: the operator code and name"
MOCK_OPERATOR="25002,25099"
assert_eq "mobile-25002	MTS" "$(smart_net_id)" "the first SIM's operator when there are two"
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
conf_reset; reload_conf
rm -f "$SMART_NET_FILE"; MOCK_DEV=rmnet_data0
smart_net_update
assert_no_file "$SMART_NET_FILE" "nothing is done for other strategies"
cp -f "$MODDIR/strategies/smart.conf" "$CONFFILE"; reload_conf

section "smart-status: successes and errors, per network and variant"
printf 'mobile-25001\n' > "$SMART_NET_FILE"
printf 'wifi-1\tHome\n' >> "$SMART_DIR/nets.tsv"
printf '#v2 header\ntls\tyoutube.com\t1\t1:3.0\t\t\t1\ntls\tx.com\t8\t1:1.0,8:2.0\t1:2.0,8:3.0\t1:1999999999\t1\ngoogle\tgooglevideo.com\t1\t1:5.0\t\t\t1\ntls\tnew.example\t1\t\t1:1.0\t\t1\ntls\tdown.example\t3\t\t1:2.0,2:2.0,3:2.0,4:2.0\t0:4999999999\t1\n' > "$SMART_DIR/mobile-25001.tsv"
ctl smart-status
assert_rc 0 "$ctl_rc" "smart-status runs"
printf '%s' "$ctl_out" > "$SANDBOX/st.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$SANDBOX/st.json" 2>/dev/null
assert_rc 0 $? "and prints valid JSON"
assert_contains "$ctl_out" '"active":1' "the smart strategy is active"
assert_contains "$ctl_out" '"id":"mobile-25001","label":"MTS","sites":3,"ok":11,"err":14,"current":1' "a network: sites with successes, successes and errors in total"
assert_contains "$ctl_out" '"nodpi":["down.example"]' "a site that is not a DPI problem is listed apart"
assert_not_contains "$ctl_out" '"host":"down.example"' "and not among the sites with errors"
assert_contains "$ctl_out" '"id":"wifi-1","label":"Home","sites":0,"ok":0,"err":0,"current":0' "a network without data shows zeros"
assert_contains "$ctl_out" '{"n":8,"name":"hardcorp74 #1","ok":2,"err":3,"sites":1}' "variants come with names, successes, errors and sites on them"
assert_contains "$ctl_out" '{"n":1,"name":"MartinBacker #1","ok":4,"err":5,"sites":2}' "they add up across sites"
assert_contains "$ctl_out" '"google":[{"n":1,"name":"hardcorp74: Google","ok":5,"err":0,"sites":1}]' "slots are separate"
assert_contains "$ctl_out" '{"host":"x.com","slot":"tls","n":8,"name":"hardcorp74 #1","ok":2,"err":3}' "a site with more errors than successes on its variant is a problem"
assert_contains "$ctl_out" '{"host":"new.example","slot":"tls","n":1,"name":"MartinBacker #1","ok":0,"err":1}' "so is one that never worked"
assert_not_contains "$ctl_out" '"host":"youtube.com"' "a working one is not"
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

section "training needs the running smart strategy"
ctl smart-train start
assert_rc 1 "$ctl_rc" "not without the service running"
ctl smart-train stop
assert_rc 0 "$ctl_rc" "stop is always fine"
assert_contains "$(cat "$SMART_TRAIN_FILE")" "state=stopped" "and says so"
assert_no_file "$STATE_DIR/smart_training" "the fast-switching mark is removed"

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
i=0; while [ "$i" -lt 20 ] && ! grep -q "оборвано застрявших" "$SERVICE_LOG" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
assert_contains "$(cat "$MOCK_IPT_STORE/iptables/filter/nfqws_smartkill" 2>/dev/null)" "-p tcp -d 104.244.42.1 --sport 40001 -j REJECT --reject-with tcp-reset" "an IPv4 connection is cut with a reset"
assert_contains "$(cat "$MOCK_IPT_STORE/ip6tables/filter/nfqws_smartkill" 2>/dev/null)" "-d 2a00:1450:4010:c05::64 --sport 40002" "an IPv6 one too"
assert_not_contains "$(cat "$MOCK_IPT_STORE/iptables/filter/nfqws_smartkill" 2>/dev/null)" "notaport" "garbage lines are skipped"
assert_contains "$(cat "$SERVICE_LOG")" "оборвано застрявших соединений — 2" "the log says how many"
svc stop
# наблюдатели сети этого запуска песочнице больше не нужны: иначе netwatch с
# заглушкой ip крутился бы в фоне и мешал соседним наборам тестов
for p in "$WD_PIDFILE" "$WN_PIDFILE"; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
assert_no_file "$SK_PIDFILE" "stopping the service stops the helper"
assert_no_file "$MOCK_IPT_STORE/iptables/filter/nfqws_smartkill" "and removes its chain"
assert_not_contains "$(cat "$MOCK_IPT_STORE/iptables/filter/OUTPUT" 2>/dev/null)" "nfqws_smartkill" "and the hook"

section "json-status says whether smart mode is on"
ctl json-status
assert_contains "$ctl_out" '"smart":1' "on"

if [ -x "${NFQWS2_TEST_BIN:-}" ]; then
  section "the orchestrator itself (inside nfqws2)"
  H="$SANDBOX/smarthome"; mkdir -p "$H/state" "$H/smart"
  out=$(cd "$REPO_DIR/lua" && "$NFQWS2_TEST_BIN" --user=root --intercept=0 --lua-init=@zapret-lib.lua --lua-init=@zapret-antidpi.lua \
    --lua-init=@zapret-auto.lua --lua-init=@zapret-smart.lua "--lua-init=SMART_TEST_HOME='$H'" --lua-init=@"$TESTS_DIR/lua/test_smart.lua" 2>&1)
  assert_contains "$out" "PASS" "tests/lua/test_smart.lua passes"
  printf '%s\n' "$out" | grep -E '^   FAIL' || true
fi

harness_finish
