#!/bin/sh
# DNS refresh is fully mocked, even on Android: PATH contains ONLY the sandbox.
# No common.sh/hosts.sh loading, root requirement, Android SDK, or device access.
HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

SANDBOX=$(mktemp -d "${NFQWS_TEST_TMP:-/tmp}/nfqws2-dns-cache.XXXXXX") || exit 1
SANDBOX=$(cd "$SANDBOX" && pwd)
MOCKBIN="$SANDBOX/bin"
MOCK_DIR="$SANDBOX/mock"
mkdir -p "$MOCKBIN" "$MOCK_DIR" "$SANDBOX/module with spaces/bin" \
  "$SANDBOX/dex/bin" "$SANDBOX/empty/bin" "$SANDBOX/fallback"
printf 'mock jar\n' > "$SANDBOX/module with spaces/bin/pkglist.jar"
printf 'mock dex\n' > "$SANDBOX/dex/bin/pkglist.dex"
printf 'mock fallback\n' > "$SANDBOX/fallback/pkglist.jar"
: > "$SANDBOX/empty/bin/pkglist.jar"
# Keep only non-Android host utilities needed by the test and implementation.
for tool in sh tr cat chmod rm grep; do
  tool_path=$(command -v "$tool") || exit 1
  ln -s "$tool_path" "$MOCKBIN/$tool" || exit 1
done

cat > "$MOCKBIN/id" <<'MOCK'
#!/bin/sh
[ "$*" = '-u' ] || exit 90
printf '%s\n' "${MOCK_UID:-0}"
exit "${MOCK_UID_RC:-0}"
MOCK
cat > "$MOCKBIN/timeout-driver" <<'MOCK'
#!/bin/sh
case "$MOCK_TIMER_KIND" in
  timeout) [ "$MOCK_TIMEOUT_OK" = 1 ] || exit 2 ;;
  busybox) [ "$MOCK_BUSYBOX_OK" = 1 ] || exit 2 ;;
  *) exit 90 ;;
esac
[ "$1" = -s ] && [ "$2" = KILL ] || exit 91
seconds=$3
shift 3
if [ "$seconds" = 1 ]; then
  [ "$*" = "sh -c exit 0" ] || exit 92
  exec "$@"
fi
[ "$seconds" = 5 ] || exit 93
printf '%s:%s:%s\n' "$MOCK_TIMER_KIND" "$seconds" "$1" >> "$MOCK_DIR/bounds"
case "$1" in
  app_process) [ "$MOCK_NATIVE_TIMEOUT" = 0 ] || exit "$MOCK_NATIVE_TIMEOUT" ;;
  am) [ "$MOCK_APPS_TIMEOUT" = 0 ] || exit "$MOCK_APPS_TIMEOUT" ;;
  *) exit 94 ;;
esac
exec "$@"
MOCK
cat > "$MOCKBIN/timeout" <<'MOCK'
#!/bin/sh
MOCK_TIMER_KIND=timeout; export MOCK_TIMER_KIND
exec "$MOCKBIN/timeout-driver" "$@"
MOCK
cat > "$MOCKBIN/busybox" <<'MOCK'
#!/bin/sh
[ "$1" = timeout ] || { printf 'busybox:%s\n' "$*" >> "$MOCK_DIR/forbidden"; exit 90; }
shift
MOCK_TIMER_KIND=busybox; export MOCK_TIMER_KIND
exec "$MOCKBIN/timeout-driver" "$@"
MOCK
cat > "$MOCKBIN/app_process" <<'MOCK'
#!/bin/sh
printf 'native\n' >> "$MOCK_DIR/order"
printf '%s\n' "$*" > "$MOCK_DIR/native_args"
printf '%s\n' "${CLASSPATH:-}" > "$MOCK_DIR/classpath"
cat "$MOCK_DIR/native_out"
cat "$MOCK_DIR/native_err" >&2
exit "$MOCK_NATIVE_RC"
MOCK
cat > "$MOCKBIN/am" <<'MOCK'
#!/bin/sh
printf 'apps\n' >> "$MOCK_DIR/order"
printf '%s\n' "$*" > "$MOCK_DIR/am_args"
printf '%s\n' "${CLASSPATH:-}" > "$MOCK_DIR/am_classpath"
cat "$MOCK_DIR/am_out"
cat "$MOCK_DIR/am_err" >&2
exit "$MOCK_AM_RC"
MOCK
for forbidden in cmd ndc service stop start svc settings setenforce killall pkill su; do
  cat > "$MOCKBIN/$forbidden" <<'MOCK'
