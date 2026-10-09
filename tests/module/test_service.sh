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

harness_finish
