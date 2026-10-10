#!/system/bin/sh
[ -n "$MODDIR" ] || { echo "MODDIR is not set" >&2; return 1 2>/dev/null || exit 1; }

: "${CONFDIR:=/data/adb/nfqws2}"
CONFFILE="$CONFDIR/nfqws2.conf"
LISTS_DIR="$CONFDIR/lists"
STATE_DIR="$CONFDIR/state"
LOG_DIR="$CONFDIR/logs"
STRATEGIES_DIR="$MODDIR/strategies"
USER_STRATEGIES_DIR="$CONFDIR/strategies"
IMPORTS_DIR="$CONFDIR/imports"

LUA_DIR="$MODDIR/lua"
BLOBS_DIR="$MODDIR/blobs"
NFQWS_BIN="$MODDIR/bin/nfqws2"

PIDFILE="$STATE_DIR/nfqws2.pid"
WD_PIDFILE="$STATE_DIR/watchdog.pid"
WN_PIDFILE="$STATE_DIR/netwatch.pid"
DESIRED_FILE="$STATE_DIR/desired"
ARGS_FILE="$STATE_DIR/last.args"
APP_UIDS_FILE="$STATE_DIR/app_uids"
SERVICE_LOG="$LOG_DIR/service.log"
NFQWS_LOG="$LOG_DIR/nfqws2.log"
ACTIVE_FILE="$STATE_DIR/active_strategy"

# Release-shipped lists; .pending = newer version kept aside due to user edits
LISTS_PENDING_DIR="$LISTS_DIR/.pending"

# Home Wi-Fi: bypass pauses on these networks (HOME_WIFI=1)
HOME_FILE="$CONFDIR/home_wifi.list"
HOME_PAUSED_FILE="$STATE_DIR/home_paused"      # paused by home network; holds SSID
HOME_OVERRIDE_FILE="$STATE_DIR/home_override"  # user re-enabled on this network

MARK_EXCLUDE="0x20000000/0x20000000"
MARK_INCLUDE="0x10000000/0x10000000"
MARK_PROCESSED="0x40000000/0x40000000"

IPT_GROUP_POST="nfqws_post"
IPT_GROUP_PRE="nfqws_pre"
IPT_GROUP_NAT="nfqws_nat"
IPT_GROUP_QOUT="nfqws_qout"
IPT_GROUP_QIN="nfqws_qin" # like QOUT, for incoming when connbytes is missing
IPT_GROUP_APP="nfqws_app"
IPT_GROUP_FWD="nfqws_fwd"
NET_STRATEGIES_DIR="$CONFDIR/net_strategies"
IPT_CAP_CACHE="$STATE_DIR/iptables-capabilities"

# xt_owner allows max 128 ranges per rule
APP_UID_MAX=128

CNT_OUT_MASK=0x0f000000
CNT_OUT_STEP=16777216
CNT_IN_MASK=0x000f0000   # bits 16-19, apart from out counter (24-27) and MARK_* (28-30)
CNT_IN_STEP=65536        # 1<<16

# dirs usually exist; builtin test avoids forking mkdir (sourced on every nfqws2-ctl call)
if [ ! -d "$LISTS_DIR" ] || [ ! -d "$STATE_DIR" ] || [ ! -d "$LOG_DIR" ] || [ ! -d "$USER_STRATEGIES_DIR" ] || [ ! -d "$NET_STRATEGIES_DIR" ]; then
  mkdir -p "$LISTS_DIR" "$STATE_DIR" "$LOG_DIR" "$USER_STRATEGIES_DIR" "$NET_STRATEGIES_DIR" 2>/dev/null
fi

set_defaults() {
  : "${ISP_INTERFACE:=}"
  : "${IFACE_EXCLUDE:=lo tun+ tap+ wg+ ppp+ ipsec+ ifb+ dummy+}"
  : "${IPV6_ENABLED:=1}"
  : "${TCP_PORTS:=80,443,1984,2053,2083,2087,2096,5222,8443}"
  : "${UDP_PORTS:=443,590:600,1400,3478:3481,5349,19294:19344,49152:65535}"
  : "${NFQUEUE_NUM:=300}"
  : "${NFQWS_USER:=root}"
  : "${LOG_LEVEL:=0}"
  : "${AUTOSTART:=1}"
  : "${WATCHDOG:=1}"
  : "${BLOCK_QUIC:=0}"
  : "${NAT_FIX:=1}"
  : "${APP_MODE:=off}"
  : "${LOG_MAX_KB:=512}"
  : "${PKT_LIMIT_OUT:=15}"
  : "${PKT_LIMIT_IN:=15}"
  : "${HOME_WIFI:=0}"
  : "${ENABLE_HOTSPOT:=1}"
  : "${NET_STRATEGY:=0}"
  : "${DOH_BYPASS:=0}"
}

log_msg() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $*"
  echo "$line"
  echo "$line" >> "$SERVICE_LOG" 2>/dev/null
  if command -v log >/dev/null 2>&1; then
    log -t nfqws "$*" 2>/dev/null
  fi
}

sync_lists_and_blobs() {
  # builtin dir check avoids a fork on every netwatch tick and nfqws2-ctl call
  [ -d "$LISTS_DIR" ] && [ -d "$LOG_DIR" ] && [ -d "$STATE_DIR" ] ||
    mkdir -p "$LISTS_DIR" "$CONFDIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null

  for sdir in "$MODDIR/lists" "$MODDIR/defaults/lists"; do
    if [ -d "$sdir" ]; then
      for f in "$sdir"/*; do
        [ -f "$f" ] || continue
        local bname="${f##*/}"
        [ -f "$LISTS_DIR/$bname" ] || cp -f "$f" "$LISTS_DIR/$bname"
      done
    fi
  done
}

rotate_file() {
  local f="$1" max="$2" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null)
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -gt "$max" ] || return 0
  tail -c $((max / 2)) "$f" > "$f.tmp" 2>/dev/null && cat "$f.tmp" > "$f" 2>/dev/null
  rm -f "$f.tmp"
}

rotate_logs() {
  local max=$(( ${LOG_MAX_KB:-512} * 1024 )) f
  for f in "$SERVICE_LOG" "$NFQWS_LOG" "$LOG_DIR/auto.log" "$LOG_DIR/dns.log"; do rotate_file "$f" "$max"; done
  if [ "$1" = "start" ]; then
    f="$LOG_DIR/nfqws2-debug.log"
    # truncate when debug on, rotate when off; && ... || would rotate on failed truncate
    if [ "$LOG_LEVEL" = "1" ]; then
      : > "$f" 2>/dev/null
    else
      rotate_file "$f" "$max"
    fi
  fi
}

