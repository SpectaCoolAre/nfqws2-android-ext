#!/system/bin/sh
# nfqws2-android-ext · lib/hosts.sh — редактор hosts без перезагрузки.
#
# Логика взята у bindhosts (https://github.com/bindhosts/bindhosts), режим
# «plain bind»: наш файл $HOSTS_FILE монтируется поверх /system/etc/hosts
# (mount --bind в пространстве имён init), и дальше правки пишутся в него на
# месте — применяются сразу, без перезагрузки и без отдельного модуля. Резолвер
# Android (netd) читает /system/etc/hosts в своём процессе, поэтому замена
# видна всем приложениям.
#
# Чего НЕ делаем, в отличие от bindhosts: не кладём system/etc/hosts в модуль
# (bindhosts и другие hosts-модули отключают модули с таким файлом — отключили
# бы весь nfqws2) и не прячем монтирование от приложений (susfs и т. п.).
#
# Итоговый hosts собирается как у bindhosts: свои записи, затем источники
# (пресеты и ссылки) по порядку; для домена остаётся первая запись; белый
# список убирает домены из источников (не из своих записей).
#
# Подключается из конца lib/common.sh; команды hosts-* — hosts_ctl.

HOSTS_DIR="$CONFDIR/hosts"
HOSTS_ENABLED_FILE="$HOSTS_DIR/enabled"
HOSTS_FILE="$HOSTS_DIR/hosts"              # то, что смонтировано поверх /system/etc/hosts
HOSTS_CUSTOM="$HOSTS_DIR/custom.txt"       # свои записи (редактор)
HOSTS_WHITELIST="$HOSTS_DIR/whitelist.txt" # домены, которые из источников не берём
HOSTS_SOURCES="$HOSTS_DIR/sources.txt"     # preset:<id> или ссылка, по строке
HOSTS_CACHE="$HOSTS_DIR/cache"
HOSTS_PRESETS_DIR="$MODDIR/defaults/hosts-presets"
HOSTS_TARGET="${HOSTS_TARGET:-/system/etc/hosts}"
HOSTS_MODULES_DIR="${HOSTS_MODULES_DIR:-/data/adb/modules}"
HOSTS_MARK="# nfqws2-android-ext hosts"

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

hosts_init() {
  [ -d "$HOSTS_DIR" ] || mkdir -p "$HOSTS_DIR" "$HOSTS_CACHE"
  [ -d "$HOSTS_CACHE" ] || mkdir -p "$HOSTS_CACHE"
  [ -f "$HOSTS_WHITELIST" ] || printf '# Домены, которые не брать из источников, по одному на строку\n' > "$HOSTS_WHITELIST"
  [ -f "$HOSTS_SOURCES" ] || : > "$HOSTS_SOURCES"
  # Свои записи при первом запуске — из текущего системного hosts
  if [ ! -f "$HOSTS_CUSTOM" ]; then
    { printf '# Свои записи: IP домен, по одной на строку\n'
      grep -v -E -e '^[[:space:]]*#' -e '[[:space:]](localhost|ip6-[a-z-]+)[[:space:]]*$' "$HOSTS_TARGET" 2>/dev/null | grep . | tr -d '\r'
    } > "$HOSTS_CUSTOM"
  fi
}

hosts_preset_url() { sed -n 's/^URL=//p' "$HOSTS_PRESETS_DIR/$1.conf" 2>/dev/null | head -n1; }
# Источник -> имя файла в кэше: пресет — по id, ссылка — по её md5
hosts_cache_name() {
  case "$1" in
    preset:*) printf '%s' "${1#preset:}" ;;
    *) printf 'url-%s' "$(printf '%s' "$1" | md5sum 2>/dev/null | cut -c1-12)" ;;
  esac
}
hosts_source_url() { case "$1" in preset:*) hosts_preset_url "${1#preset:}" ;; *) printf '%s' "$1" ;; esac; }
hosts_sources() { sed 's/#.*//; s/[[:space:]]*$//; s/^[[:space:]]*//' "$HOSTS_SOURCES" 2>/dev/null | grep -E '^(preset:[a-z0-9_-]+|https?://[^[:space:]]+)$'; }

