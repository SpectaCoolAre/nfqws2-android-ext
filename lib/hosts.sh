#!/system/bin/sh
# nfqws2-android-ext · lib/hosts.sh — редактор hosts без перезагрузки.
#
# Подмена — как у bindhosts (https://github.com/bindhosts/bindhosts), режим
# «plain bind»: наш файл $HOSTS_FILE монтируется поверх /system/etc/hosts
# (mount --bind в пространстве имён init), и дальше пишется на месте —
# применяется сразу, без перезагрузки и без отдельного модуля. Резолвер
# Android (netd) читает /system/etc/hosts сам, поэтому замена видна всем.
# system/etc/hosts в модуль не кладём: bindhosts и другие hosts-модули
# отключают модули с таким файлом — отключили бы весь nfqws2.
#
# hosts состоит из двух частей, у каждой свой файл:
#   bypass.txt — обход ограничений: «IP домен», правится свободно; заполнить
#     можно пресетом (GeoHide или dns.malw.link — по одному: на один домен
#     резолвер всё равно берёт одну запись, а смесь адресов разных сервисов
#     для одного сайта ломает его чаще, чем помогает);
#   block.txt — блокировка рекламы: собирается из источников (AdAway, AdGuard,
#     рекламная часть dns.malw.link, свои ссылки) и своих доменов
#     (block_custom.txt), минус исключения (whitelist.txt). Огромный — его не
#     открываем в WebUI, только показываем число и даём файлом.
# Итог: заголовок, localhost, обход, строка-разделитель, блокировка; домен из
# обхода в блокировку не попадает. По разделителю hosts снова делится на части.
#
# Подключается из конца lib/common.sh; команды hosts-* — hosts_ctl.

HOSTS_DIR="$CONFDIR/hosts"
HOSTS_ENABLED_FILE="$HOSTS_DIR/enabled"
HOSTS_FILE="$HOSTS_DIR/hosts"                  # смонтирован поверх /system/etc/hosts
HOSTS_BYPASS="$HOSTS_DIR/bypass.txt"           # обход ограничений (редактор)
HOSTS_BLOCK="$HOSTS_DIR/block.txt"             # блокировка — собирается, не правится
HOSTS_BLOCK_CUSTOM="$HOSTS_DIR/block_custom.txt" # свои домены для блокировки
HOSTS_WHITELIST="$HOSTS_DIR/whitelist.txt"     # домены, которые из источников не блокируем
HOSTS_SOURCES="$HOSTS_DIR/sources.txt"         # источники блокировки: preset:<id>, local:imported, ссылка
HOSTS_BYPASS_PRESET="$HOSTS_DIR/bypass_preset" # какой пресет загружен в обход
HOSTS_CACHE="$HOSTS_DIR/cache"
HOSTS_PRESETS_DIR="$MODDIR/defaults/hosts-presets"
HOSTS_TARGET="${HOSTS_TARGET:-/system/etc/hosts}"
HOSTS_MODULES_DIR="${HOSTS_MODULES_DIR:-/data/adb/modules}"
HOSTS_MARK="# nfqws2-android-ext hosts"
HOSTS_SEP="# ==== nfqws2-android-ext: блокировка рекламы ===="
HOSTS_IMPORT_MAX=3000   # блок из прежнего hosts длиннее — в источник, а не в свои домены

hosts_enabled() { [ -f "$HOSTS_ENABLED_FILE" ]; }

# Команда в пространстве имён монтирования init: WebUI и su могут жить в
# своём, а монтирование должно быть общим — его видит netd.
hosts_global() {
  local init_ns
  init_ns=$(readlink /proc/1/ns/mnt 2>/dev/null)
  # Своё пространство init не видно (не root) или оно то же — выполняем как есть
  if [ -z "$init_ns" ] || [ "$init_ns" = "$(readlink /proc/self/ns/mnt 2>/dev/null)" ]; then
    "$@"
  elif command -v nsenter >/dev/null 2>&1; then
    nsenter -t 1 -m -- "$@"
  else
    busybox nsenter -t 1 -m -- "$@"
  fi
}