validate_conf() {
  awk '
    BEGIN { ok = 1 }
    /`/ { printf "line %d: backtick is forbidden\n", NR; ok = 0 }
    /\$\(/ { printf "line %d: $( is forbidden\n", NR; ok = 0 }
    END { exit ok ? 0 : 1 }
  ' "$1"
}

load_conf() {
  sync_lists_and_blobs
  if [ ! -f "$CONFFILE" ]; then
    cp -f "$MODDIR/defaults/nfqws2.conf" "$CONFFILE" 2>/dev/null
  fi
  local err
  err=$(validate_conf "$CONFFILE" 2>&1) || {
    log_msg "Конфиг $CONFFILE содержит ошибки: $err"
    . "$MODDIR/defaults/nfqws2.conf"
    set_defaults
    return 1
  }
  . "$CONFFILE"
  set_defaults
  return 0
}

validate_args_conf() {
  local v var
  for var in NFQWS_BASE_ARGS NFQWS_ARGS NFQWS_ARGS_QUIC NFQWS_ARGS_UDP NFQWS_EXTRA_ARGS NFQWS_ARGS_IPSET; do
    eval "v=\$$var"
    case "$v" in
      *--new*) echo "Использовать --new в $var нельзя. Используйте NFQWS_ARGS_CUSTOM"; return 1 ;;
    esac
  done
  return 0
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  return 0
}

list_count() {
  [ -f "$1" ] || { printf 0; return; }
  local c
  c=$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" 2>/dev/null)
  printf '%s' "${c:-0}"
}

# list_count for many files in one grep; counts space-separated, 0 if missing.
# grep not awk: toybox awk is 4x slower on large ipset lists.
list_counts() {
  local f out="" c r="" have=""
  for f; do [ -f "$f" ] && have="$have${have:+
}$f"; done
  # trailing /dev/null makes grep print "name:count" even for a single file
  [ -n "$have" ] && out=$(IFS='
'; set -f; grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' $have /dev/null 2>/dev/null)
  out="
$out"
  for f; do
    c=0
    case "$out" in *"
$f:"*) c="${out#*"
$f:"}"; c="${c%%[!0-9]*}" ;; esac
    r="$r${r:+ }${c:-0}"
  done
  printf '%s' "$r"
}

# Rewrite keenetic paths to module dirs.
# Specific paths must be substituted before the generic /opt/etc/nfqws2.
# arg "refs": keep $LUA_DIR/... references (for stored config); no arg: expand.
rewrite_keenetic_paths() {
  if [ "$1" = "refs" ]; then
    sed -e 's#/opt/etc/nfqws2/lua#$LUA_DIR#g' \
        -e 's#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g' \
        -e 's#/opt/etc/nfqws2/lists#$LISTS_DIR#g' \
        -e 's#/opt/etc/nfqws2#$CONFDIR#g' \
        -e 's#/opt/var/log#$LOG_DIR#g'
  else
    sed -e "s#/opt/etc/nfqws2/lua#$LUA_DIR#g" \
        -e "s#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g" \
        -e "s#/opt/etc/nfqws2/lists#$LISTS_DIR#g" \
        -e "s#/opt/etc/nfqws2#$CONFDIR#g" \
        -e "s#/opt/var/log#$LOG_DIR#g"
  fi
}

norm_args() {
  printf '%s\n' "$1" \
    | sed -e 's/^[[:space:]]*#.*$//' -e 's/\\//g' \
    | awk '{ for (i=1; i<=NF; i++) printf "%s ", $i } END { print "" }' \
    | rewrite_keenetic_paths \
    | sed -e 's/  */ /g; s/^ //; s/ $//'
}

app_mode_active() {
  case "$APP_MODE" in include|exclude) return 0 ;; *) return 1 ;; esac
}

# apps.list package names -> comma-separated UIDs via pm
resolve_app_uids() {
  local f="$CONFDIR/apps.list" PM=pm
  [ -f "$f" ] || return 0
  # WebUI/root shell may lack /system/bin in PATH
  command -v pm >/dev/null 2>&1 || PM=/system/bin/pm
  command -v "$PM" >/dev/null 2>&1 || return 0
  [ -s "$f" ] || return 0
  "$PM" list packages -U 2>/dev/null | awk '
    NR == FNR {
      sub(/\r$/, "")
      sub(/^[ \t]+/, "")
      sub(/[ \t]+$/, "")
      if ($0 != "" && $0 !~ /^#/) w[tolower($0)] = 1
      next
    }
    $1 ~ /^package:/ {
      p = tolower(substr($1, 9)); u = $2; sub(/^uid:/, "", u)
      if ((p in w) && u ~ /^[0-9]+$/) print u
    }' "$f" - | sort -n -u | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $0 }'
}

app_features_ok() {
  has_ipt_feature "$1" -m owner --uid-owner 0 -j RETURN &&
  has_ipt_feature "$1" -m connmark --mark 0x1/0x1 -j RETURN &&
  has_ipt_feature "$1" -j CONNMARK --set-xmark 0x1/0x1
}

app_uid_count() {
  local n
  [ -f "$APP_UIDS_FILE" ] || { printf 0; return; }
  n=$(tr ',' '\n' < "$APP_UIDS_FILE" 2>/dev/null | grep -cE '^[0-9]+$')
  printf '%s' "${n:-0}"
}

# 0 = app filter applied, 1 = off/not applicable, 2 = error
app_rules() {
  local CMD="$1" uids n chunk mark FAM="${FW_FAMILY:-$1}"
  if ! app_mode_active; then
    $CMD -w -t mangle -F $IPT_GROUP_APP 2>/dev/null
    $CMD -w -t mangle -X $IPT_GROUP_APP 2>/dev/null
    rm -f "$APP_UIDS_FILE"
    return 1
  fi
  if ! app_features_ok "$CMD"; then
    [ "$FAM" = "iptables" ] && log_msg "Нет xt_owner/xt_CONNMARK — фильтр по приложениям не применяется"
    return 2
  fi
  uids=$(resolve_app_uids)
  n=$(printf '%s\n' "$uids" | tr ',' '\n' | grep -cE '^[0-9]+$')
  if [ "$FAM" = "iptables" ]; then
    printf '%s\n' "$uids" > "$APP_UIDS_FILE"
    n=$(app_uid_count)
  fi
  if [ "$n" = "0" ]; then
    log_msg "apps.list: ни один пакет не сопоставлен с UID — фильтр по приложениям ($APP_MODE) не действует"
    return 2
  fi

  # -m owner needs a socket, so UID matching runs in POSTROUTING; replies use the conn mark
  mark="$MARK_INCLUDE"
  [ "$APP_MODE" = "exclude" ] && mark="$MARK_EXCLUDE"
  $CMD -w -t mangle -N $IPT_GROUP_APP 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_APP
  printf '%s\n' "$uids" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n -u | awk -v mx="$APP_UID_MAX" '
      # не a[b] = (b in a ? …): mawk и toybox awk заводят a[b] до проверки,
      # и первый UID получал запятую впереди («--uid-owner ,10201»)
      { b = int((NR - 1) / mx); if (b in a) a[b] = a[b] "," $0; else a[b] = $0 }
      END { for (i = 0; i <= b; i++) if (i in a) print a[i] }' | while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    $CMD -w -t mangle -A $IPT_GROUP_APP -m owner --uid-owner "$chunk" -j CONNMARK --set-xmark "$mark"
  done
  $CMD -w -t mangle -A $IPT_GROUP_POST -j $IPT_GROUP_APP
  if [ "$APP_MODE" = "exclude" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark --mark "$MARK_EXCLUDE" -j RETURN
    [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE -m connmark --mark "$MARK_EXCLUDE" -j RETURN
  else
    $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark ! --mark "$MARK_INCLUDE" -j RETURN
    [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE -m connmark ! --mark "$MARK_INCLUDE" -j RETURN
  fi
  log_msg "Фильтр по приложениям ($APP_MODE): $n UID"
  return 0
}

port_list_without() {
  printf ',%s,' "$1" | sed "s/,$2,/,/g; s/^,//; s/,\$//"
}

_startup_args() {
  local base tcp quic udp extra custom ipset
  base=$(norm_args "$NFQWS_BASE_ARGS")
  tcp=$(norm_args "$NFQWS_ARGS")
  quic=$(norm_args "$NFQWS_ARGS_QUIC")
  udp=$(norm_args "$NFQWS_ARGS_UDP")
  extra=$(norm_args "$NFQWS_EXTRA_ARGS")
  custom=$(norm_args "$NFQWS_ARGS_CUSTOM")
  ipset=""
  if [ -n "$NFQWS_ARGS_IPSET" ] && [ "$(list_count "$LISTS_DIR/ipset.list")" -gt 0 ]; then
    ipset=$(norm_args "$NFQWS_ARGS_IPSET")
  fi

  local args="--user=$NFQWS_USER --qnum=$NFQUEUE_NUM"

  if [ -n "$ISP_INTERFACE" ] && [ "$(echo $ISP_INTERFACE | wc -w)" -gt 1 ]; then
    args="$args --bind-fix4"
    [ "$IPV6_ENABLED" != "0" ] && args="$args --bind-fix6"
  fi

  if [ "$LOG_LEVEL" = "1" ]; then
    args="--debug=@$LOG_DIR/nfqws2-debug.log $args"
  else
    args="--debug=@$NFQWS_LOG $args"
  fi

  args="$args $base"
  # Обход блокировки DoT/DoH — первым профилем, чтобы его не перехватила стратегия
  if [ "$DOH_BYPASS" = "1" ] && [ -f "$MODDIR/defaults/doh-bypass.conf" ]; then
    args="$args --blob=doh_tls:@$BLOBS_DIR/tls_clienthello.bin $(norm_args "$(cat "$MODDIR/defaults/doh-bypass.conf")") --new"
  fi
  [ -n "$custom" ] && args="$args $custom --new"
  [ -n "$udp" ] && args="$args $udp --new"

  if [ -n "$quic" ] && [ "$BLOCK_QUIC" != "1" ]; then
    [ -n "$ipset" ] && args="$args $quic $ipset --ipset-ip=0.0.0.0 --new"
    args="$args $quic $extra --new"
  fi

  [ -n "$ipset" ] && args="$args $tcp $ipset --ipset-ip=0.0.0.0 --new"
  args="$args $tcp $extra"

  printf '%s' "$args" | tr -s ' '
}

dry_run_check() { # <args...>
  [ -x "$NFQWS_BIN" ] || return 0
  local out rc
  out=$(
    cd "$MODDIR/bin" 2>/dev/null || exit 1
    set -f
    if [ "$#" -eq 1 ]; then
      set -- $1
    fi
    "$NFQWS_BIN" --dry-run "$@" 2>&1
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      echo "nfqws2: ошибка параметров (код $rc)"
    fi
    return "$rc"
  fi
  return 0
}

validate_conf_file() { # <conf_file>
  local f="$1" err out rc
  [ -f "$f" ] || { echo "Файл не найден: $f"; return 1; }
  err=$(validate_conf "$f" 2>&1) || { echo "$err"; return 1; }
  out=$(
    export CONFDIR MODDIR
    . "$f" >/dev/null 2>&1 || { echo "Ошибка синтаксиса в $f"; exit 1; }
    set_defaults
    err=$(validate_args_conf) || { echo "$err"; exit 1; }
    local args
    args=$(_startup_args)
    dry_run_check "$args" || exit 1
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      echo "Ошибка валидации параметров nfqws2 (код $rc)"
    fi
    return "$rc"
  fi
  return 0
}

kernel_modules() {
  command -v modprobe >/dev/null 2>&1 || return 0
  modprobe -a -q nfnetlink_queue xt_multiport xt_connbytes xt_NFQUEUE xt_CONNMARK xt_connmark xt_owner nf_conntrack 2>/dev/null
  return 0
}

has_ipt_feature() {
  ipt_probe "$@" >/dev/null 2>&1
}

_ipt_cap_cache_get() { # <command> <probe key>
  [ "$1" = _fw_batch_cmd ] && set -- "$FW_PROBE_CMD" "$2"
  [ -n "$MOCK_IPT_FEATURES" ] && return 1
  local kernel value
  kernel=$(uname -r 2>/dev/null) || return 1
  [ -n "$kernel" ] || return 1
  [ -f "$IPT_CAP_CACHE" ] || return 1
  value=$(while IFS='|' read -r k c p v; do
    [ "$k" = "$kernel" ] && [ "$c" = "$1" ] && [ "$p" = "$2" ] && {
      printf '%s' "$v"
      break
    }
  done < "$IPT_CAP_CACHE")
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

_ipt_cap_cache_put() { # <command> <probe key> <value>
  [ "$1" = _fw_batch_cmd ] && set -- "$FW_PROBE_CMD" "$2" "$3"
  [ -n "$MOCK_IPT_FEATURES" ] && return 0
  local kernel tmp
  kernel=$(uname -r 2>/dev/null) || return 0
  [ -n "$kernel" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  tmp="$IPT_CAP_CACHE.tmp"
  if [ -f "$IPT_CAP_CACHE" ]; then
    while IFS='|' read -r k c p v; do
      [ "$k" = "$kernel" ] && [ "$c" = "$1" ] && [ "$p" = "$2" ] && continue
      printf '%s|%s|%s|%s\n' "$k" "$c" "$p" "$v"
    done < "$IPT_CAP_CACHE" > "$tmp"
  fi
  printf '%s|%s|%s|%s\n' "$kernel" "$1" "$2" "$3" >> "$tmp"
  mv -f "$tmp" "$IPT_CAP_CACHE"
}

ipt_probe() {
  local CMD="$1"; shift
  local err rc
  $CMD -w -t mangle -N nfqws_test >/dev/null 2>&1
  $CMD -w -t mangle -F nfqws_test >/dev/null 2>&1
  err=$($CMD -w -t mangle -A nfqws_test "$@" 2>&1); rc=$?
  $CMD -w -t mangle -F nfqws_test >/dev/null 2>&1
  $CMD -w -t mangle -X nfqws_test >/dev/null 2>&1
  [ "$rc" -eq 0 ] || printf '%s' "$err" | tail -n1
  return $rc
}

# Кэш — только положительных ответов: «нет» могло быть оттого, что модуль
# ядра ещё не загружен (проверка на загрузке раньше modprobe), а запомненное
# «нет» держало бы худший режим до смены ядра. Отрицательный ответ дешевле
# перепроверить при следующей сборке правил.
detect_limiter() {
  local C="${1:-iptables}"
  [ "$(_ipt_cap_cache_get "$C" limiter)" = connbytes ] && { echo connbytes; return 0; }
  if has_ipt_feature $C -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:15 -j RETURN; then
    _ipt_cap_cache_put "$C" limiter connbytes
    echo connbytes
  else
    echo connmark_out
  fi
}

has_multiport() {
  local C="$1"
  [ "$(_ipt_cap_cache_get "$C" multiport)" = 1 ] && return 0
  has_ipt_feature "$C" -p tcp -m multiport --dports 80,443 -j RETURN || return 1
  _ipt_cap_cache_put "$C" multiport 1
  return 0
}

_fw_counter_chain() {
  local CMD="$1" CH="$2" MASK="$3" STEP="$4" LIM="$5" k
  case "$LIM" in ''|*[!0-9]*) LIM=15 ;; esac
  [ "$LIM" -gt 15 ] && LIM=15
  [ "$LIM" -lt 1 ] && LIM=1
  $CMD -w -t mangle -N "$CH" 2>/dev/null
  $CMD -w -t mangle -F "$CH"
  $CMD -w -t mangle -A "$CH" -m connmark --mark $((LIM * STEP))/$MASK -j RETURN
  k=$((LIM - 1))
  while [ "$k" -ge 0 ]; do
    $CMD -w -t mangle -A "$CH" -m connmark --mark $((k * STEP))/$MASK -j CONNMARK --set-xmark $(((k + 1) * STEP))/$MASK
    k=$((k - 1))
  done
  $CMD -w -t mangle -A "$CH" -j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass
}

_fw_add_rule() {
  # $1: CMD, $2: CHAIN, $3: IFSPEC (-o / -i), $4: proto (tcp/udp), $5: dir (dports/sports), $6: ports, $7: extra flags, $8: target
  local CMD="$1" CH="$2" IFSPEC="$3" PROTO="$4" DIR="$5" PORTS="$6" EXTRA="$7" TARGET="$8"
  [ -z "$PORTS" ] && return 0

  local applied=0
  if [ "$HAS_MULTIPORT" = "1" ]; then
    if $CMD -w -t mangle -A "$CH" $IFSPEC -p "$PROTO" -m multiport "--$DIR" "$PORTS" $EXTRA $TARGET 2>/dev/null; then
      applied=1
    fi
  fi

  if [ "$applied" = "0" ]; then
    local sdir p
    if [ "$DIR" = "dports" ]; then
      sdir="--dport"
    else
      sdir="--sport"
    fi
    for p in $(printf '%s' "$PORTS" | tr ',' ' '); do
      $CMD -w -t mangle -A "$CH" $IFSPEC -p "$PROTO" $sdir "$p" $EXTRA $TARGET 2>/dev/null
    done
  fi
}

_fw_batch_cmd() {
  local table=mangle arg line original="$*"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -w) shift ;;
      -t) table="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 1
  # run via real command to reflect actual kernel
  case "$*" in
    *nfqws_test*) "$FW_PROBE_CMD" $original; return $? ;;
  esac
  case "$1" in
    -D) return 1 ;;
    -N|-F|-X|-A|-I)
      line="$1"; shift
      for arg in "$@"; do line="$line $arg"; done
      printf '%s|%s\n' "$table" "$line" >> "$FW_BATCH_FILE"
      return 0 ;;
  esac
  return 1
}

# Пакетная загрузка правил: тот же построитель _firewall_start, но вместо
# iptables — _fw_batch_cmd, который складывает команды в файл, а потом всё
# применяется одним iptables-restore. Построитель смотрит на имя команды
# (NAT_FIX, файл лимитера, UID приложений — только для iptables), поэтому
# настоящая команда передаётся в FW_FAMILY.
_firewall_start_restore() {
  local CMD="$1" restore raw rules table line current="" restore_file
  restore_file="${FW_RESTORE_DIR}/${CMD}.rules"
  raw="${FW_RESTORE_DIR}/${CMD}.raw"
  rules="${FW_RESTORE_DIR}/${CMD}.input"

  command -v "${CMD}-restore" >/dev/null 2>&1 || return 1
  _firewall_stop "$CMD" || true
  FW_BATCH_FILE="$raw"
  FW_PROBE_CMD="$CMD"
  : > "$raw"
  FW_FAMILY="$CMD"
  _firewall_start _fw_batch_cmd || { FW_FAMILY=""; rm -f "$raw"; return 1; }
  FW_FAMILY=""

  current=""
  : > "$rules"
  while IFS='|' read -r table line; do
    [ "$table" = "$current" ] || {
      [ -z "$current" ] || printf 'COMMIT\n' >> "$rules"
      current="$table"
      printf '*%s\n' "$table" >> "$rules"
    }
    printf '%s\n' "$line" >> "$rules"
  done < "$raw"
  [ -z "$current" ] || printf 'COMMIT\n' >> "$rules"

  "${CMD}-restore" --noflush < "$rules"
  local rc=$?
  rm -f "$raw" "$rules"
  return "$rc"
}

_fw_iface_rules() {
  local CMD="$1" OUT="$2" IN="$3"
  local JNFQ="-j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass"
  local UP="$IPT_UDP_EFF" TP="$IPT_TCP_PORTS"
  local CB_OUT="" CB_IN="" LIM_OUT="" LIM_IN=""
  local TARGET_OUT TARGET_IN

  case "$LIMITER" in
    connbytes)
      CB_OUT="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_OUT"
      CB_IN="-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_IN"
      TARGET_OUT="$CB_OUT $JNFQ"
      TARGET_IN="$CB_IN $JNFQ"
      ;;
    connmark_out)
      LIM_OUT="-j $IPT_GROUP_QOUT"
      LIM_IN="-j $IPT_GROUP_QIN"
      TARGET_OUT="$LIM_OUT"
      TARGET_IN="$LIM_IN"
      ;;
  esac

  # don't requeue packets already processed by nfqws2
  $CMD -w -t mangle -A $IPT_GROUP_POST $OUT -m mark --mark $MARK_PROCESSED -j RETURN
  $CMD -w -t mangle -A $IPT_GROUP_PRE $IN -m mark --mark $MARK_PROCESSED -j RETURN

  # outgoing (POSTROUTING)
  [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" udp dports "$UP" "" "$TARGET_OUT"
  [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "" "$TARGET_OUT"

  # FIN/RST go to nfqws for clean conntrack
  if [ -n "$TP" ]; then
    _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "--tcp-flags fin fin" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "--tcp-flags rst rst" "$JNFQ"
  fi

  # NAT fix for UDP
  if [ "${FW_FAMILY:-$CMD}" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -A $IPT_GROUP_NAT $OUT -p udp -m mark --mark $MARK_PROCESSED -j MASQUERADE
  fi

  # incoming (PREROUTING)
  if [ -n "$TP" ]; then
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags syn,ack syn,ack" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags fin fin" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags rst rst" "$JNFQ"
  fi

  # Incoming data flow (connbytes or connmark_in)
  [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" udp sports "$UP" "" "$TARGET_IN"
  [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "" "$TARGET_IN"
}

_firewall_start() {
  local CMD="$1" IF ex FAM="${FW_FAMILY:-$1}"

  IPT_TCP_PORTS=$(printf '%s' "$TCP_PORTS" | tr '-' ':')
  IPT_UDP_EFF=$(printf '%s' "$UDP_PORTS" | tr '-' ':')
  [ "$BLOCK_QUIC" = "1" ] && IPT_UDP_EFF=$(port_list_without "$IPT_UDP_EFF" 443)
  # DoT (853) нужен в очереди, только когда включён обход блокировки DoT/DoH
  if [ "$DOH_BYPASS" = "1" ]; then
    case ",$IPT_TCP_PORTS," in *,853,*) ;; *) IPT_TCP_PORTS="$IPT_TCP_PORTS,853" ;; esac
    case ",$IPT_UDP_EFF," in *,853,*) ;; *) IPT_UDP_EFF="$IPT_UDP_EFF,853" ;; esac
  fi

  LIMITER=$(detect_limiter "$CMD")
  [ "$FAM" = "iptables" ] && echo "$LIMITER" > "$STATE_DIR/limiter" 2>/dev/null

  HAS_MULTIPORT=0
  has_multiport "$CMD" && HAS_MULTIPORT=1

  $CMD -w -t mangle -N $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_POST
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done

  $CMD -w -t mangle -N $IPT_GROUP_PRE 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_PRE
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done

  if [ "$LIMITER" = "connmark_out" ]; then
    _fw_counter_chain "$CMD" $IPT_GROUP_QOUT $CNT_OUT_MASK $CNT_OUT_STEP "$PKT_LIMIT_OUT"
    _fw_counter_chain "$CMD" $IPT_GROUP_QIN $CNT_IN_MASK $CNT_IN_STEP "$PKT_LIMIT_IN"
  fi

  if [ "$FAM" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -N $IPT_GROUP_NAT 2>/dev/null
    $CMD -w -t nat -F $IPT_GROUP_NAT
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
  fi

  if [ -z "$ISP_INTERFACE" ]; then
    for ex in $IFACE_EXCLUDE; do
      $CMD -w -t mangle -A $IPT_GROUP_POST -o "$ex" -j RETURN
      $CMD -w -t mangle -A $IPT_GROUP_PRE -i "$ex" -j RETURN
    done
  fi

  app_rules "$CMD"

  if [ "$BLOCK_QUIC" = "1" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_POST -p udp --dport 443 -j DROP
  fi

  if [ -n "$ISP_INTERFACE" ]; then
    for IF in $ISP_INTERFACE; do
      _fw_iface_rules "$CMD" "-o $IF" "-i $IF"
    done
  else
    _fw_iface_rules "$CMD" "" ""
  fi

  $CMD -w -t mangle -I POSTROUTING 1 -j $IPT_GROUP_POST
  $CMD -w -t mangle -I PREROUTING 1 -j $IPT_GROUP_PRE
  if [ "$FAM" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -I POSTROUTING 1 -j $IPT_GROUP_NAT
  fi

  if [ "$ENABLE_HOTSPOT" = "1" ]; then
    $CMD -w -t mangle -N $IPT_GROUP_FWD 2>/dev/null
    $CMD -w -t mangle -F $IPT_GROUP_FWD
    while $CMD -w -t mangle -D FORWARD -j $IPT_GROUP_FWD 2>/dev/null; do :; done

    $CMD -w -t mangle -A $IPT_GROUP_FWD -m mark --mark $MARK_PROCESSED -j RETURN

    if [ "$BLOCK_QUIC" = "1" ]; then
      $CMD -w -t mangle -A $IPT_GROUP_FWD -p udp --dport 443 -j DROP
    fi

    local JNFQ="-j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass"
    local UP="$IPT_UDP_EFF" TP="$IPT_TCP_PORTS"
    local TARGET_OUT TARGET_IN
    case "$LIMITER" in
      connbytes)
        TARGET_OUT="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_OUT $JNFQ"
        TARGET_IN="-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_IN $JNFQ"
        ;;
      connmark_out)
        TARGET_OUT="-j $IPT_GROUP_QOUT"
        TARGET_IN="-j $IPT_GROUP_QIN"
        ;;
    esac

    [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" udp dports "$UP" "" "$TARGET_OUT"
    [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" tcp dports "$TP" "" "$TARGET_OUT"
    [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" udp sports "$UP" "" "$TARGET_IN"
    [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_FWD "" tcp sports "$TP" "" "$TARGET_IN"

    $CMD -w -t mangle -I FORWARD 1 -j $IPT_GROUP_FWD
  fi
}

_firewall_stop() {
  local CMD="$1"
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done
  while $CMD -w -t mangle -D FORWARD -j $IPT_GROUP_FWD 2>/dev/null; do :; done
  $CMD -w -t mangle -F $IPT_GROUP_POST 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_PRE 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_PRE 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_FWD 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_FWD 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_QOUT 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_QOUT 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_QIN 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_QIN 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_APP 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_APP 2>/dev/null
  if [ "$CMD" = "iptables" ]; then
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
    $CMD -w -t nat -F $IPT_GROUP_NAT 2>/dev/null; $CMD -w -t nat -X $IPT_GROUP_NAT 2>/dev/null
  fi
}

firewall_iptables()  { _firewall_start iptables; }
firewall_ip6tables() { [ "$IPV6_ENABLED" = "0" ] && return 0; _firewall_start ip6tables; }

firewall_iptables_restore()  { _firewall_start_restore iptables; }
firewall_ip6tables_restore() { [ "$IPV6_ENABLED" = "0" ] && return 0; _firewall_start_restore ip6tables; }

# Аппаратное ускорение раздачи (tether offload): на многих телефонах трафик
# раздачи обрабатывает модем в обход iptables, и nfqws2 его не видит. Пока
# включён обход для точки доступа, ускорение выключаем. Прежнее значение
# запоминаем и возвращаем его же — пользователь мог выключить ускорение сам.
# settings — это запуск Java, поэтому трогаем его, только если значение не то.
TETHER_SAVED_FILE="$STATE_DIR/tether_offload.saved"
apply_tether_offload() {
  command -v settings >/dev/null 2>&1 || return 0
  [ "$ENABLE_HOTSPOT" = "1" ] || { restore_tether_offload; return 0; }
  local cur
  cur=$(settings get global tether_offload_disabled 2>/dev/null | tr -d '\r')
  [ "$cur" = "1" ] && return 0
  [ -f "$TETHER_SAVED_FILE" ] || printf '%s\n' "${cur:-null}" > "$TETHER_SAVED_FILE"
  settings put global tether_offload_disabled 1 2>/dev/null || true
}

restore_tether_offload() {
  [ -f "$TETHER_SAVED_FILE" ] || return 0
  command -v settings >/dev/null 2>&1 || return 0
  local was
  IFS= read -r was < "$TETHER_SAVED_FILE"
  case "$was" in
    ''|null) settings delete global tether_offload_disabled >/dev/null 2>&1 || true ;;
    *) settings put global tether_offload_disabled "$was" 2>/dev/null || true ;;
  esac
  rm -f "$TETHER_SAVED_FILE"
}

# check both rc: firewall_ip6tables returns 0 when IPv6 is off, masking an iptables failure
firewall_start() {
  local rc=0
  FW_RESTORE_DIR="$STATE_DIR/firewall-restore"
  mkdir -p "$FW_RESTORE_DIR" 2>/dev/null
  if command -v iptables-restore >/dev/null 2>&1; then
    firewall_iptables_restore || { firewall_iptables || rc=1; }
  else
    firewall_iptables || rc=1
  fi
  if [ "$IPV6_ENABLED" = "0" ]; then
    :
  elif command -v ip6tables-restore >/dev/null 2>&1; then
    firewall_ip6tables_restore || { firewall_ip6tables || rc=1; }
  else
    firewall_ip6tables || rc=1
  fi
  apply_tether_offload
  return $rc
}

firewall_stop() {
  local rc=0
  _firewall_stop iptables || rc=1
  _firewall_stop ip6tables || rc=1
  restore_tether_offload
  return $rc
}

firewall_ok() {
  iptables -w -t mangle -C POSTROUTING -j $IPT_GROUP_POST 2>/dev/null || return 1
  iptables -w -t mangle -S $IPT_GROUP_POST 2>/dev/null | grep -qE -- 'NFQUEUE|nfqws_qout'
}

# Some ROMs freeze the app cgroup the root process started in; move it to the
# root cgroup (v2), which is not frozen. Best-effort.
# -w first: dash reports a redirect open() error before 2>/dev/null applies.
protect_process() {   # $1 - PID; default: current process
  local p="${1:-$$}"
  [ -z "$p" ] && return 0
  [ -d "/proc/$p" ] || return 0
  if [ -w "/proc/$p/oom_score_adj" ] 2>/dev/null; then
    echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null
  elif [ -w "/proc/$p/oom_adj" ] 2>/dev/null; then
    echo -17 > "/proc/$p/oom_adj" 2>/dev/null
  fi
  if [ -w /sys/fs/cgroup/cgroup.procs ] 2>/dev/null; then
    echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
  fi
  if [ -w /dev/cpuset/cgroup.procs ] 2>/dev/null; then
    echo "$p" > /dev/cpuset/cgroup.procs 2>/dev/null
  fi
  return 0
}

# Параметр (partial wakelock на время работы) убран в v2.0.1. Лок в
# ядре не привязан к процессу и пережил бы обновление у тех, у кого он был
# включён, поэтому остановка службы и удаление модуля его по-прежнему снимают.
# Имя — id из module.prop (проверяет test_data.sh).
release_wakelock() {
  [ -w /sys/power/wake_unlock ] 2>/dev/null || return 0
  echo "nfqws2-android" > /sys/power/wake_unlock 2>/dev/null
  return 0
}

system_config() {
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1
  sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1 || {
    [ -w /proc/sys/net/ipv4/tcp_timestamps ] && echo 1 > /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null
  }
  sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.rmem_default=2097152 >/dev/null 2>&1
  sysctl -w net.core.netdev_max_backlog=16384 >/dev/null 2>&1

  # Values proven stable on the reference router (1200 / 16384). Android defaults
  # can expire idle long-lived connections; their packets then look INVALID and
  # are silently dropped.
  local cur_max
  cur_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
  sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=1200 >/dev/null 2>&1
  if [ -n "$cur_max" ] && [ "$cur_max" -lt 16384 ] 2>/dev/null; then
    log_msg "conntrack: nf_conntrack_max было $cur_max, поднимаем до 16384 (как на эталонном роутере)"
    sysctl -w net.netfilter.nf_conntrack_max=16384 >/dev/null 2>&1
  fi
  setup_cli_symlinks
  return 0
}

setup_cli_symlinks() {
  local p
  for p in /data/adb/ap/bin /data/adb/ksu/bin; do
    if [ -d "$p" ]; then
      ln -sf "$MODDIR/bin/nfqws2-ctl" "$p/nfqws2-ctl" 2>/dev/null
    fi
  done
  return 0
}

# ---------------------------------------------------------------- batch config import
# A keenetic config has at least 2 key variables.
is_keenetic_config() {
  local f="$1" n
  [ -f "$f" ] || return 1
  n=$(grep -cE '^[[:space:]]*(NFQWS_BASE_ARGS|NFQWS_ARGS|NFQWS_ARGS_QUIC|NFQWS_ARGS_UDP|NFQWS_EXTRA_ARGS|NFQWS_ARGS_IPSET|ISP_INTERFACE|TCP_PORTS)=' "$f" 2>/dev/null)
  [ "${n:-0}" -ge 2 ]
}

import_safe_name() {
  # strip only shell/path-dangerous bytes; they are single-byte ASCII, so
  # multibyte names (Cyrillic etc.) survive
  printf '%s' "$1" | tr -d '/\\`$"'"'" | tr -d '\n\r\t' | sed -e 's/^[[:space:].]*//' -e 's/[[:space:]]*$//' | cut -c1-200
}

