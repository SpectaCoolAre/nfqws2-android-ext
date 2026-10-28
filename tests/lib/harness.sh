# Regression-test harness for the nfqws2-android module.
#
# POSIX sh — the suite is meant to run under dash (closest to Android's sh) and
# under bash. Test files start with:
#
#     HERE=$(cd "$(dirname "$0")" && pwd)
#     TESTS_DIR=$(cd "$HERE/.." && pwd)
#     REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
#     . "$TESTS_DIR/lib/harness.sh"
#
# and finish with `harness_summary`.

: "${REPO_DIR:?REPO_DIR must be set before sourcing harness.sh}"
: "${TESTS_DIR:?TESTS_DIR must be set before sourcing harness.sh}"

PASS=0
FAIL=0
FAILURES=""
SECTION=""

section() { SECTION="$1"; printf '\n== %s\n' "$1"; }

_ok()   { PASS=$((PASS + 1)); printf '   ok   %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); FAILURES="$FAILURES
   - [$SECTION] $1"; printf '   FAIL %s\n' "$1"; }

assert_eq() { # expected actual label
  if [ "$1" = "$2" ]; then _ok "$3"; else _fail "$3 -- expected [$1], got [$2]"; fi
}
assert_match() { # value ere label
  if printf '%s' "$1" | grep -Eq "$2"; then _ok "$3"; else _fail "$3 -- [$1] does not match /$2/"; fi
}
assert_no_match() { # value ere label
  if printf '%s' "$1" | grep -Eq "$2"; then _fail "$3 -- [$1] unexpectedly matches /$2/"; else _ok "$3"; fi
}
# Matching is done with `case`, not `printf | grep`: the pattern is quoted, so it
# is a literal substring test — exactly what `grep -F` did — but without spawning
# two processes per assertion. There are about a hundred of these across the
# suites, and on Windows each spawn costs a third of a second.
assert_contains() { # haystack needle label
  case "$1" in *"$2"*) _ok "$3" ;; *) _fail "$3 -- [$2] not found" ;; esac
}
assert_not_contains() { # haystack needle label
  case "$1" in *"$2"*) _fail "$3 -- [$2] unexpectedly present" ;; *) _ok "$3" ;; esac
}
assert_file()     { if [ -f "$1" ]; then _ok "$2"; else _fail "$2 -- missing file $1"; fi }
assert_no_file()  { if [ -f "$1" ]; then _fail "$2 -- file $1 exists"; else _ok "$2"; fi }
assert_rc()       { if [ "$1" = "$2" ]; then _ok "$3"; else _fail "$3 -- expected rc $1, got $2"; fi }
assert_ge() { # actual min label
  if [ "$1" -ge "$2" ] 2>/dev/null; then _ok "$3"; else _fail "$3 -- $1 is below $2"; fi
}

harness_summary() {
  printf '\n%s\n' "----------------------------------------"
  if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d checks\n' "$PASS"
    return 0
  fi
  printf 'FAIL  %d of %d checks failed\n%s\n' "$FAIL" "$((PASS + FAIL))" "$FAILURES"
  return 1
}

# ── sandbox ───────────────────────────────────────────────────────────────────
# A throwaway copy of the module plus stub Android tools, so nothing touches the
# real /data/adb and every system call is observable.

SANDBOX=""