# Смонтирован ли наш файл: тот же inode у /system/etc/hosts в общем пространстве
hosts_mounted() {
  local a b
  [ -f "$HOSTS_FILE" ] || return 1
  a=$(stat -c '%d:%i' "$HOSTS_FILE" 2>/dev/null)
  b=$(hosts_global stat -L -c '%d:%i' "$HOSTS_TARGET" 2>/dev/null)
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# Другие модули, которые подменяют hosts (bindhosts, AdAway systemless и т. п.):
# вдвоём результат непредсказуем, поэтому включать не даём, пока они включены.
hosts_conflicts() {
  local m id
  for m in "$HOSTS_MODULES_DIR"/*; do
    [ -d "$m" ] || continue
    id=${m##*/}
    case "$id" in nfqws2-android-ext) continue ;; esac
    [ -f "$m/disable" ] || [ -f "$m/remove" ] && continue
    if [ -f "$m/system/etc/hosts" ] || [ "$id" = bindhosts ]; then echo "$id"; fi
  done
}

# Права и контекст SELinux как у системного файла: иначе netd (и приложения)
# не прочитают файл из /data/adb, и имена перестанут резолвиться вовсе.
hosts_set_perm() {
  chmod 0644 "$1" 2>/dev/null
  chown 0:0 "$1" 2>/dev/null
  chcon u:object_r:system_file:s0 "$1" 2>/dev/null || chcon --reference=/system/etc "$1" 2>/dev/null
}

# Чистка: комментарии, CRLF, «IP имя1 имя2» — по строке на имя; адреса
# блокировки (127.0.0.1, ::, ::1, 0) — в 0.0.0.0; не «IP домен» — прочь.
# Голый домен (свои домены для блокировки) — тоже в «0.0.0.0 домен».
hosts_clean() {
  tr -d '\r' | sed 's/#.*//' | awk '
    function out(ip, d) {
      d = tolower(d)
      if (d == "localhost" || d == "localhost.localdomain" || d == "local" || d == "broadcasthost" || d ~ /^ip6-/) return
      if (d ~ /^[a-z0-9_][a-z0-9_.-]*$/ && d ~ /\./) print ip, d
    }
    NF == 1 && $1 ~ /[a-z]/ { out("0.0.0.0", $1); next }
    NF >= 2 && $1 ~ /^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9A-Fa-f]*:[0-9A-Fa-f:.]*|0)$/ {
      ip = $1; if (ip == "127.0.0.1" || ip == "::" || ip == "::1" || ip == "0") ip = "0.0.0.0"
      for (i = 2; i <= NF; i++) out(ip, $i)
    }'
}
hosts_only_bypass() { awk '$1 != "0.0.0.0"'; }
hosts_only_block()  { awk '$1 == "0.0.0.0"'; }

# Разделить hosts (stdin) на обход и блокировку: по разделителю, если он есть,
# иначе по адресу (0.0.0.0 — блокировка). Пишет в $1 (обход) и $2 (блок).
hosts_split() {
  local raw="$HOSTS_DIR/split.raw"
  cat > "$raw"
  if grep -qxF "$HOSTS_SEP" "$raw"; then
    awk -v sep="$HOSTS_SEP" '$0 == sep { exit } { print }' "$raw" | hosts_clean > "$1"
    awk -v sep="$HOSTS_SEP" 'f { print } $0 == sep { f = 1 }' "$raw" | hosts_clean | hosts_only_block > "$2"
  else
    hosts_clean < "$raw" > "$raw.c"
    hosts_only_bypass < "$raw.c" > "$1"
    hosts_only_block < "$raw.c" > "$2"
    rm -f "$raw.c"
  fi
  rm -f "$raw"
}

