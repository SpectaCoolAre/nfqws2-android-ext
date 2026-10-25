#!/system/bin/sh

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
umask 077
. "$MODDIR/lib/common.sh"
load_conf

STARTED_FILE="$STATE_DIR/started_at"
STARTED_CS_FILE="$STATE_DIR/started_cs"

wait_for_process() { # <pid> <expected state: up|down> <timeout in 50 ms ticks>
  local pid="$1" want="$2" ticks="${3:-24}" i=0 alive
  while [ "$i" -lt "$ticks" ]; do
    kill -0 "$pid" 2>/dev/null
    alive=$?
    if [ "$want" = "up" ] && [ "$alive" -eq 0 ]; then return 0; fi
    if [ "$want" = "down" ] && [ "$alive" -ne 0 ]; then return 0; fi
    sleep 0.05
    i=$((i + 1))
  done
  [ "$want" = "up" ] && kill -0 "$pid" 2>/dev/null
  [ "$want" = "down" ] && ! kill -0 "$pid" 2>/dev/null
}

# both start() failures end with the log tail; keep it in one place
start_failed() {
  log_msg "$1"
  log_msg "Последние строки лога:"
  tail -n 8 "$NFQWS_LOG" 2>/dev/null | while IFS= read -r l; do log_msg "  $l"; done
  update_description stopped
  # правила без живого демона гнали бы трафик в очередь без слушателя
  firewall_stop
}

# watchdog/netwatch: auto-restart, home Wi-Fi pause, per-network strategies.
# Наблюдатели живут, только пока есть за чем следить: «Контроль работы» — пока
# служба должна работать (остановленную вручную сторожить незачем), пауза в
# домашнем Wi‑Fi и при VPN — всегда (они же службу и возобновляют), DNS — пока
# включён (пауза при VPN, перезапуск при смене сети), умный режим — пока служба
# должна работать (ему нужно знать, в какой он сети). Ничего из этого —
# наблюдатели сами завершаются на следующем шаге, запуск службы поднимет снова
# Белые списки проверяются, пока обход должен работать или стоит на паузе
wl_wanted() { [ "$WL_PAUSE" = "1" ] && { [ -f "$DESIRED_FILE" ] || [ -f "$HOME_PAUSED_FILE" ]; }; }
watchers_wanted() {
  { [ -f "$DESIRED_FILE" ] && { [ "$WATCHDOG" = "1" ] || smart_active; }; } || [ "$HOME_WIFI" = "1" ] || [ "$VPN_PAUSE" = "1" ] || dns_enabled
}

