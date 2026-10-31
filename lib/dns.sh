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
DNS_HOME_FILE="$DNS_DIR/home_pause"      # есть файл — DNS на паузе в домашнем Wi‑Fi
DNS_PRESETS_DIR="$MODDIR/defaults/dns-presets"
DNS_BIN="$MODDIR/bin/dnsproxy"
DNS_RUN_DIR="$STATE_DIR/dns"
DNS_PIDFILE="$STATE_DIR/dnsproxy.pid"
DNS_LOG="$LOG_DIR/dns.log"
DNS_PORT=15353
# Умный DNS (DNS_SMART): домены видео и CDN — отдельному dnsproxy, который
# спрашивает DNS сети и публичные и отдаёт самый быстрый по соединению адрес;
# у обоих — оптимистичный кэш (повторный ответ мгновенно, обновление — фоном)
DNS_CDN_PORT=15354
DNS_CDN_PIDFILE="$STATE_DIR/dnsproxy-cdn.pid"
DNS_CDN_LIST="$MODDIR/defaults/dns-cdn.list"
# Обход геоблока (DNS_GEO, умный режим): домены из списка geoblock.list идут
# в DNS с обходом (DNS_GEO_VIA: по умолчанию DoH Comss — тот же сервер, что
# «Частный DNS» dns.comss.one; можно GeoHide, dns.zapret.moe или всех сразу), всё
# остальное — в DNS сети. Так делают mihomo (nameserver-policy), chinadns-ng
# (тег gfw) и smartdns (nameserver /домен/группа): маршрут — по списку, а не по
# догадке из ответа. Это обычные правила dnsproxy, как у профилей. Список —
# geoblock из itdoginfo/allow-domains и список GeoHide, обновляется кнопкой;
# свои домены пользователь дописывает в него сам. Домены включённых профилей,
# CDN, push-уведомлений Google и dns-geo-never.list (российские сервисы) в
# обход не идут.
DNS_GEO_LIST="$LISTS_DIR/geoblock.list"
DNS_GEO_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/geoblock.lst"
DNS_GEO_CAND="$MODDIR/defaults/dns-geo-servers.list"
# Домены-образцы проверки: ИИ, игры Supercell, сервисы с геоблоком для России.
# Прокси — ответ, не совпавший с DNS сети (см. helper/geoscan.go)
DNS_GEO_SAMPLES="chatgpt.com,claude.ai,gemini.google.com,gamea.clashofclans.com,accounts.supercell.com,intel.com,spotify.com"
DNS_GEO_SCAN_DIR="$CONFDIR/dns/geoscan"
DNS_GEO_SCAN_EVERY=21600     # 6 часов
DNS_GEO_POOL=3
DNS_GEO_FALLBACK="https://dns.comss.one/dns-query"
DNS_GEO_SCAN_COOL=300        # ручная проверка — не чаще раза в 5 минут
DNS_GEO_UPD_COOL=1800        # обновление списка — раз в 30 минут
DNS_GEO_NEVER="$MODDIR/defaults/dns-geo-never.list"
DNS_CHAIN=nfqws_dns          # nat OUTPUT: перехват в dnsproxy
DNS_CHAIN6F=nfqws_dns6       # filter OUTPUT (IPv6 без nat): отказ, резолвер уйдёт на IPv4

# Пределы. Серверов в профиле — сколько разумно опрашивать по очереди;
# доменов — чтобы строка правил dnsproxy и экран WebUI оставались подъёмными.
DNS_MAX_PROFILES=32
DNS_MAX_SERVERS=12
DNS_MAX_DOMAINS=1000

# Резервные публичные DNS: bootstrap для имён DoH/DoT-серверов и запасной
# вариант, когда DNS сети не определился или не отвечает.
DNS_PUBLIC="77.88.8.8 1.1.1.1 8.8.8.8"

# Push-уведомления (FCM): сервисы Google держат одно соединение с mtalk.google.com,
# через него приходят уведомления почти всех приложений. DNS «для обхода»
# (Comss, GeoHide, zapret.moe) отдают для доменов Google адреса своих прокси, а те
# не принимают порт 5228: FCM не мог переподключиться, уведомления копились и
# приходили пачкой, когда приложение открывали. Поэтому, если DNS по умолчанию
# — профиль, эти домены всегда идут в DNS Google (настройка разработчика
# DNS_PUSH, по умолчанию включена). Свои профили на те же домены добавляются
# к этим серверам, а не заменяют их
DNS_PUSH_DOMAINS="mtalk.google.com mtalk4.google.com alt1-mtalk.google.com alt2-mtalk.google.com alt3-mtalk.google.com alt4-mtalk.google.com alt5-mtalk.google.com alt6-mtalk.google.com alt7-mtalk.google.com alt8-mtalk.google.com android.apis.google.com device-provisioning.googleapis.com firebaseinstallations.googleapis.com fcm.googleapis.com fcm-xmpp.googleapis.com gcm-http.googleapis.com gcm-xmpp.googleapis.com"
DNS_PUSH_SERVERS="https://dns.google/dns-query tls://dns.google 8.8.8.8 8.8.4.4"
dns_push_on() { [ "${DNS_PUSH:-1}" = 1 ] && [ "$(dns_default_used)" != net ]; }