# Первый запуск: файлов частей нет — берём их из текущего hosts. Дальше
# источник правды — файлы; hosts из них собирается (hosts_assemble).
hosts_init() {
  [ -d "$HOSTS_CACHE" ] || mkdir -p "$HOSTS_CACHE"
  [ -f "$HOSTS_WHITELIST" ] || printf '# Домены, которые не блокировать, даже если они есть в источниках\n' > "$HOSTS_WHITELIST"
  [ -f "$HOSTS_SOURCES" ] || : > "$HOSTS_SOURCES"
  hosts_migrate
  [ -s "$HOSTS_BYPASS" ] && [ -f "$HOSTS_BLOCK_CUSTOM" ] && return 0
  hosts_import
}
# Прежний формат (одна часть, custom.txt): кэш источников хранил и записи
# обхода, а пресеты обхода стояли в sources.txt. Части возьмутся из hosts.
hosts_migrate() {
  local src id
  [ -f "$HOSTS_DIR/custom.txt" ] || return 0
  rm -f "$HOSTS_DIR/custom.txt" "$HOSTS_CACHE"/*.txt "$HOSTS_BYPASS" "$HOSTS_BLOCK_CUSTOM" "$HOSTS_BLOCK"
  hosts_sources | while IFS= read -r src; do
    case "$src" in preset:*) id=${src#preset:}; [ "$(hosts_preset_get "$id" BLOCK)" = 1 ] || continue ;; esac
    echo "$src"
  done > "$HOSTS_SOURCES.tmp"
  mv -f "$HOSTS_SOURCES.tmp" "$HOSTS_SOURCES"
}
# Откуда брать текущий hosts: наш файл, если он подключён, иначе системный
hosts_current() { if hosts_enabled && [ -s "$HOSTS_FILE" ]; then echo "$HOSTS_FILE"; else echo "$HOSTS_TARGET"; fi; }

# Части из текущего hosts. Наш hosts (с разделителем) при собранном block.txt
# сводится к правкам: новые домены блокировки — в свои, удалённые — в
# исключения. Чужой hosts (первый запуск) делится по адресам.
hosts_import() {
  local b="$HOSTS_DIR/import.bypass" k="$HOSTS_DIR/import.block" src n ours=0
  [ -d "$HOSTS_CACHE" ] || mkdir -p "$HOSTS_CACHE"
  [ -f "$HOSTS_WHITELIST" ] || printf '# Домены, которые не блокировать, даже если они есть в источниках\n' > "$HOSTS_WHITELIST"
  [ -f "$HOSTS_SOURCES" ] || : > "$HOSTS_SOURCES"
  src=$(hosts_current)
  grep -qxF "$HOSTS_SEP" "$src" 2>/dev/null && [ -f "$HOSTS_BLOCK" ] && [ -f "$HOSTS_BLOCK_CUSTOM" ] && ours=1
  hosts_split "$b" "$k" < "$src"
  { printf '# Обход ограничений: IP и домен, по одной записи на строку\n'; cat "$b"; } > "$HOSTS_BYPASS"
  if [ "$ours" = 1 ]; then
    # добавленные руками — в свои домены
    awk -v of="$HOSTS_BLOCK" 'BEGIN { while ((getline l < of) > 0) { split(l, a, " "); old[a[2]] = 1 } } !($2 in old) { print $2 }' "$k" > "$k.add"
    if [ -s "$k.add" ]; then
      [ -n "$(tail -c 1 "$HOSTS_BLOCK_CUSTOM")" ] && echo >> "$HOSTS_BLOCK_CUSTOM"
      cat "$k.add" >> "$HOSTS_BLOCK_CUSTOM"
    fi
    # удалённые — в исключения (если удалено почти всё — файл, скорее, обрезан)
    awk -v nf="$k" 'BEGIN { while ((getline l < nf) > 0) { split(l, a, " "); now[a[2]] = 1 } } !($2 in now) { print $2 }' "$HOSTS_BLOCK" > "$k.del"
    n=$(wc -l < "$k.del" | tr -d ' ')
    if [ "$n" -gt 0 ] && [ "$n" -le "$HOSTS_IMPORT_MAX" ]; then
      [ -n "$(tail -c 1 "$HOSTS_WHITELIST")" ] && echo >> "$HOSTS_WHITELIST"
      cat "$k.del" >> "$HOSTS_WHITELIST"
    fi
    rm -f "$k.add" "$k.del"
  else
    n=$(wc -l < "$k" | tr -d ' ')
    if [ "$n" -le "$HOSTS_IMPORT_MAX" ]; then
      { printf '# Свои домены для блокировки, по одному на строку\n'; awk '{ print $2 }' "$k"; } > "$HOSTS_BLOCK_CUSTOM"
      rm -f "$HOSTS_CACHE/imported.txt"
      grep -vx 'local:imported' "$HOSTS_SOURCES" > "$HOSTS_SOURCES.tmp"; mv -f "$HOSTS_SOURCES.tmp" "$HOSTS_SOURCES"
    else
      # большой блок (от прежнего hosts-модуля) — отдельным источником
      printf '# Свои домены для блокировки, по одному на строку\n' > "$HOSTS_BLOCK_CUSTOM"
      cp -f "$k" "$HOSTS_CACHE/imported.txt"
      grep -qx 'local:imported' "$HOSTS_SOURCES" || echo 'local:imported' >> "$HOSTS_SOURCES"
    fi
  fi
  rm -f "$b" "$k" "$HOSTS_BYPASS_PRESET"
  hosts_build_block
}

hosts_preset_get() { sed -n "s/^$2=//p" "$HOSTS_PRESETS_DIR/$1.conf" 2>/dev/null | head -n1; }
hosts_cache_name() {
  case "$1" in
    preset:*) printf '%s' "${1#preset:}" ;;
    local:imported) printf 'imported' ;;
    *) printf 'url-%s' "$(printf '%s' "$1" | md5sum 2>/dev/null | cut -c1-12)" ;;
  esac
}
hosts_source_url() { case "$1" in preset:*) hosts_preset_get "${1#preset:}" URL ;; local:*) ;; *) printf '%s' "$1" ;; esac; }
hosts_sources() { sed 's/#.*//; s/[[:space:]]*$//; s/^[[:space:]]*//' "$HOSTS_SOURCES" 2>/dev/null | grep -E '^(preset:[a-z0-9_-]+|local:imported|https?://[^[:space:]]+)$'; }

hosts_download() { # <url> <файл>
  local to=""
  command -v timeout >/dev/null 2>&1 && to="timeout 90"
  if command -v curl >/dev/null 2>&1; then
    $to curl -fsSL --connect-timeout 10 --max-time 80 -o "$2" "$1"
  else
    $to busybox wget -T 15 --no-check-certificate -qO "$2" "$1"
  fi
}
# Источник блокировки в кэш: только записи блокировки (у dns.malw.link в том
# же файле сначала идёт обход — его отсюда не берём)
hosts_fetch_block() { # <источник>
  local src="$1" url name tmp
  url=$(hosts_source_url "$src"); name=$(hosts_cache_name "$src"); tmp="$HOSTS_CACHE/$name.tmp"
  [ -n "$url" ] || return 0
  if hosts_download "$url" "$tmp" && [ -s "$tmp" ]; then
    hosts_clean < "$tmp" | hosts_only_block > "$HOSTS_CACHE/$name.txt"
    rm -f "$tmp"
    [ -s "$HOSTS_CACHE/$name.txt" ]
  else
    rm -f "$tmp"; return 1
  fi
}

# block.txt: свои домены, затем источники по порядку; без дублей и исключений
hosts_build_block() {
  local wl="$HOSTS_DIR/wl.tmp" src
  sed 's/#.*//' "$HOSTS_WHITELIST" 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z' | awk 'NF { print $1 }' > "$wl"
  {
    hosts_clean < "$HOSTS_BLOCK_CUSTOM" 2>/dev/null | hosts_only_block
    hosts_sources | while IFS= read -r src; do
      cat "$HOSTS_CACHE/$(hosts_cache_name "$src").txt" 2>/dev/null
    done
  } | hosts_only_block | awk -v wlf="$wl" '
    BEGIN { while ((getline l < wlf) > 0) wl[l] = 1 }
    {
      d = $2; if (d in seen) next
      k = d
      while (1) { if (k in wl) next; p = index(k, "."); if (!p) break; k = substr(k, p + 1) }
      seen[d] = 1; print "0.0.0.0", d
    }' > "$HOSTS_BLOCK.tmp"
  mv -f "$HOSTS_BLOCK.tmp" "$HOSTS_BLOCK"
  rm -f "$wl"
}

# Собрать hosts из частей в stdout. Детерминированно (без даты): по сравнению
# с $HOSTS_FILE видно, правили ли файлы частей в обход WebUI.
hosts_assemble() {
  [ -f "$HOSTS_BLOCK" ] || hosts_build_block
  printf '%s\n127.0.0.1 localhost\n::1 localhost\n' "$HOSTS_MARK"
  hosts_clean < "$HOSTS_BYPASS" | hosts_only_bypass | awk '!seen[$2]++'
  printf '%s\n' "$HOSTS_SEP"
  hosts_clean < "$HOSTS_BYPASS" | hosts_only_bypass | awk '{ print $2 }' > "$HOSTS_DIR/bypass.names"
  awk -v nf="$HOSTS_DIR/bypass.names" 'BEGIN { while ((getline l < nf) > 0) by[l] = 1 } !($2 in by)' "$HOSTS_BLOCK"
  rm -f "$HOSTS_DIR/bypass.names"
}
# Записать собранный hosts на место (cat >: inode и монтирование остаются)
hosts_write() {
  hosts_init
  hosts_assemble > "$HOSTS_DIR/hosts.new"
  [ -f "$HOSTS_FILE" ] || : > "$HOSTS_FILE"
  cat "$HOSTS_DIR/hosts.new" > "$HOSTS_FILE" && rm -f "$HOSTS_DIR/hosts.new"
  hosts_set_perm "$HOSTS_FILE"
}
# Файлы частей разошлись с hosts (правили в MT Manager и т. п.)?
hosts_differs() {
  local f rc
  hosts_enabled && [ -f "$HOSTS_FILE" ] || return 1
  # свои домены, исключения или источники правили после сборки block.txt
  for f in "$HOSTS_BLOCK_CUSTOM" "$HOSTS_WHITELIST" "$HOSTS_SOURCES"; do
    [ "$f" -nt "$HOSTS_BLOCK" ] && return 0
  done
  hosts_assemble > "$HOSTS_DIR/hosts.cmp"
  ! cmp -s "$HOSTS_DIR/hosts.cmp" "$HOSTS_FILE"
  rc=$?; rm -f "$HOSTS_DIR/hosts.cmp"; return $rc
}

hosts_mount() {
  hosts_mounted && return 0
  [ -s "$HOSTS_FILE" ] || hosts_write
  hosts_set_perm "$HOSTS_FILE"
  hosts_global mount --bind "$HOSTS_FILE" "$HOSTS_TARGET" 2>/dev/null && hosts_mounted
}
hosts_umount() {
  hosts_mounted || return 0
  hosts_global umount "$HOSTS_TARGET" 2>/dev/null || hosts_global umount -l "$HOSTS_TARGET" 2>/dev/null
  ! hosts_mounted
}
hosts_boot() { hosts_enabled && hosts_mount; return 0; }

# Обновить источники блокировки; строка на каждый: S <источник> <ok N|fail>
hosts_update() {
  local src n ok=0 all=0 f name
  hosts_init
  for src in $(hosts_sources); do
    case "$src" in local:*) continue ;; esac
    all=$((all + 1))
    if hosts_fetch_block "$src"; then
      ok=$((ok + 1)); n=$(wc -l < "$HOSTS_CACHE/$(hosts_cache_name "$src").txt" | tr -d ' ')
      printf 'S\t%s\tok %s\n' "$src" "$n"
    else
      printf 'S\t%s\tfail\n' "$src"
    fi
  done
  # кэш источников, которых больше нет в списке
  for f in "$HOSTS_CACHE"/*.txt; do
    [ -f "$f" ] || continue
    name=${f##*/}; name=${name%.txt}
    hosts_sources | while IFS= read -r src; do [ "$(hosts_cache_name "$src")" = "$name" ] && echo y; done | grep -q y || rm -f "$f"
  done
  hosts_build_block
  hosts_write
  [ "$all" = 0 ] || [ "$ok" -gt 0 ]
}

