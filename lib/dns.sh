#!/system/bin/sh
# nfqws2-android-ext · lib/dns.sh — DNS по профилям.
#
# Как в Keenetic: у профиля есть DNS-серверы (обычный, TCP, DoH, DoH3, DoT, DoQ,
# DNSCrypt) и домены, запросы к этим доменам (и их поддоменам) уходят на его
# серверы, остальные — на «DNS по умолчанию». Резолвит AdGuard dnsproxy
# ($MODDIR/bin/dnsproxy), а DNS-запросы телефона заворачиваются к нему правилом
# в таблице nat.
#
# Подключается из конца lib/common.sh. Служба зовёт dns_start / dns_stop /
# dns_check, nfqws2-ctl — команды dns-* (dns_ctl). Без bin/dnsproxy (его
# кладёт в архив release.yml; в тестах и в оригинальном nfqws2-android его нет)
# функция считается выключенной, что бы ни лежало в $CONFDIR/dns.
#
# Почему без зацикливания. Системный резолвер Android (netd) ставит на свои
# DNS-сокеты fwmark с номером сети в младших 16 битах. dnsproxy — статический
# Go-бинарник, bionic он не использует, и его сокеты метки не получают. Правило
# перехвата берёт только помеченные пакеты, поэтому собственные запросы
# dnsproxy (к серверам на порт 53 и bootstrap) уходят в сеть напрямую.

DNS_DIR="$CONFDIR/dns"
DNS_PROFILES_DIR="$DNS_DIR/profiles"
DNS_ENABLED_FILE="$DNS_DIR/enabled"      # есть файл — функция включена
DNS_DEFAULT_FILE="$DNS_DIR/default"      # net | id профиля
DNS_PRESETS_DIR="$MODDIR/defaults/dns-presets"
DNS_BIN="$MODDIR/bin/dnsproxy"
DNS_RUN_DIR="$STATE_DIR/dns"
DNS_PIDFILE="$STATE_DIR/dnsproxy.pid"
DNS_LOG="$LOG_DIR/dns.log"
DNS_PORT=15353
DNS_CHAIN=nfqws_dns          # nat OUTPUT: перехват в dnsproxy
DNS_CHAIN6F=nfqws_dns6       # filter OUTPUT (IPv6 без nat): отказ, резолвер уйдёт на IPv4

# Пределы. Серверов в профиле — сколько разумно опрашивать по очереди;
# доменов — чтобы строка правил dnsproxy и экран WebUI оставались подъёмными.
DNS_MAX_PROFILES=32
DNS_MAX_SERVERS=8
DNS_MAX_DOMAINS=1000

# Резервные публичные DNS: bootstrap для имён DoH/DoT-серверов и запасной
# вариант, когда DNS сети не определился или не отвечает.
DNS_PUBLIC="77.88.8.8 1.1.1.1 8.8.8.8"

dns_enabled() { [ -f "$DNS_ENABLED_FILE" ] && [ -f "$DNS_BIN" ]; }

dns_default() {
  local d=""
  [ -f "$DNS_DEFAULT_FILE" ] && IFS= read -r d < "$DNS_DEFAULT_FILE"
  case "$d" in ''|*[!a-z0-9_-]*) d=net ;; esac
  printf '%s' "$d"
}

# Первый запуск: каталоги и пресеты. Пресеты кладутся обычными профилями,
# выключенными: дальше пользователь меняет и удаляет их как свои.
dns_init() {
  [ -d "$DNS_PROFILES_DIR" ] && return 0
  mkdir -p "$DNS_PROFILES_DIR" "$DNS_RUN_DIR" 2>/dev/null || return 1
  local f id
  for f in "$DNS_PRESETS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id="${f##*/}"; id="${id%.conf}"
    sed 's/^ENABLED=.*/ENABLED=0/' "$f" > "$DNS_PROFILES_DIR/$id.conf"
  done
  [ -f "$DNS_DEFAULT_FILE" ] || echo net > "$DNS_DEFAULT_FILE"
  return 0
}

dns_id_ok() { case "$1" in ''|*[!a-z0-9_-]*) return 1 ;; esac; [ "${#1}" -le 40 ]; }

# ---------------------------------------------------------------- проверка ввода
# Адрес сервера — ровно в синтаксисе dnsproxy, тип определяется схемой:
#   1.1.1.1  1.1.1.1:53  [2606:4700::1111]:53  udp://…   обычный DNS
#   tcp://host[:port]       DNS по TCP
#   https://host[:port]/path   DoH        h3://…  DoH по HTTP/3
#   tls://host[:port]       DoT           quic://host[:port]  DoQ
#   sdns://…                DNS-штамп (DNSCrypt и др.)
dns_server_ok() {
  printf '%s' "$1" | grep -qE \
    -e '^(https|h3)://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._~%/?=&+-]*)?$' \
    -e '^(tls|quic|tcp|udp)://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?$' \
    -e '^sdns://[A-Za-z0-9_=-]+$' \
    -e '^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?$' \
    -e '^\[[0-9A-Fa-f:.]+(%[A-Za-z0-9_.-]+)?\](:[0-9]{1,5})?$' \
    -e '^[0-9A-Fa-f]*:[0-9A-Fa-f:.]+(%[A-Za-z0-9_.-]+)?$'
}