list_imports() {
  local f
  for f in "$IMPORTS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    basename "$f" .conf
  done | sort
}

# Keys defining the bypass itself; the rest are module settings, identical for
# all strategies and taken from the live config on switch (see USER_KEYS).
STRATEGY_KEYS="NFQWS_BASE_ARGS NFQWS_ARGS NFQWS_ARGS_QUIC NFQWS_ARGS_UDP NFQWS_ARGS_IPSET NFQWS_ARGS_CUSTOM"

# foreign options to strip
FOREIGN_OPTS=""

# Unsupported long options in a file, one per line. FOREIGN_OPTS plus a grep of
# the binary (option names are strings in it); if the binary isn't nfqws2
# (no "lua-desync"), FOREIGN_OPTS only.
unsupported_opts() { # <file>
  local n real=0
  grep -qF lua-desync "$NFQWS_BIN" 2>/dev/null && grep -qF filter-tcp "$NFQWS_BIN" 2>/dev/null && real=1
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -oE -e '(^|[[:space:]"])--[A-Za-z0-9][A-Za-z0-9-]*' | sed 's/^.*--//' | sort -u |
  while IFS= read -r n; do
    case " $FOREIGN_OPTS " in *" $n "*) echo "$n"; continue ;; esac
    [ "$real" = 1 ] && ! grep -qF -e "$n" "$NFQWS_BIN" 2>/dev/null && echo "$n"
  done
}

