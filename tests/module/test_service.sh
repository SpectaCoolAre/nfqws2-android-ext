#!/bin/sh
# Service lifecycle and firewall rule-set tests.
#
# These are the slowest tests in the suite: every iptables call is a process
# spawn, and a full rule set is ~130 rules across two tables. They are kept in
# their own file so the fast suites can be run without them.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
conf_reset

# IPv6 off by default, switched on only in the section that tests it. With it on,
# every firewall_apply/firewall_stop in this file drives both tables, and the
# module applies rules one iptables call at a time — at ~0.3 s per call on
# Windows that is the single largest cost in the whole suite. Only two assertions
# here look at ip6tables at all, and the section that enables it covers them.
printf 'WATCHDOG=0\nIPV6_ENABLED=0\n' >> "$CONFFILE"

# ── start ─────────────────────────────────────────────────────────────────────
section "start: the daemon comes up and the arguments are assembled"

svc start
assert_rc 0 "$svc_rc" "start succeeds with the stub daemon"
assert_file "$CONFDIR/state/nfqws2.pid" "the pidfile is written"
assert_file "$CONFDIR/state/last.args" "the argument file is written"
assert_file "$CONFDIR/state/desired" "the desired-state marker is written"
assert_file "$CONFDIR/state/started_at" "the start timestamp is written"

args=$(cat "$CONFDIR/state/last.args")
assert_contains "$args" "--qnum=300" "the queue number reaches the daemon"
assert_contains "$args" "--user=root" "the run-as user reaches the daemon"
assert_contains "$args" "--debug=@$NFQWS_LOG" "the log path reaches the daemon"
assert_not_contains "$args" "/opt/etc/nfqws2" "no keenetic paths leak into the arguments"
assert_not_contains "$args" "MODE_" "MODE_ references are expanded before launch"

section "start: iptables chains"

assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "nfqws_post chain is created"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_pre" "nfqws_pre chain is created"
# APP_MODE defaults to off, so app_rules() actively removes its chain.
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "no app chain while APP_MODE=off"
assert_file "$MOCK_IPT_STORE/iptables/nat/nfqws_nat" "nfqws_nat chain is created with NAT_FIX=1"

assert_contains "$(ipt_rules nfqws_post)" "-j NFQUEUE --queue-num 300" "outgoing traffic is queued"
assert_contains "$(ipt_rules nfqws_pre)" "-j NFQUEUE --queue-num 300" "incoming traffic is queued"
assert_contains "$(ipt_rules nfqws_pre)" "--tcp-flags syn,ack syn,ack" "SYN/ACK replies are queued"
assert_contains "$(ipt_rules nfqws_post)" "-m connbytes" "connbytes is used when the kernel has it"
assert_not_contains "$(ipt_rules nfqws_post)" "-j nfqws_qout" "no counter chain is used in connbytes mode"
assert_contains "$(ipt_rules nfqws_post)" "-o lo -j RETURN" "loopback is excluded"
assert_contains "$(ipt_rules nfqws_nat nat)" "-j MASQUERADE" "the NAT fix is installed"

post=$(ipt_count nfqws_post)
assert_ge "$post" 10 "the postrouting chain has a substantial rule set ($post rules)"

section "start: the limiter is recorded for the UI"

assert_eq "connbytes" "$(cat "$CONFDIR/state/limiter")" "the limiter state file says connbytes"

# ── stop ──────────────────────────────────────────────────────────────────────
section "stop: everything is torn down"

svc stop
assert_rc 0 "$svc_rc" "stop succeeds"
assert_no_file "$CONFDIR/state/nfqws2.pid" "the pidfile is removed"
assert_no_file "$CONFDIR/state/desired" "the desired-state marker is removed"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "nfqws_post is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_pre" "nfqws_pre is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "nfqws_app is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/nat/nfqws_nat" "nfqws_nat is deleted"

# ── start failure ─────────────────────────────────────────────────────────────
section "start: a daemon that dies at once is reported with the log tail"