# Домен в виде, в котором его сравнивает dnsproxy: строчные буквы, без точки в
# конце. Кириллические имена WebUI переводит в punycode заранее.
dns_domain_ok() {
  [ "${#1}" -le 253 ] || return 1
  printf '%s' "$1" | grep -qE '^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?)*$'
}

# Профиль из WebUI (stdin) -> нормализованный файл (stdout). Строки:
#   NAME=…  DESC=… (необязательно)  ENABLED=0|1  SERVER=…  DOMAIN=…
# Неизвестные строки и пустые значения отбрасываются, повторы — тоже.
# Ошибка ввода — сообщение в stderr и код 1, файл тогда не пишется.
dns_profile_normalize() {
  awk -v maxs="$DNS_MAX_SERVERS" -v maxd="$DNS_MAX_DOMAINS" '
    { sub(/\r$/, "") }
    /^NAME=/    { name = substr($0, 6); next }
    /^DESC=/    { desc = substr($0, 6); next }
    /^ENABLED=/ { en = (substr($0, 9) == "1") ? 1 : 0; next }
    /^SERVER=/  { v = substr($0, 8); if (v != "" && !(v in s)) { s[v] = 1; so[++ns] = v }; next }
    /^DOMAIN=/  { v = tolower(substr($0, 8)); sub(/^\*?\./, "", v); sub(/\.$/, "", v)
                  if (v != "" && !(v in d)) { d[v] = 1; dor[++nd] = v }; next }
    END {
      gsub(/[\001-\037]/, "", name); sub(/^[ \t]+/, "", name); sub(/[ \t]+$/, "", name)
      if (name == "") { print "Нужно название профиля" > "/dev/stderr"; exit 1 }
      if (length(name) > 60) name = substr(name, 1, 60)
      if (ns > maxs) { printf "В профиле не больше %d серверов\n", maxs > "/dev/stderr"; exit 1 }
      if (nd > maxd) { printf "В профиле не больше %d доменов\n", maxd > "/dev/stderr"; exit 1 }
      gsub(/[\001-\037]/, "", desc); if (length(desc) > 200) desc = substr(desc, 1, 200)
      print "NAME=" name
      if (desc != "") print "DESC=" desc
      print "ENABLED=" (en ? 1 : 0)
      for (i = 1; i <= ns; i++) print "SERVER=" so[i]
      for (i = 1; i <= nd; i++) print "DOMAIN=" dor[i]
    }'
}

dns_profile_check() { # <файл> — каждый сервер и домен по отдельности
  local l v bad=0
  while IFS= read -r l; do
    case "$l" in
      SERVER=*) v="${l#SERVER=}"; dns_server_ok "$v" || { echo "Неверный адрес сервера: $v" >&2; bad=1; } ;;
      DOMAIN=*) v="${l#DOMAIN=}"; dns_domain_ok "$v" || { echo "Неверный домен: $v" >&2; bad=1; } ;;
    esac
  done < "$1"
  return $bad
}

dns_profile_save() { # <id>  stdin: профиль
  local id="$1" tmp="$DNS_RUN_DIR/save.$$" n
  dns_id_ok "$id" || { echo "Некорректный идентификатор профиля" >&2; return 1; }
  dns_init
  mkdir -p "$DNS_RUN_DIR"
  if [ ! -f "$DNS_PROFILES_DIR/$id.conf" ]; then
    n=$(ls "$DNS_PROFILES_DIR" 2>/dev/null | grep -c '\.conf$')
    [ "${n:-0}" -lt "$DNS_MAX_PROFILES" ] || { echo "Профилей не больше $DNS_MAX_PROFILES" >&2; return 1; }
  fi
  dns_profile_normalize > "$tmp" || { rm -f "$tmp"; return 1; }
  dns_profile_check "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$DNS_PROFILES_DIR/$id.conf" && chmod 0644 "$DNS_PROFILES_DIR/$id.conf"
}

dns_profile_set_enabled() { # <id> <0|1>
  local f="$DNS_PROFILES_DIR/$1.conf"
  dns_id_ok "$1" && [ -f "$f" ] || { echo "Профиль не найден" >&2; return 1; }
  case "$2" in 0|1) ;; *) echo "Допустимо 0 или 1" >&2; return 1 ;; esac
  sed "s/^ENABLED=.*/ENABLED=$2/" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# ---------------------------------------------------------------- DNS сети
# Серверы, которые Android назначил текущей сети по умолчанию, через запятую.
# Берутся из dumpsys connectivity: строка «Active default network: N» и
# NetworkAgentInfo этой сети с «DnsAddresses: [ /1.2.3.4,/… ]». Формат
# меняется от версии к версии, поэтому разбор терпимый, а запасной путь —
# свойства net.dns1/net.dns2 старых версий.
dns_net_servers() {
  local s
  s=$(dumpsys connectivity 2>/dev/null | awk '
    /^ *Active default network:/ { act = $NF }
    /NetworkAgentInfo/ && match($0, /network\{[0-9]+\}/) {
      id = substr($0, RSTART + 8, RLENGTH - 9)
      if (match($0, /DnsAddresses: \[[^]]*\]/)) {
        v = substr($0, RSTART + 15, RLENGTH - 16); gsub(/[ \/]/, "", v)
        if (!(id in dns)) { dns[id] = v; if (first == "") first = id }
      }
    }
    END { if (act in dns) print dns[act]; else if (first != "") print dns[first] }')
  if [ -z "$s" ]; then
    s=$(for p in net.dns1 net.dns2; do getprop "$p" 2>/dev/null; done | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
  fi
  printf '%s' "$s" | tr ',' '\n' | grep -E '^[0-9A-Fa-f.:%a-z_]+$' | head -n 4 | tr '\n' ',' | sed 's/,$//'
}

# 1.2.3.4 -> 1.2.3.4:53, fe80::1%wlan0 -> [fe80::1%wlan0]:53
dns_addr_port() {
  case "$1" in *:*) printf '[%s]:53' "$1" ;; *) printf '%s:53' "$1" ;; esac
}

