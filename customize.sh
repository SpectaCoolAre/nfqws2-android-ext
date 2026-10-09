#!/system/bin/sh

# grab own info (version)
version=$(sed -n 's/^version=//p' "$MODPATH/module.prop")

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
       "$MODPATH/docs" "$MODPATH/update.json" "$MODPATH/changelog.md"
rm -f "$MODPATH"/*.zip

for f in \
  service.sh action.sh uninstall.sh lib/common.sh lib/dns.sh bin/nfqws2-ctl \
  defaults/nfqws2.conf \
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

CONF=/data/adb/nfqws2
mkdir -p "$CONF/lists" "$CONF/state" "$CONF/logs" "$CONF/imports" "$CONF/strategies" ||
  abort "! Cannot create $CONF; check /data/adb access"

if [ -f "$CONF/nfqws2.conf" ]; then
  ui_print "- Keeping existing config: $CONF/nfqws2.conf"
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf.dist" ||
    abort "! Failed to save the default config"
else
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf" ||
    abort "! Failed to create $CONF/nfqws2.conf"
  ui_print "- Created config: $CONF/nfqws2.conf"
fi

DIST="$CONF/lists/.dist"
PEND="$CONF/lists/.pending"
mkdir -p "$DIST" "$PEND" || abort "! Cannot create list update directories"

for src in "$MODPATH"/lists/*.list; do
  [ -f "$src" ] || continue
  f=${src##*/}
  dst="$CONF/lists/$f"

  if [ "$f" = auto.list ]; then
    if [ ! -f "$dst" ]; then
      cp -f "$src" "$dst" || abort "! Failed to install $f"
    fi
    cp -f "$src" "$DIST/$f" || abort "! Failed to save release copy of $f"
    continue
  fi

  if [ ! -f "$dst" ] || cmp -s "$src" "$dst"; then
    cp -f "$src" "$dst" || abort "! Failed to install $f"
    rm -f "$PEND/$f"
  elif [ -f "$DIST/$f" ] && cmp -s "$src" "$DIST/$f"; then
    :
  elif [ -f "$DIST/$f" ] && cmp -s "$dst" "$DIST/$f"; then
    cp -f "$src" "$dst" || abort "! Failed to update $f"
    rm -f "$PEND/$f"
  elif [ ! -f "$DIST/$f" ]; then
    case " user exclude ipset ipset_exclude probe_hosts " in
      *" ${f%.list} "*)
        cp -f "$src" "$PEND/$f" || abort "! Failed to save pending update for $f"
        ui_print "- $f has local changes; the release version is available in the WebUI"
        ;;
      *)
        cp -f "$src" "$dst" || abort "! Failed to migrate $f"
        rm -f "$PEND/$f"
        ;;
    esac
  else
    cp -f "$src" "$PEND/$f" || abort "! Failed to save pending update for $f"
    ui_print "- $f has local changes; the release version is available in the WebUI"
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

# set perms to nfwqws2
busybox chmod +x "$MODPATH/bin/nfqws2"
busybox chmod +x "$MODPATH/bin/nfqws2-ctl"
busybox chmod +x "$MODPATH/bin/dnsproxy"

ui_print "- Installation complete! Reboot your device."