# Neither refusal branch in start() was covered before, and the two of them share
# one ending: the reason, then the tail of the startup log — exactly the part
# that used to be copy-pasted into both. This drives the first branch, where the
# daemon exits non-zero.
#
# The service has to be down for it: start() returns 0 without doing anything if
# it is already up, and the section above is where it gets stopped.
#
# The status is asserted as well as the log. service.sh used to end with `exit 0`,
# so every dispatched command reported success no matter what — nfqws2-ctl just
# passes that status along, which made a failed start indistinguishable from a
# good one for anything that checks it.
: > "$SERVICE_LOG"
MOCK_NFQWS_FAIL=3
export MOCK_NFQWS_FAIL
svc start
assert_rc 1 "$svc_rc" "start reports failure through its exit status"
assert_contains "$(cat "$SERVICE_LOG")" "завершился с кодом 3" "the exit code reaches the log"
assert_contains "$(cat "$SERVICE_LOG")" "Последние строки лога" "the log tail is announced"
assert_contains "$(cat "$SERVICE_LOG")" "refusing to start" "and the tail itself is included"
unset MOCK_NFQWS_FAIL
assert_no_file "$CONFDIR/state/nfqws2.pid" "no pidfile is left behind"

section "start: preflight dry-run rejection"
: > "$SERVICE_LOG"
# аргументы прошлого успешного запуска запомнены — проверка при старте их
# пропустила бы; здесь нужен именно неизвестный набор
rm -f "$CONFDIR/state/dryrun.ok"
MOCK_NFQWS_DRY_RUN_FAIL=2
export MOCK_NFQWS_DRY_RUN_FAIL
svc start
assert_rc 1 "$svc_rc" "start reports failure when dry-run rejects parameters"
assert_contains "$(cat "$SERVICE_LOG")" "--dry-run" "the dry-run failure is announced in service.log"
assert_no_file "$CONFDIR/state/nfqws2.pid" "no pidfile on dry-run failure"
unset MOCK_NFQWS_DRY_RUN_FAIL

# A command that succeeds still has to say so — propagating the status must not
# turn everything red.
svc status
assert_rc 0 "$svc_rc" "status still reports success"

# ── connmark_out mode ─────────────────────────────────────────────────────────
section "connmark_out: a kernel without connbytes gets counter chains"

conf_reset
printf 'WATCHDOG=0\nBLOCK_QUIC=1\nIPV6_ENABLED=0\nAPP_MODE=include\n' >> "$CONFFILE"
printf 'com.termux\n' > "$CONFDIR/apps.list"
MOCK_IPT_FEATURES="multiport owner NFQUEUE"
export MOCK_IPT_FEATURES
ipt_reset

svc firewall_apply
assert_rc 0 "$svc_rc" "firewall_apply succeeds without connbytes"

assert_eq "connmark_out" "$(cat "$CONFDIR/state/limiter")" "the limiter state file says connmark_out"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_qout" "the outgoing counter chain exists"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_qin" "the incoming counter chain exists"
assert_contains "$(ipt_rules nfqws_post)" "-j nfqws_qout" "outgoing traffic goes through the counter chain"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "an app chain appears once APP_MODE is set"
assert_contains "$(ipt_rules nfqws_app)" "--uid-owner 10201" "the resolved UID is matched by owner"
assert_contains "$(ipt_rules nfqws_app)" "--set-xmark 0x10000000/0x10000000" "include mode marks matching traffic"
assert_contains "$(ipt_rules nfqws_post)" "! --mark 0x10000000/0x10000000 -j RETURN" "unmarked traffic is skipped in include mode"
assert_contains "$(ipt_rules nfqws_pre)" "-j nfqws_qin" "incoming traffic goes through the counter chain"