# ---------------------------------------------------------------- конфиг dnsproxy
# Пишет $DNS_RUN_DIR/upstreams.txt (основные серверы и правила по доменам),
# fallback.txt и args (аргументы запуска). Код 1 — включённых правил нет,
# и перехватывать нечего: DNS по умолчанию «DNS сети» и ни одного профиля.
dns_build() {
  local def net up="$DNS_RUN_DIR/upstreams.txt.new" a ip routed
  mkdir -p "$DNS_RUN_DIR"
  def=$(dns_default)
  net=$(dns_net_servers)
  printf '%s\n' "$net" > "$DNS_RUN_DIR/net_dns"

  # Правила по доменам: строка на сервер, домены пачками по 100 — dnsproxy
  # объединяет одинаковые домены из разных строк в один набор серверов.
  awk '
    FNR == 1 { flush(); en = 0; ns = 0; nd = 0 }
    /^ENABLED=1$/ { en = 1 }
    /^SERVER=/ { srv[++ns] = substr($0, 8) }
    /^DOMAIN=/ { dom[++nd] = substr($0, 8) }
    function flush(   i, j, k, line) {
      if (!en || !ns || !nd) return
      for (k = 1; k <= nd; k += 100) {
        line = "[/"
        for (j = k; j <= nd && j < k + 100; j++) line = line dom[j] "/"
        line = line "]"
        for (i = 1; i <= ns; i++) print line srv[i]
      }
    }
    END { flush() }' "$DNS_PROFILES_DIR"/*.conf 2>/dev/null > "$up.rules"
  routed=$(grep -c . "$up.rules" 2>/dev/null)

  # DNS по умолчанию: серверы выбранного профиля (его домены всё равно идут
  # по правилам выше) или DNS текущей сети.
  : > "$up"
  if [ "$def" != net ] && [ -f "$DNS_PROFILES_DIR/$def.conf" ]; then
    sed -n 's/^SERVER=//p' "$DNS_PROFILES_DIR/$def.conf" >> "$up"
  fi
  if [ ! -s "$up" ]; then
    [ "$def" = net ] && [ "${routed:-0}" = 0 ] && { rm -f "$up" "$up.rules"; return 1; }
    for ip in $(printf '%s' "$net" | tr ',' ' '); do dns_addr_port "$ip" >> "$up"; echo >> "$up"; done
  fi
  # Ни сеть, ни профиль серверов не дали — тогда публичные
  [ -s "$up" ] || for ip in $DNS_PUBLIC; do echo "$ip:53" >> "$up"; done
  cat "$up.rules" >> "$up"; rm -f "$up.rules"
  mv -f "$up" "$DNS_RUN_DIR/upstreams.txt"

  # Запасные серверы — если основные не ответили: DNS сети, затем публичные.
  : > "$DNS_RUN_DIR/fallback.txt"
  for ip in $(printf '%s' "$net" | tr ',' ' ') $DNS_PUBLIC; do
    dns_addr_port "$ip" >> "$DNS_RUN_DIR/fallback.txt"; echo >> "$DNS_RUN_DIR/fallback.txt"
  done

  # Аргументы — по одному на строку. Bootstrap (адреса DoH/DoT-серверов) — та
  # же цепочка: DNS сети, затем публичные.
  {
    echo "-l"; echo "127.0.0.1"
    if ip -6 addr show dev lo 2>/dev/null | grep -q '::1/128'; then echo "-l"; echo "::1"; fi
    echo "-p"; echo "$DNS_PORT"
    echo "-u"; echo "$DNS_RUN_DIR/upstreams.txt"
    echo "-f"; echo "$DNS_RUN_DIR/fallback.txt"
    for ip in $(printf '%s' "$net" | tr ',' ' ') $DNS_PUBLIC; do echo "-b"; dns_addr_port "$ip"; echo; done
    echo "--cache"
    echo "--timeout=5s"
    echo "--upstream-mode=load_balance"
    [ "${LOG_LEVEL:-0}" = 1 ] && echo "-v"
  } > "$DNS_RUN_DIR/args"
  return 0
}

# ---------------------------------------------------------------- процесс
# Подробный журнал DNS — тот же файл, куда пишет сам dnsproxy (экран
# «Журналы» → DNS). В журнал службы идут только включение, выключение и ошибки.
dns_log() {
  printf '[%s] nfqws2: %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$DNS_LOG" 2>/dev/null
}

# Последняя ошибка — для WebUI; снимается при удачном запуске и при выключении
dns_fail() { log_msg "DNS: $1"; dns_log "ошибка: $1"; printf '%s\n' "$1" > "$DNS_RUN_DIR/error" 2>/dev/null; return 1; }