# Загрузить пресет в обход: заменяет bypass.txt его частью обхода
hosts_bypass_preset() { # <id>
  local id="$1" url tmp="$HOSTS_CACHE/bypass.tmp"
  [ "$(hosts_preset_get "$id" BYPASS)" = 1 ] || { echo "Этот пресет не для обхода" >&2; return 1; }
  url=$(hosts_preset_get "$id" URL)
  hosts_init
  hosts_download "$url" "$tmp" && [ -s "$tmp" ] || { rm -f "$tmp"; echo "Не удалось скачать пресет" >&2; return 1; }
  hosts_clean < "$tmp" | hosts_only_bypass > "$tmp.c"; rm -f "$tmp"
  [ -s "$tmp.c" ] || { rm -f "$tmp.c"; echo "В пресете нет записей обхода" >&2; return 1; }
  { printf '# Обход ограничений: %s\n' "$(hosts_preset_get "$id" NAME)"; cat "$tmp.c"; } > "$HOSTS_BYPASS"
  rm -f "$tmp.c"
  echo "$id" > "$HOSTS_BYPASS_PRESET"
  hosts_write
}

hosts_state() {
  local f id c
  hosts_init
  echo "#status"
  echo "enabled=$(hosts_enabled && echo 1 || echo 0)"
  echo "mounted=$(hosts_mounted && echo 1 || echo 0)"
  echo "differs=$(hosts_differs && echo 1 || echo 0)"
  echo "conflicts=$(hosts_conflicts | tr '\n' ' ' | sed 's/ $//')"
  echo "bypass=$(hosts_clean < "$HOSTS_BYPASS" | hosts_only_bypass | wc -l | tr -d ' ')"
  echo "bypass_preset=$(cat "$HOSTS_BYPASS_PRESET" 2>/dev/null)"
  echo "blocked=$(wc -l < "$HOSTS_BLOCK" 2>/dev/null | tr -d ' ')"
  echo "block_custom=$(hosts_clean < "$HOSTS_BLOCK_CUSTOM" | hosts_only_block | wc -l | tr -d ' ')"
  echo "imported=$(wc -l < "$HOSTS_CACHE/imported.txt" 2>/dev/null | tr -d ' ')"
  echo "dir=$HOSTS_DIR"
  for f in "$HOSTS_PRESETS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.conf}
    echo "#preset $id"
    grep -E '^(NAME|DESC|BLOCK_DESC|URL|BYPASS|BLOCK)=' "$f"
    grep -qx "preset:$id" "$HOSTS_SOURCES" 2>/dev/null && echo "ENABLED=1" || echo "ENABLED=0"
    c="$HOSTS_CACHE/$id.txt"; [ -s "$c" ] && echo "COUNT=$(wc -l < "$c" | tr -d ' ')"
  done
  hosts_sources | grep -E '^https?://' | while IFS= read -r f; do
    echo "#url"
    echo "URL=$f"
    c="$HOSTS_CACHE/$(hosts_cache_name "$f").txt"; [ -s "$c" ] && echo "COUNT=$(wc -l < "$c" | tr -d ' ')"
  done
}

