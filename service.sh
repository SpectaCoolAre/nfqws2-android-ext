#!/system/bin/sh

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
umask 077
. "$MODDIR/lib/common.sh"
load_conf

STARTED_FILE="$STATE_DIR/started_at"

# both start() failures end with the log tail; keep it in one place
start_failed() {
  log_msg "$1"
  log_msg "Последние строки лога:"
  tail -n 8 "$NFQWS_LOG" 2>/dev/null | while IFS= read -r l; do log_msg "  $l"; done
  update_description stopped
}

# watchdog/netwatch: auto-restart, home Wi-Fi pause, per-network strategies
watchers_wanted() { [ "$WATCHDOG" = "1" ] || [ "$HOME_WIFI" = "1" ] || [ "$NET_STRATEGY" = "1" ] || dns_enabled; }

start() {
  if is_running; then
    echo "Служба nfqws2 уже запущена (PID $(cat "$PIDFILE"))"
    return 0
  fi
  if [ ! -x "$NFQWS_BIN" ]; then
    chmod 0755 "$NFQWS_BIN" 2>/dev/null
    [ -x "$NFQWS_BIN" ] || { log_msg "Ошибка: нет исполняемого $NFQWS_BIN"; return 1; }
  fi
  local err
  err=$(validate_args_conf) || { log_msg "$err"; return 1; }

  log_msg "Запуск nfqws2..."
  kernel_modules
  rotate_logs start

  local args
  args=$(_startup_args)
  printf '%s\n' "$args" > "$ARGS_FILE"

  local dry_err
  if ! dry_err=$(dry_run_check "$args"); then
    log_msg "Ошибка: проверка nfqws2 --dry-run не пройдена"
    printf '%s\n' "$dry_err" >> "$NFQWS_LOG"
    start_failed "Ошибка: параметры запуска nfqws2 некорректны (проверка --dry-run отклонена)."
    return 1
  fi

  cd "$MODDIR/bin" || return 1
  set -f

  # built-in --daemon: nfqws2 reparents to init and writes its PID to $PIDFILE
  rm -f "$PIDFILE"
  "$NFQWS_BIN" --daemon --pidfile="$PIDFILE" $args >> "$NFQWS_LOG" 2>&1
  local res=$?
  set +f

  if [ "$res" -ne 0 ]; then
    start_failed "Ошибка: nfqws2 завершился с кодом $res."
    return 1
  fi

  sleep 1.2
  local pid=""
  [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || pid=$(pidof nfqws2 2>/dev/null | awk '{print $1}')

  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    start_failed "Ошибка: nfqws2 не запустился."
    return 1
  fi

  echo "$pid" > "$PIDFILE"
  protect_process "$pid"
  date +%s > "$STARTED_FILE"

  # firewall_start can return 0 with no rule in place; without the POSTROUTING
  # jump the daemon runs but nothing reaches NFQUEUE
  firewall_start
  if ! firewall_ok; then
    log_msg "Ошибка: правила iptables не применились — трафик не перехватывается"
    # a daemon without rules is useless and a stale pidfile would claim it runs
    kill -TERM "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    update_description stopped
    return 1
  fi

  system_config
  echo 1 > "$DESIRED_FILE"
  log_msg "nfqws2 запущен (PID $pid, Native Daemon)"
  update_description running
  ensure_watchdog
  dns_start "запуск службы"
  return 0
}

stop() {
  rm -f "$DESIRED_FILE" "$STARTED_FILE"
  # DNS «без службы» переживает остановку обхода
  dns_standalone || dns_stop "остановка службы"
  release_wakelock
  firewall_stop
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      sleep 0.8
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
  fi
  pidof nfqws2 >/dev/null 2>&1 && killall -9 nfqws2 2>/dev/null

  # a leftover chain still jumps to NFQUEUE with no listener, so the kernel
  # drops that traffic: stopped must mean rules gone
  if firewall_ok; then
    log_msg "Ошибка: правила iptables остались на месте — трафик в NFQUEUE без слушателя"
    return 1
  fi

  log_msg "nfqws2 остановлен"
  update_description stopped
  return 0
}

reload_lists() {
  is_running || { echo "Служба не запущена"; return 1; }
  kill -HUP "$(cat "$PIDFILE")" 2>/dev/null
  log_msg "Списки перечитаны (SIGHUP)"
}

# Start a helper unless it already runs. Returns 0 when it was just started,
# 1 when it is running or the precondition failed. ensure_watchdog uses this
# to raise netwatch only alongside the watchdog.
ensure_helper() {
  local pf="$1" sub="$2"; shift 2
  # bare "$@" is a no-op with no args in dash, but be explicit about it
  [ $# -eq 0 ] || { "$@" || return 1; }
  if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
    return 1
  fi
  (
    exec 0</dev/null
    exec >/dev/null 2>&1
    exec sh "$MODDIR/service.sh" "$sub"
  ) &
  return 0
}

ensure_watchdog() {
  watchers_wanted || return 0
  ensure_helper "$WD_PIDFILE" watchdog || return 0
  ensure_netwatch
}

# Rebuild rules on events, not on a timer. Routers use a netfilter.d firmware
# hook for this; ip monitor is the Android equivalent. Watchdog is the
# fallback where ip monitor is unsupported.
ensure_netwatch() {
  watchers_wanted || return 0
  ensure_helper "$WN_PIDFILE" netwatch command -v ip || return 0
}

netwatch() {
  echo $$ > "$WN_PIDFILE"
  protect_process
  command -v ip >/dev/null 2>&1 || { rm -f "$WN_PIDFILE"; return 0; }

  EVFILE="$STATE_DIR/netwatch_events"
  rm -f "$EVFILE"
  local prev="" acted="" backoff=2 saw=0 sz mon up recheck
  # Первая перепроверка — через 30 с после старта: при загрузке сеть ещё
  # устанавливается, и её смена до запуска ip monitor не дала бы события
  read -r up _ < /proc/uptime; recheck=$(( ${up%.*} + 30 ))
  # The monitor writes events to a file, reaction is on its size changing.
  # A file, not a pipe, so kill -TERM reaps ip monitor itself instead of a
  # wrapper that would leave an orphan. Poll every 2s to spare battery
  # through the night.
  while :; do
    ip monitor route link 2>/dev/null >> "$EVFILE" &
    mon=$!
    saw=0
    while :; do
      sleep 2
      load_conf >/dev/null 2>&1
      watchers_wanted || break 2
      if ! kill -0 "$mon" 2>/dev/null; then
        # died on its own. If it never wrote a byte, ip monitor is unsupported
        # here: grow the pause instead of restarting it in a loop.
        if [ "$saw" = 0 ]; then
          sleep "$backoff"
          [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
        else
          backoff=2
        fi
        break
      fi
      # Контрольная перепроверка через 30 с после смены сети: в момент события
      # Wi‑Fi бывает ещё в переходном состоянии (отключается, переподключается),
      # и решение о паузе, принятое по нему, могло остаться неверным.
      if [ "$recheck" -gt 0 ]; then
        read -r up _ < /proc/uptime; up=${up%.*}
        if [ "$up" -ge "$recheck" ]; then
          recheck=0
          home_check
          network_strategy_check
        fi
      fi
      sz=$(wc -c < "$EVFILE" 2>/dev/null)
      case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
      if [ "$sz" != "$prev" ]; then
        # events still arriving; wait one quiet tick so a burst from a single
        # network change does not rebuild the rules per packet
        prev="$sz"
        saw=1
        continue
      fi
      if [ "$sz" != "$acted" ] && [ "$sz" != 0 ]; then
        if [ -f "$DESIRED_FILE" ] && is_running; then
          log_msg "netwatch: сеть изменилась (ip monitor) — пересобираю правила"
          firewall_start
        fi
        home_check
        network_strategy_check
        # DNS сети сменился вместе с сетью; работает и без службы
        dns_enabled && dns_start "смена сети"
        acted="$sz"
        read -r up _ < /proc/uptime; recheck=$(( ${up%.*} + 30 ))
      fi
      [ "$sz" -gt 262144 ] && { kill -TERM "$mon" 2>/dev/null; : > "$EVFILE"; prev=""; acted=""; }
    done
    kill -TERM "$mon" 2>/dev/null
    wait "$mon" 2>/dev/null
  done
  kill -TERM "$mon" 2>/dev/null
  rm -f "$WN_PIDFILE" "$EVFILE"
}

watchdog() {
  echo $$ > "$WD_PIDFILE"
  protect_process
  local fails=0 tick=0
  while :; do
    sleep 20
    load_conf >/dev/null 2>&1
    watchers_wanted || break
    tick=$((tick + 1))
    # once a minute: cmd wifi is the expensive part
    [ "$HOME_WIFI" = "1" ] && [ $((tick % 3)) -eq 0 ] && home_check
    [ "$NET_STRATEGY" = "1" ] && [ $((tick % 3)) -eq 0 ] && network_strategy_check
    # DNS — до проверки WATCHDOG: упавший dnsproxy с правилами перехвата
    # оставил бы телефон совсем без DNS
    dns_enabled && dns_check
    [ "$WATCHDOG" = "1" ] || continue
    [ -f "$DESIRED_FILE" ] || continue

    if ! is_running; then
      fails=$((fails + 1))
      log_msg "watchdog: nfqws2 упал, автоперезапуск (#$fails)..."
      firewall_stop
      start
      sleep 2
      continue
    fi

    # survived a full cycle: reset the fail counter
    fails=0

    # fast iptables recovery after a network switch
    if ! firewall_ok; then
      log_msg "watchdog: правила iptables сброшены системой — восстановление"
      firewall_start
    fi
    [ $((tick % 25)) -eq 0 ] && rotate_logs
  done
  rm -f "$WD_PIDFILE"
}

# home Wi-Fi: networks from home_wifi.list pause the service; leaving resumes.
# A manual start there is remembered in home_override while that SSID stays.
home_check() {
  # the lock dir keeps the two watchers from stop/starting twice; a lock older
  # than two minutes is residue from a killed process
  [ -n "$(find "$STATE_DIR/home.lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$STATE_DIR/home.lock" 2>/dev/null
  mkdir "$STATE_DIR/home.lock" 2>/dev/null || return 0
  local ssid=""
  if [ "$HOME_WIFI" = "1" ]; then
    ssid=$(active_ssid)
    if [ -f "$HOME_OVERRIDE_FILE" ] && [ "$(cat "$HOME_OVERRIDE_FILE" 2>/dev/null)" != "$ssid" ]; then
      rm -f "$HOME_OVERRIDE_FILE"
    fi
  fi
  if [ "$HOME_WIFI" = "1" ] && ssid_is_home "$ssid"; then
    if [ ! -f "$HOME_OVERRIDE_FILE" ] && is_running && [ ! -f "$HOME_PAUSED_FILE" ]; then
      log_msg "Домашняя Wi-Fi «$ssid» — обход приостановлен"
      stop >/dev/null 2>&1
      printf '%s' "$ssid" > "$HOME_PAUSED_FILE"
      update_description paused "$ssid"
    fi
  elif [ -f "$HOME_PAUSED_FILE" ]; then
    rm -f "$HOME_PAUSED_FILE"
    log_msg "Домашняя Wi-Fi больше не активна — обход возобновлён"
    start >/dev/null 2>&1 || log_msg "Не удалось возобновить обход после домашней Wi-Fi"
  fi
  rmdir "$STATE_DIR/home.lock" 2>/dev/null
  return 0
}

# On a network change apply the strategy saved for that network.
network_strategy_check() {
  [ "$NET_STRATEGY" = "1" ] || return 0
  is_running || return 0
  [ -f "$HOME_PAUSED_FILE" ] && return 0 # keep the strategy during a home pause

  local cur_net last_net saved cur_strat
  cur_net=$(current_network_key 2>/dev/null)
  [ -n "$cur_net" ] || return 0
  last_net=$(cat "$STATE_DIR/last_network" 2>/dev/null)

  if [ "$cur_net" != "$last_net" ]; then
    printf '%s' "$cur_net" > "$STATE_DIR/last_network"
    saved=$(load_net_strategy "$cur_net" 2>/dev/null)
    cur_strat=$(get_current_strategy 2>/dev/null)
    if [ -n "$saved" ] && [ "$saved" != "$cur_strat" ]; then
      log_msg "Смена сети на $(current_network_title 2>/dev/null || echo "$cur_net") — переключение на сохранённую стратегию «$saved»"
      if sh "$MODDIR/bin/nfqws2-ctl" set-strategy "$saved" >/dev/null 2>&1; then
        stop >/dev/null 2>&1
        start >/dev/null 2>&1
      fi
    fi
  fi
  return 0
}

# Manual start clears the pause; on a home network it also records the SSID as
# an override so the bypass keeps running there.
manual_start() {
  local ssid
  rm -f "$HOME_PAUSED_FILE"
  if [ "$HOME_WIFI" = "1" ] && ssid=$(active_ssid) && ssid_is_home "$ssid"; then
    printf '%s' "$ssid" > "$HOME_OVERRIDE_FILE"
  fi
  start
}

status_service() {
  if is_running; then
    echo "Служба NFQWS2 запущена (PID $(cat "$PIDFILE"))"
  else
    echo "Служба NFQWS2 остановлена"
  fi
}

case "$1" in
  start)              manual_start ;;
  stop)               rm -f "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE"; stop ;;
  home_check)         home_check; ensure_watchdog ;;
  net_check)          network_strategy_check ;;
  restart)            stop; start ;;
  reload)             reload_lists ;;
  status)             status_service ;;
  watchdog)           watchdog ;;
  netwatch)           netwatch ;;
  firewall_apply)     firewall_start ;;
  firewall_stop)      firewall_stop ;;
  dns_apply)          dns_start "настройки изменены" ;;
  dns_stop)           dns_stop ;;
  *)
    until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do sleep 3; done
    sleep 4
    [ -f "$CONFDIR/disable" ] && { log_msg "Найден $CONFDIR/disable — автозапуск пропущен"; exit 0; }
    rm -f "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE"
    rmdir "$STATE_DIR/home.lock" 2>/dev/null
    dns_boot_reset
    if [ "$AUTOSTART" = "1" ]; then
      ssid=$(active_ssid)
      if [ "$HOME_WIFI" = "1" ] && ssid_is_home "$ssid"; then
        log_msg "Домашняя Wi-Fi «$ssid» — автозапуск отложен до выхода из неё"
        printf '%s' "$ssid" > "$HOME_PAUSED_FILE"
        update_description paused "$ssid"
      else
        start || log_msg "Автозапуск не удался"
      fi
    else
      update_description stopped
    fi
    # DNS «без службы» поднимается и когда служба не стартовала
    dns_start "загрузка"
    ensure_watchdog
    ;;
esac
# Exit with the command status, not always 0: nfqws2-ctl passes it through,
# so a failed start is not read as success.
exit $?
