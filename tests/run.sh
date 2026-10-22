#!/bin/sh
# Regression suite for the nfqws2-android module and its WebUI.
#
#   sh tests/run.sh              # everything
#   sh tests/run.sh --fast       # skip the slow service/rule-set and browser tests
#   sh tests/run.sh --keep       # keep the sandboxes for inspection
#
# Exit status is 0 only when every suite passed.
#
# Runtime note: on Windows/Git Bash every process spawn costs a few hundred
# milliseconds, and these suites spawn thousands of them, so a full run takes
# several minutes. On Linux the same suite finishes in seconds.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$HERE/.." && pwd)

FAST=0
for a in "$@"; do
  case "$a" in
    --fast) FAST=1 ;;
    --keep) NFQWS_TEST_KEEP=1 ;;
    -h|--help)
      printf 'usage: sh tests/run.sh [--fast] [--keep]\n'
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$a" >&2; exit 2 ;;
  esac
done
export NFQWS_TEST_KEEP="${NFQWS_TEST_KEEP:-0}"

# tools/ живут только на машине: они не нужны ни модулю на устройстве,
# ни тому, кто его собирает из архива.
if tracked=$(git -C "$REPO_DIR" ls-files tools 2>/dev/null) && [ -n "$tracked" ]; then
  printf 'tools/ попали под git — их не должно быть в репозитории:\n%s\n' "$tracked" >&2
  printf 'уберите: git rm -r --cached tools\n' >&2
  exit 1
fi