# Remove listed --name[=value] options from a config, merging orphaned quotes and
# line continuations so the file looks as if the option was never there.
strip_opts() { # <space-separated names>  stdin -> stdout
  awk -v bad=" $1 " '
    function emit(l) { if (have) print prev; prev = l; have = 1 }
    {
      s = $0; out = ""; cut = 0
      while (match(s, /(^|[[:space:]"])--[A-Za-z0-9][A-Za-z0-9-]*(=[^[:space:]"]*)?/)) {
        tok = substr(s, RSTART, RLENGTH); lead = ""
        if (substr(tok, 1, 2) != "--") { lead = substr(tok, 1, 1); tok = substr(tok, 2) }
        name = substr(tok, 3); sub(/=.*/, "", name)
        pre = substr(s, 1, RSTART - 1); s = substr(s, RSTART + RLENGTH)
        if (index(bad, " " name " ")) {
          cut = 1
          # no space needed before the option if one follows it
          if (lead ~ /[[:space:]]/ && s ~ /^[[:space:]]/) lead = ""
          out = out pre lead
        } else out = out pre lead tok
      }
      out = out s
      if (!cut) {
        if (join) { sub(/^[[:space:]]+/, "", out); out = held out; join = 0 }
        emit(out); next
      }
      sub(/[[:space:]]+$/, "", out); sub(/[[:space:]]+"/, "\"", out)
      if (join) { sub(/^[[:space:]]+/, "", out); out = held out; join = 0 }
      if (out ~ /^[[:space:]]*$/) next
      if (out ~ /^[[:space:]]*"$/ && have) { prev = prev "\""; next }
      if (out ~ /="$/) { held = out; join = 1; next }
      emit(out)
    }
    END { if (join) emit(held); if (have) print prev }'
}

# Convert an imported keenetic config into strategy format: defaults/nfqws2.conf
# skeleton, only STRATEGY_KEYS and their own variables from the import, paths
# rewritten, unsupported options stripped. A missing key stays empty, not
# inherited. Idempotent.
normalize_import() { # <import file> -> stdout
  local src="$1" clean="$STATE_DIR/import_norm.$$"
  [ -f "$src" ] || return 1
  tr -d '\r' < "$src" | rewrite_keenetic_paths refs > "$clean"
  local bad
  bad=$(unsupported_opts "$clean" | tr '\n' ' ')
  if [ -n "$bad" ]; then strip_opts "$bad" < "$clean" > "$clean.s" && mv -f "$clean.s" "$clean"; fi
  awk -v skeys=" $STRATEGY_KEYS " -v tpl="$MODDIR/defaults/nfqws2.conf" '
    function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
    function keyof(line) { return match(line, /^[A-Za-z_][A-Za-z0-9_]*=/) ? substr(line, 1, RLENGTH - 1) : "" }
    # read file into KEY=blocks (values may span lines)
    function load(file, blk, ord,   line, k, cur, inval, n) {
      n = 0; inval = 0; cur = ""
      while ((getline line < file) > 0) {
        if (inval) { blk[cur] = blk[cur] "\n" line; if (quotes(line) % 2 == 1) inval = 0; continue }
        k = keyof(line)
        if (k == "") { if (file == tpl) { ord[++n] = "\001" line } continue }
        cur = k; blk[k] = line; ord[++n] = k
        if (quotes(line) % 2 == 1) inval = 1
      }
      close(file)
      return n
    }
    BEGIN {
      ni = load(ARGV[1], imp, iord)
      nt = load(tpl, tblk, tord)
      for (i = 1; i <= nt; i++) if (substr(tord[i], 1, 1) != "\001") intpl[tord[i]] = 1
      skip["ISP_INTERFACE"]; skip["USER"]; skip["POLICY_NAME"]; skip["POLICY_EXCLUDE"]; skip["LOG_DEBUG_PATH"]
      first = 1
      for (i = 1; i <= nt; i++) {
        k = tord[i]
        if (substr(k, 1, 1) == "\001") { print substr(k, 2); continue }
        if (index(skeys, " " k " ")) {
          # own variables of the import must precede bypass keys using them
          if (first) {
            for (j = 1; j <= ni; j++) { e = iord[j]
              if (!(e in intpl) && !(e in skip) && !(e in done)) { print imp[e]; print ""; done[e] = 1 } }
            first = 0
          }
          print ((k in imp) ? imp[k] : k "=\"\"")
        } else {
          print tblk[k]
        }
      }
      exit
    }' "$clean"
  rm -f "$clean"
}

# Import preview for the editor: strategy + settings from the live config
render_import_merged() {
  local raw="$STATE_DIR/import_prev.$$"
  normalize_import "$1" > "$raw" || { rm -f "$raw"; return 1; }
  if [ -f "$CONFFILE" ]; then merge_user_keys "$raw" "$CONFFILE"; else cat "$raw"; fi
  rm -f "$raw"
}

# ---------------------------------------------------------------- service output language
# WebUI-shown content strings follow NFQWS_LANG; service logs stay Russian.
M() { if [ "$NFQWS_LANG" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# ---------------------------------------------------------------- status in module.prop
# Managers show description in the module list, so write live state there.
# cat > (not mv) keeps module.prop owner and mode.
DESC_BASE="Обход DPI на базе nfqws2."
current_mode() {
  awk '/^NFQWS_EXTRA_ARGS=/ { if (match($0, /MODE_[A-Z]*/)) print tolower(substr($0, RSTART + 5, RLENGTH - 5)); exit }' "$CONFFILE" 2>/dev/null
}
update_description() { # running | stopped | paused <ssid>
  local prop="$MODDIR/module.prop" d strat mode tmp
  if [ ! -f "$prop" ] || [ ! -w "$prop" ]; then return 0; fi
  case "$1" in
    running)
      strat=$(cat "$ACTIVE_FILE" 2>/dev/null); strat="${strat#imp:}"
      mode=$(current_mode)
      d="✅ Работает · ${strat:-default}${mode:+ · $mode}" ;;
    paused) d="⏸ Пауза: домашняя Wi-Fi «$2»" ;;
    *)      d="⛔ Остановлено" ;;
  esac
  d=$(printf '%s' "$d | $DESC_BASE" | tr -d '\n\r')
  tmp="$STATE_DIR/module.prop.$$"
  awk -v d="$d" 'BEGIN { done = 0 } /^description=/ { print "description=" d; done = 1; next } { print }
    END { if (!done) print "description=" d }' "$prop" > "$tmp" && cat "$tmp" > "$prop"
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------- strategies
# Built-in strategies ship in the module; a user edit under the same name in
# $USER_STRATEGIES_DIR overrides it. Reset = delete that copy.
# Imported configs are selectable as "imp:<name>".
strategy_name_ok() {
  case "$1" in ''|*/*|*'`'*|*'$'*|*'"'*|*\'*|*'\'*|.*) return 1 ;; esac
  return 0
}
strategy_builtin_file() { [ -f "$STRATEGIES_DIR/$1.conf" ] && printf '%s' "$STRATEGIES_DIR/$1.conf"; }
strategy_file() { # effective strategy file: user edit first, else built-in
  case "$1" in
    imp:*) [ -f "$IMPORTS_DIR/${1#imp:}.conf" ] && printf '%s' "$IMPORTS_DIR/${1#imp:}.conf" ;;
    *) if [ -f "$USER_STRATEGIES_DIR/$1.conf" ]; then printf '%s' "$USER_STRATEGIES_DIR/$1.conf"
       else strategy_builtin_file "$1"; fi ;;
  esac
}
# 0: built-in strategy was edited and differs from the original
strategy_modified() {
  local b
  b=$(strategy_builtin_file "$1") || return 1
  [ -f "$USER_STRATEGIES_DIR/$1.conf" ] || return 1
  ! cmp -s "$b" "$USER_STRATEGIES_DIR/$1.conf"
}

# Strategy config as set-strategy writes it, before carrying over user settings.
render_strategy() {
  local f
  case "$1" in
    ''|default) cat "$MODDIR/defaults/nfqws2.conf" ;;
    imp:*) f=$(strategy_file "$1") || return 1; normalize_import "$f" ;;
    *) f=$(strategy_file "$1") || return 1
       rewrite_keenetic_paths < "$f" \
         | sed -e 's#^[[:space:]]*ISP_INTERFACE=.*#ISP_INTERFACE=""#' \
               -e 's#^[[:space:]]*USER=.*#NFQWS_USER=root#' ;;
  esac
}

# Module settings (same across strategies) are carried over whole from the live
# config on strategy change/reset. NFQWS_EXTRA_ARGS only for standard $MODE_* refs.
USER_KEYS="DOH_BYPASS IPV6_ENABLED TCP_PORTS UDP_PORTS NFQUEUE_NUM PKT_LIMIT_OUT PKT_LIMIT_IN BLOCK_QUIC NAT_FIX APP_MODE AUTOSTART WATCHDOG NFQWS_USER LOG_LEVEL LOG_MAX_KB HOME_WIFI ENABLE_HOTSPOT NET_STRATEGY NFQWS_EXTRA_ARGS"
merge_user_keys() { # <generated config> <settings source config>  -> stdout
  awk -v keys=" $USER_KEYS " -v src="$2" '
    function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
    function keyof(line) { return match(line, /^[A-Za-z_][A-Za-z0-9_]*=/) ? substr(line, 1, RLENGTH - 1) : "" }
    BEGIN {
      while ((getline line < src) > 0) {
        k = keyof(line)
        if (k == "" || !index(keys, " " k " ") || quotes(line) % 2 == 1 || (k in keep)) continue
        if (k != "NFQWS_EXTRA_ARGS" || line ~ /^NFQWS_EXTRA_ARGS="?\$MODE_(LIST|AUTO|ALL)"?[ \t]*$/) keep[k] = line
      }
      close(src)
    }
    skip { if (quotes($0) % 2 == 1) skip = 0; next }
    {
      k = keyof($0)
      if (k != "" && (k in keep) && !(k in done)) {
        print keep[k]; done[k] = 1
        if (quotes($0) % 2 == 1) skip = 1
        next
      }
      print
    }
    END {
      hdr = 0
      for (k in keep) {
        if (!(k in done)) {
          if (!hdr) { print ""; print "# ---- Настройки Android"; hdr = 1 }
          print keep[k]
        }
      }
    }' "$1"
}

# ---------------------------------------------------------------- home Wi-Fi
# Current SSID, rc 1 if not on Wi-Fi. cmd wifi needs Android 11; dumpsys is the fallback.
current_ssid() {
  local out s
  out=$(cmd wifi status 2>/dev/null)
  case "$out" in
    *"Wifi is "*)
      # cmd wifi отвечает — ему и верим: нет «connected to» значит не подключено.
      # Раньше тут откатывались к dumpsys wifi, а в нём лежит история недавних
      # состояний: сразу после ухода из дома первой находилась старая запись о
      # домашней сети, и пауза оставалась на мобильном интернете.
      s=$(printf '%s\n' "$out" | sed -n 's/^Wifi is connected to "\(.*\)"[[:space:]]*$/\1/p' | head -n1) ;;
    *)
      # старые Android без cmd wifi status
      s=$(dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo SSID: .*Supplicant state: COMPLETED' \
          | sed -e 's/.*mWifiInfo SSID: //' -e 's/, BSSID:.*//' -e 's/^"\(.*\)"$/\1/') ;;
  esac
  case "$s" in ''|'<unknown ssid>'|'<none>'|0x) return 1 ;; esac
  printf '%s' "$s"
}
# Несёт ли Wi‑Fi трафик: Android держит Wi‑Fi подключённой и когда в ней нет
# интернета (роутер завис, ещё грузится после перезагрузки) — тогда основная
# сеть мобильная, и считать телефон «дома» нельзя: обход встал бы на паузу на
# мобильном интернете. Основная сеть — «Active default network» из dumpsys
# connectivity и её NetworkAgentInfo. Формат не разобрать — верим SSID, как раньше.
wifi_is_default() {
  local r
  r=$(dumpsys connectivity 2>/dev/null | awk '
    /^ *Active default network:/ { act = $NF; seen = 1 }
    /NetworkAgentInfo/ && match($0, /network\{[0-9]+\}/) {
      id = substr($0, RSTART + 8, RLENGTH - 9)
      if (!(id in kind)) kind[id] = ($0 ~ /ni\{WIFI/ || $0 ~ /Transports: [A-Z|]*WIFI/ || $0 ~ /InterfaceName: wlan/) ? "wifi" : "other"
    }
    END {
      if (!seen) print "unknown"
      else if (act == "none" || act == "null") print "none"
      else if (act in kind) print kind[act]
      else print "unknown"
    }')
  case "$r" in wifi|unknown) return 0 ;; *) return 1 ;; esac
}
# SSID Wi‑Fi, через которую сейчас идёт трафик (для домашней сети и стратегий по сетям)
active_ssid() {
  local s
  s=$(current_ssid) || return 1
  wifi_is_default || return 1
  printf '%s' "$s"
}
ssid_is_home() {
  if [ -z "$1" ] || [ ! -f "$HOME_FILE" ]; then return 1; fi
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$HOME_FILE" 2>/dev/null | grep -Fxq -- "$1"
}