# Блокировка. dns_start/dns_stop/dns_check зовут watchdog, netwatch, запуск
# службы и WebUI — каждый своим процессом. Без неё два запуска одновременно
# оставляли «сироту»: второй dnsproxy затирал PID-файл первого, первый держал
# порт, а watchdog писал «упал — перезапуск» про живой процесс.
# mkdir атомарен; владелец записан внутри, блокировку умершего — снимаем.
DNS_LOCK="$STATE_DIR/dns.lock"
DNS_LOCK_HELD=0
dns_lock() { # [0 — не ждать]
  local i=0 owner
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
  while ! mkdir "$DNS_LOCK" 2>/dev/null; do
    owner=""
    [ -f "$DNS_LOCK/pid" ] && IFS= read -r owner < "$DNS_LOCK/pid"
    if [ -n "$owner" ] && [ ! -d "/proc/$owner" ]; then
      rm -rf "$DNS_LOCK"; continue
    fi
    [ "$1" = 0 ] && return 1
    # ~15 с: запуск dnsproxy ждёт порт до 4 с, плюс iptables
    i=$((i + 1)); [ "$i" -ge 75 ] && return 1
    sleep 0.2
  done
  echo $$ > "$DNS_LOCK/pid"
}
dns_unlock() { rm -rf "$DNS_LOCK"; }
_dns_locked() { # <0|1 ждать> <функция> [аргументы]
  local wait="$1" rc; shift
  [ "$DNS_LOCK_HELD" = 1 ] && { "$@"; return; }
  dns_lock "$wait" || return 2
  DNS_LOCK_HELD=1
  "$@"; rc=$?
  DNS_LOCK_HELD=0
  dns_unlock
  return $rc
}

# Жив ли процесс — по /proc, а не kill -0: у kill -0 из другого процесса
# бывает отказ (EPERM) и у живого dnsproxy. Зомби (завершился, но не прибран)
# — не жив.
dns_alive() { # <pid>
  local _a _b st=""
  [ -d "/proc/$1" ] || return 1
  [ -r "/proc/$1/stat" ] && read -r _a _b st _a < "/proc/$1/stat"
  [ "$st" != Z ]
}
dns_pid() {
  local p=""
  [ -f "$DNS_PIDFILE" ] && IFS= read -r p < "$DNS_PIDFILE"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  dns_alive "$p" || return 1
  printf '%s' "$p"
}
# Что с процессом из PID-файла — для журнала, когда он «не работает»
dns_pid_diag() { # <pid>
  local d _a _b st=""
  [ -n "$1" ] || { printf 'пусто'; return; }
  d="PID $1"
  if [ -d "/proc/$1" ]; then
    [ -r "/proc/$1/stat" ] && read -r _a _b st _a < "/proc/$1/stat"
    d="$d: есть в /proc, $_b, состояние ${st:-?}"
  else
    d="$d: нет в /proc"
  fi
  kill -0 "$1" 2>/dev/null && d="$d, kill -0 ok" || d="$d, kill -0 отказ"
  printf '%s' "$d"
}
# dnsproxy этого модуля (по пути бинарника), кроме PID из аргумента
dns_own_pids() { # [исключить PID]
  local p exe
  for p in $(pidof dnsproxy 2>/dev/null); do
    [ "$p" = "$1" ] && continue
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    [ "$exe" = "$DNS_BIN" ] && dns_alive "$p" && echo "$p"
  done
}

# Корневые сертификаты для DoH/DoT: Go ищет их в /etc/ssl/certs, а у Android
# они в APEX conscrypt (Android 14+) и в /system/etc/security/cacerts.
dns_cert_dirs() {
  local d out=""
  for d in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts; do
    [ -d "$d" ] && out="$out${out:+:}$d"
  done
  printf '%s' "$out"
}

# dnsproxy этого модуля, про которые PID-файл не знает (остались от сбоя или
# от старой версии без блокировки): держат порт, и новый запуск не поднимется.
dns_kill_strays() {
  local p
  for p in $(dns_own_pids "$(dns_pid)"); do
    dns_log "лишний dnsproxy (PID $p) без PID-файла — завершаю"
    kill -KILL "$p" 2>/dev/null
  done
}