# The counter chain walks PKT_LIMIT_OUT down to zero and then queues.
qout=$(ipt_rules nfqws_qout)
assert_contains "$qout" "--set-xmark" "the counter chain increments the connmark counter"
assert_contains "$qout" "-j NFQUEUE --queue-num 300" "the counter chain ends in NFQUEUE"
assert_contains "$qout" "/0x0f000000" "the outgoing counter uses its own mark bits"
assert_eq "15" "$(printf '%s\n' "$qout" | grep -c -- '--set-xmark')" "PKT_LIMIT_OUT=15 yields 15 counter steps"
qin=$(ipt_rules nfqws_qin)
assert_contains "$qin" "/0x000f0000" "the incoming counter uses disjoint mark bits"

section "connmark_out: BLOCK_QUIC drops UDP/443"

assert_contains "$(ipt_rules nfqws_post)" "-p udp --dport 443 -j DROP" "QUIC is blocked in the post chain"

section "IPv6 disabled"

assert_no_file "$MOCK_IPT_STORE/ip6tables/mangle/nfqws_post" "no ip6tables chain is created"

# ── firewall_ok ───────────────────────────────────────────────────────────────
section "firewall_ok"

firewall_ok
assert_rc 0 $? "firewall_ok sees the installed rules"

svc firewall_stop >/dev/null 2>&1
firewall_ok
assert_rc 1 $? "firewall_ok reports missing rules after firewall_stop"

section "IPv6 enabled builds both tables"

conf_reset
printf 'WATCHDOG=0\nIPV6_ENABLED=1\n' >> "$CONFFILE"
MOCK_IPT_FEATURES="connbytes multiport owner NFQUEUE"
export MOCK_IPT_FEATURES
ipt_reset

svc firewall_apply
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "the IPv4 chain exists"
assert_file "$MOCK_IPT_STORE/ip6tables/mangle/nfqws_post" "the IPv6 chain exists"
svc firewall_stop >/dev/null 2>&1

section "firewall_start reports a failure in either half"

# firewall_start() runs the IPv4 and IPv6 halves in sequence and used to return the
# status of the last one. firewall_ip6tables() returns 0 unconditionally when
# IPV6_ENABLED=0, so an IPv4 failure was reported as success.
#
# The pin matters twice over: the section above turns IPv6 on, and with it every
# failing call would be made twice — the mock still has to be started to fail.
printf 'IPV6_ENABLED=0\n' >> "$CONFFILE"
MOCK_IPT_FAIL=1
export MOCK_IPT_FAIL
svc firewall_apply
assert_rc 1 "$svc_rc" "firewall_apply fails when the rules cannot be installed"
unset MOCK_IPT_FAIL

section "start: a firewall that does not install is a failed start"

# start() ignored firewall_start() entirely, so a kernel where the rules did not
# install gave a running daemon and a desired-state marker with nothing
# intercepting traffic — visible from outside as a successful start. The daemon is
# rolled back now, so the failure does not leave a half-applied state either.
: > "$SERVICE_LOG"
MOCK_IPT_FAIL=1
export MOCK_IPT_FAIL
svc start
assert_rc 1 "$svc_rc" "start fails when the rules cannot be installed"
assert_contains "$(cat "$SERVICE_LOG")" "не применились" "and says why"
assert_no_file "$CONFDIR/state/desired" "the service is not marked as desired"
assert_no_file "$CONFDIR/state/nfqws2.pid" "and the daemon is rolled back"
unset MOCK_IPT_FAIL

section "iptables-restore: one batch gives the same rules as one call per rule"