dns_enabled() { [ -f "$DNS_ENABLED_FILE" ] && [ -f "$DNS_BIN" ]; }
dns_smart_on() { [ "${DNS_SMART:-1}" = 1 ]; }
dns_geo_on() { [ "${DNS_GEO:-1}" = 1 ]; }
dns_geo_count() { list_count "$DNS_GEO_LIST"; }
# DNS для обхода геоблока выбирает сам модуль, как умный режим обхода —
# вариант: раз в несколько часов тихо проверяет DoT-серверы из defaults/dns-
# geo-servers.list (nfqws2-helper -geoscan) и берёт самые быстрые из тех, что
# для доменов-образцов отдают адреса своих прокси, — см. dns_geo_scan. Свой
# сервер для своих сервисов — профилем. Раньше был ручной выбор (Comss,
# GeoHide, «все сразу»): у каждого свои прокси, и первым отвечал ближний, а не
# тот, чей прокси работает в этой сети
dns_geo_label() {
  local p; p=$(dns_geo_pick | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  if [ -n "$p" ]; then echo "$p"; else echo "Comss — до первой проверки"; fi
}
# Серверы обхода геоблока через пробел: пул проверки, пока её не было — DoH Comss
dns_geo_servers() {
  local h; h=$(dns_geo_pick_up | tr '\n' ' ' | sed 's/ $//')
  echo "${h:-$DNS_GEO_FALLBACK}"
}

# ---------------------------------------------------------------- авто-выбор
# Проверка серверов — своя для каждой сети (ключ — DNS сети): то, что
# открывается у одного оператора, у другого может быть закрыто. Строки файла —
# вывод nfqws2-helper -geoscan (сервер ok|fail мс прокси образцов отметки),
# первая — «#time=… boot=…».
dns_geo_net_key() {
  local s; s=$(dns_net_servers); [ -n "$s" ] || s=default
  printf '%s' "$s" | tr -c 'A-Za-z0-9.' '_'
}
dns_geo_scan_file() { echo "$DNS_GEO_SCAN_DIR/$(dns_geo_net_key).tsv"; }
dns_geo_scan_time() { sed -n '1s/^#time=\([0-9]*\).*/\1/p' "$(dns_geo_scan_file)" 2>/dev/null; }
# Пул: доступные серверы с наибольшим покрытием образцов (прокси для всех,
# если такие есть), самые быстрые — до DNS_GEO_POOL штук. Сервер, который
# обслуживает только часть сервисов (dns.zapret.moe — сервисы ИИ), в общий
# пул не идёт, пока есть серверы шире: dnsproxy берёт первый ответ, и его
# «настоящий» адрес для игры увёл бы её в геоблок
dns_geo_pool() { # -> «мс сервер протокол» пула, лучшие сверху
  local f; f=$(dns_geo_scan_file); [ -s "$f" ] || return 0
  awk -F'\t' '!/^#/ && $2 == "ok" && $4 > 0 { c++; h[c] = $1; ms[c] = $3; pr[c] = ($7 == "https" ? "https" : "tls"); p[c] = $4 + 0; if (p[c] > max) max = p[c] }
    END { for (i = 1; i <= c; i++) if (p[i] == max) print ms[i] "\t" h[i] "\t" pr[i] }' "$f" | sort -n | head -n "$DNS_GEO_POOL"
}
dns_geo_pick() { dns_geo_pool | cut -f2; }
# Адреса пула для dnsproxy: DoT, а где в этой сети прошёл только DoH — DoH
dns_geo_pick_up() {
  dns_geo_pool | awk -F'\t' '{ print ($3 == "https" ? "https://" $2 "/dns-query" : "tls://" $2) }'
}
# Пора проверять: проверки в этой сети не было, она старше DNS_GEO_SCAN_EVERY
# или ни один сервер тогда не ответил (сеть ещё не поднялась) — через 10 минут
dns_geo_scan_due() {
  local t now f
  dns_geo_on && [ -x "$HELPER_BIN" ] || return 1
  f=$(dns_geo_scan_file); t=$(dns_geo_scan_time); now=$(date +%s)
  [ -n "$t" ] || return 0
  [ $((now - t)) -ge "$DNS_GEO_SCAN_EVERY" ] && return 0
  grep -q '	ok	' "$f" 2>/dev/null && return 1
  [ $((now - t)) -ge 600 ]
}
# Проверить серверы; пул сменился — применить. Запросов немного (сервер —
# одно соединение и по запросу на образец), раз в несколько часов
dns_geo_scan() {
  local f boot cand before after n ok lock="$DNS_RUN_DIR/geoscan.lock"
  [ -x "$HELPER_BIN" ] && [ -f "$DNS_GEO_CAND" ] || return 1
  mkdir -p "$DNS_GEO_SCAN_DIR" "$DNS_RUN_DIR"
  # прошлая проверка оборвалась — её метка старше двух минут
  [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 0
  boot=$(dns_net_servers | tr ',' '\n' | awk '/^[0-9]+(\.[0-9]+)(\.[0-9]+)(\.[0-9]+)$/ { print; exit }')
  boot="${boot:-77.88.8.8}:53"
  cand=$(tr -d '\r' < "$DNS_GEO_CAND" | sed 's/[[:space:]]*#.*//; s/[[:space:]]//g' | awk NF | tr '\n' ',' | sed 's/,$//')
  f=$(dns_geo_scan_file); before=$(dns_geo_pick | tr '\n' ' ')
  { echo "#time=$(date +%s) boot=$boot"
    "$HELPER_BIN" -geoscan "$cand" -samples "$DNS_GEO_SAMPLES" -boot "$boot" -wait 8s 2>/dev/null
  } > "$f.tmp" && mv -f "$f.tmp" "$f"
  rmdir "$lock" 2>/dev/null
  after=$(dns_geo_pick | tr '\n' ' ')
  n=$(grep -c -v '^#' "$f" 2>/dev/null); ok=$(grep -c '	ok	' "$f" 2>/dev/null)
  dns_log "проверка DNS обхода геоблока: ответили ${ok:-0} из ${n:-0}; пул — ${after:-пусто (остаётся Comss)}"
  [ "$before" != "$after" ] && dns_apply_now
  return 0
}
# Кулдаун: <время прошлого раза, unix> <секунд>. Рано — сообщение и код 1
dns_cool() {
  local left
  [ -n "$1" ] || return 0
  left=$(( $1 + $2 - $(date +%s) ))
  [ "$left" -gt 0 ] || return 0
  echo "Слишком часто — повторить можно через $(( (left + 59) / 60 )) мин" >&2
  return 1
}
# Включённые свои профили, перехватывающие домены из списка геоблока (в
# умном режиме у профиля свой маршрут, и обход геоблока для этих доменов не
# работает): строки «id число» — сколько доменов списка уходит в профиль
dns_geo_overlap() {
  local f id
  dns_geo_on && [ -s "$DNS_GEO_LIST" ] || return 0
  for f in "$DNS_PROFILES_DIR"/*.conf; do
    [ -f "$f" ] && grep -q '^ENABLED=1$' "$f" 2>/dev/null || continue
    id=${f##*/}; id=${id%.conf}
    dns_geo_profile "$id" && continue
    sed -n 's/^DOMAIN=//p' "$f" | tr -d '\r' | tr 'A-Z' 'a-z' | awk -v id="$id" -v lf="$DNS_GEO_LIST" '
      BEGIN { while ((getline l < lf) > 0) { sub(/[[:space:]]*#.*/, "", l); gsub(/[[:space:]]/, "", l); if (l != "") g[tolower(l)] = 1 } }
      NF { p[$0] = 1 }
      END {
        for (d in g) { x = d; while (1) { if (x in p) { n++; break }; if ((i = index(x, ".")) == 0) break; x = substr(x, i + 1) } }
        if (n) print id, n
      }'
  done
}
# В фоне, отвязанно: проверка идёт до 10 секунд, ждать её никому не нужно
dns_geo_scan_bg() {
  ( dns_geo_scan >/dev/null 2>&1 & ) 2>/dev/null
}

# Обновить список геоблока: свежий geoblock из itdoginfo и домены пресета
# GeoHide добавляются к тому, что уже есть, — свои домены пользователя
# остаются. Код 1 — не скачалось (старый список не тронут). -> число доменов
dns_geo_update() {
  local tmp="$DNS_GEO_LIST.dl" n
  hosts_download "$DNS_GEO_URL" "$tmp" || { rm -f "$tmp"; return 1; }
  tr -d '\r' < "$tmp" | tr 'A-Z' 'a-z' | sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' |
    grep -E '^[a-z0-9.-]+\.[a-z0-9-]+$' > "$tmp.ok"
  rm -f "$tmp"
  [ "$(grep -c . "$tmp.ok" 2>/dev/null)" -ge 50 ] || { rm -f "$tmp.ok"; return 1; }
  {
    grep '^#' "$DNS_GEO_LIST" 2>/dev/null
    { grep -v '^#' "$DNS_GEO_LIST" 2>/dev/null; cat "$tmp.ok"
      sed -n 's/^DOMAIN=//p' "$DNS_PRESETS_DIR/geohide.conf" 2>/dev/null; } |
      tr -d '\r' | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . | sort -u
  } > "$DNS_GEO_LIST.new"
  rm -f "$tmp.ok"
  mv -f "$DNS_GEO_LIST.new" "$DNS_GEO_LIST" && chmod 0644 "$DNS_GEO_LIST" || return 1
  mkdir -p "$DNS_DIR"; date +%s > "$DNS_DIR/geo_updated"
  n=$(dns_geo_count); echo "$n"
}

dns_default() {
  local d=""
  [ -f "$DNS_DEFAULT_FILE" ] && IFS= read -r d < "$DNS_DEFAULT_FILE"
  case "$d" in ''|*[!a-z0-9_-]*) d=net ;; esac
  printf '%s' "$d"
}
# DNS по умолчанию, который работает сейчас. В умном режиме — всегда DNS сети:
# он самый быстрый (кэши оператора рядом), а сервисы с геоблоком идут по
# списку в DNS с обходом. Выбранный пользователем — для режима «Профили»
dns_default_used() {
  if [ "${DNS_GEO:-1}" = 1 ]; then printf net; else dns_default; fi
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
  # chmod: nfqws2-ctl работает с umask 077, и после mv файл стал бы 0600
  sed "s/^ENABLED=.*/ENABLED=$2/" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f" && chmod 0644 "$f" ||
    { rm -f "$f.tmp"; return 1; }
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

# Профили, которые участвуют в правилах. В умном режиме профили DNS обхода
# геоблока (GeoHide, Comss, zapret.moe, malw — пресеты, включённые как свои
# профили) своих правил не ставят: их домены идут в обход геоблока вместе со
# списком. Иначе включённый профиль GeoHide со своими 352 доменами уводил
# Claude и остальное на прокси GeoHide при любом выборе DNS для обхода
DNS_GEO_PROFILE_IDS="geohide comss zapret malw"
dns_geo_profile() { dns_geo_on && case " $DNS_GEO_PROFILE_IDS " in *" $1 "*) return 0 ;; esac; return 1; }
dns_profile_files() {
  local f id
  for f in "$DNS_PROFILES_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.conf}
    dns_geo_profile "$id" || echo "$f"
  done
}
# Домены включённых профилей: own — с собственным маршрутом, geo — профилей
# обхода геоблока (в умном режиме они уходят в обход геоблока)
dns_profile_domains() {
  local f id
  for f in "$DNS_PROFILES_DIR"/*.conf; do
    [ -f "$f" ] && grep -q '^ENABLED=1$' "$f" 2>/dev/null || continue
    id=${f##*/}; id=${id%.conf}
    if dns_geo_profile "$id"; then [ "$1" = geo ] || continue; else [ "$1" = own ] || continue; fi
    sed -n 's/^DOMAIN=//p' "$f"
  done | tr -d '\r'
}

# ---------------------------------------------------------------- конфиг dnsproxy
# Пишет $DNS_RUN_DIR/upstreams.txt (основные серверы и правила по доменам),
# fallback.txt и args (аргументы запуска). Код 1 — включённых правил нет,
# и перехватывать нечего: DNS по умолчанию «DNS сети» и ни одного профиля.
dns_build() {
  local def net up="$DNS_RUN_DIR/upstreams.txt.new" ip routed
  mkdir -p "$DNS_RUN_DIR"
  def=$(dns_default_used)
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
    END { flush() }' $(dns_profile_files) < /dev/null 2>/dev/null > "$up.rules"
  if dns_push_on; then
    local d s pl="[/"
    for d in $DNS_PUSH_DOMAINS; do pl="$pl$d/"; done
    for s in $DNS_PUSH_SERVERS; do echo "$pl]$s"; done >> "$up.rules"
  fi
  # Умный DNS: домены CDN, которых нет во включённых профилях, — к
  # CDN-экземпляру. Из DNS сети: у оператора — ближние кэши
  rm -f "$DNS_RUN_DIR/cdn.args.new" "$DNS_RUN_DIR/cdn.upstreams.txt.new"
  if dns_smart_on && [ -f "$DNS_CDN_LIST" ]; then
    local cdn f
    dns_profile_domains own > "$DNS_RUN_DIR/cdn.taken"
    cdn=$(tr -d '\r' < "$DNS_CDN_LIST" | awk -v tf="$DNS_RUN_DIR/cdn.taken" '
      BEGIN { while ((getline l < tf) > 0) taken[l] = 1 }
      /^[[:space:]]*(#|$)/ { next } !($1 in taken) { printf "%s/", $1 }')
    rm -f "$DNS_RUN_DIR/cdn.taken"
    if [ -n "$cdn" ]; then
      echo "[/$cdn]127.0.0.1:$DNS_CDN_PORT" >> "$up.rules"
      for ip in $(printf '%s' "$net" | tr ',' ' ') $DNS_PUBLIC; do dns_addr_port "$ip"; echo; done > "$DNS_RUN_DIR/cdn.upstreams.txt.new"
      {
        echo "-l"; echo "127.0.0.1"
        echo "-p"; echo "$DNS_CDN_PORT"
        echo "-u"; echo "$DNS_RUN_DIR/cdn.upstreams.txt"
        echo "--cache"; echo "--cache-optimistic"
        # ждёт ответа всех серверов: молчащий не должен задерживать надолго.
        # DNS в сети отвечает за 30–100 мс, ответ позже секунды — уже потеря
        echo "--timeout=1s"
        echo "--upstream-mode=fastest_addr"
        [ "${LOG_LEVEL:-0}" = 1 ] && echo "-v"
      } > "$DNS_RUN_DIR/cdn.args.new"
    fi
  fi
  # Обход геоблока: домены списка (и профилей обхода геоблока) — серверам
  # dns_geo_servers; проверки серверов в этой сети ещё не было или она
  # устарела — в фоне, пул применится по её итогу. Без доменов, у которых свой маршрут (профили, CDN, push Google), и
  # без «никогда в обход»; совпадение — по окончанию имени, как у dnsproxy
  if dns_geo_on && [ -s "$DNS_GEO_LIST" ]; then
    local gp gs
    dns_geo_scan_due && dns_geo_scan_bg
    gs=$(dns_geo_servers)
    {
      dns_profile_domains own
      cat "$DNS_GEO_NEVER" "$DNS_CDN_LIST" 2>/dev/null
      for gp in $DNS_PUSH_DOMAINS; do echo "$gp"; done
    } | tr -d '\r' > "$DNS_RUN_DIR/geo.skip"
    { cat "$DNS_GEO_LIST"; dns_profile_domains geo; } | tr -d '\r' | tr 'A-Z' 'a-z' | awk -v sf="$DNS_RUN_DIR/geo.skip" -v srv="$gs" '
      BEGIN { while ((getline l < sf) > 0) { sub(/[[:space:]]*#.*/, "", l); if (l != "") skip[l] = 1 }; ns = split(srv, s, " ") }
      { sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "") }
      $0 == "" || seen[$0]++ { next }
      { d = $0; while (1) { if (d in skip) next; if ((i = index(d, ".")) == 0) break; d = substr(d, i + 1) }; dom[++nd] = $0 }
      END {
        if (!ns) exit
        for (k = 1; k <= nd; k += 100) {
          line = "[/"
          for (j = k; j <= nd && j < k + 100; j++) line = line dom[j] "/"
          for (i = 1; i <= ns; i++) print line "]" s[i]
        }
      }' >> "$up.rules"
    rm -f "$DNS_RUN_DIR/geo.skip"
  fi
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
  # остатки арбитра geodns прежних версий
  rm -f "$DNS_RUN_DIR"/geo.* "$DNS_RUN_DIR/main_port" "$DNS_RUN_DIR/geo_failed"
  if [ -f "$DNS_RUN_DIR/cdn.args.new" ]; then
    mv -f "$DNS_RUN_DIR/cdn.upstreams.txt.new" "$DNS_RUN_DIR/cdn.upstreams.txt"
    mv -f "$DNS_RUN_DIR/cdn.args.new" "$DNS_RUN_DIR/cdn.args"
  else
    rm -f "$DNS_RUN_DIR/cdn.upstreams.txt" "$DNS_RUN_DIR/cdn.args"
  fi

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
    dns_smart_on && echo "--cache-optimistic"
    echo "--timeout=5s"
    # parallel: запрос — всем серверам профиля, ответ — от первого ответившего.
    # В load_balance он уходил одному случайному, и молчащий сервер (часть DNS
    # с геоблоком не отвечает на запросы типа HTTPS) давал ошибку и ожидание
    echo "--upstream-mode=parallel"
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
    # каталог без pid дольше секунды — владелец умер между mkdir и записью pid;
    # первую секунду ждём: он может как раз записывать
    if [ -z "$owner" ] && [ "$i" -ge 5 ]; then
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
dns_cdn_pid() {
  local p=""
  [ -f "$DNS_CDN_PIDFILE" ] && IFS= read -r p < "$DNS_CDN_PIDFILE"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  dns_alive "$p" || return 1
  printf '%s' "$p"
}
# dnsproxy этого модуля (по пути бинарника), кроме основного из аргумента и
# CDN-экземпляра умного DNS
dns_own_pids() { # [исключить PID]
  local p exe cdn
  cdn=$(dns_cdn_pid)
  for p in $(pidof dnsproxy 2>/dev/null); do
    [ "$p" = "$1" ] && continue
    [ -n "$cdn" ] && [ "$p" = "$cdn" ] && continue
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
# а следующая за окном — со счётчиком пропущенных. Недоставленные ответы на
# сменившийся адрес телефона — одна строка на адрес. С LOG_LEVEL=1 — всё как есть.
DNS_LOG_FILTER='
function tsec(t,   a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + int(a[3]) }
{
  if (index($0, " ERROR response received ")) next
  # остановка: TLS-соединение к серверу закрылось раньше прощального пакета — норма
  if (index($0, "failed to send closeNotify")) next
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
  # Ответ на адрес, которого у телефона уже нет: сеть переподключилась и
  # сменила адрес, пока запросы были в пути. Таких строк — десятки за
  # миллисекунду; оставляем первую с пояснением, повторы на тот же адрес — нет
  if (index($0, " ERROR responding request ") && index($0, "network is unreachable")) {
    ip = ""; if (match($0, /->[0-9.]+:/)) ip = substr($0, RSTART + 2, RLENGTH - 3)
    now = tsec($2) + day * 86400
    if (now < prev) { day++; now += 86400 }
    prev = now
    if ((ip in gone) && now - gone[ip] < 300) next
    gone[ip] = now
    print
    printf "%s %s INFO nfqws2: ответ не доставлен на %s — у телефона сменился адрес (сеть переподключилась), повторы скрыты\n", $1, $2, ip
    fflush()
    next
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
  # Фильтр защищён так же, как dnsproxy: запущенный из WebUI, он иначе
  # погибает вместе с приложением, и dnsproxy молча завершается на первой же
  # записи в журнал (Go выходит по SIGPIPE на stdout/stderr) — DNS пропадает
  local out="$DNS_LOG" fifo="$DNS_RUN_DIR/log.fifo"
  rm -f "$fifo"
  if [ "${LOG_LEVEL:-0}" != 1 ] && mkfifo "$fifo" 2>/dev/null; then
    awk "$DNS_LOG_FILTER" < "$fifo" >> "$DNS_LOG" 2>/dev/null &
    protect_process "$!"
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
  local port=$DNS_PORT
  while [ "$i" -lt 20 ]; do
    dns_alive "$pid" || break
    grep -qi ":$(printf '%04X' "$port") " /proc/net/udp /proc/net/udp6 2>/dev/null && { listen=1; break; }
    sleep 0.2; i=$((i + 1))
  done
  if ! dns_alive "$pid"; then
    wait "$pid" 2>/dev/null
    rm -f "$DNS_PIDFILE"
    dns_fail "dnsproxy не запустился: $(grep -v '] nfqws2: ' "$DNS_LOG" 2>/dev/null | tail -n 1)"
    return 1
  fi
  if [ "$listen" = 1 ]; then dns_log "dnsproxy запущен, PID $pid, порт $port"
  else dns_log "dnsproxy запущен (PID $pid), но порт $port за 4 с не открылся — ждём дальше"; fi
  protect_process "$pid"
  cp -f "$DNS_RUN_DIR/upstreams.txt" "$DNS_RUN_DIR/running.upstreams" 2>/dev/null
  cp -f "$DNS_RUN_DIR/args" "$DNS_RUN_DIR/running.args" 2>/dev/null
  read -r i _ < /proc/uptime && echo "${i%.*}" > "$DNS_RUN_DIR/started_at"
  dns_cdn_start
  return 0
}

# CDN-экземпляр умного DNS. Не поднялся — не беда: основной всё равно
# отвечает, домены CDN тогда идут на его запасные серверы
dns_cdn_start() {
  local pid i
  dns_cdn_stop
  [ -f "$DNS_RUN_DIR/cdn.args" ] || return 0
  (
    set -f
    IFS='
'
    exec 0</dev/null >>"$DNS_LOG" 2>&1
    exec "$DNS_BIN" $(cat "$DNS_RUN_DIR/cdn.args")
  ) &
  pid=$!
  echo "$pid" > "$DNS_CDN_PIDFILE"
  i=0
  while [ "$i" -lt 10 ]; do
    dns_alive "$pid" || break
    grep -qi ":$(printf '%04X' "$DNS_CDN_PORT") " /proc/net/udp 2>/dev/null && break
    sleep 0.2; i=$((i + 1))
  done
  if ! dns_alive "$pid"; then
    wait "$pid" 2>/dev/null; rm -f "$DNS_CDN_PIDFILE"
    dns_log "умный DNS: dnsproxy для видео и CDN не запустился — эти домены идут через основной"
    return 1
  fi
  protect_process "$pid"
  cp -f "$DNS_RUN_DIR/cdn.args" "$DNS_RUN_DIR/running.cdn.args" 2>/dev/null
  cp -f "$DNS_RUN_DIR/cdn.upstreams.txt" "$DNS_RUN_DIR/running.cdn.upstreams" 2>/dev/null
  dns_log "умный DNS: видео и CDN — самый быстрый адрес (PID $pid, порт $DNS_CDN_PORT)"
}
dns_cdn_stop() {
  local pid
  pid=$(dns_cdn_pid) && { kill -TERM "$pid" 2>/dev/null; sleep 0.2; dns_alive "$pid" && kill -KILL "$pid" 2>/dev/null; }
  rm -f "$DNS_CDN_PIDFILE" "$DNS_RUN_DIR/running.cdn.args" "$DNS_RUN_DIR/running.cdn.upstreams"
}
# CDN-экземпляр в том виде, в каком его сейчас нужно: оба файла совпадают с
# запущенным (или CDN не нужен и не запущен)
dns_cdn_same() {
  if [ -f "$DNS_RUN_DIR/cdn.args" ]; then
    dns_cdn_pid >/dev/null && cmp -s "$DNS_RUN_DIR/cdn.args" "$DNS_RUN_DIR/running.cdn.args" &&
      cmp -s "$DNS_RUN_DIR/cdn.upstreams.txt" "$DNS_RUN_DIR/running.cdn.upstreams"
  else
    ! dns_cdn_pid >/dev/null
  fi
}

dns_proxy_stop() {
  local pid
  pid=$(dns_pid) && {
    kill -TERM "$pid" 2>/dev/null; sleep 0.3; dns_alive "$pid" && kill -KILL "$pid" 2>/dev/null
    dns_log "dnsproxy (PID $pid) остановлен"
  }
  rm -f "$DNS_PIDFILE" "$DNS_RUN_DIR/running.upstreams" "$DNS_RUN_DIR/running.args"
  dns_cdn_stop
}

# ---------------------------------------------------------------- перехват
# В nat OUTPUT: непомеченные пакеты (не от netd, в том числе сам dnsproxy) —
# мимо, остальные UDP/TCP на порт 53 — в dnsproxy. Для IPv6 то же через
# ip6tables nat; если ядро его не умеет — отказ IPv6-запросам netd, чтобы
# резолвер ушёл на IPv4-серверы сети (только если такие есть, иначе DNS
# пропал бы совсем).
# Запросы, уходящие в туннель VPN (tun, wg, ppp, ipsec, tap), не трогаем: у них
# свой DNS внутри туннеля, а ответ dnsproxy с 127.0.0.1 на адрес туннеля ядро
# отвергает («sendmsg: invalid argument»), и запрос пропадал
DNS_VPN_IFACES="tun+ wg+ ppp+ ipsec+ tap+"
_dns_skip_vpn() { # <iptables|ip6tables> <таблица> <цепочка>
  local i
  for i in $DNS_VPN_IFACES; do $1 -w -t "$2" -A "$3" -o "$i" -j RETURN || return 1; done
}
_dns_chain_nat() { # <iptables|ip6tables>
  local C="$1"
  $C -w -t nat -N $DNS_CHAIN 2>/dev/null
  $C -w -t nat -F $DNS_CHAIN 2>/dev/null &&
  _dns_skip_vpn "$C" nat $DNS_CHAIN &&
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
         _dns_skip_vpn ip6tables filter $DNS_CHAIN6F &&
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
  # цепочки «мимо VPN» версии 2.1.2 — снять, если остались
  _dns_unchain iptables mangle nfqws_dnsm
  while iptables -w -t nat -D POSTROUTING -j nfqws_dnss 2>/dev/null; do :; done
  iptables -w -t nat -F nfqws_dnss 2>/dev/null; iptables -w -t nat -X nfqws_dnss 2>/dev/null
  rm -f "$DNS_RUN_DIR/ipv6"
}

dns_rules_ok() { iptables -w -t nat -C OUTPUT -j $DNS_CHAIN 2>/dev/null; }

# ---------------------------------------------------------------- жизненный цикл
# Загрузка: всё в $DNS_RUN_DIR — от прошлой загрузки. Старый PID мог достаться
# другому процессу, и dns_start счёл бы dnsproxy живым.
dns_boot_reset() {
  # standalone — флаг прежних версий: теперь DNS всегда работает сам по себе
  # geodns.pid, running.geo.* — от арбитра geodns прежних версий
  rm -f "$DNS_DIR/standalone" "$DNS_PIDFILE" "$DNS_CDN_PIDFILE" "$STATE_DIR/geodns.pid" "$DNS_RUN_DIR/running.upstreams" "$DNS_RUN_DIR/running.args" \
        "$DNS_RUN_DIR/running.cdn.args" "$DNS_RUN_DIR/running.cdn.upstreams" "$DNS_RUN_DIR/geo_failed" \
        "$DNS_RUN_DIR/running.geo.args" "$DNS_RUN_DIR/running.geo.providers" "$DNS_RUN_DIR/running.geo.never" \
        "$DNS_RUN_DIR/active" "$DNS_RUN_DIR/error" "$DNS_RUN_DIR/ipv6" \
        "$DNS_RUN_DIR/bypass" "$DNS_RUN_DIR/bypass_fail" "$DNS_RUN_DIR/runner" 2>/dev/null
}

# Нужен ли перехват сейчас. DNS работает независимо от службы обхода:
# остановка службы и её пауза его не трогают. Но при VPN DNS модуля на паузе —
# как «Частный DNS» Android: DNS приложений и так идёт через VPN, а перехват
# заворачивал бы в туннель и сам dnsproxy. В домашнем Wi‑Fi — на паузе, только
# если так выбрано в настройках домашнего Wi‑Fi. Есть ли что применять,
# решает dns_build.
dns_vpn_paused() { vpn_active; }
# Домашний Wi‑Fi определяет home_check (service.sh) и пишет SSID в HOME_AT_FILE
dns_home_paused() { [ -f "$DNS_HOME_FILE" ] && [ "${HOME_WIFI:-0}" = 1 ] && [ -s "$HOME_AT_FILE" ]; }
dns_pause_reason() { # vpn | home | пусто
  if dns_vpn_paused; then echo vpn
  elif dns_home_paused; then echo home
  fi
}
dns_wanted() { dns_enabled && [ -z "$(dns_pause_reason)" ]; }

# Что будет применено — одной строкой в журнал DNS
dns_describe() {
  local def net up rules prof pm
  def=$(dns_default_used); net=$(cat "$DNS_RUN_DIR/net_dns" 2>/dev/null)
  rules=$(grep -c '^\[/' "$DNS_RUN_DIR/upstreams.txt" 2>/dev/null)
  prof=$(grep -l '^ENABLED=1$' "$DNS_PROFILES_DIR"/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##' | tr '\n' ' ' | sed 's/ $//')
  up=$(grep -v '^\[/' "$DNS_RUN_DIR/upstreams.txt" 2>/dev/null | grep . | tr '\n' ' ' | sed 's/ $//')
  if [ "$def" = net ]; then def="DNS сети"; else def="профиль $def"; fi
  dns_log "по умолчанию: $def ($up); включённые профили: ${prof:-нет}; правил по доменам: ${rules:-0}; DNS сети: ${net:-не определён}$(dns_push_on && echo "; push-уведомления Google — через DNS Google")$([ -f "$DNS_RUN_DIR/cdn.args" ] && echo "; умный DNS: видео и CDN — самый быстрый адрес из DNS сети и публичных, оптимистичный кэш")$(dns_geo_on && echo "; обход геоблока: доменов из списка — $(dns_geo_count), через DNS с обходом ($(dns_geo_label))")"
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
_dns_start() { # <причина> [force — перезапуск dnsproxy и при том же конфиге]
  local why="${1:-запрос}"
  dns_init
  if ! dns_wanted; then
    case "$(dns_enabled && dns_pause_reason)" in
      vpn)  _dns_stop "$why: включён VPN — DNS модуля на паузе" ;;
      home) _dns_stop "$why: домашний Wi‑Fi — DNS модуля на паузе" ;;
      *)    _dns_stop "$why: не нужен" ;;
    esac
    return 0
  fi
  if ! dns_build; then _dns_stop "$why: применять нечего — DNS сети и нет включённых профилей"; return 0; fi
  mkdir -p "$DNS_RUN_DIR"
  # Свежий dnsproxy (меньше 20 с) с тем же конфигом уже открыл соединения в
  # новой сети: одна смена сети — несколько событий и запуск службы, и он
  # перезапускался трижды за 15 секунд
  if [ "$2" = force ] && dns_fresh; then set -- "$1"; fi
  if [ "$2" = force ] && dns_pid >/dev/null && dns_rules_ok; then
    # Сеть или VPN сменились: соединения dnsproxy к серверам привязаны к старой
    # сети. Правила перехвата не снимаем — на время перезапуска (доли секунды)
    # запросы получают отказ и повторяются, но к DNS оператора не уходят
    dns_log "$why: сеть или VPN сменились — перезапуск dnsproxy"
    dns_describe
    dns_proxy_stop
    if ! dns_proxy_start; then dns_rules_del; return 1; fi
    rm -f "$DNS_RUN_DIR/error"
    return 0
  fi
  if dns_pid >/dev/null && cmp -s "$DNS_RUN_DIR/upstreams.txt" "$DNS_RUN_DIR/running.upstreams" &&
     cmp -s "$DNS_RUN_DIR/args" "$DNS_RUN_DIR/running.args"; then
    # основной тот же, а CDN-экземпляр умного DNS изменился или упал
    dns_cdn_same || dns_cdn_start
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
dns_fresh() { # запущен меньше 20 с назад с тем конфигом, что собран сейчас
  local at up
  dns_pid >/dev/null || return 1
  cmp -s "$DNS_RUN_DIR/upstreams.txt" "$DNS_RUN_DIR/running.upstreams" &&
    cmp -s "$DNS_RUN_DIR/args" "$DNS_RUN_DIR/running.args" || return 1
  [ -f "$DNS_RUN_DIR/started_at" ] && IFS= read -r at < "$DNS_RUN_DIR/started_at" || return 1
  read -r up _ < /proc/uptime
  [ $(( ${up%.*} - ${at:-0} )) -lt 20 ]
}
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
# Процесс жив — ещё не значит, что он отвечает. Помощник спрашивает dnsproxy
# (и CDN-экземпляр) о том, на что тот отвечает сам, без серверов (helper/
# probe.go): молчащие серверы и пропавшая сеть сюда не попадают — только
# зависший dnsproxy. Два раза подряд без ответа (watchdog спрашивает раз в
# минуту) — перезапуск. Без помощника проверки нет
dns_probe_check() {
  local ports="127.0.0.1:$DNS_PORT" n=0
  [ -x "$HELPER_BIN" ] || return 0
  [ -f "$DNS_RUN_DIR/cdn.args" ] && ports="$ports,127.0.0.1:$DNS_CDN_PORT"
  if "$HELPER_BIN" -probe "$ports" >/dev/null 2>"$DNS_RUN_DIR/probe.err"; then
    rm -f "$DNS_RUN_DIR/probe_fail" "$DNS_RUN_DIR/probe.err"
    return 0
  fi
  [ -f "$DNS_RUN_DIR/probe_fail" ] && IFS= read -r n < "$DNS_RUN_DIR/probe_fail"
  n=$((${n:-0} + 1))
  if [ "$n" -lt 2 ]; then echo "$n" > "$DNS_RUN_DIR/probe_fail"; return 0; fi
  rm -f "$DNS_RUN_DIR/probe_fail"
  dns_log "watchdog: dnsproxy работает, но не отвечает на запросы ($(sed 's/^nfqws2-helper: [0-9/]* [0-9:]* //' "$DNS_RUN_DIR/probe.err" | tr '\n' ' ')) — перезапуск"
  log_msg "DNS: dnsproxy завис — перезапуск (подробности — в журнале DNS)"
  dns_proxy_stop
  if dns_proxy_start; then log_msg "DNS: dnsproxy перезапущен"; else dns_rules_del; fi
  rm -f "$DNS_RUN_DIR/probe.err"
}

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
    elif [ -f "$DNS_RUN_DIR/cdn.args" ] && ! dns_cdn_pid >/dev/null; then
      dns_log "watchdog: dnsproxy умного DNS (видео и CDN) не работает — перезапуск"
      dns_cdn_start
    elif ! dns_rules_ok; then
      dns_log "watchdog: правила перехвата пропали — восстанавливаю"
      dns_rules_add || dns_fail "не удалось восстановить перехват"
    elif [ "${DNS_PROBE:-1}" = 1 ]; then
      dns_probe_check
      dns_geo_scan_due && dns_geo_scan_bg
    fi
  elif dns_pid >/dev/null || dns_rules_ok; then
    _dns_stop "watchdog: больше не нужен"
  fi
}

# Куда DNS модуля отправит домен: geo — DNS с обходом геоблока, cdn — умный
# DNS видео и CDN, rule <сервер> — профиль, default — DNS по умолчанию,
# off — DNS модуля не работает
dns_route() { # <домен>
  local up="$DNS_RUN_DIR/upstreams.txt"
  dns_pid >/dev/null && [ -f "$up" ] || { echo off; return; }
  awk -v d="$1" -v cdn="127.0.0.1:$DNS_CDN_PORT" -v geo="$(dns_geo_servers 2>/dev/null)" '
    BEGIN { n = split(d, p, "."); for (i = 1; i <= n; i++) { s = p[i]; for (j = i + 1; j <= n; j++) s = s "." p[j]; c[s] = 1 } }
    /^\[\// {
      k = index($0, "/]"); doms = substr($0, 3, k - 3); srv = substr($0, k + 2)
      m = split(doms, a, "/")
      for (i = 1; i <= m; i++) if ((a[i] in c) && length(a[i]) > best) { best = length(a[i]); hit = srv }
    }
    END {
      if (hit == "") print "default"
      else if (hit == cdn) print "cdn"
      else if (index(" " geo " ", " " hit " ")) print "geo"
      else print "rule " hit
    }' "$up"
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
  echo "paused=$(dns_enabled && dns_pause_reason)"
  echo "home_pause=$([ -f "$DNS_HOME_FILE" ] && echo 1 || echo 0)"
  echo "push=$(dns_push_on && echo 1 || echo 0)"
  echo "smart=$(dns_smart_on && echo 1 || echo 0)"
  echo "cdn=$(dns_cdn_pid >/dev/null && echo running || { [ -f "$DNS_RUN_DIR/cdn.args" ] && echo down; })"
  # обход геоблока: сколько доменов в списке и когда его обновляли (unix)
  echo "geo=$(dns_geo_on && echo on || echo off)"
  echo "geo_label=$(dns_geo_label)"
  echo "geo_scan_time=$(dns_geo_scan_time)"
  echo "geo_pool=$(dns_geo_pick | tr '\n' ' ' | sed 's/ $//')"
  echo "geo_domains=$(dns_geo_count)"
  dns_geo_overlap | while read -r id n; do echo "geo_overlap_$id=$n"; done
  echo "geo_updated=$(cat "$DNS_DIR/geo_updated" 2>/dev/null)"
  echo "default=$(dns_default)"
  echo "default_used=$(dns_default_used)"
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
  # проверка DNS обхода геоблока в этой сети: строки nfqws2-helper -geoscan
  echo "#geoscan"
  grep -v '^#' "$(dns_geo_scan_file)" 2>/dev/null
  for f in "$DNS_PROFILES_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id="${f##*/}"; echo "#profile ${id%.conf}"; cat "$f"
  done
  for f in "$DNS_PRESETS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id="${f##*/}"; echo "#preset ${id%.conf}"; cat "$f"
  done
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
  local cmd="$1" n; shift
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
    dns-set-home) # пауза DNS в домашнем Wi‑Fi (экран домашнего Wi‑Fi)
      dns_init
      case "$1" in
        1) : > "$DNS_HOME_FILE" ;;
        0) rm -f "$DNS_HOME_FILE" ;;
        *) echo "Допустимо 0 или 1" >&2; return 1 ;;
      esac
      sh "$MODDIR/service.sh" home_check >/dev/null 2>&1
      dns_apply_now; echo OK ;;
    dns-restart) # долгое нажатие на «DNS профили»: как выключить и включить, но без смены настроек
      dns_init
      dns_enabled || { echo "DNS выключен" >&2; return 1; }
      case "$(dns_pause_reason)" in
        vpn) echo "DNS на паузе: включён VPN" >&2; return 1 ;;
        home) echo "DNS на паузе: домашний Wi‑Fi" >&2; return 1 ;;
      esac
      dns_stop "перезапуск по запросу" || { echo "Другой запуск DNS не завершился" >&2; return 1; }
      dns_start "перезапуск по запросу" || { echo "DNS не запустился — подробности в журнале DNS" >&2; return 1; }
      dns_pid >/dev/null || { echo "DNS не запустился — подробности в журнале DNS" >&2; return 1; }
      echo OK ;;
    dns-set-default)
      dns_init
      if [ "$1" != net ]; then dns_id_ok "$1" && [ -f "$DNS_PROFILES_DIR/$1.conf" ] || { echo "Профиль не найден" >&2; return 1; }; fi
      echo "$1" > "$DNS_DEFAULT_FILE"; dns_apply_now; echo OK ;;
    dns-save-b64) # <id> <профиль в base64>
      b64d "$2" | dns_profile_save "$1" || return 1
      dns_apply_now; echo OK ;;
    dns-profile-enable) dns_profile_set_enabled "$1" "$2" || return 1; dns_apply_now; echo OK ;;
    # обновить список сервисов с геоблоком и применить
    # dns-geo-scan — проверить DNS обхода геоблока сейчас (кнопка на экране DNS)
    # ручные проверка и обновление — не чаще DNS_GEO_*_COOL: частые вызовы серверам
    # и GitHub только вредят (код 3 — «слишком часто», текст — для тоста)
    dns-geo-scan)
      dns_cool "$(dns_geo_scan_time)" "$DNS_GEO_SCAN_COOL" || return 3
      dns_geo_scan || { echo "Проверка недоступна: нет nfqws2-helper" >&2; return 1; }; dns_geo_label ;;
    dns-geo-update)
      dns_cool "$(cat "$DNS_DIR/geo_updated" 2>/dev/null)" "$DNS_GEO_UPD_COOL" || return 3
      n=$(dns_geo_update) || { echo "Не удалось скачать список — старый оставлен" >&2; return 1; }; dns_apply_now; echo "$n" ;;
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
    *) echo "Неизвестная команда $cmd" >&2; return 1 ;;
  esac
}