# Фильтр вывода dnsproxy в журнал. Каждый неответ сервера dnsproxy пишет
# дважды («response received» и «exchange failed»), а один и тот же
# недоступный сервер — на каждый запрос: журнал за минуты забивался
# одинаковыми строками. Первая строка «response received» отбрасывается,
# одинаковая ошибка (сервер + текст без чисел) показывается раз в 5 минут,
# а следующая за окном — со счётчиком пропущенных. С LOG_LEVEL=1 — всё как есть.
DNS_LOG_FILTER='
function tsec(t,   a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + int(a[3]) }
{
  if (index($0, " ERROR response received ")) next
  if (index($0, " ERROR exchange failed ")) {
    up = ""; if (match($0, /upstream=[^ ]+/)) up = substr($0, RSTART + 9, RLENGTH - 9)
    er = ""; if (match($0, /err="[^"]*"/)) er = substr($0, RSTART + 5, RLENGTH - 6)
    gsub(/[0-9]+/, "N", er)
    k = up "|" er
    now = tsec($2) + day * 86400
    if (now < prev) { day++; now += 86400 }
    prev = now
    if ((k in last) && now - last[k] < 300) { cnt[k]++; next }
    if (cnt[k] > 0) printf "%s %s INFO nfqws2: ошибка сервера %s повторялась, скрыто повторов за 5 мин: %d\n", $1, $2, up, cnt[k]
    cnt[k] = 0; last[k] = now
  }
  print
  fflush()
}'


dns_proxy_start() {
  local pid i listen=0
  [ -x "$DNS_BIN" ] || chmod 0755 "$DNS_BIN" 2>/dev/null
  [ -x "$DNS_BIN" ] || { dns_fail "нет исполняемого $DNS_BIN"; return 1; }
  rotate_file "$DNS_LOG" $(( ${LOG_MAX_KB:-512} * 1024 ))
  dns_kill_strays
  # Вывод dnsproxy — через фильтр (FIFO, чтобы $! остался PID самого
  # dnsproxy). Фильтр завершается сам, когда dnsproxy закрывает FIFO.
  local out="$DNS_LOG" fifo="$DNS_RUN_DIR/log.fifo"
  rm -f "$fifo"
  if [ "${LOG_LEVEL:-0}" != 1 ] && mkfifo "$fifo" 2>/dev/null; then
    awk "$DNS_LOG_FILTER" < "$fifo" >> "$DNS_LOG" 2>/dev/null &
    out="$fifo"
  fi
  (
    set -f
    IFS='
'
    exec 0</dev/null >>"$out" 2>&1
    SSL_CERT_DIR=$(dns_cert_dirs); export SSL_CERT_DIR
    exec "$DNS_BIN" $(cat "$DNS_RUN_DIR/args")
  ) &
  pid=$!
  echo "$pid" > "$DNS_PIDFILE"
  # Готов, когда слушает порт: /proc/net/udp, порт в шестнадцатеричном виде
  i=0
  while [ "$i" -lt 20 ]; do
    dns_alive "$pid" || break
    grep -qi ":$(printf '%04X' "$DNS_PORT") " /proc/net/udp /proc/net/udp6 2>/dev/null && { listen=1; break; }
    sleep 0.2; i=$((i + 1))
  done
  if ! dns_alive "$pid"; then
    wait "$pid" 2>/dev/null
    rm -f "$DNS_PIDFILE"
    dns_fail "dnsproxy не запустился: $(grep -v '] nfqws2: ' "$DNS_LOG" 2>/dev/null | tail -n 1)"
    return 1
  fi
  if [ "$listen" = 1 ]; then dns_log "dnsproxy запущен, PID $pid, порт $DNS_PORT"
  else dns_log "dnsproxy запущен (PID $pid), но порт $DNS_PORT за 4 с не открылся — ждём дальше"; fi
  protect_process "$pid"
  cp -f "$DNS_RUN_DIR/upstreams.txt" "$DNS_RUN_DIR/running.upstreams" 2>/dev/null
  cp -f "$DNS_RUN_DIR/args" "$DNS_RUN_DIR/running.args" 2>/dev/null
  return 0
}

dns_proxy_stop() {
  local pid
  pid=$(dns_pid) && {
    kill -TERM "$pid" 2>/dev/null; sleep 0.3; dns_alive "$pid" && kill -KILL "$pid" 2>/dev/null
    dns_log "dnsproxy (PID $pid) остановлен"
  }
  rm -f "$DNS_PIDFILE" "$DNS_RUN_DIR/running.upstreams" "$DNS_RUN_DIR/running.args"
}

# ---------------------------------------------------------------- перехват
# В nat OUTPUT: непомеченные пакеты (не от netd, в том числе сам dnsproxy) —
# мимо, остальные UDP/TCP на порт 53 — в dnsproxy. Для IPv6 то же через
# ip6tables nat; если ядро его не умеет — отказ IPv6-запросам netd, чтобы
# резолвер ушёл на IPv4-серверы сети (только если такие есть, иначе DNS
# пропал бы совсем).
_dns_chain_nat() { # <iptables|ip6tables>
  local C="$1"
  $C -w -t nat -N $DNS_CHAIN 2>/dev/null
  $C -w -t nat -F $DNS_CHAIN 2>/dev/null &&
  $C -w -t nat -A $DNS_CHAIN -m mark --mark 0x0/0xffff -j RETURN &&
  $C -w -t nat -A $DNS_CHAIN -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT &&
  $C -w -t nat -A $DNS_CHAIN -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT &&
  { $C -w -t nat -C OUTPUT -j $DNS_CHAIN 2>/dev/null || $C -w -t nat -I OUTPUT 1 -j $DNS_CHAIN; }
}
_dns_unchain() { # <iptables|ip6tables> <таблица> <цепочка>
  while $1 -w -t "$2" -D OUTPUT -j "$3" 2>/dev/null; do :; done
  $1 -w -t "$2" -F "$3" 2>/dev/null
  $1 -w -t "$2" -X "$3" 2>/dev/null
}

dns_rules_add() {
  local net v4=0 ip
  _dns_chain_nat iptables >/dev/null 2>&1 || { _dns_unchain iptables nat $DNS_CHAIN; return 1; }
  if _dns_chain_nat ip6tables >/dev/null 2>&1; then
    echo redirect > "$DNS_RUN_DIR/ipv6"
  else
    _dns_unchain ip6tables nat $DNS_CHAIN
    net=$(cat "$DNS_RUN_DIR/net_dns" 2>/dev/null)
    for ip in $(printf '%s' "$net" | tr ',' ' '); do case "$ip" in *:*) ;; *) v4=1 ;; esac; done
    if [ "$v4" = 1 ] && {
         ip6tables -w -t filter -N $DNS_CHAIN6F 2>/dev/null; ip6tables -w -t filter -F $DNS_CHAIN6F &&
         ip6tables -w -t filter -A $DNS_CHAIN6F -m mark --mark 0x0/0xffff -j RETURN &&
         ip6tables -w -t filter -A $DNS_CHAIN6F -p udp --dport 53 -j REJECT &&
         ip6tables -w -t filter -A $DNS_CHAIN6F -p tcp --dport 53 -j REJECT --reject-with tcp-reset &&
         { ip6tables -w -t filter -C OUTPUT -j $DNS_CHAIN6F 2>/dev/null || ip6tables -w -t filter -I OUTPUT 1 -j $DNS_CHAIN6F; }
       } >/dev/null 2>&1; then
      echo reject > "$DNS_RUN_DIR/ipv6"
    else
      _dns_unchain ip6tables filter $DNS_CHAIN6F
      echo none > "$DNS_RUN_DIR/ipv6"
    fi
  fi
  return 0
}