# Запуск под замком: netwatch, watchdog, загрузка и WebUI могут позвать start
# одновременно, и два демона сели бы на одну очередь (из оригинала, caa8be3).
# Второй ждёт до 10 с и видит уже запущенную службу. Замок старше двух минут —
# остаток убитого процесса.
start() {
  if is_running; then
    echo "Служба nfqws2 уже запущена (PID $(cat "$PIDFILE"))"
    return 0
  fi
  local lock="$STATE_DIR/start.lock" own=0 i=0 rc=0
  [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
  while [ "$i" -lt 50 ]; do
    mkdir "$lock" 2>/dev/null && { own=1; break; }
    sleep 0.2; i=$((i + 1))
  done
  if is_running; then
    echo "Служба nfqws2 уже запущена (PID $(cat "$PIDFILE"))"
  elif [ "$own" = 1 ]; then
    _start || rc=$?
  else
    log_msg "Запуск пропущен: другой запуск не завершился за 10 с"
    rc=1
  fi
  [ "$own" = 1 ] && rmdir "$lock" 2>/dev/null
  return "$rc"
}

_start() {
  if [ ! -x "$NFQWS_BIN" ]; then
    chmod 0755 "$NFQWS_BIN" 2>/dev/null
    [ -x "$NFQWS_BIN" ] || { log_msg "Ошибка: нет исполняемого $NFQWS_BIN"; return 1; }
  fi
  local err
  err=$(validate_args_conf) || { log_msg "$err"; return 1; }

  # DNS — первым (если включён): обход геоблока DNS-профилями должен работать
  # раньше, чем пойдёт трафик через обход. Повторный вызов ничего не меняет
  dns_start "запуск службы"
  log_msg "Запуск nfqws2..."
  kernel_modules
  rotate_logs start

  local args
  args=$(_startup_args)
  printf '%s\n' "$args" > "$ARGS_FILE"
  # умному режиму — в какой он сети, до первого пакета, и имена его вариантов
  # для журнала
  smart_net_update
  sed -n 's/^#@//p' "$STRATEGIES_DIR/smart.conf" > "$STATE_DIR/smart_names" 2>/dev/null
  smart_pool_sync

  local dry_err
  if dry_run_known "$args"; then
    :   # эти аргументы уже прошли проверку (обычно — при выборе стратегии)
  elif ! dry_err=$(dry_run_check "$args"); then
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

  # Демон пишет PID-файл после fork — ждём его опросом (до ~1.2 с), а не
  # фиксированной паузой; затем ещё 0.2 с: упавший сразу после старта демон
  # (не тот интерфейс, занятая очередь) — тоже неудачный запуск.
  local pid="" i=0
  while [ "$i" -lt 24 ]; do
    [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] || pid=$(pidof nfqws2 2>/dev/null | awk '{print $1}')
    [ -n "$pid" ] && break
    sleep 0.05; i=$((i + 1))
  done
  [ -n "$pid" ] && wait_for_process "$pid" up 4 && sleep 0.2

  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    start_failed "Ошибка: nfqws2 не запустился."
    return 1
  fi

  echo "$pid" > "$PIDFILE"
  protect_process "$pid"
  date +%s > "$STARTED_FILE"
  # Время работы считается по часам с загрузки (/proc/uptime): перевод часов
  # и смена часового пояса его не трогают
  awk '{ printf "%d\n", $1 * 100 }' /proc/uptime > "$STARTED_CS_FILE" 2>/dev/null

  # firewall_start can return 0 with no rule in place; without the POSTROUTING
  # jump the daemon runs but nothing reaches NFQUEUE
  firewall_start
  if ! firewall_ok; then
    log_msg "Ошибка: правила iptables не применились — трафик не перехватывается"
    # a daemon without rules is useless and a stale pidfile would claim it runs
    kill -TERM "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    start_failed "Ошибка: правила iptables не применились."
    return 1
  fi

  system_config
  echo 1 > "$DESIRED_FILE"
  log_msg "nfqws2 запущен (PID $pid, Native Daemon)"
  update_description running
  ensure_watchdog
  return 0
}

stop() {
  rm -f "$DESIRED_FILE" "$STARTED_FILE" "$STARTED_CS_FILE"
  release_wakelock
  # помощник умного режима — вместе со службой, его правила — здесь же: иначе
  # умирающий помощник мог бы снять цепочку, которую уже завёл новый
  if [ -f "$SK_PIDFILE" ]; then
    kill -KILL "$(cat "$SK_PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$SK_PIDFILE"
    smartkill_chain del
  fi
  firewall_stop
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      wait_for_process "$pid" down 16 || kill -KILL "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
  fi
  # оставшиеся демоны (двойной запуск, потерянный PID-файл); -x — ровно nfqws2
  if pidof nfqws2 >/dev/null 2>&1; then
    pkill -9 -x nfqws2 2>/dev/null || kill -9 $(pidof nfqws2) 2>/dev/null
  fi

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
  # SIGHUP перечитывает содержимое списков, но не состав профилей. А профили
  # исключений и IP-списка есть, только пока их список не пуст (пустой список
  # в профиле nfqws2 значит «подходит всё»): список стал пустым или перестал
  # им быть — нужен перезапуск с новыми аргументами
  if [ "$(_startup_args)" != "$(cat "$ARGS_FILE" 2>/dev/null)" ]; then
    log_msg "Списки: состав профилей изменился — перезапуск nfqws2"
    stop; start
    return
  fi
  kill -HUP "$(cat "$PIDFILE")" 2>/dev/null || { log_msg "Списки не перечитаны: SIGHUP не доставлен"; return 1; }
  log_msg "Списки перечитаны (SIGHUP)"
}

# Start a helper unless it already runs. Returns 0 when it was just started,
# 1 when it is running or the precondition failed. ensure_watchdog uses this
# to raise netwatch only alongside the watchdog.
ensure_helper() {
  local pf="$1" sub="$2"; shift 2
  # условие запуска — молча: «command -v ip» печатал бы путь в вывод start
  [ $# -eq 0 ] || "$@" >/dev/null 2>&1 || return 1
  if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
    return 1
  fi
  (
    exec 0</dev/null
    exec >/dev/null 2>&1
    if command -v setsid >/dev/null 2>&1; then
      exec setsid sh "$MODDIR/service.sh" "$sub"
    else
      exec sh "$MODDIR/service.sh" "$sub"
    fi
  ) &
  # PID пишет и сам помощник, но только после загрузки библиотек и конфига;
  # второй ensure_watchdog в этот промежуток поднял бы ещё одну копию.
  # exec сохраняет PID, так что $! — это и есть помощник
  echo $! > "$pf"
  return 0
}

ensure_watchdog() {
  # обрыв застрявших соединений — пока работает умный режим
  is_running && ensure_helper "$SK_PIDFILE" smartkill smart_active
  ensure_helper "$WL_PIDFILE" wlwatch wl_wanted
  watchers_wanted || return 0
  ensure_helper "$WD_PIDFILE" watchdog || return 0
  ensure_netwatch
}

# Умный режим замечает соединения, которые DPI оборвал посреди работы (телефон
# переотправляет данные, ответа нет), и пишет их в state/smart_kill. Здесь они
# обрываются по-настоящему: REJECT с tcp-reset в OUTPUT отвечает сокету телефона
# сбросом, и приложение сразу открывает новое соединение — уже на другом
# варианте обхода, — а не ждёт своего таймаута. Правила живут 15 секунд: старое
# соединение к тому времени закрыто. Помощник спит по 3 секунды и сам выходит,
# когда служба остановлена или выбрана другая стратегия
SK_CHAIN=nfqws_smartkill
smartkill_chain() { # <add|del>
  local c
  for c in iptables ip6tables; do
    command -v "$c" >/dev/null 2>&1 || continue
    if [ "$1" = add ]; then
      $c -w -t filter -N $SK_CHAIN 2>/dev/null
      $c -w -t filter -C OUTPUT -j $SK_CHAIN 2>/dev/null || $c -w -t filter -I OUTPUT 1 -j $SK_CHAIN 2>/dev/null
    else
      while $c -w -t filter -D OUTPUT -j $SK_CHAIN 2>/dev/null; do :; done
      $c -w -t filter -F $SK_CHAIN 2>/dev/null
      $c -w -t filter -X $SK_CHAIN 2>/dev/null
    fi
  done
}
smartkill() {
  echo $$ > "$SK_PIDFILE"
  protect_process
  trap 'smartkill_exit; exit 0' TERM INT HUP
  local w="$SMART_KILL_FILE.work" ver ip lp c up flush=0 n learn_at=0 lp_pid= every
  # заявки прошлого запуска — до того, как цепочка заработает: их порты уже
  # могли достаться другим соединениям
  rm -f "$SMART_KILL_FILE"
  smartkill_chain add
  while :; do
    sleep 3
    conf_refresh
    is_running && smart_active || break
    read -r up _ < /proc/uptime; up=${up%.*}
    # фоновое обучение: раз в SMART_LEARN_EVERY секунд — один случайный сайт.
    # Первый — через минуту после запуска, пока служба не освоилась
    [ "$learn_at" = 0 ] && learn_at=$((up + 60))
    # идёт игра-пасхалка — сайт раз в SMART_TURBO_EVERY секунд
    every=$SMART_LEARN_EVERY
    if [ -f "$SMART_TURBO_FILE" ] && [ "$(cat "$SMART_TURBO_FILE" 2>/dev/null)" -gt "$(date +%s)" ] 2>/dev/null; then
      every=$SMART_TURBO_EVERY
      [ "$learn_at" -gt $((up + every)) ] && learn_at=$((up + every))
    fi
    if [ "${SMART_LEARN:-1}" = 1 ] && [ "$up" -ge "$learn_at" ]; then
      learn_at=$((up + every))
      if [ -z "$lp_pid" ] || ! kill -0 "$lp_pid" 2>/dev/null; then
        sh "$MODDIR/bin/nfqws2-ctl" smart-learn-once </dev/null >/dev/null 2>&1 &
        lp_pid=$!
      fi
    fi
    if [ -s "$SMART_KILL_FILE" ]; then
      mv -f "$SMART_KILL_FILE" "$w" 2>/dev/null
      n=0
      while read -r ver ip lp; do
        case "$ver" in 4) c=iptables ;; 6) c=ip6tables ;; *) continue ;; esac
        case "$ip" in ''|*[!0-9a-fA-F.:]*) continue ;; esac
        case "$lp" in ''|*[!0-9]*) continue ;; esac
        $c -w -t filter -A $SK_CHAIN -p tcp -d "$ip" --sport "$lp" -j REJECT --reject-with tcp-reset 2>/dev/null && n=$((n + 1))
      done < "$w"
      rm -f "$w"
      [ "$n" -gt 0 ] && flush=$((up + 15))
    fi
    # в журнал службы обрывы не пишутся: каждый — в журнале умного режима
    if [ "$flush" -gt 0 ] && [ "$up" -ge "$flush" ]; then
      iptables -w -t filter -F $SK_CHAIN 2>/dev/null; ip6tables -w -t filter -F $SK_CHAIN 2>/dev/null
      flush=0
    fi
  done
  smartkill_chain del
  smartkill_exit
}
# Белые списки у мобильного оператора (wl_probe в lib/common.sh): пока они
# включены, обход на паузе (причина @wl), как при VPN. Проверка — только в
# мобильной сети: раз в 5 минут, сразу при смене сети и раз в 2 минуты, пока
# пауза. Белые списки — только по двум проверкам подряд с промежутком 20 с
# (одна неудачная могла быть случайностью); обычный интернет — по одной
wlwatch() {
  echo $$ > "$WL_PIDFILE"
  protect_process
  trap 'wlwatch_exit; exit 0' TERM INT HUP
  local up next=0 pend=0 net last="" res
  while :; do
    sleep 5
    conf_refresh
    wl_wanted || break
    read -r up _ < /proc/uptime; up=${up%.*}
    net=$(cat "$SMART_NET_FILE" 2>/dev/null)
    [ "$net" != "$last" ] && { last="$net"; next=0; pend=0; }
    [ "$up" -ge "$next" ] || continue
    if on_wifi || vpn_active; then
      # Wi‑Fi или VPN: белые списки мобильной сети тут ни при чём
      [ -f "$WL_FILE" ] && { rm -f "$WL_FILE"; sh "$MODDIR/service.sh" home_check >/dev/null 2>&1; }
      pend=0; next=$((up + 60)); continue
    fi
    res=$(wl_probe)
    case "$res" in
      whitelist)
        if [ -f "$WL_FILE" ]; then next=$((up + 120))
        elif [ "$pend" -gt 0 ] && [ $((up - pend)) -ge 20 ]; then
          date +%s > "$WL_FILE"; pend=0; next=$((up + 120))
          sh "$MODDIR/service.sh" home_check >/dev/null 2>&1
        else
          [ "$pend" -gt 0 ] || pend=$up
          next=$((up + 20))
        fi ;;
      normal)
        pend=0; next=$((up + 300))
        [ -f "$WL_FILE" ] && { rm -f "$WL_FILE"; sh "$MODDIR/service.sh" home_check >/dev/null 2>&1; } ;;
      *) pend=0; next=$((up + 60)) ;;
    esac
  done
  # выключили в настройках — белые списки забываем (пауза снимается); помощник
  # просто вышел вместе со службой — отметка остаётся: новый проверит сразу
  if [ "$WL_PAUSE" != "1" ] && [ -f "$WL_FILE" ]; then rm -f "$WL_FILE"; sh "$MODDIR/service.sh" home_check >/dev/null 2>&1; fi
  wlwatch_exit
}
wlwatch_exit() {
  [ "$(cat "$WL_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$WL_PIDFILE"
  rm -f "$STATE_DIR/conf_seen.$$"
}
smartkill_exit() {
  [ "$(cat "$SK_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$SK_PIDFILE"
  rm -f "$STATE_DIR/conf_seen.$$"
}

# Перечитать конфиг, только если он менялся с прошлого раза. netwatch опрашивает
# раз в секунду всю ночь: load_conf каждый тик — это лишние awk и чтение файлов.
# Метка — свой файл у каждого процесса; -nt есть в dash, mksh и bash
conf_refresh() {
  local st="$STATE_DIR/conf_seen.$$"
  if [ ! -f "$st" ] || [ "$CONFFILE" -nt "$st" ]; then
    : > "$st"
    load_conf >/dev/null 2>&1
  fi
}

# Rebuild rules on events, not on a timer. Routers use a netfilter.d firmware
# hook for this; ip monitor is the Android equivalent. Watchdog is the
# fallback where ip monitor is unsupported.
ensure_netwatch() { # зовётся только из ensure_watchdog, после watchers_wanted
  ensure_helper "$WN_PIDFILE" netwatch command -v ip
  return 0
}

# Подпись сети: через какой интерфейс идёт трафик наружу и есть ли VPN. Смена —
# повод сразу перезапустить dnsproxy: его соединения к DoH/DoT-серверам остались
# привязаны к прежней сети, и запросы ждали бы, пока они отвалятся по таймауту.
net_signature() {
  local dev
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  # Wi‑Fi или мобильная сеть под VPN: маршрут один (tun), а сеть под ним разная
  printf '%s|%s|%s' "$dev" "$(vpn_active && echo vpn)" "$(on_wifi && echo wifi)"
}

netwatch() {
  echo $$ > "$WN_PIDFILE"
  protect_process
  command -v ip >/dev/null 2>&1 || { rm -f "$WN_PIDFILE"; return 0; }

  # Без опроса: процесс спит в wait, пока ip monitor не сообщит о смене
  # маршрутов или интерфейсов. Читатель событий шлёт USR1, сон прерывается,
  # и через секунду тишины (одна смена сети — пачка событий) правила, DNS и
  # пауза пересчитываются. Без событий — пробуждение раз в минуту: перечитать
  # конфиг, выйти, если наблюдатели больше не нужны, поднять упавший ip
  # monitor. Раньше файл событий проверялся каждую секунду — два запуска
  # внешних программ в секунду, 170 тысяч в сутки, и процессор не засыпал.
  local wake=0 mon="" reader="" sp="" netsig sig recheck=0 backoff=2 started up me=$$
  local fifo="$STATE_DIR/netwatch.fifo"
  netsig=$(net_signature)
  trap 'wake=1' USR1
  # ip monitor и читатель — свои PID (через FIFO, не конвейер в подоболочке):
  # убитый извне netwatch забирает их с собой, сирот не остаётся
  trap 'kill -TERM "$mon" "$reader" "$sp" 2>/dev/null; rm -f "$WN_PIDFILE" "$fifo" "$STATE_DIR/conf_seen.$$"; exit 0' TERM INT HUP
  # Первая перепроверка — через 30 с после старта: при загрузке сеть ещё
  # устанавливается, и её смена до запуска ip monitor не дала бы события
  read -r up _ < /proc/uptime; recheck=$(( ${up%.*} + 30 ))
  while :; do
    if [ -z "$mon" ] || ! kill -0 "$mon" 2>/dev/null; then
      # ip monitor упал или не поддерживается: не перезапускать в цикле
      if [ -n "$mon" ]; then
        kill -TERM "$reader" 2>/dev/null
        read -r up _ < /proc/uptime
        if [ $(( ${up%.*} - started )) -lt 10 ]; then
          sleep "$backoff"; [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
        else backoff=2; fi
      fi
      rm -f "$fifo"; mkfifo "$fifo" 2>/dev/null || { sleep 60; continue; }
      while IFS= read -r _; do kill -USR1 "$me" 2>/dev/null || exit 0; done < "$fifo" &
      reader=$!
      ip monitor route link > "$fifo" 2>/dev/null &
      mon=$!
      read -r up _ < /proc/uptime; started=${up%.*}
    fi
    if [ "$wake" = 0 ]; then
      # Сон до события или до минуты. Сигнал, пришедший между проверкой и
      # wait, ловится сразу после запуска sleep — trap выполняется между командами
      sleep 60 & sp=$!
      [ "$wake" = 1 ] || wait "$sp"
      kill "$sp" 2>/dev/null; sp=""
    fi
    conf_refresh
    watchers_wanted || break
    if [ "$wake" = 1 ]; then
      # пачка событий одной смены сети: ждём секунду тишины
      while [ "$wake" = 1 ]; do wake=0; sleep 1; done
      # DNS — первым: пока он перезапускается, правила перехвата на месте, и
      # запросы не уходят к DNS оператора. Сеть или VPN сменились — dnsproxy
      # перезапускается целиком (или останавливается на время VPN), иначе —
      # только сверка конфига (DNS сети)
      sig=$(net_signature)
      if dns_enabled; then
        if [ "$sig" != "$netsig" ]; then dns_start "смена сети" force
        else dns_start "смена сети"; fi
      fi
      netsig="$sig"
      # умный режим переключается на выученное для новой сети сам, без перезапуска
      smart_net_update
      if [ -f "$DESIRED_FILE" ] && is_running; then
        log_msg "netwatch: сеть изменилась (ip monitor) — пересобираю правила"
        firewall_start
      fi
      home_check
      read -r up _ < /proc/uptime; recheck=$(( ${up%.*} + 30 ))
      continue
    fi
    # Контрольная перепроверка через 30 с после смены сети: в момент события
    # Wi‑Fi бывает ещё в переходном состоянии, и решение о паузе могло
    # остаться неверным. Сон до минуты её не задерживает дольше 60 с
    if [ "$recheck" -gt 0 ]; then
      read -r up _ < /proc/uptime
      if [ "${up%.*}" -ge "$recheck" ]; then recheck=0; home_check; fi
    fi
  done
  kill -TERM "$mon" "$reader" 2>/dev/null
  rm -f "$WN_PIDFILE" "$fifo" "$STATE_DIR/conf_seen.$$"
}

watchdog() {
  echo $$ > "$WD_PIDFILE"
  # убитый извне — без PID-файла, иначе следующий запуск верил бы мёртвому PID (оригинал, 00c1a16)
  trap 'rm -f "$WD_PIDFILE"; exit 0' INT TERM
  protect_process
  local fails=0 tick=0 dpid
  while :; do
    sleep 20
    load_conf >/dev/null 2>&1
    watchers_wanted || break
    tick=$((tick + 1))
    # once a minute: cmd wifi is the expensive part
    { [ "$HOME_WIFI" = "1" ] || [ "$VPN_PAUSE" = "1" ]; } && [ $((tick % 3)) -eq 0 ] && home_check
    # сеть для умного режима — и там, где ip monitor не работает
    [ $((tick % 3)) -eq 0 ] && is_running && smart_net_update
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
      if [ "$fails" -ge 5 ]; then
        log_msg "watchdog: частые сбои службы (#$fails), пауза 60s..."
        sleep 60
      else
        sleep 2
      fi
      continue
    fi

    # survived a full cycle: reset the fail counter
    fails=0

    # Защита от LMK: периодически поддерживаем иммунитет демона и вотчдога
    dpid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$dpid" ] && protect_process "$dpid"
    protect_process

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
  # Пауза — домашний Wi‑Fi (в файле SSID) или VPN (метка @vpn). Ручной запуск
  # оставляет то же значение в override: оно действует, пока причина не уйдёт.
  local ssid="" vpn=0 wl=0 ovr="" want=""
  [ "$HOME_WIFI" = "1" ] && ssid=$(active_ssid)
  [ "$VPN_PAUSE" = "1" ] && vpn_active && vpn=1
  [ "$WL_PAUSE" = "1" ] && [ -f "$WL_FILE" ] && wl=1
  [ -f "$HOME_OVERRIDE_FILE" ] && ovr=$(cat "$HOME_OVERRIDE_FILE" 2>/dev/null)
  case "$ovr" in
    '') ;;
    @vpn) [ "$vpn" = 1 ] || { rm -f "$HOME_OVERRIDE_FILE"; ovr=""; } ;;
    @wl) [ "$wl" = 1 ] || { rm -f "$HOME_OVERRIDE_FILE"; ovr=""; } ;;
    *) [ "$ovr" = "$ssid" ] || { rm -f "$HOME_OVERRIDE_FILE"; ovr=""; } ;;
  esac
  # Телефон в домашнем Wi‑Fi (для паузы DNS дома — от ручного запуска обхода
  # не зависит). Сменилось — DNS заново решает, работать ли
  local athome=""
  [ "$HOME_WIFI" = "1" ] && ssid_is_home "$ssid" && athome="$ssid"
  if [ "$athome" != "$(cat "$HOME_AT_FILE" 2>/dev/null)" ]; then
    if [ -n "$athome" ]; then printf '%s' "$athome" > "$HOME_AT_FILE"; else rm -f "$HOME_AT_FILE"; fi
    [ -f "$DNS_HOME_FILE" ] && dns_enabled && dns_start "домашний Wi‑Fi"
  fi
  if [ "$vpn" = 1 ] && [ "$ovr" != "@vpn" ]; then
    want="@vpn"
  elif [ "$wl" = 1 ] && [ "$ovr" != "@wl" ]; then
    want="@wl"
  elif [ "$HOME_WIFI" = "1" ] && ssid_is_home "$ssid" && [ "$ovr" != "$ssid" ]; then
    want="$ssid"
  fi
  if [ -n "$want" ]; then
    if is_running && [ ! -f "$HOME_PAUSED_FILE" ]; then
      case "$want" in
        @vpn) log_msg "Включён VPN — обход приостановлен" ;;
        @wl)  log_msg "У оператора включены белые списки — обход приостановлен" ;;
        *)    log_msg "Домашний Wi-Fi «$want» — обход приостановлен" ;;
      esac
      stop >/dev/null 2>&1
      printf '%s' "$want" > "$HOME_PAUSED_FILE"
      update_description paused "$want"
    elif [ -f "$HOME_PAUSED_FILE" ] && [ "$(cat "$HOME_PAUSED_FILE" 2>/dev/null)" != "$want" ]; then
      # причина паузы сменилась (VPN выключили дома) — пауза остаётся
      printf '%s' "$want" > "$HOME_PAUSED_FILE"
      update_description paused "$want"
    fi
  elif [ -f "$HOME_PAUSED_FILE" ]; then
    case "$(cat "$HOME_PAUSED_FILE" 2>/dev/null)" in
      @vpn) log_msg "VPN выключен — обход возобновлён" ;;
      @wl)  log_msg "Белые списки выключены — обход возобновлён" ;;
      *)    log_msg "Домашний Wi-Fi больше не активен — обход возобновлён" ;;
    esac
    rm -f "$HOME_PAUSED_FILE"
    start >/dev/null 2>&1 || log_msg "Не удалось возобновить обход после паузы"
  fi
  rmdir "$STATE_DIR/home.lock" 2>/dev/null
  return 0
}