# ---------------------------------------------------------------- network strategy caching
current_network_key() {
  local ssid op
  if ssid=$(active_ssid 2>/dev/null) && [ -n "$ssid" ]; then
    printf 'wifi_%s' "$(printf '%s' "$ssid" | tr -c 'a-zA-Z0-9._-' '_')"
    return 0
  fi
  op=$(getprop gsm.operator.alpha 2>/dev/null | cut -d',' -f1 | tr -d '\r\n')
  [ -z "$op" ] && op=$(getprop gsm.sim.operator.alpha 2>/dev/null | cut -d',' -f1 | tr -d '\r\n')
  if [ -n "$op" ]; then
    printf 'cell_%s' "$(printf '%s' "$op" | tr -c 'a-zA-Z0-9._-' '_')"
  else
    printf 'cellular'
  fi
  return 0
}

current_network_title() {
  local ssid op
  if ssid=$(active_ssid 2>/dev/null) && [ -n "$ssid" ]; then
    printf 'Wi-Fi «%s»' "$ssid"
    return 0
  fi
  op=$(getprop gsm.operator.alpha 2>/dev/null | cut -d',' -f1 | tr -d '\r\n')
  [ -z "$op" ] && op=$(getprop gsm.sim.operator.alpha 2>/dev/null | cut -d',' -f1 | tr -d '\r\n')
  if [ -n "$op" ]; then
    printf 'Мобильная сеть (%s)' "$op"
  else
    printf 'Мобильная сеть'
  fi
  return 0
}