dns_rules_del() {
  _dns_unchain iptables nat $DNS_CHAIN
  _dns_unchain ip6tables nat $DNS_CHAIN
  _dns_unchain ip6tables filter $DNS_CHAIN6F
  rm -f "$DNS_RUN_DIR/ipv6"
}

dns_rules_ok() { iptables -w -t nat -C OUTPUT -j $DNS_CHAIN 2>/dev/null; }

# ---------------------------------------------------------------- жизненный цикл
# Загрузка: всё в $DNS_RUN_DIR — от прошлой загрузки. Старый PID мог достаться
# другому процессу, и dns_start счёл бы dnsproxy живым.
dns_boot_reset() {
  # standalone — флаг прежних версий: теперь DNS всегда работает сам по себе
  rm -f "$DNS_DIR/standalone" "$DNS_PIDFILE" "$DNS_RUN_DIR/running.upstreams" "$DNS_RUN_DIR/running.args" \
        "$DNS_RUN_DIR/active" "$DNS_RUN_DIR/error" "$DNS_RUN_DIR/ipv6" 2>/dev/null
}

# Нужен ли перехват сейчас. DNS работает независимо от службы обхода:
# остановка службы, пауза в домашней Wi‑Fi или при VPN его не трогают —
# выключить его можно только главным переключателем на экране DNS. Есть ли
# что применять, решает dns_build.
dns_wanted() { dns_enabled; }

# Что будет применено — одной строкой в журнал DNS
dns_describe() {
  local def net up rules prof ipv6 pm
  def=$(dns_default); net=$(cat "$DNS_RUN_DIR/net_dns" 2>/dev/null)
  rules=$(grep -c '^\[/' "$DNS_RUN_DIR/upstreams.txt" 2>/dev/null)
  prof=$(grep -l '^ENABLED=1$' "$DNS_PROFILES_DIR"/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##' | tr '\n' ' ' | sed 's/ $//')
  up=$(grep -v '^\[/' "$DNS_RUN_DIR/upstreams.txt" 2>/dev/null | grep . | tr '\n' ' ' | sed 's/ $//')
  if [ "$def" = net ]; then def="DNS сети"; else def="профиль $def"; fi
  dns_log "по умолчанию: $def ($up); включённые профили: ${prof:-нет}; правил по доменам: ${rules:-0}; DNS сети: ${net:-не определён}"
  pm=$(dns_private_mode)
  case "$pm" in hostname|opportunistic)
    dns_log "внимание: «Частный DNS» = $pm — запросы через DoT системы идут мимо перехвата" ;;
  esac
}

# Идемпотентно: пересобирает конфиг и перезапускает dnsproxy, только если
# конфиг изменился или процесс не живой. Сбой — без перехвата: лучше DNS
# сети, чем никакого. Аргумент — причина, для журнала DNS.
dns_start() {
  local rc
  _dns_locked 1 _dns_start "$@"; rc=$?
  [ "$rc" = 2 ] && { dns_log "запуск (${1:-запрос}) пропущен: другой запуск DNS не завершился за 15 с"; return 1; }
  return "$rc"
}
_dns_start() {
  local why="${1:-запрос}"
  dns_init
  if ! dns_wanted; then _dns_stop "$why: не нужен"; return 0; fi
  if ! dns_build; then _dns_stop "$why: применять нечего — DNS сети и нет включённых профилей"; return 0; fi
  mkdir -p "$DNS_RUN_DIR"
  if dns_pid >/dev/null && cmp -s "$DNS_RUN_DIR/upstreams.txt" "$DNS_RUN_DIR/running.upstreams" &&
     cmp -s "$DNS_RUN_DIR/args" "$DNS_RUN_DIR/running.args"; then
    if ! dns_rules_ok; then
      dns_log "$why: конфиг тот же, правила перехвата пропали — восстанавливаю"
      dns_rules_add || dns_fail "не удалось восстановить перехват"
    fi
    return 0
  fi
  if dns_pid >/dev/null; then dns_log "$why: конфиг изменился — перезапуск dnsproxy"
  else dns_log "$why: запуск dnsproxy"; fi
  dns_describe
  dns_proxy_stop
  if ! dns_proxy_start; then dns_rules_del; return 1; fi
  if ! dns_rules_add; then
    dns_fail "правила перехвата не применились (нет nat/REDIRECT в ядре?)"
    dns_proxy_stop
    return 1
  fi
  dns_log "перехват включён: IPv4 — nat REDIRECT, IPv6 — $(cat "$DNS_RUN_DIR/ipv6" 2>/dev/null)"
  rm -f "$DNS_RUN_DIR/error"
  [ -f "$DNS_RUN_DIR/active" ] || log_msg "DNS: перехват включён, правил по доменам: $(grep -c '^\[/' "$DNS_RUN_DIR/upstreams.txt" 2>/dev/null)"
  : > "$DNS_RUN_DIR/active"
  return 0
}