sandbox_init() {
  # Deliberately an explicit /tmp path rather than $TMPDIR: on Git Bash for
  # Windows TMPDIR holds a Windows path ("C:\Users\...\Temp"), and those
  # backslashes and colons get mangled by the sed-based path rewriting inside
  # lib/common.sh (the \U and \L sequences are eaten as case conversions).
  SANDBOX=$(mktemp -d "${NFQWS_TEST_TMP:-/tmp}/nfqws2-test.XXXXXX") || exit 1
  SANDBOX=$(cd "$SANDBOX" && pwd)
  MODDIR="$SANDBOX/mod"
  CONFDIR="$SANDBOX/conf"
  MOCKBIN="$SANDBOX/bin"
  MOCK_DIR="$SANDBOX/mock"

  mkdir -p "$MODDIR/bin" "$MODDIR/system/bin" "$MODDIR/lib" "$MODDIR/strategies" "$MODDIR/defaults/lists" \
           "$MODDIR/lists" "$MODDIR/blobs" "$MODDIR/lua" "$CONFDIR" "$MOCKBIN" "$MOCK_DIR"

  cp "$REPO_DIR/bin/nfqws2-ctl"        "$MODDIR/bin/nfqws2-ctl"
  cp "$REPO_DIR/system/bin/nfqws2-ctl" "$MODDIR/system/bin/nfqws2-ctl" 2>/dev/null || true
  cp "$REPO_DIR/bin"/pkglist.*         "$MODDIR/bin/" 2>/dev/null || true
  cp "$REPO_DIR/lib/common.sh"         "$MODDIR/lib/common.sh"
  # extended: DNS по профилям
  if [ -f "$REPO_DIR/lib/dns.sh" ]; then
    cp "$REPO_DIR/lib/dns.sh" "$MODDIR/lib/dns.sh"
    mkdir -p "$MODDIR/defaults/dns-presets"
    cp -R "$REPO_DIR"/defaults/dns-presets/. "$MODDIR/defaults/dns-presets/"
    cp "$REPO_DIR/defaults/dns-cdn.list" "$REPO_DIR/defaults/dns-geo-never.list" "$MODDIR/defaults/" 2>/dev/null || true
  fi
  # Редактор hosts: файл назначения — в песочнице, mount/umount — заглушки
  cp "$REPO_DIR/lib/hosts.sh" "$MODDIR/lib/hosts.sh"
  mkdir -p "$MODDIR/defaults/hosts-presets"
  cp -R "$REPO_DIR"/defaults/hosts-presets/. "$MODDIR/defaults/hosts-presets/"
  cp "$REPO_DIR/defaults/hosts-bypass.txt" "$MODDIR/defaults/hosts-bypass.txt"
  HOSTS_TARGET="$SANDBOX/system_etc_hosts"
  printf '127.0.0.1 localhost\n::1 ip6-localhost\n# system\n1.2.3.4 sys.example\n' > "$HOSTS_TARGET"
  cp "$TESTS_DIR/lib/mock/mount" "$MOCKBIN/mount"
  cp "$TESTS_DIR/lib/mock/mount" "$MOCKBIN/umount"
  cp "$REPO_DIR/service.sh"            "$MODDIR/service.sh"
  cp "$REPO_DIR/boot-completed.sh"     "$MODDIR/boot-completed.sh" 2>/dev/null || true
  cp "$REPO_DIR/module.prop"           "$MODDIR/module.prop"
  cp "$REPO_DIR/defaults/nfqws2.conf"  "$MODDIR/defaults/nfqws2.conf"
  cp "$REPO_DIR/defaults/doh-bypass.conf" "$MODDIR/defaults/doh-bypass.conf"
  cp "$REPO_DIR/defaults/calls-bypass.conf" "$MODDIR/defaults/calls-bypass.conf"
  # -R on the directories: one process per tree instead of one per file, which
  # matters a lot when every spawn costs a few hundred milliseconds.
  cp -R "$REPO_DIR"/strategies/.       "$MODDIR/strategies/"
  cp -R "$REPO_DIR"/defaults/lists/.   "$MODDIR/defaults/lists/"
  cp -R "$REPO_DIR"/lua/.              "$MODDIR/lua/"
  cp -R "$REPO_DIR"/blobs/.            "$MODDIR/blobs/"
  # Only the lists customize.sh actually installs. The extra files in the repo's
  # lists/ are strategy inputs that lib/common.sh regenerates on demand, and
  # carrying them here would make sync_lists_and_blobs() — which runs on every
  # single load_conf() — walk three times as many files for no added coverage.
  for f in user exclude ipset ipset_exclude auto probe_hosts; do
    cp "$REPO_DIR/lists/$f.list" "$MODDIR/lists/$f.list"
  done
  chmod 0755 "$MODDIR/bin/nfqws2-ctl" "$MODDIR/service.sh" "$MODDIR/boot-completed.sh" "$MODDIR/system/bin/nfqws2-ctl" 2>/dev/null || true

  cp "$TESTS_DIR/lib/mock/iptables"    "$MOCKBIN/iptables"
  cp "$TESTS_DIR/lib/mock/iptables"    "$MOCKBIN/ip6tables"
  cp "$TESTS_DIR/lib/mock/iptables-restore" "$MOCKBIN/iptables-restore"
  cp "$TESTS_DIR/lib/mock/iptables-restore" "$MOCKBIN/ip6tables-restore"
  cp "$TESTS_DIR/lib/mock/iptables-save" "$MOCKBIN/iptables-save"
  cp "$TESTS_DIR/lib/mock/iptables-save" "$MOCKBIN/ip6tables-save"
  cp "$TESTS_DIR/lib/mock/rm"          "$MOCKBIN/rm"
  for n in pm getprop sysctl modprobe settings content am; do
    cp "$TESTS_DIR/lib/mock/android-stub" "$MOCKBIN/$n"
  done
  cp "$TESTS_DIR/lib/mock/nfqws2" "$MODDIR/bin/nfqws2"
  # curl по умолчанию — «нет сети»: помощники модуля (белые списки, фоновое
  # обучение) не должны ходить из тестов в настоящий интернет. Тесты, которым
  # нужен ответ, кладут свой curl поверх
  printf '#!/bin/sh\nexit 7\n' > "$MOCKBIN/curl"
  chmod 0755 "$MOCKBIN"/* "$MODDIR/bin/nfqws2"

  MOCK_IPT_STORE="$MOCK_DIR/ipt"
  MOCK_NFQWS_ARGS_FILE="$MOCK_DIR/nfqws2.args"
  MOCK_PM_FILE=""
  MOCK_IPT_FEATURES="connbytes multiport owner NFQUEUE"
  unset MOCK_NFQWS_FAIL MOCK_ABI
  export MOCK_IPT_STORE MOCK_NFQWS_ARGS_FILE MOCK_PM_FILE MOCK_IPT_FEATURES MOCK_DIR
  export MODDIR CONFDIR HOSTS_TARGET
  PATH="$MOCKBIN:$PATH"; export PATH
}

# NOTE: deliberately no EXIT trap. In dash (and POSIX sh generally) a command
# substitution — `args=$(_startup_args)` — forks a subshell that *inherits* the
# trap, so the trap fires the moment that subshell exits and wipes the sandbox
# out from under the running test. Test files call harness_finish() instead;
# INT/TERM are trapped because a subshell never receives those.
sandbox_cleanup() {
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    if [ "${NFQWS_TEST_KEEP:-0}" = "1" ]; then
      printf '\n[sandbox kept: %s]\n' "$SANDBOX"
    else
      # `find -delete`, not `rm -rf`: rm here is a safe-delete wrapper that can
      # take seconds per call (and prompt), which is why the trap used to wedge.
      find "$SANDBOX" -delete 2>/dev/null
      rmdir "$SANDBOX" 2>/dev/null
    fi
  fi
  SANDBOX=""
}

harness_finish() {
  _rc=0
  harness_summary || _rc=1
  sandbox_cleanup
  return $_rc
}

# Cleanup on interrupt, and *stop*: a trap that only cleans up would let the
# run continue against a sandbox that no longer exists, producing a cascade of
# bogus failures. (Process spawns cost ~0.3 s each on this machine, so a full
# module suite runs for about a minute and a careless `timeout` is easy to hit.)
trap 'sandbox_cleanup; exit 130' INT TERM

# ── module helpers ────────────────────────────────────────────────────────────

# Loads lib/common.sh into the current shell with the sandbox paths in place.
load_common() {
  export CONFDIR MODDIR
  . "$MODDIR/lib/common.sh"
}

ctl_out=""
ctl_rc=0
ctl() { # args...
  ctl_out=$(sh "$MODDIR/bin/nfqws2-ctl" "$@" 2>&1)
  ctl_rc=$?
  return 0
}

svc_out=""
svc_rc=0
svc() { # args...
  svc_out=$(sh "$MODDIR/service.sh" "$@" 2>&1)
  svc_rc=$?
  return 0
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | openssl base64 -d 2>/dev/null; }

conf_reset() { cp -f "$MODDIR/defaults/nfqws2.conf" "$CONFDIR/nfqws2.conf"; }

# Re-reads the config the way load_conf() does, minus the list/blob sync that
# load_conf() performs on every call. Tests use this for the many small conf
# edits; the sync itself is exercised once, explicitly, by load_conf().
reload_conf() { . "$CONFFILE"; set_defaults; }

# ── mock iptables inspection ──────────────────────────────────────────────────

ipt_reset() { rm -rf "$MOCK_IPT_STORE"; mkdir -p "$MOCK_IPT_STORE"; }

ipt_rules() { # chain [table] [binary]
  f="$MOCK_IPT_STORE/${3:-iptables}/${2:-mangle}/$1"
  [ -f "$f" ] && cat "$f"
  return 0
}

ipt_count() { # chain [table] [binary]
  ipt_rules "$1" "$2" "$3" | grep -c . || true
}
