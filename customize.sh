#!/system/bin/sh

# grab own info (version)
version=$(sed -n 's/^version=//p' "$MODPATH/module.prop" | tr -d '\r')

ui_print "*******************************************"
ui_print "- nfqws2-android-ext"
ui_print "- $version"
ui_print "*******************************************"

# Форк и оригинальный nfqws2-android делят /data/adb/nfqws2 и одни и те же
# цепочки iptables: вдвоём они мешали бы друг другу. Оригинал отключаем (не
# удаляем — настройки общие, вернуться можно, включив его обратно).
ORIG=/data/adb/modules/nfqws2-android
if [ -f "$ORIG/module.prop" ] && [ ! -f "$ORIG/disable" ]; then
  touch "$ORIG/disable" 2>/dev/null &&
    ui_print "- Original nfqws2-android disabled: it can't run together with this fork." &&
    ui_print "  Settings in /data/adb/nfqws2 are shared; remove it in the manager after reboot."
fi

case "$ARCH" in
  arm64) BIN=android-arm64 ;;
  arm) BIN=android-arm ;;
  x86_64) BIN=android-x86_64 ;;
  x86) BIN=android-x86 ;;
  *) abort "! Unsupported architecture: ${ARCH:-unknown}" ;;
esac
ui_print "- Architecture: $ARCH -> $BIN"

# Архив, собранный вручную из всего репозитория (zip -r .), — без файлов разработки
rm -rf "$MODPATH/tests" "$MODPATH/tools" "$MODPATH/.workbuddy-ai" \
       "$MODPATH/.git" "$MODPATH/.github" "$MODPATH/.gitattributes" \
       "$MODPATH/CONTRIBUTING.md" \
       "$MODPATH/docs" "$MODPATH/update.json"
rm -f "$MODPATH"/*.zip

for f in \
  service.sh action.sh boot-completed.sh uninstall.sh lib/common.sh lib/dns.sh lib/dns-cache.sh lib/hosts.sh bin/nfqws2-ctl \
  system/bin/nfqws2-ctl defaults/nfqws2.conf \
  "binaries/$BIN/nfqws2" "binaries/$BIN/dnsproxy"
do
  [ -s "$MODPATH/$f" ] || abort "! Missing or empty module file: $f"
done

cp -f "$MODPATH/binaries/$BIN/nfqws2" "$MODPATH/bin/nfqws2" ||
  abort "! Failed to install nfqws2 binary"
[ -s "$MODPATH/bin/nfqws2" ] || abort "! Installed nfqws2 binary is empty"
# AdGuard dnsproxy for DNS profiles
cp -f "$MODPATH/binaries/$BIN/dnsproxy" "$MODPATH/bin/dnsproxy" ||
  abort "! Failed to install dnsproxy"
[ -s "$MODPATH/bin/dnsproxy" ] || abort "! Installed dnsproxy binary is empty"
rm -rf "$MODPATH/binaries"

# Иконка модуля для Magisk / KernelSU / APatch / MMRL
[ -f "$MODPATH/webroot/icon.png" ] && cp -f "$MODPATH/webroot/icon.png" "$MODPATH/icon.png" 2>/dev/null

CONF=/data/adb/nfqws2
mkdir -p "$CONF/lists" "$CONF/state" "$CONF/logs" "$CONF/imports" "$CONF/strategies" ||
  abort "! Cannot create $CONF; check /data/adb access"

if [ -f "$CONF/nfqws2.conf" ]; then
  ui_print "- Keeping existing config: $CONF/nfqws2.conf"
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf.dist" ||
    abort "! Failed to save the default config"
else
  # Первая установка: сразу самая рабочая стратегия (FIRST_STRATEGY в lib/common.sh)
  first="$MODPATH/strategies/hardcorp74.conf"
  if [ -f "$first" ] && cp -f "$first" "$CONF/nfqws2.conf"; then
    echo hardcorp74 > "$CONF/state/active_strategy"
    ui_print "- Created config: $CONF/nfqws2.conf (strategy hardcorp74)"
  else
    cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf" ||
      abort "! Failed to create $CONF/nfqws2.conf"
    ui_print "- Created config: $CONF/nfqws2.conf"
  fi
fi

# Списки из релиза. Нетронутый список (совпадает с прошлой версией из релиза,
# .dist) обновляется молча, свой — не трогаем: обновление по запросу из WebUI
# убрано, правки пользователя главнее
DIST="$CONF/lists/.dist"
mkdir -p "$DIST" || abort "! Cannot create list update directories"
rm -rf "${CONF:?}/lists/.pending"
# исключение VPN-приложения из обхода (2.1.2) убрано: с ним перестала
# грузиться лента X; запомненные UID больше не нужны
rm -f "${CONF:?}/vpn_uids"

# Убранные пресеты DNS: их копии среди профилей удаляются, если профиль
# выключен и не выбран DNS по умолчанию. Включённые и выбранные остаются —
# ими пользуются
DP="$CONF/dns/profiles"
# один раз: метка .presets2 — дальше набор профилей целиком в руках пользователя
if [ -d "$DP" ] && [ ! -f "$CONF/dns/.presets2" ]; then
  dflt=$(cat "$CONF/dns/default" 2>/dev/null)
  for id in astracat dns-ai ntc rutor supercell twitch xbox; do
    f="$DP/$id.conf"
    [ -f "$f" ] || continue
    grep -q '^ENABLED=1' "$f" && continue
    [ "$id" = "$dflt" ] && continue
    rm -f "$f" && ui_print "- DNS: removed old preset profile $id"
  done
  # новые пресеты (Google, Яндекс, Cloudflare) — выключенными, если их ещё нет
  # (удалённые пользователем Comss, GeoHide, malw не возвращаются)
  for id in google yandex cloudflare; do
    f="$MODPATH/defaults/dns-presets/$id.conf"
    [ -f "$f" ] || continue
    [ -f "$DP/$id.conf" ] && continue
    sed 's/^ENABLED=.*/ENABLED=0/' "$f" > "$DP/$id.conf" && chmod 0644 "$DP/$id.conf"
  done
  # Comss, GeoHide, malw: серверы — актуальные из релиза; включён ли профиль
  # и его домены — как были у пользователя
  for id in comss geohide malw; do
    f="$MODPATH/defaults/dns-presets/$id.conf"
    [ -f "$f" ] && [ -f "$DP/$id.conf" ] || continue
    { grep -E '^(NAME|DESC)=' "$f"; grep '^ENABLED=' "$DP/$id.conf"; grep '^SERVER=' "$f"; grep '^DOMAIN=' "$DP/$id.conf"; true; } > "$DP/$id.conf.new" &&
      mv -f "$DP/$id.conf.new" "$DP/$id.conf" && chmod 0644 "$DP/$id.conf"
  done
  : > "$CONF/dns/.presets2"