# Слепок всех цепочек обеих команд и таблиц
ipt_snapshot() {
  (cd "$MOCK_IPT_STORE" && find . -type f | sort | while IFS= read -r f; do echo "== $f"; cat "$f"; done)
}
conf_reset
printf 'WATCHDOG=0\nIPV6_ENABLED=1\nNAT_FIX=1\nBLOCK_QUIC=1\nAPP_MODE=include\nENABLE_HOTSPOT=1\n' >> "$CONFFILE"
printf 'com.termux\n' > "$CONFDIR/apps.list"
load_conf >/dev/null 2>&1
unset MOCK_IPT_FEATURES
for feat in "" "multiport owner connmark CONNMARK NFQUEUE MASQUERADE"; do
  MOCK_IPT_FEATURES="$feat"; [ -n "$feat" ] && export MOCK_IPT_FEATURES || unset MOCK_IPT_FEATURES
  label=${feat:+connmark_out}; label=${label:-connbytes}
  ipt_reset; rm -f "$CONFDIR/state/limiter" "$CONFDIR/state/app_uids"
  MOCK_IPT_RESTORE_FAIL=1; export MOCK_IPT_RESTORE_FAIL
  firewall_start >/dev/null 2>&1
  one=$(ipt_snapshot); lim1=$(cat "$CONFDIR/state/limiter" 2>/dev/null); uid1=$(cat "$CONFDIR/state/app_uids" 2>/dev/null)
  ipt_reset; rm -f "$CONFDIR/state/limiter" "$CONFDIR/state/app_uids"
  unset MOCK_IPT_RESTORE_FAIL
  firewall_start >/dev/null 2>&1
  assert_rc 0 $? "$label: the batch applies"
  batch=$(ipt_snapshot)
  assert_eq "$one" "$batch" "$label: same chains and rules as without iptables-restore"
  assert_contains "$batch" "MASQUERADE" "$label: NAT_FIX is part of the batch"
  assert_eq "$lim1" "$(cat "$CONFDIR/state/limiter" 2>/dev/null)" "$label: the limiter is still recorded for the UI"
  assert_eq "$uid1" "$(cat "$CONFDIR/state/app_uids" 2>/dev/null)" "$label: and the app UIDs"
done
unset MOCK_IPT_FEATURES
firewall_stop >/dev/null 2>&1

section "QUIC to Meta is rejected at once"
conf_reset
load_conf >/dev/null 2>&1
ipt_reset
firewall_start >/dev/null 2>&1
snap=$(ipt_snapshot)
assert_contains "$snap" "-p udp --dport 443 -d 157.240.0.0/16,31.13.24.0/21," "on by default: QUIC to Meta gets an ICMP reject, all nets in one call"
assert_contains "$snap" "-j REJECT --reject-with icmp-port-unreachable" "with a port-unreachable reject"
assert_contains "$snap" "2a03:2880::/32 -j REJECT --reject-with icmp6-port-unreachable" "and over IPv6"
assert_eq "1" "$(grep -c nfqws_mquic "$MOCK_IPT_STORE/iptables/filter/OUTPUT" 2>/dev/null)" "for the phone's own traffic"
assert_eq "1" "$(grep -c nfqws_mquic "$MOCK_IPT_STORE/iptables/filter/FORWARD" 2>/dev/null)" "and for hotspot clients"
firewall_stop >/dev/null 2>&1
assert_not_contains "$(ipt_snapshot)" "nfqws_mquic" "stopping removes the rules"
printf 'META_QUIC_REJECT=0\n' >> "$CONFFILE"
load_conf >/dev/null 2>&1
ipt_reset
firewall_start >/dev/null 2>&1
assert_not_contains "$(ipt_snapshot)" "nfqws_mquic" "off: no reject rules"
firewall_stop >/dev/null 2>&1
conf_reset
load_conf >/dev/null 2>&1

section "DoT/DoH blocking bypass queues port 853"
ipt_reset
firewall_start >/dev/null 2>&1
assert_not_contains "$(ipt_snapshot)" "853" "off: port 853 is not queued"
firewall_stop >/dev/null 2>&1
printf 'DOH_BYPASS=1\n' >> "$CONFFILE"
load_conf >/dev/null 2>&1
ipt_reset
firewall_start >/dev/null 2>&1
assert_contains "$(ipt_snapshot)" "853" "on: DoT traffic goes to the queue"

