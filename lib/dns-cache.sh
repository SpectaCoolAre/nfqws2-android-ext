#!/system/bin/sh
# Best-effort refresh after an effective hosts change, once under the hosts lock.
# No mounts, resolver configuration, service restarts, or settings are changed.
#
# dns_cache_flush prints only machine-readable status/reason pairs. Return 1 if
# either operation failed; unsupported/none are non-errors, NOT successful flushes.
# The caller must retain the output even on a nonzero return (and must not undo
# the hosts change). Each Android command gets at most five seconds, then SIGKILL.
# With no usable timeout implementation we report unsupported, never run unbounded.
#
# apps=ok means ActivityManager accepted the protected root broadcast. Delivery to
# ActivityThread is asynchronous: it clears standard Java InetAddress caches and
# notifies NetworkEventDispatcher, not arbitrary engine caches or open sockets.

_dns_cache_find_timeout() {
  _dc_timeout=''
  if command -v timeout >/dev/null 2>&1 &&
     timeout -s KILL 1 sh -c 'exit 0' >/dev/null 2>&1; then
    _dc_timeout=timeout
  elif command -v busybox >/dev/null 2>&1 &&
       busybox timeout -s KILL 1 sh -c 'exit 0' >/dev/null 2>&1; then
    _dc_timeout=busybox
  fi
}

_dns_cache_run() {
  case "$_dc_timeout" in
    timeout) timeout -s KILL 5 "$@" ;;
    busybox) busybox timeout -s KILL 5 "$@" ;;
    *) return 125 ;;
  esac
}

# Inspect combined stdout/stderr even when a ROM's command exits zero on error.
# The raw output is never passed to a caller, sourced, or evaluated.
_dns_cache_error_reason() {
  local text
  text=$(printf '%s\n' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$text" in
    *securityexception*|*permission*deni*|*permission*reject*|*not\ permitted*|*not\ allowed*|*avc:*denied*)
      printf '%s' permission_denied ;;
    *timed\ out*|*timeout*) printf '%s' timeout ;;
    *error*|*exception*|*failed*|*failure*|*unknown\ command*|*not\ found*|*cannot*|*can\'t*|*usage:*)
      printf '%s' command_error ;;
  esac
}

_dns_cache_native() {
  local dir candidate payload='' out rc status='' reason='' line seen=0 seen_reason=0 error
  resolver=unsupported
  resolver_reason=helper_missing
  # Match the existing PkgList payload search without a second jar or wrapper.
  for dir in "${MODDIR:+$MODDIR/bin}" "${BIN_DIR:-}"; do
    [ -n "$dir" ] || continue
    for candidate in "$dir/pkglist.jar" "$dir/pkglist.dex"; do
      if [ -f "$candidate" ]; then payload="$candidate"; break; fi
    done
    [ -z "$payload" ] || break
  done
  [ -n "$payload" ] || return 0
  if [ ! -r "$payload" ] || [ ! -s "$payload" ]; then
    resolver=failed; resolver_reason=helper_unreadable; return 0
  fi
  if ! command -v app_process >/dev/null 2>&1; then
    resolver_reason=app_process_missing; return 0
  fi
  if [ -z "$_dc_timeout" ]; then
    resolver_reason=timeout_unavailable; return 0
  fi
  # Only the native subprocess gets this payload; am keeps its own classpath.
  rc=0
  out=$(export CLASSPATH="$payload"; _dns_cache_run app_process /system/bin com.deathwatcher.DnsCache 2>&1) || rc=$?
  case "$rc" in
    124|137|143) resolver=failed; resolver_reason=timeout; return 0 ;;
  esac
  # A previously packaged PkgList-only jar is a missing optional capability.
  case "$out" in
    *ClassNotFoundException*com.deathwatcher.DnsCache*|*'Could not find or load main class com.deathwatcher.DnsCache'*|*'Could not find class: com.deathwatcher.DnsCache'*)
      resolver_reason=helper_unavailable; return 0 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      resolver=*) status=${line#resolver=}; seen=$((seen + 1)) ;;
      resolver_reason=*) reason=${line#resolver_reason=}; seen_reason=$((seen_reason + 1)) ;;
    esac
  done <<EOF
$out
EOF
  # Only our helper's complete, unambiguous protocol can acknowledge a flush.
  resolver=failed
  resolver_reason=helper_protocol
  [ "$seen" -eq 1 ] && [ "$seen_reason" -eq 1 ] || {
    error=$(_dns_cache_error_reason "$out")
    [ -z "$error" ] || resolver_reason="$error"
    return 0
  }
  case "$reason" in ''|*[!a-z0-9_]*) return 0 ;; esac
  case "$status" in ok|unsupported|none|failed) ;; *) return 0 ;; esac
  if [ "$status" = failed ]; then
    resolver_reason="$reason"; return 0
  fi
  if [ "$rc" -ne 0 ]; then
    resolver_reason=helper_exit; return 0
  fi
  error=$(_dns_cache_error_reason "$out")
  if [ -n "$error" ]; then
    resolver_reason="$error"; return 0
  fi
  resolver="$status"
  resolver_reason="$reason"
}

_dns_cache_apps() {
  local out rc error complete=0 line
  apps=unsupported
  apps_reason=am_missing
  command -v am >/dev/null 2>&1 || return 0
  if [ -z "$_dc_timeout" ]; then
    apps_reason=timeout_unavailable; return 0
  fi
  rc=0
  # This is android.net.action, NOT android.intent.action. Run as the caller's
  # root uid; do not try su, an alternative broadcast, or a disruptive fallback.
  out=$(_dns_cache_run am broadcast --user all -a android.net.action.CLEAR_DNS_CACHE 2>&1) || rc=$?
  apps=failed
  case "$rc" in
    124|137|143) apps_reason=timeout; return 0 ;;
  esac
  error=$(_dns_cache_error_reason "$out")
  if [ -n "$error" ]; then apps_reason="$error"; return 0; fi
  if [ "$rc" -ne 0 ]; then apps_reason=am_exit; return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'Broadcast completed: result=0'|'Broadcast completed: result=0,'*) complete=$((complete + 1)) ;;
    esac
  done <<EOF
$out
EOF
  if [ "$complete" -ne 1 ]; then apps_reason=unconfirmed; return 0; fi
  apps=ok
  apps_reason=broadcast_accepted
}

dns_cache_flush() (
  # Isolate temporary variables and CLASSPATH from the watcher. No disk state.
  resolver=failed; resolver_reason=permission_denied
  apps=failed; apps_reason=permission_denied
  uid=$(id -u 2>/dev/null) || uid=''
  if [ "$uid" = 0 ]; then
    _dns_cache_find_timeout
    _dns_cache_native
    # Deliberately unconditional: old APIs, no networks, and native errors must
    # never prevent the safe application-cache notification.
    _dns_cache_apps
  elif [ -z "$uid" ]; then
    resolver_reason=uid_unavailable; apps_reason=uid_unavailable
  fi
  printf 'resolver=%s\napps=%s\nresolver_reason=%s\napps_reason=%s\n' \
    "$resolver" "$apps" "$resolver_reason" "$apps_reason"
  case "$resolver:$apps" in failed:*|*:failed) return 1 ;; esac
  return 0
)