hosts_download() { # <url> <файл>
  local to=""
  command -v timeout >/dev/null 2>&1 && to="timeout 60"
  if command -v curl >/dev/null 2>&1; then
    $to curl -fsSL --connect-timeout 10 --max-time 50 -o "$2" "$1"
  else
    $to busybox wget -T 15 --no-check-certificate -qO "$2" "$1"
  fi
}

# Чистка источника: комментарии, CRLF, лишние пробелы; «IP имя1 имя2» —
# по строке на имя; 127.0.0.1 и :: — в 0.0.0.0 (блокировка); строки, не
# похожие на «IP домен», — прочь.
hosts_clean() {
  tr -d '\r' | sed 's/#.*//' | awk '
    NF >= 2 && $1 ~ /^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9A-Fa-f:]+)$/ {
      ip = $1; if (ip == "127.0.0.1" || ip == "::" || ip == "::1" || ip == "0") ip = "0.0.0.0"
      for (i = 2; i <= NF; i++) {
        d = tolower($i)
        if (d == "localhost" || d == "localhost.localdomain" || d == "local" || d == "broadcasthost" || d ~ /^ip6-/) continue
        if (d ~ /^[a-z0-9_.-]+$/) print ip, d
      }
    }'
}

# Сборка $HOSTS_FILE из своих записей и кэша источников; без загрузки.
# Пишем на месте (cat > файл): так inode, а с ним и монтирование, остаются.
hosts_build() {
  local tmp="$HOSTS_DIR/hosts.new" wl="$HOSTS_DIR/wl.tmp" src name
  hosts_init
  sed 's/#.*//' "$HOSTS_WHITELIST" | tr -d '\r' | tr 'A-Z' 'a-z' | awk 'NF { print $1 }' > "$wl"
  {
    printf '%s, %s\n' "$HOSTS_MARK" "$(date '+%Y.%m.%d %H:%M:%S')"
    printf '127.0.0.1 localhost\n::1 localhost\n'
    printf '#S custom\n'
    hosts_clean < "$HOSTS_CUSTOM" | sed 's/^/C /'
    hosts_sources | while IFS= read -r src; do
      name=$(hosts_cache_name "$src")
      [ -s "$HOSTS_CACHE/$name.txt" ] || continue
      printf '#S %s\n' "$src"
      cat "$HOSTS_CACHE/$name.txt"
    done
  } | awk -v wlf="$wl" '
    BEGIN { while ((getline l < wlf) > 0) wl[l] = 1 }
    /^#S / { print "# " substr($0, 4); next }
    /^#/ || /localhost$/ { print; next }
    {
      own = ($1 == "C"); if (own) { $1 = ""; sub(/^ /, "") }
      d = $2
      if (d in seen) next
      if (!own) {   # белый список — для домена и всех его поддоменов
        k = d; skip = 0
        while (1) { if (k in wl) { skip = 1; break }; p = index(k, "."); if (!p) break; k = substr(k, p + 1) }
        if (skip) next
      }
      seen[d] = 1; print $1, d
    }' > "$tmp"
  rm -f "$wl"
  [ -f "$HOSTS_FILE" ] || { : > "$HOSTS_FILE"; hosts_set_perm "$HOSTS_FILE"; }
  cat "$tmp" > "$HOSTS_FILE" && rm -f "$tmp"
  hosts_set_perm "$HOSTS_FILE"
}

hosts_mount() {
  hosts_mounted && return 0
  [ -s "$HOSTS_FILE" ] || hosts_build
  hosts_set_perm "$HOSTS_FILE"
  hosts_global mount --bind "$HOSTS_FILE" "$HOSTS_TARGET" 2>/dev/null && hosts_mounted
}
hosts_umount() {
  hosts_mounted || return 0
  hosts_global umount "$HOSTS_TARGET" 2>/dev/null || hosts_global umount -l "$HOSTS_TARGET" 2>/dev/null
  ! hosts_mounted
}