section "start skips a dry-run the same arguments already passed"
conf_reset
printf 'WATCHDOG=0\n' >> "$CONFFILE"   # без наблюдателей: они пережили бы секцию
load_conf >/dev/null 2>&1
svc stop >/dev/null 2>&1
rm -f "$CONFDIR/state/dryrun.ok"
svc start >/dev/null 2>&1
assert_file "$CONFDIR/state/dryrun.ok" "a passed dry-run is remembered"
svc stop >/dev/null 2>&1
MOCK_NFQWS_DRY_RUN_FAIL=2; export MOCK_NFQWS_DRY_RUN_FAIL
svc start >/dev/null 2>&1
assert_rc 0 "$svc_rc" "the same arguments start without a second dry-run"
unset MOCK_NFQWS_DRY_RUN_FAIL
svc stop >/dev/null 2>&1
printf 'BLOCK_QUIC=1\n' >> "$CONFFILE"
load_conf >/dev/null 2>&1
MOCK_NFQWS_DRY_RUN_FAIL=2; export MOCK_NFQWS_DRY_RUN_FAIL
svc start >/dev/null 2>&1
assert_rc 1 "$svc_rc" "changed arguments are checked again"
unset MOCK_NFQWS_DRY_RUN_FAIL
conf_reset
load_conf >/dev/null 2>&1

section "stopping the rules: one save/restore per table"
ipt_reset
firewall_start >/dev/null 2>&1
iptables -w -t nat -N nfqws_dns 2>/dev/null; iptables -w -t nat -A OUTPUT -j nfqws_dns
firewall_stop >/dev/null 2>&1
snap=$(ipt_snapshot)
assert_not_contains "$snap" "nfqws_post" "the bypass chains are gone"
assert_not_contains "$snap" "nfqws_nat" "NAT fix included"
assert_contains "$(iptables -w -t nat -S OUTPUT)" "-j nfqws_dns" "the DNS interception is left alone"
firewall_ok; assert_rc 1 $? "firewall_ok sees no rules"
iptables -w -t nat -D OUTPUT -j nfqws_dns; iptables -w -t nat -X nfqws_dns
ipt_reset
firewall_start >/dev/null 2>&1
MOCK_IPT_SAVE_FAIL=1; export MOCK_IPT_SAVE_FAIL
firewall_stop >/dev/null 2>&1
unset MOCK_IPT_SAVE_FAIL
assert_not_contains "$(ipt_snapshot)" "nfqws_post" "without iptables-save the rule-by-rule path still clears everything"

section "call bypass queues the call ports"
conf_reset
load_conf >/dev/null 2>&1
ipt_reset
firewall_start >/dev/null 2>&1
assert_not_contains "$(ipt_snapshot)" "3478:3482" "off: the usual UDP ports"
firewall_stop >/dev/null 2>&1
printf 'CALLS_BYPASS=1\n' >> "$CONFFILE"
load_conf >/dev/null 2>&1
ipt_reset
firewall_start >/dev/null 2>&1
snap=$(ipt_snapshot)
assert_contains "$snap" "590:1400" "on: Telegram relay ports are queued"
assert_contains "$snap" "3478:3482" "and the WhatsApp ones up to 3482"
firewall_stop >/dev/null 2>&1

section "watchdog and netwatch helpers"

# Both are started through one shared helper now, and the helper's return value
# carries meaning: 0 means "I just started it", 1 means "nothing to do". That sign
# is what keeps ensure_watchdog starting netwatch only at the moment it starts the
# watchdog. A refactor of a load-bearing spawn is exactly where a silent change
# would hide, so the decisions are pinned here.
# Помощник поднимается отсоединённым процессом, поэтому его pidfile появляется
# не мгновенно. Ждём появления, иначе проверка гоняет наперегонки с запуском.
wait_for_file() { # <file> [секунды]
  _i=0
  while [ "$_i" -lt "${2:-5}" ]; do
    [ -f "$1" ] && return 0
    sleep 1
    _i=$((_i + 1))
  done
  return 1
}