# Резервная копия: части (кроме собранного block.txt), источники, включённость
hosts_backup_add() { # <каталог в архиве>
  [ -d "$HOSTS_DIR" ] || return 0
  mkdir -p "$1"
  cp -f "$HOSTS_BYPASS" "$HOSTS_BLOCK_CUSTOM" "$HOSTS_WHITELIST" "$HOSTS_SOURCES" "$1/" 2>/dev/null
  hosts_enabled && : > "$1/enabled"
  return 0
}
hosts_backup_restore() { # <каталог из архива>
  [ -d "$1" ] || return 0
  [ -d "$HOSTS_CACHE" ] || mkdir -p "$HOSTS_CACHE"
  local f
  for f in bypass.txt block_custom.txt whitelist.txt sources.txt; do [ -f "$1/$f" ] && cp -f "$1/$f" "$HOSTS_DIR/$f"; done
  if [ -f "$1/enabled" ]; then : > "$HOSTS_ENABLED_FILE"; else rm -f "$HOSTS_ENABLED_FILE"; fi
  hosts_init
  hosts_build_block
  hosts_write
  if hosts_enabled; then hosts_mount; else hosts_umount; fi
  return 0
}

hosts_file_of() { # <bypass|block_custom|whitelist|sources>
  case "$1" in
    bypass) echo "$HOSTS_BYPASS" ;; block_custom) echo "$HOSTS_BLOCK_CUSTOM" ;;
    whitelist) echo "$HOSTS_WHITELIST" ;; sources) echo "$HOSTS_SOURCES" ;;
    *) return 1 ;;
  esac
}