WORK=$(mktemp -d "${NFQWS_TEST_TMP:-/tmp}/nfqws2-run.XXXXXX") || exit 1
cleanup() { find "$WORK" -delete 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap 'cleanup' EXIT INT TERM

RESULTS=""
FAILED=0

# Suites run in parallel and their output is printed in order afterwards.
#
# They are independent — each builds its own sandbox under /tmp — and on
# Windows/Git Bash the run is bound by process-spawn rate rather than by the CPU:
# a single `sh -c true` costs half a second here. Serial execution left the
# machine mostly idle while paying that over and over, so the wall clock now
# follows the slowest suite instead of the sum.
#
# Set NFQWS_TEST_JOBS=1 to force the old serial behaviour.
#
# One lane per core, capped at 8: past that the suites — thousands of process
# spawns each — start competing for the same disk and stop gaining. Override with
# NFQWS_TEST_JOBS when a machine is busy with something else.
if [ -n "${NFQWS_TEST_JOBS:-}" ]; then
  JOBS="$NFQWS_TEST_JOBS"
else
  JOBS=$(nproc 2>/dev/null || echo 4)
  [ "$JOBS" -gt 8 ] 2>/dev/null && JOBS=8
fi
NSUITE=0

queue_suite() { # <label> <command...>
  NSUITE=$((NSUITE + 1))
  _n="$NSUITE"; _label="$1"; shift
  printf '%s\n' "$_label" > "$WORK/$_n.label"
  if [ "$JOBS" -le 1 ]; then
    if "$@" > "$WORK/$_n.out" 2>&1; then echo 0 > "$WORK/$_n.rc"; else echo 1 > "$WORK/$_n.rc"; fi
    return
  fi
  ( if "$@" > "$WORK/$_n.out" 2>&1; then echo 0 > "$WORK/$_n.rc"; else echo 1 > "$WORK/$_n.rc"; fi ) &
  # Держим не больше JOBS одновременных сьютов: каждый поднимает браузер или
  # песочницу, и десяток сразу только мешает друг другу.
  while [ "$(jobs -p | wc -l)" -ge "$JOBS" ]; do sleep 1; done
}

queue_skip() { # <label> <reason>
  NSUITE=$((NSUITE + 1))
  printf '%s\n' "$1" > "$WORK/$NSUITE.label"
  printf 'SKIP %s\n' "$2" > "$WORK/$NSUITE.skip"
}

report_suites() {
  _i=1
  while [ "$_i" -le "$NSUITE" ]; do
    _label=$(cat "$WORK/$_i.label" 2>/dev/null)
    printf '\n########## %s\n' "$_label"
    if [ -f "$WORK/$_i.skip" ]; then
      _reason=$(cat "$WORK/$_i.skip")
      printf '   SKIP  %s\n' "$_reason"
      RESULTS="$RESULTS
   SKIP  $_label ($_reason)"
    else
      cat "$WORK/$_i.out" 2>/dev/null
      if [ "$(cat "$WORK/$_i.rc" 2>/dev/null)" = "0" ]; then
        RESULTS="$RESULTS
   PASS  $_label"
      else
        RESULTS="$RESULTS
   FAIL  $_label"
        FAILED=$((FAILED + 1))
      fi
    fi
    _i=$((_i + 1))
  done
}

# ── tooling ───────────────────────────────────────────────────────────────────
SHELLS=""
for s in ${NFQWS_TEST_SHELLS:-dash bash}; do
  command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"
done
[ -n "$SHELLS" ] || SHELLS=" sh"

NODE_BIN="${NFQWS_TEST_NODE:-}"
if [ -z "$NODE_BIN" ]; then
  if command -v node >/dev/null 2>&1; then
    NODE_BIN=node
  else
    for _n in "$HOME"/.workbuddy-ai/binaries/node/versions/*/node.exe; do
      if [ -x "$_n" ]; then NODE_BIN="$_n"; break; fi
    done
  fi
fi

# Playwright is not a dependency of the module; point NODE_PATH at a workspace
# that has it, or the browser suite skips itself.
if [ -z "${NODE_PATH:-}" ] && [ -d "$HOME/.workbuddy-ai/binaries/node/workspace/node_modules" ]; then
  NODE_PATH="$HOME/.workbuddy-ai/binaries/node/workspace/node_modules"
fi
export NODE_PATH="${NODE_PATH:-}"

printf 'nfqws2-android regression suite\n'
printf 'repo:    %s\n' "$REPO_DIR"
printf 'shells: %s\n' "$SHELLS"
printf 'node:   %s\n' "${NODE_BIN:-<not found>}"

# ── module ────────────────────────────────────────────────────────────────────
queue_suite "module: data integrity" sh "$HERE/module/test_data.sh"
queue_suite "module: packaging" sh "$HERE/module/test_packaging.sh"

# The optional Java fixture runner exits 77 without a JDK. Report a real SKIP,
# rather than silently treating its exit as a passed test or failing every shell run.
java_compiler=${JAVAC:-${JAVA_HOME:+$JAVA_HOME/bin/}javac}
java_runtime=${JAVA:-${JAVA_HOME:+$JAVA_HOME/bin/}java}
if "$java_compiler" -version >/dev/null 2>&1 && "$java_runtime" -version >/dev/null 2>&1; then
  queue_suite "java: DNS cache resolver contract" sh "$HERE/java/dns-cache/run.sh"
else
  queue_skip "java: DNS cache resolver contract" "usable JDK unavailable (set JAVA_HOME)"
fi

for s in $SHELLS; do
  queue_suite "module: lib/common.sh under $s" "$s" "$HERE/module/test_common.sh"
  queue_suite "module: hosts network pause under $s" "$s" "$HERE/module/test_hosts_pause.sh"
  queue_suite "module: DNS cache refresh under $s" "$s" "$HERE/module/test_dns_cache.sh"
done

queue_suite "module: nfqws2-ctl" sh "$HERE/module/test_ctl.sh"
[ -f "$REPO_DIR/lib/dns.sh" ] && queue_suite "module: DNS profiles (extended)" sh "$HERE/module/test_dns.sh"
queue_suite "module: hosts editor" sh "$HERE/module/test_hosts.sh"
queue_suite "module: smart mode" sh "$HERE/module/test_smart.sh"

if [ "$FAST" = 1 ]; then
  queue_skip "module: service and firewall" "--fast"
else
  queue_suite "module: service and firewall" sh "$HERE/module/test_service.sh"
fi

# ── webui ─────────────────────────────────────────────────────────────────────
if [ -z "$NODE_BIN" ]; then
  queue_skip "webui: static invariants" "node not found"
  queue_skip "webui: app filter" "node not found"
  queue_skip "webui: hosts network pause" "node not found"
  queue_skip "webui: monet palette" "node not found"
  queue_skip "webui: dpi detector" "node not found"
  queue_skip "webui: export & backup" "node not found"
  queue_skip "webui: ctl contract" "node not found"
  queue_skip "webui: rendered geometry" "node not found"
else
  queue_suite "webui: static invariants" "$NODE_BIN" "$HERE/webui/test_static.js"
  queue_suite "webui: app filter" "$NODE_BIN" "$HERE/webui/test_apps.js"
  queue_suite "webui: hosts network pause" "$NODE_BIN" "$HERE/webui/test_hosts.js"
  queue_suite "webui: monet palette" "$NODE_BIN" "$HERE/webui/test_monet.js"
  queue_suite "webui: dpi detector" "$NODE_BIN" "$HERE/webui/test_dpi.js"
  queue_suite "webui: export & backup" "$NODE_BIN" "$HERE/webui/test_export.js"

  # The contract test compares index.html against the real ctl, so the ctl
  # output is produced here and handed over as files.
  sh "$HERE/lib/dump-ctl.sh" json-status > "$WORK/json-status.txt" 2>/dev/null
  sh "$HERE/lib/dump-ctl.sh" list-strategies > "$WORK/list-strategies.txt" 2>/dev/null
  if [ -s "$WORK/json-status.txt" ]; then
    queue_suite "webui: ctl contract" "$NODE_BIN" "$HERE/webui/test_contract.js" \
      "$WORK/json-status.txt" "$WORK/list-strategies.txt"
  else
    queue_skip "webui: ctl contract" "could not collect json-status from the sandbox"
  fi

  if [ "$FAST" = 1 ]; then
    queue_skip "webui: rendered geometry" "--fast"
    queue_skip "webui: tab paging" "--fast"
    queue_skip "webui: long presses" "--fast"
  else
    queue_suite "webui: rendered geometry" "$NODE_BIN" "$HERE/webui/test_layout.js"
    queue_suite "webui: tab paging" "$NODE_BIN" "$HERE/webui/test_swipe.js"
    queue_suite "webui: long presses" "$NODE_BIN" "$HERE/webui/test_longpress.js"
    queue_suite "webui: uptime ticks evenly" "$NODE_BIN" "$HERE/webui/test_uptime.js"
    queue_suite "webui: easter egg game" "$NODE_BIN" "$HERE/webui/test_flappy.js"
    queue_suite "webui: quick actions on tabs" "$NODE_BIN" "$HERE/webui/test_navquick.js"
    [ -f "$REPO_DIR/webroot/js/dns.js" ] && queue_suite "webui: DNS profiles (extended)" "$NODE_BIN" "$HERE/webui/test_dns.js"
  fi
fi

# ── collect and report ────────────────────────────────────────────────────────
wait
report_suites

# ── summary ───────────────────────────────────────────────────────────────────
printf '\n========================================\n'
printf 'summary%s\n' "$RESULTS"
printf '========================================\n'

if [ "$FAILED" -eq 0 ]; then
  printf 'all suites passed\n'
  exit 0
fi
printf '%d suite(s) failed\n' "$FAILED"
exit 1