#!/bin/sh
printf '%s:%s\n' "$0" "$*" >> "$MOCK_DIR/forbidden"
exit 99
MOCK
done
# Change only generated mock scripts, never symlinks to host utilities.
for tool in id timeout-driver timeout busybox app_process am cmd ndc service stop start svc settings setenforce killall pkill su; do
  chmod 0755 "$MOCKBIN/$tool" || exit 1
done
# A non-executable file is not the same as an absent command in every shell.
for absent in app_process am; do
  mkdir -p "$SANDBOX/without-$absent"
  for executable in "$MOCKBIN"/*; do
    name=${executable##*/}
    [ "$name" = "$absent" ] || ln -s "$executable" "$SANDBOX/without-$absent/$name"
  done
done
PATH="$MOCKBIN"; export PATH MOCKBIN MOCK_DIR
. "$REPO_DIR/lib/dns-cache.sh"

# Validate the canonical sandbox before deleting, and never use harness's generic
# cleanup/find implementation (this test intentionally has an isolated PATH).
sandbox_cleanup() {
  case "$SANDBOX" in
    /*/nfqws2-dns-cache.??????)
      if [ -d "$SANDBOX" ] && [ "$(cd "$SANDBOX" && pwd)" = "$SANDBOX" ]; then
        rm -rf -- "$SANDBOX"
      fi ;;
    *) printf 'Refusing unexpected sandbox path\n' >&2; return 1 ;;
  esac
  SANDBOX=''
}

reset_case() {
  PATH="$MOCKBIN"; export PATH
  MODDIR="$SANDBOX/module with spaces"
  BIN_DIR=''
  MOCK_UID=0; MOCK_UID_RC=0
  MOCK_TIMEOUT_OK=1; MOCK_BUSYBOX_OK=1
  MOCK_NATIVE_TIMEOUT=0; MOCK_APPS_TIMEOUT=0
  MOCK_NATIVE_RC=0; MOCK_AM_RC=0
  export MODDIR BIN_DIR MOCK_UID MOCK_UID_RC MOCK_TIMEOUT_OK MOCK_BUSYBOX_OK \
    MOCK_NATIVE_TIMEOUT MOCK_APPS_TIMEOUT MOCK_NATIVE_RC MOCK_AM_RC
  chmod 0755 "$MOCKBIN/timeout" "$MOCKBIN/busybox" "$MOCKBIN/app_process" "$MOCKBIN/am"
  printf 'resolver=ok\nresolver_reason=flushed\n' > "$MOCK_DIR/native_out"
  printf 'Broadcasting: Intent { act=android.net.action.CLEAR_DNS_CACHE }\nBroadcast completed: result=0\n' > "$MOCK_DIR/am_out"
  for log in native_err am_err order bounds forbidden native_args am_args classpath am_classpath; do
    : > "$MOCK_DIR/$log"
  done
}
run_flush() {
  flush_rc=0
  flush_out=$(dns_cache_flush 2> "$MOCK_DIR/stderr") || flush_rc=$?
  assert_eq '' "$(cat "$MOCK_DIR/stderr")" 'public API does not leak diagnostics'
  assert_eq '' "$(cat "$MOCK_DIR/forbidden")" 'no disruptive or guessed command is invoked'
  # Four and only four key=value lines, statuses first, no raw command output.
  line_count=0
  while IFS= read -r output_line; do
    line_count=$((line_count + 1))
    case "$line_count:$output_line" in
      1:resolver=ok|1:resolver=unsupported|1:resolver=failed|1:resolver=none|\
      2:apps=ok|2:apps=unsupported|2:apps=failed|\
      3:resolver_reason=*|4:apps_reason=*) ;;
      *) _fail "unexpected protocol line: $output_line" ;;
    esac
  done <<EOF
$flush_out
EOF
  assert_eq 4 "$line_count" 'public protocol has exactly four lines'
}
expect_status() {
  assert_contains "$flush_out" "resolver=$1
apps=$2" "$3"
}

section 'native first, then exact protected application broadcast'
reset_case
CLASSPATH=parent-classpath; export CLASSPATH
run_flush
assert_rc 0 "$flush_rc" 'successful best-effort refresh returns zero'
expect_status ok ok 'both cache layers acknowledge success'
assert_eq "$(printf 'native\napps')" "$(cat "$MOCK_DIR/order")" 'native runs before apps, exactly once each'
assert_eq 'broadcast --user all -a android.net.action.CLEAR_DNS_CACHE' "$(cat "$MOCK_DIR/am_args")" 'uses net action, all users, no extra options'
assert_eq '/system/bin com.deathwatcher.DnsCache' "$(cat "$MOCK_DIR/native_args")" 'runs only the scoped helper'
assert_eq "$MODDIR/bin/pkglist.jar" "$(cat "$MOCK_DIR/classpath")" 'reuses pkglist.jar and preserves spaces'
assert_eq parent-classpath "$CLASSPATH" 'helper classpath does not escape to caller'
assert_eq parent-classpath "$(cat "$MOCK_DIR/am_classpath")" 'helper classpath does not escape to am'
assert_eq "$(printf 'timeout:5:app_process\ntimeout:5:am')" "$(cat "$MOCK_DIR/bounds")" 'both operations have independent hard deadlines'

section 'optional payload and runtime capabilities'
reset_case
MODDIR="$SANDBOX/missing"
run_flush
expect_status unsupported ok 'missing payload still broadcasts'
assert_contains "$flush_out" 'resolver_reason=helper_missing' 'missing payload has its own diagnosis'
assert_eq apps "$(cat "$MOCK_DIR/order")" 'no native process without a payload'
assert_rc 0 "$flush_rc" 'unsupported is not reported as an execution failure'

reset_case
MODDIR="$SANDBOX/dex"
run_flush
assert_eq "$MODDIR/bin/pkglist.dex" "$(cat "$MOCK_DIR/classpath")" 'supports existing raw dex payload'
reset_case
MODDIR="$SANDBOX/missing"; BIN_DIR="$SANDBOX/fallback"
run_flush
assert_eq "$BIN_DIR/pkglist.jar" "$(cat "$MOCK_DIR/classpath")" 'supports existing BIN_DIR fallback'
reset_case
MODDIR="$SANDBOX/empty"
run_flush
expect_status failed ok 'empty payload fails without preventing apps'
assert_contains "$flush_out" 'resolver_reason=helper_unreadable' 'invalid payload is not unsupported success'

reset_case
PATH="$SANDBOX/without-app_process"
run_flush
expect_status unsupported ok 'missing app_process still broadcasts'
assert_contains "$flush_out" 'resolver_reason=app_process_missing' 'missing Android launcher is explicit'
reset_case
printf 'java.lang.ClassNotFoundException: com.deathwatcher.DnsCache\n' > "$MOCK_DIR/native_err"
: > "$MOCK_DIR/native_out"; MOCK_NATIVE_RC=1
run_flush
expect_status unsupported ok 'older PkgList-only jar is a capability gap'
assert_contains "$flush_out" 'resolver_reason=helper_unavailable' 'missing helper class is distinct from missing jar'

for reason in resolver_api_unavailable method_unavailable framework_unavailable service_unavailable reflection_unavailable network_id_unavailable; do
  reset_case
  printf 'resolver=unsupported\nresolver_reason=%s\n' "$reason" > "$MOCK_DIR/native_out"
  run_flush
  expect_status unsupported ok "native capability gap $reason does not block apps"
  assert_contains "$flush_out" "resolver_reason=$reason" 'helper capability diagnosis is retained'
  assert_rc 0 "$flush_rc" 'capability gap is a non-error'
done
reset_case
printf 'resolver=none\nresolver_reason=no_networks\n' > "$MOCK_DIR/native_out"
run_flush
expect_status none ok 'disconnected device has no native networks, but still broadcasts'
assert_contains "$flush_out" 'resolver_reason=no_networks' 'disconnection is not confused with unsupported API'

section 'native errors never suppress the app notification'
for reason in network_gone permission_denied enumeration_failed flush_failed invalid_network_id; do
  reset_case
  printf 'resolver=failed\nresolver_reason=%s\n' "$reason" > "$MOCK_DIR/native_out"
  MOCK_NATIVE_RC=1
  run_flush
  expect_status failed ok "native $reason still broadcasts"
  assert_contains "$flush_out" "resolver_reason=$reason" 'native failure diagnosis is retained'
  assert_rc 1 "$flush_rc" 'native failure makes the public return nonzero'
  assert_eq "$(printf 'native\napps')" "$(cat "$MOCK_DIR/order")" 'failure does not change ordering'
done
reset_case
MOCK_NATIVE_RC=8
run_flush
expect_status failed ok 'success text with a failing process is not success'
assert_contains "$flush_out" 'resolver_reason=helper_exit' 'nonzero exit is explicit'
reset_case
printf 'SecurityException: Permission denial\n' > "$MOCK_DIR/native_err"
run_flush
expect_status failed ok 'zero-exit native permission error is not hidden'
assert_contains "$flush_out" 'resolver_reason=permission_denied' 'permission output is inspected'
reset_case
printf 'Error: unexpected native failure\n' > "$MOCK_DIR/native_err"
run_flush
expect_status failed ok 'zero-exit native error is not hidden'
reset_case
printf 'resolver=ok\nresolver=unsupported\nresolver_reason=flushed\n' > "$MOCK_DIR/native_out"
run_flush
expect_status failed ok 'ambiguous native status is rejected'
reset_case
printf 'resolver=ok\n' > "$MOCK_DIR/native_out"
run_flush
expect_status failed ok 'incomplete native protocol is rejected'
reset_case
printf 'resolver=failed\nresolver_reason=network_gone\n' > "$MOCK_DIR/native_out"
run_flush
expect_status failed ok 'failure status cannot turn successful via zero exit'
assert_rc 1 "$flush_rc" 'helper failure status always returns nonzero'

section 'bounded execution and graceful timeout capability fallback'
for code in 124 137 143; do
  reset_case
  MOCK_NATIVE_TIMEOUT=$code
  run_flush
  expect_status failed ok "native timeout exit $code still broadcasts"
  assert_contains "$flush_out" 'resolver_reason=timeout' 'native deadline is distinguished'
  assert_eq "$(printf 'timeout:5:app_process\ntimeout:5:am')" "$(cat "$MOCK_DIR/bounds")" 'app deadline is still armed after native timeout'
  assert_rc 1 "$flush_rc" 'native timeout is a failure'
done
reset_case
MOCK_APPS_TIMEOUT=124
run_flush
expect_status ok failed 'app timeout is not successful notification'
assert_contains "$flush_out" 'apps_reason=timeout' 'app deadline is distinguished'
assert_rc 1 "$flush_rc" 'app timeout returns nonzero'
reset_case
chmod 0644 "$MOCKBIN/timeout"
run_flush
expect_status ok ok 'busybox timeout works without standalone timeout'
assert_eq "$(printf 'busybox:5:app_process\nbusybox:5:am')" "$(cat "$MOCK_DIR/bounds")" 'busybox protects both commands'
reset_case
MOCK_TIMEOUT_OK=0
run_flush
expect_status ok ok 'incompatible standalone timeout falls back to busybox'
assert_contains "$(cat "$MOCK_DIR/bounds")" busybox 'probe detects compatible flag handling'
reset_case
MOCK_TIMEOUT_OK=0; MOCK_BUSYBOX_OK=0
run_flush
expect_status unsupported unsupported 'no usable deadline means no unbounded fallback'
assert_contains "$flush_out" 'resolver_reason=timeout_unavailable' 'native bound is required'
assert_contains "$flush_out" 'apps_reason=timeout_unavailable' 'app bound is required'
assert_eq '' "$(cat "$MOCK_DIR/order")" 'neither Android command ran unbounded'
reset_case
chmod 0644 "$MOCKBIN/timeout" "$MOCKBIN/busybox"
run_flush
expect_status unsupported unsupported 'missing timeout commands are handled gracefully'
assert_eq '' "$(cat "$MOCK_DIR/order")" 'missing timers do not execute Android commands'

section 'broadcast acknowledgements, permissions, and exit status'
for message in 'SecurityException: Permission Denial' 'Error: access rejected' 'Exception occurred while executing broadcast' 'Unknown command: broadcast' 'Failure: ActivityManager unavailable'; do
  reset_case
  printf '%s\n' "$message" > "$MOCK_DIR/am_err"
  run_flush
  expect_status ok failed "broadcast error is rejected even with exit zero: $message"
  assert_rc 1 "$flush_rc" 'broadcast diagnostics make the return nonzero'
done
reset_case
MOCK_AM_RC=1
run_flush
expect_status ok failed 'broadcast completion text cannot hide nonzero exit'
assert_contains "$flush_out" 'apps_reason=am_exit' 'failing broadcast exit is explicit'
reset_case
: > "$MOCK_DIR/am_out"
run_flush
expect_status ok failed 'empty zero-exit output is not acknowledged delivery'
assert_contains "$flush_out" 'apps_reason=unconfirmed' 'missing completion is explicit'
reset_case
printf 'Broadcast completed: result=-1\n' > "$MOCK_DIR/am_out"
run_flush
expect_status ok failed 'nonzero broadcast result is not success'
reset_case
printf 'Broadcast completed: result=0, data=""\n' > "$MOCK_DIR/am_out"
run_flush
expect_status ok ok 'standard optional completion data is accepted'
reset_case
PATH="$SANDBOX/without-am"
run_flush
expect_status ok unsupported 'missing am is explicit, without guessed cmd fallback'
assert_contains "$flush_out" 'apps_reason=am_missing' 'missing broadcast command is diagnosed'
reset_case
MOCK_UID=2000
run_flush
expect_status failed failed 'non-root caller does not claim a protected broadcast'
assert_eq '' "$(cat "$MOCK_DIR/order")" 'does not invoke su or Android commands as shell uid'
assert_contains "$flush_out" 'apps_reason=permission_denied' 'root requirement is explicit'
reset_case
MOCK_UID_RC=1
run_flush
expect_status failed failed 'unknown uid is not assumed root'
assert_contains "$flush_out" 'apps_reason=uid_unavailable' 'uid failure is diagnosed'

harness_finish