dns_stop() { _dns_locked 1 _dns_stop "$@"; [ $? = 2 ] && return 1; return 0; }
_dns_stop() {
  local had=0
  { dns_pid >/dev/null || dns_rules_ok; } && had=1
  # Ничего не запущено и правил нет — не тратим вызовы iptables на каждый stop
  [ "$had" = 1 ] || [ -f "$DNS_RUN_DIR/ipv6" ] || return 0
  dns_rules_del
  dns_proxy_stop
  rm -f "$DNS_RUN_DIR/active" "$DNS_RUN_DIR/error"
  if [ "$had" = 1 ]; then
    dns_log "перехват выключен (${1:-остановка})"
    log_msg "DNS: перехват выключен"
  fi
  return 0
}

# Тик watchdog: процесс упал или правила снесла система — поднимаем заново.
# Только то, что уже было запущено (метка active): применять нечего или запуск
# не удался — каждые 20 с не пробуем, ждём смены сети или настроек.
# Блокировку не ждёт: занята — значит, DNS прямо сейчас запускают или
# останавливают, и проверять на полпути нечего.
dns_check() { _dns_locked 0 _dns_check; return 0; }
_dns_check() {
  local p="" own
  if dns_wanted; then
    [ -f "$DNS_RUN_DIR/active" ] || return 0
    if ! dns_pid >/dev/null; then
      [ -f "$DNS_PIDFILE" ] && IFS= read -r p < "$DNS_PIDFILE"
      # PID-файл врёт, а dnsproxy этого модуля работает — не перезапускаем,
      # а берём его; в журнал — подробности для разбора
      own=$(dns_own_pids | head -n 1)
      if [ -n "$own" ]; then
        echo "$own" > "$DNS_PIDFILE"
        dns_log "watchdog: PID-файл ($(dns_pid_diag "$p")) не указывал на dnsproxy, но он работает (PID $own) — PID-файл исправлен, перезапуск не нужен"
        return 0
      fi
      dns_log "dnsproxy не работает ($(dns_pid_diag "$p")) — перезапуск. Последние строки его вывода — выше"
      log_msg "DNS: dnsproxy упал — перезапуск (подробности — в журнале DNS)"
      rm -f "$DNS_PIDFILE"
      if _dns_start "watchdog"; then log_msg "DNS: dnsproxy перезапущен"; fi
    elif ! dns_rules_ok; then
      dns_log "watchdog: правила перехвата пропали — восстанавливаю"
      dns_rules_add || dns_fail "не удалось восстановить перехват"
    fi
  elif dns_pid >/dev/null || dns_rules_ok; then
    _dns_stop "watchdog: больше не нужен"
  fi
}

# ---------------------------------------------------------------- состояние для WebUI
dns_private_mode() { settings get global private_dns_mode 2>/dev/null | tr -d '\r\n '; }

dns_hits() {
  iptables -w -t nat -L $DNS_CHAIN -v -n -x 2>/dev/null | awk '/REDIRECT/ { s += $1 } END { print s + 0 }'
}