printf 'IPV6_ENABLED=0\nWATCHDOG=0\n' >> "$CONFFILE"
svc stop >/dev/null 2>&1
svc start >/dev/null 2>&1
assert_no_file "$WD_PIDFILE" "with WATCHDOG=0 no watchdog is spawned"
assert_no_file "$WN_PIDFILE" "and no netwatch either"

# start() returns early when the service is already up, so the helpers are only
# reached from a genuinely stopped state.
svc stop >/dev/null 2>&1
printf 'WATCHDOG=1\n' >> "$CONFFILE"
svc start >/dev/null 2>&1
wait_for_file "$WD_PIDFILE" 8
assert_file "$WD_PIDFILE" "with WATCHDOG=1 the watchdog is spawned"
# The sandbox has no `ip`, so the netwatch precondition fails and it must stay down.
assert_no_file "$WN_PIDFILE" "netwatch stays down while ip is missing"

# Kill the daemon but leave the watchdog alive: the next start must reuse the
# running watchdog rather than spawn a second one. That guard is only reachable
# with the service down and the watchdog up — the state after a daemon crash.
wd=$(cat "$WD_PIDFILE" 2>/dev/null)
kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
svc start >/dev/null 2>&1
assert_eq "$wd" "$(cat "$WD_PIDFILE" 2>/dev/null)" "a running watchdog is not spawned twice"

kill "$wd" 2>/dev/null
rm -f "$WD_PIDFILE"

# С ip netwatch обязан подниматься вместе с watchdog. В v2.1.0 объявление
# ensure_netwatch затёрла правка соседнего кода, и netwatch не запускался
# вовсе: смену сети и VPN служба замечала только через watchdog, за 20–60 с.
# Песочница без ip этого не видела — здесь ip подставлен.
: > "$MOCK_DIR/ipmon"
cat > "$MOCKBIN/ip" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "monitor "*) exec tail -n 0 -f "$MOCK_DIR/ipmon" ;;
  "route get") echo "1.1.1.1 via 10.0.0.1 dev wlan0 src 10.0.0.2 uid 0" ;;
esac
exit 0
EOF
chmod 0755 "$MOCKBIN/ip"
out=$(sh "$MODDIR/service.sh" status 2>&1)
assert_not_contains "$out" "not found" "service.sh loads without «command not found» (a mangled function line would show here)"
svc stop >/dev/null 2>&1
svc start >/dev/null 2>&1
wait_for_file "$WN_PIDFILE" 8
assert_file "$WN_PIDFILE" "with ip present netwatch is spawned alongside the watchdog"

# Событие ip monitor будит netwatch сразу — без опроса раз в секунду
sleep 1
echo "2: wlan0: <BROADCAST,MULTICAST,UP> state UP" >> "$MOCK_DIR/ipmon"
i=0; while [ "$i" -lt 8 ] && ! grep -q "netwatch: сеть изменилась" "$SERVICE_LOG" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
assert_contains "$(cat "$SERVICE_LOG")" "netwatch: сеть изменилась" "a network event is acted on within seconds"
assert_rc 0 "$([ "$i" -le 6 ] && echo 0 || echo 1)" "about a second after the burst ends ($((i * 5 / 10)) s)"
# Спит в wait: никакого цикла с sleep 1 в фоне
nw=$(cat "$WN_PIDFILE" 2>/dev/null)
kids=$(ps -o pid= -o comm= --ppid "$nw" 2>/dev/null | grep -c " sleep$")
assert_eq 1 "$kids" "netwatch idles on one long sleep, not a once-a-second poll"
kill "$nw" "$(cat "$WD_PIDFILE" 2>/dev/null)" 2>/dev/null
sleep 0.5
assert_eq "" "$(pgrep -f "tail -n 0 -f $MOCK_DIR/ipmon" 2>/dev/null)" "a stopped netwatch takes ip monitor with it"
assert_no_file "$STATE_DIR/netwatch.fifo" "and removes its FIFO"
rm -f "$MOCKBIN/ip" "$WN_PIDFILE" "$WD_PIDFILE"