# Manual start clears the pause; on a home network it also records the SSID as
# an override so the bypass keeps running there.
manual_start() {
  local ssid
  rm -f "$HOME_PAUSED_FILE"
  if [ "$VPN_PAUSE" = "1" ] && vpn_active; then
    printf '%s' "@vpn" > "$HOME_OVERRIDE_FILE"
  elif [ "$WL_PAUSE" = "1" ] && [ -f "$WL_FILE" ]; then
    # запущен вручную при белых списках — пока они не кончатся, не мешаем
    printf '%s' "@wl" > "$HOME_OVERRIDE_FILE"
  elif [ "$HOME_WIFI" = "1" ] && ssid=$(active_ssid) && ssid_is_home "$ssid"; then
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
  # «Состояние» → оттянуть вниз: сеть, VPN и DNS — заново, наблюдатели — на месте
  net_recheck)        dns_enabled && dns_start "проверка сети по запросу"; home_check; ensure_watchdog ;;
  restart)            stop; start ;;
  reload)             reload_lists ;;
  status)             status_service ;;
  ensure_watchdog)    ensure_watchdog ;;
  watchdog)           watchdog ;;
  netwatch)           netwatch ;;
  smartkill)          smartkill ;;
  wlwatch)            wlwatch ;;
  firewall_apply)     firewall_start ;;
  firewall_stop)      firewall_stop ;;
  dns_apply)          dns_start "настройки изменены" ;;
  dns_stop)           dns_stop ;;
  hosts_off)          hosts_umount ;;
  # boot-completed.sh: поднять службу, если она должна работать и не на
  # паузе дома. Не manual_start: тот дома запомнил бы «запущено вручную».
  boot_recover)       [ -f "$HOME_PAUSED_FILE" ] || start ;;
  *)
    # Метка «загрузочный запуск закончен» — её ждёт boot-completed.sh
    rm -f "$STATE_DIR/boot_done"
    # Состояние прошлой загрузки: каталог на /data переживает перезагрузку, а
    # номера PID — нет. Старый PID мог достаться чужому процессу, и тогда
    # служба «уже запущена», наблюдатель «уже работает», а stop убил бы чужое.
    # desired — «служба должна работать»: без сброса boot-completed поднимал бы
    # её и при выключенном автозапуске
    rm -f "$PIDFILE" "$WD_PIDFILE" "$WN_PIDFILE" "$SK_PIDFILE" "$WL_PIDFILE" "$WL_FILE" "$DESIRED_FILE" "$STARTED_FILE" "$STARTED_CS_FILE"
    rm -f "$STATE_DIR"/conf_seen.*
    rmdir "$STATE_DIR/start.lock" 2>/dev/null
    until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do sleep 3; done
    sleep 4
    [ -f "$CONFDIR/disable" ] && { log_msg "Найден $CONFDIR/disable — автозапуск пропущен"; : > "$STATE_DIR/boot_done"; exit 0; }
    rm -f "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE" "$HOME_AT_FILE"
    rmdir "$STATE_DIR/home.lock" 2>/dev/null
    dns_boot_reset
    # Пауза DNS дома: SSID нужен до запуска DNS (два вызова Java — только
    # когда пауза включена)
    if [ -f "$DNS_HOME_FILE" ] && [ "$HOME_WIFI" = "1" ] && dns_enabled && ssid=$(active_ssid) && ssid_is_home "$ssid"; then
      printf '%s' "$ssid" > "$HOME_AT_FILE"
    fi
    # DNS — первым: пока он не поднят, первые запросы приложений уходят мимо
    # профилей (геоблок), и ответы остаются в кэше. От службы он не зависит
    dns_start "загрузка"
    if [ "$AUTOSTART" = "1" ]; then
      if [ "$VPN_PAUSE" = "1" ] && vpn_active; then
        log_msg "Включён VPN — автозапуск отложен до его отключения"
        printf '%s' "@vpn" > "$HOME_PAUSED_FILE"
        update_description paused "@vpn"
      # SSID — только когда пауза дома включена: это два вызова Java на загрузке
      elif [ "$HOME_WIFI" = "1" ] && ssid=$(active_ssid) && ssid_is_home "$ssid"; then
        log_msg "Домашний Wi-Fi «$ssid» — автозапуск отложен до выхода из него"
        printf '%s' "$ssid" > "$HOME_PAUSED_FILE"
        update_description paused "$ssid"
      else
        start || log_msg "Автозапуск не удался"
      fi
    else
      update_description stopped
    fi
    hosts_boot
    ensure_watchdog
    : > "$STATE_DIR/boot_done"
    ;;
esac
# Exit with the command status, not always 0: nfqws2-ctl passes it through,
# so a failed start is not read as success.
exit $?