# Ответ dns-state: секция #status (ключ=значение), затем #profile <id> и
# #preset <id> с содержимым файлов как есть.
dns_state() {
  local pm ph proxy=stopped f id
  dns_init
  pm=$(dns_private_mode); [ -n "$pm" ] && [ "$pm" != null ] || pm=opportunistic
  [ "$pm" = hostname ] && ph=$(settings get global private_dns_specifier 2>/dev/null | tr -d '\r\n ')
  if dns_pid >/dev/null; then proxy=running
  elif [ ! -x "$DNS_BIN" ] && [ ! -f "$DNS_BIN" ]; then proxy=missing
  fi
  echo "#status"
  echo "enabled=$(dns_enabled && echo 1 || echo 0)"
  echo "default=$(dns_default)"
  echo "proxy=$proxy"
  echo "rules=$(dns_rules_ok && echo on || echo off)"
  echo "ipv6=$(cat "$DNS_RUN_DIR/ipv6" 2>/dev/null)"
  echo "private=$pm"
  echo "private_host=$ph"
  echo "net_dns=$(cat "$DNS_RUN_DIR/net_dns" 2>/dev/null)"
  echo "hits=$(dns_hits)"
  echo "error=$(head -n 1 "$DNS_RUN_DIR/error" 2>/dev/null)"
  echo "max_profiles=$DNS_MAX_PROFILES"
  echo "max_servers=$DNS_MAX_SERVERS"
  echo "max_domains=$DNS_MAX_DOMAINS"
  for f in "$DNS_PROFILES_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id="${f##*/}"; echo "#profile ${id%.conf}"; cat "$f"
  done
  for f in "$DNS_PRESETS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id="${f##*/}"; echo "#preset ${id%.conf}"; cat "$f"
  done
}

# Проверка домена: через системный резолвер (значит, через перехват), плюс
# какой профиль его забирает — самое длинное совпадение суффикса, как у dnsproxy.
dns_test() { # <домен>
  local d="$1" ip prof
  dns_domain_ok "$d" || { echo "Некорректный домен" >&2; return 1; }
  ip=$(ping -c 1 -W 2 "$d" 2>/dev/null | sed -n '1s/^PING [^(]*(\([^)]*\)).*/\1/p')
  [ -n "$ip" ] || ip=$(ping6 -c 1 -W 2 "$d" 2>/dev/null | sed -n '1s/^PING [^(]*(\([^)]*\)).*/\1/p')
  prof=$(awk -v q="$d" '
    FNR == 1 { id = FILENAME; sub(/.*\//, "", id); sub(/\.conf$/, "", id); en = 0 }
    /^ENABLED=1$/ { en = 1 }
    /^DOMAIN=/ && en {
      v = substr($0, 8)
      if ((q == v || substr(q, length(q) - length(v)) == "." v) && length(v) > best) { best = length(v); hit = id }
    }
    END { print hit }' "$DNS_PROFILES_DIR"/*.conf 2>/dev/null)
  printf '%s\t%s\n' "${ip:-—}" "$prof"
}

dns_doctor() { # строки для «Диагностики»; в обычной сборке — ничего
  [ -f "$DNS_BIN" ] || return 0
  dns_enabled || { row info dns "$(M 'DNS по профилям выключен' 'DNS profiles are off')"; return 0; }
  if dns_pid >/dev/null && dns_rules_ok; then
    row ok dns "$(M "dnsproxy работает, перехвачено запросов: $(dns_hits)" "dnsproxy running, queries intercepted: $(dns_hits)")"
  elif dns_wanted; then
    row warn dns "$(M 'включён, но перехват не работает — см. журнал службы' 'on, but interception is not working — see the service log')"
  fi
  case "$(dns_private_mode)" in
    hostname) row warn private_dns "$(M 'в Android включён «Частный DNS» — профили не применяются' 'Android Private DNS is on — profiles do not apply')" ;;
  esac
}

# ---------------------------------------------------------------- резервная копия
dns_backup_add() { # <каталог в архиве>
  [ -d "$DNS_PROFILES_DIR" ] || return 0
  mkdir -p "$1/profiles" && cp -f "$DNS_PROFILES_DIR"/*.conf "$1/profiles/" 2>/dev/null
  cp -f "$DNS_DEFAULT_FILE" "$1/" 2>/dev/null
  dns_enabled && : > "$1/enabled"
  return 0
}
# Профили из архива проходят ту же проверку, что и сохранение из WebUI.
dns_backup_restore() { # <каталог из архива>
  local f id
  [ -d "$1/profiles" ] || return 0
  dns_init
  for f in "$1"/profiles/*.conf; do
    [ -f "$f" ] || continue
    id="${f##*/}"; id="${id%.conf}"
    dns_profile_save "$id" < "$f" 2>/dev/null
  done
  [ -f "$1/default" ] && cp -f "$1/default" "$DNS_DEFAULT_FILE"
  if [ -f "$1/enabled" ]; then : > "$DNS_ENABLED_FILE"; else rm -f "$DNS_ENABLED_FILE"; fi
  return 0
}

# ---------------------------------------------------------------- команды nfqws2-ctl
dns_apply_now() { # применить сейчас: dns_start сам решит, запускать или снимать
  dns_wanted || dns_pid >/dev/null || dns_rules_ok || return 0
  sh "$MODDIR/service.sh" dns_apply >/dev/null 2>&1 || echo "Сохранено, но DNS не перезапустился — см. журнал службы" >&2
}

dns_ctl() {
  local cmd="$1"; shift
  case "$cmd" in
    dns-state) dns_state ;;
    dns-set-enabled)
      dns_init
      case "$1" in
        1) : > "$DNS_ENABLED_FILE" ;;
        0) rm -f "$DNS_ENABLED_FILE" ;;
        *) echo "Допустимо 0 или 1" >&2; return 1 ;;
      esac
      # Наблюдатели нужны DNS для смены сети; home_check поднимает их по нужде
      sh "$MODDIR/service.sh" home_check >/dev/null 2>&1
      dns_apply_now; echo OK ;;
    dns-set-default)
      dns_init
      if [ "$1" != net ]; then dns_id_ok "$1" && [ -f "$DNS_PROFILES_DIR/$1.conf" ] || { echo "Профиль не найден" >&2; return 1; }; fi
      echo "$1" > "$DNS_DEFAULT_FILE"; dns_apply_now; echo OK ;;
    dns-save-b64) # <id> <профиль в base64>
      b64d "$2" | dns_profile_save "$1" || return 1
      dns_apply_now; echo OK ;;
    dns-profile-enable) dns_profile_set_enabled "$1" "$2" || return 1; dns_apply_now; echo OK ;;
    dns-delete) # <id>… — несколько сразу (выбор в WebUI), применяется один раз
      local id def
      [ $# -gt 0 ] || { echo "Профиль не найден" >&2; return 1; }
      for id in "$@"; do
        dns_id_ok "$id" && [ -f "$DNS_PROFILES_DIR/$id.conf" ] || { echo "Профиль не найден: $id" >&2; return 1; }
      done
      def=$(dns_default)
      for id in "$@"; do
        rm -f "$DNS_PROFILES_DIR/$id.conf"
        [ "$def" = "$id" ] && echo net > "$DNS_DEFAULT_FILE"
      done
      dns_apply_now; echo OK ;;
    dns-test) dns_test "$1" ;;
    dns-log) tail -n "${1:-100}" "$DNS_LOG" 2>/dev/null ;;
    *) echo "Неизвестная команда $cmd" >&2; return 1 ;;
  esac
}