save_net_strategy() { # <strategy_name> [net_key]
  local strat="$1" key="${2:-$(current_network_key 2>/dev/null)}" title
  if [ -z "$strat" ] || [ -z "$key" ]; then
    return 1
  fi
  [ -d "$NET_STRATEGIES_DIR" ] || mkdir -p "$NET_STRATEGIES_DIR" 2>/dev/null
  printf '%s\n' "$strat" > "$NET_STRATEGIES_DIR/$key"
  title=$(current_network_title 2>/dev/null)
  [ -n "$title" ] && printf '%s\n' "$title" > "$NET_STRATEGIES_DIR/$key.title"
  return 0
}

load_net_strategy() { # [net_key] -> prints strategy name
  local key="${1:-$(current_network_key 2>/dev/null)}"
  [ -f "$NET_STRATEGIES_DIR/$key" ] || return 1
  local s
  s=$(head -n1 "$NET_STRATEGIES_DIR/$key" 2>/dev/null | tr -d '\r\n')
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}

list_net_strategies() {
  local f key strat title
  for f in "$NET_STRATEGIES_DIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.title) continue ;; esac
    key="${f##*/}"
    strat=$(head -n1 "$f" 2>/dev/null | tr -d '\r\n')
    title=""
    [ -f "$f.title" ] && title=$(head -n1 "$f.title" 2>/dev/null | tr -d '\r\n')
    [ -n "$title" ] || title="$key"
    printf '%s\t%s\t%s\n' "$key" "$strat" "$title"
  done
}

clear_net_strategies() {
  rm -rf "$NET_STRATEGIES_DIR"/* 2>/dev/null
}

# DNS по профилям: без bin/dnsproxy dns_enabled всегда ложно, и всё dns_* молчит.
. "$MODDIR/lib/dns.sh"
# Редактор hosts без перезагрузки (логика bindhosts)
. "$MODDIR/lib/hosts.sh"