fi

for src in "$MODPATH"/lists/*.list; do
  [ -f "$src" ] || continue
  f=${src##*/}
  dst="$CONF/lists/$f"

  if [ "$f" = auto.list ]; then
    if [ ! -f "$dst" ]; then
      cp -f "$src" "$dst" || abort "! Failed to install $f"
    fi
  elif [ ! -f "$dst" ] || cmp -s "$src" "$dst"; then
    cp -f "$src" "$dst" || abort "! Failed to install $f"
  elif [ -f "$DIST/$f" ] && cmp -s "$dst" "$DIST/$f"; then
    cp -f "$src" "$dst" || abort "! Failed to update $f"
  elif [ ! -f "$DIST/$f" ]; then
    case " user exclude ipset ipset_exclude probe_hosts " in
      *" ${f%.list} "*) ui_print "- $f has local changes, kept as is" ;;
      *) cp -f "$src" "$dst" || abort "! Failed to migrate $f" ;;
    esac
  else
    ui_print "- $f has local changes, kept as is"
  fi

  cp -f "$src" "$DIST/$f" || abort "! Failed to save release copy of $f"
done

if [ ! -f "$CONF/apps.list" ]; then
  printf '%s\n' "# App packages (APP_MODE=include|exclude), one per line" > "$CONF/apps.list" ||
    abort "! Failed to create $CONF/apps.list"
fi
if [ ! -f "$CONF/home_wifi.list" ]; then
  printf '%s\n' "# Home Wi-Fi SSIDs, one per line" > "$CONF/home_wifi.list" ||
    abort "! Failed to create $CONF/home_wifi.list"
fi

# set perms for nfqws2
busybox chmod +x "$MODPATH/bin/nfqws2"
busybox chmod +x "$MODPATH/bin/nfqws2-ctl"
busybox chmod +x "$MODPATH/bin/dnsproxy"
busybox chmod +x "$MODPATH/boot-completed.sh"
# Обёртка для терминала: без +x Magisk смонтирует её в /system/bin неисполняемой
busybox chmod 0755 "$MODPATH/system/bin/nfqws2-ctl"

ui_print "- Installation complete! Reboot your device."