# Загрузка источников; строка на каждый: S <источник> <ok строк|fail>
hosts_update() {
  local src url name tmp n ok=0 all=0
  hosts_init
  for src in $(hosts_sources); do
    all=$((all + 1))
    url=$(hosts_source_url "$src"); name=$(hosts_cache_name "$src"); tmp="$HOSTS_CACHE/$name.tmp"
    if [ -n "$url" ] && hosts_download "$url" "$tmp" && [ -s "$tmp" ]; then
      hosts_clean < "$tmp" > "$HOSTS_CACHE/$name.txt"
      n=$(wc -l < "$HOSTS_CACHE/$name.txt" | tr -d ' ')
      if [ "$n" -gt 0 ]; then ok=$((ok + 1)); printf 'S\t%s\tok %s\n' "$src" "$n"
      else printf 'S\t%s\tfail empty\n' "$src"; fi
    else
      printf 'S\t%s\tfail download\n' "$src"
    fi
    rm -f "$tmp"
  done
  # Кэш источников, которых больше нет в списке
  for f in "$HOSTS_CACHE"/*.txt; do
    [ -f "$f" ] || continue
    name=${f##*/}; name=${name%.txt}
    hosts_sources | while IFS= read -r src; do [ "$(hosts_cache_name "$src")" = "$name" ] && echo y; done | grep -q y || rm -f "$f"
  done
  hosts_build
  [ "$all" = 0 ] || [ "$ok" -gt 0 ]
}

hosts_boot() { hosts_enabled && hosts_mount; return 0; }

hosts_state() {
  local f id c
  hosts_init
  echo "#status"
  echo "enabled=$(hosts_enabled && echo 1 || echo 0)"
  echo "mounted=$(hosts_mounted && echo 1 || echo 0)"
  echo "conflicts=$(hosts_conflicts | tr '\n' ' ' | sed 's/ $//')"
  if [ -f "$HOSTS_FILE" ]; then
    awk '/^#/ || /localhost$/ { next } { if ($1 == "0.0.0.0") b++; else r++ } END { printf "blocked=%d\nredirects=%d\n", b, r }' "$HOSTS_FILE"
    echo "built=$(sed -n "1s/^$HOSTS_MARK, //p" "$HOSTS_FILE")"
  fi
  echo "custom=$(hosts_clean < "$HOSTS_CUSTOM" | wc -l | tr -d ' ')"
  for f in "$HOSTS_PRESETS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.conf}
    echo "#preset $id"
    grep -E '^(NAME|DESC|URL|KIND)=' "$f"
    grep -qx "preset:$id" "$HOSTS_SOURCES" 2>/dev/null && echo "ENABLED=1" || echo "ENABLED=0"
    c="$HOSTS_CACHE/$id.txt"; [ -s "$c" ] && echo "COUNT=$(wc -l < "$c" | tr -d ' ')"
  done
  hosts_sources | grep -v '^preset:' | while IFS= read -r f; do
    echo "#url"
    echo "URL=$f"
    c="$HOSTS_CACHE/$(hosts_cache_name "$f").txt"; [ -s "$c" ] && echo "COUNT=$(wc -l < "$c" | tr -d ' ')"
  done
}

# Резервная копия: свои записи, белый список, источники и включённость
hosts_backup_add() { # <каталог в архиве>
  [ -d "$HOSTS_DIR" ] || return 0
  mkdir -p "$1"
  cp -f "$HOSTS_CUSTOM" "$HOSTS_WHITELIST" "$HOSTS_SOURCES" "$1/" 2>/dev/null
  hosts_enabled && : > "$1/enabled"
  return 0
}
hosts_backup_restore() { # <каталог из архива>
  [ -d "$1" ] || return 0
  hosts_init
  local f
  for f in custom.txt whitelist.txt sources.txt; do [ -f "$1/$f" ] && cp -f "$1/$f" "$HOSTS_DIR/$f"; done
  if [ -f "$1/enabled" ]; then : > "$HOSTS_ENABLED_FILE"; else rm -f "$HOSTS_ENABLED_FILE"; fi
  hosts_build
  if hosts_enabled; then hosts_mount; else hosts_umount; fi
  return 0
}