# ── pause while a VPN is on ──────────────────────────────────────────────────
section "VPN pause"
NFQWS_SYSNET="$SANDBOX/sysnet"; export NFQWS_SYSNET
mkdir -p "$NFQWS_SYSNET/rmnet_data1"; printf '0x1003\n' > "$NFQWS_SYSNET/rmnet_data1/flags"
svc stop >/dev/null 2>&1
printf 'VPN_PAUSE=1\nWATCHDOG=0\n' >> "$CONFFILE"
svc start >/dev/null 2>&1
assert_file "$PIDFILE" "without a VPN the bypass runs"
mkdir -p "$NFQWS_SYSNET/tun0"; printf '0x1091\n' > "$NFQWS_SYSNET/tun0/flags"
svc home_check >/dev/null 2>&1
assert_no_file "$PIDFILE" "a VPN coming up pauses the bypass"
assert_eq "@vpn" "$(cat "$HOME_PAUSED_FILE" 2>/dev/null)" "and the pause is marked as VPN"
svc start >/dev/null 2>&1
assert_file "$PIDFILE" "a manual start overrides the VPN pause"
assert_eq "@vpn" "$(cat "$HOME_OVERRIDE_FILE" 2>/dev/null)" "until the VPN goes away"
svc home_check >/dev/null 2>&1
assert_file "$PIDFILE" "the override holds while the VPN is on"
printf '0x1090\n' > "$NFQWS_SYSNET/tun0/flags"
svc home_check >/dev/null 2>&1
assert_no_file "$HOME_OVERRIDE_FILE" "a VPN going down clears the override"
printf '0x1091\n' > "$NFQWS_SYSNET/tun0/flags"
svc home_check >/dev/null 2>&1
assert_no_file "$PIDFILE" "the next VPN pauses again"
rm -rf "$NFQWS_SYSNET/tun0"
svc home_check >/dev/null 2>&1
assert_file "$PIDFILE" "the VPN going away resumes the bypass"
assert_no_file "$HOME_PAUSED_FILE" "and clears the pause"
svc stop >/dev/null 2>&1
conf_reset
unset NFQWS_SYSNET

# ── boot-completed.sh lifecycle hook ──────────────────────────────────────────
section "boot-completed.sh lifecycle hook"

assert_file "$MODDIR/boot-completed.sh" "boot-completed.sh exists in sandbox"
svc stop >/dev/null 2>&1

# Хук ждёт, пока service.sh закончит загрузочный запуск (метка boot_done)
: > "$CONFDIR/state/boot_done"

# На паузе в домашнем Wi‑Fi хук службу не поднимает
printf 'AUTOSTART=1\n' >> "$CONFFILE"
printf 'Home' > "$HOME_PAUSED_FILE"
sh "$MODDIR/boot-completed.sh" >/dev/null 2>&1
assert_no_file "$PIDFILE" "boot-completed hook leaves a home pause alone"
assert_no_file "$HOME_OVERRIDE_FILE" "and does not mark the start as manual"
rm -f "$HOME_PAUSED_FILE"

# When AUTOSTART=1 and service is down, boot-completed hook revives it
sh "$MODDIR/boot-completed.sh" >/dev/null 2>&1
assert_file "$PIDFILE" "boot-completed hook starts service when AUTOSTART=1"

# When already running, running boot-completed hook maintains service state
sh "$MODDIR/boot-completed.sh" >/dev/null 2>&1
assert_file "$PIDFILE" "boot-completed hook maintains running service"

svc stop >/dev/null 2>&1

# ── protect_process ───────────────────────────────────────────────────────────
section "protect_process"

protect_process $$
assert_rc 0 $? "protect_process succeeds on valid pid"
protect_process ""
assert_rc 0 $? "protect_process handles empty pid gracefully"
protect_process "99999999"
assert_rc 0 $? "protect_process handles non-existent pid gracefully"

harness_finish
