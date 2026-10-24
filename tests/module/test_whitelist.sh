#!/bin/sh
# Белые списки мобильного оператора: проверка сети (wl_probe), пауза обхода с
# причиной @wl, ручной запуск поверх неё, переключатель WL_PAUSE.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common

# curl: «время соединения» по хосту — зарубежные отвечают только при MOCK_WL=normal
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
for a; do u="$a"; done
h=${u#https://}; h=${h%%/*}
case "$MOCK_WL:$h" in
  normal:*) echo 0.042 ;;
  whitelist:ya.ru|whitelist:vk.com|whitelist:www.gosuslugi.ru|whitelist:mail.ru) echo 0.031 ;;
  partial:github.com|partial:ya.ru|partial:vk.com) echo 0.05 ;;
  *) echo 0.000000; exit 28 ;;
esac
X
chmod 0755 "$MOCKBIN/curl"

section "the probe tells white lists from the normal internet"
MOCK_WL=normal; export MOCK_WL
assert_eq normal "$(wl_probe)" "foreign sites connect: the normal internet"
MOCK_WL=whitelist
assert_eq whitelist "$(wl_probe)" "only Russian services connect: white lists"
MOCK_WL=offline
assert_eq offline "$(wl_probe)" "nothing connects: no network, not white lists"
MOCK_WL=partial
assert_eq partial "$(wl_probe)" "one foreign site: not sure, no pause"
assert_eq "" "$(ls "$STATE_DIR" | grep wlprobe)" "it leaves no temporary files"

section "white lists pause the bypass, like a VPN"
NFQWS_SYSNET="$SANDBOX/sysnet"; export NFQWS_SYSNET
mkdir -p "$NFQWS_SYSNET/rmnet_data1"; printf '0x1003\n' > "$NFQWS_SYSNET/rmnet_data1/flags"
printf 'WATCHDOG=0\n' >> "$CONFFILE"
svc start >/dev/null 2>&1
assert_file "$PIDFILE" "the bypass runs"
date +%s > "$WL_FILE"
svc home_check >/dev/null 2>&1
assert_no_file "$PIDFILE" "white lists pause it"
assert_eq "@wl" "$(cat "$HOME_PAUSED_FILE" 2>/dev/null)" "with the white lists as the reason"
assert_contains "$(cat "$SERVICE_LOG")" "белые списки — обход приостановлен" "and say so in the log"
ctl json-status
assert_contains "$ctl_out" '"paused":"@wl"' "the status shows the reason"
svc start >/dev/null 2>&1
assert_file "$PIDFILE" "a manual start overrides the pause"
assert_eq "@wl" "$(cat "$HOME_OVERRIDE_FILE" 2>/dev/null)" "until the white lists end"
svc home_check >/dev/null 2>&1
assert_file "$PIDFILE" "the override holds while they last"
rm -f "$WL_FILE"
svc home_check >/dev/null 2>&1
assert_no_file "$HOME_OVERRIDE_FILE" "their end clears the override"
date +%s > "$WL_FILE"
svc home_check >/dev/null 2>&1
assert_no_file "$PIDFILE" "the next white lists pause again"
rm -f "$WL_FILE"
svc home_check >/dev/null 2>&1
assert_file "$PIDFILE" "their end resumes the bypass"
assert_contains "$(cat "$SERVICE_LOG")" "Белые списки выключены — обход возобновлён" "and says so"

section "the switch"
date +%s > "$WL_FILE"
svc home_check >/dev/null 2>&1
assert_no_file "$PIDFILE" "paused again"
ctl set WL_PAUSE 0
assert_rc 0 "$ctl_rc" "it can be turned off"
assert_no_file "$WL_FILE" "turning it off forgets the white lists"
assert_file "$PIDFILE" "and resumes the bypass"
ctl set WL_PAUSE 1
svc stop >/dev/null 2>&1
for f in "$WL_PIDFILE" "$WD_PIDFILE" "$WN_PIDFILE" "$SK_PIDFILE"; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
unset NFQWS_SYSNET MOCK_WL

harness_finish