hosts_file_of() { # <custom|whitelist|sources>
  case "$1" in
    custom) echo "$HOSTS_CUSTOM" ;; whitelist) echo "$HOSTS_WHITELIST" ;; sources) echo "$HOSTS_SOURCES" ;;
    *) return 1 ;;
  esac
}

hosts_ctl() {
  local cmd="$1" f c; shift
  case "$cmd" in
    hosts-state) hosts_state ;;
    hosts-get)
      hosts_init
      case "$1" in
        current) cat "$HOSTS_TARGET" ;;
        *) f=$(hosts_file_of "$1") || { echo "Неизвестный файл" >&2; return 1; }; cat "$f" ;;
      esac ;;
    hosts-save-b64) # <custom|whitelist|sources> <base64>
      hosts_init
      f=$(hosts_file_of "$1") || { echo "Неизвестный файл" >&2; return 1; }
      b64d "$2" | tr -d '\r' > "$f.tmp" && mv -f "$f.tmp" "$f" || { echo "Не удалось сохранить" >&2; return 1; }
      hosts_build
      echo OK ;;
    hosts-set-enabled)
      hosts_init
      case "$1" in
        1)
          c=$(hosts_conflicts | tr '\n' ' ' | sed 's/ $//')
          [ -z "$c" ] || { echo "Сначала отключите модуль, который тоже меняет hosts: $c" >&2; return 1; }
          : > "$HOSTS_ENABLED_FILE"
          hosts_build
          hosts_mount || { rm -f "$HOSTS_ENABLED_FILE"; echo "Не удалось подменить $HOSTS_TARGET (mount --bind)" >&2; return 1; }
          log_msg "hosts: свой файл подключён" ;;
        0)
          rm -f "$HOSTS_ENABLED_FILE"
          hosts_umount || { echo "Не удалось вернуть системный hosts — он вернётся после перезагрузки" >&2; return 1; }
          log_msg "hosts: возвращён системный файл" ;;
        *) echo "Допустимо 0 или 1" >&2; return 1 ;;
      esac
      echo OK ;;
    hosts-preset) # <id> <0|1>
      hosts_init
      case "$1" in ''|*[!a-z0-9_-]*) echo "Неизвестный пресет" >&2; return 1 ;; esac
      [ -f "$HOSTS_PRESETS_DIR/$1.conf" ] || { echo "Неизвестный пресет" >&2; return 1; }
      grep -vx "preset:$1" "$HOSTS_SOURCES" > "$HOSTS_SOURCES.tmp"
      [ "$2" = 1 ] && echo "preset:$1" >> "$HOSTS_SOURCES.tmp"
      mv -f "$HOSTS_SOURCES.tmp" "$HOSTS_SOURCES"
      if [ "$2" = 1 ] && [ ! -s "$HOSTS_CACHE/$1.txt" ]; then
        hosts_download "$(hosts_preset_url "$1")" "$HOSTS_CACHE/$1.tmp" && hosts_clean < "$HOSTS_CACHE/$1.tmp" > "$HOSTS_CACHE/$1.txt"
        rm -f "$HOSTS_CACHE/$1.tmp"
        [ -s "$HOSTS_CACHE/$1.txt" ] || { hosts_build; echo "Пресет включён, но скачать его не удалось — нажмите «Обновить источники»" >&2; return 1; }
      fi
      hosts_build
      echo OK ;;
    hosts-update) hosts_update || { echo "Ни один источник не скачался — оставлен прежний файл" >&2; return 1; } ;;
    *) echo "Неизвестная команда $cmd" >&2; return 1 ;;
  esac
}