hosts_ctl() {
  local cmd="$1" f c; shift
  case "$cmd" in
    hosts-state) hosts_state ;;
    hosts-get)
      hosts_init
      f=$(hosts_file_of "$1") || { echo "Неизвестный файл" >&2; return 1; }
      cat "$f" ;;
    hosts-save-b64) # <bypass|block_custom|whitelist|sources> <base64>
      hosts_init
      f=$(hosts_file_of "$1") || { echo "Неизвестный файл" >&2; return 1; }
      b64d "$2" | tr -d '\r' > "$f.tmp" && mv -f "$f.tmp" "$f" || { echo "Не удалось сохранить" >&2; return 1; }
      # пустой файл частей при следующем запуске взялся бы из hosts заново
      [ -s "$f" ] || printf '#\n' > "$f"
      [ "$1" = bypass ] && rm -f "$HOSTS_BYPASS_PRESET" || hosts_build_block
      hosts_write
      echo OK ;;
    hosts-block-add) # <домен>... — свои домены для блокировки, по одному или блоком
      hosts_init
      printf '%s\n' "$@" | tr ' ,;' '\n\n\n' | hosts_clean | hosts_only_block | awk '{ print $2 }' > "$HOSTS_DIR/add.tmp"
      [ -s "$HOSTS_DIR/add.tmp" ] || { rm -f "$HOSTS_DIR/add.tmp"; echo "Нет доменов" >&2; return 1; }
      c=$(wc -l < "$HOSTS_DIR/add.tmp" | tr -d ' ')
      [ -n "$(tail -c 1 "$HOSTS_BLOCK_CUSTOM")" ] && echo >> "$HOSTS_BLOCK_CUSTOM"
      cat "$HOSTS_DIR/add.tmp" >> "$HOSTS_BLOCK_CUSTOM"; rm -f "$HOSTS_DIR/add.tmp"
      hosts_build_block; hosts_write
      echo "$c" ;;
    hosts-set-enabled)
      hosts_init
      case "$1" in
        1)
          c=$(hosts_conflicts | tr '\n' ' ' | sed 's/ $//')
          [ -z "$c" ] || { echo "Сначала отключите модуль, который тоже меняет hosts: $c" >&2; return 1; }
          : > "$HOSTS_ENABLED_FILE"
          hosts_write
          hosts_mount || { rm -f "$HOSTS_ENABLED_FILE"; echo "Не удалось подменить $HOSTS_TARGET (mount --bind)" >&2; return 1; }
          log_msg "hosts: свой файл подключён" ;;
        0)
          rm -f "$HOSTS_ENABLED_FILE"
          hosts_umount || { echo "Не удалось вернуть системный hosts — он вернётся после перезагрузки" >&2; return 1; }
          log_msg "hosts: возвращён системный файл" ;;
        *) echo "Допустимо 0 или 1" >&2; return 1 ;;
      esac
      echo OK ;;
    hosts-sync) # apply — собрать hosts из файлов; import — файлы из hosts
      hosts_init
      case "$1" in
        apply) hosts_build_block; hosts_write ;;
        import) hosts_import; hosts_write ;;  # файлы частей — из подключённого hosts
        *) echo "apply или import" >&2; return 1 ;;
      esac
      echo OK ;;
    hosts-bypass-preset) hosts_bypass_preset "$1" && echo OK ;;
    hosts-preset) # <id> <0|1> — источник блокировки
      hosts_init
      case "$1" in ''|*[!a-z0-9_-]*) echo "Неизвестный пресет" >&2; return 1 ;; esac
      [ "$(hosts_preset_get "$1" BLOCK)" = 1 ] || { echo "Неизвестный пресет" >&2; return 1; }
      grep -vx "preset:$1" "$HOSTS_SOURCES" > "$HOSTS_SOURCES.tmp"
      [ "$2" = 1 ] && echo "preset:$1" >> "$HOSTS_SOURCES.tmp"
      mv -f "$HOSTS_SOURCES.tmp" "$HOSTS_SOURCES"
      if [ "$2" = 1 ] && [ ! -s "$HOSTS_CACHE/$1.txt" ] && ! hosts_fetch_block "preset:$1"; then
        hosts_build_block; hosts_write
        echo "Источник включён, но скачать его не удалось — нажмите «Обновить источники»" >&2; return 1
      fi
      hosts_build_block; hosts_write
      echo OK ;;
    hosts-update) hosts_update || { echo "Ни один источник не скачался — оставлен прежний список" >&2; return 1; } ;;
    *) echo "Неизвестная команда $cmd" >&2; return 1 ;;
  esac
}
