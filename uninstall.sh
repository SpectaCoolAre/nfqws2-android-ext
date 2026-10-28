#!/system/bin/sh
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
# Снимаем partial wakelock: в ядре это именованный лок, не привязанный к процессу, поэтому он
# переживает удаление модуля — без этой строки телефон после uninstall не заснёт до перезагрузки.
# Имя лока совпадает с id в module.prop.
if [ -w /sys/power/wake_unlock ] 2>/dev/null; then
  echo nfqws2-android > /sys/power/wake_unlock 2>/dev/null
fi
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android-ext
# Наблюдатели: PID из файла может быть устаревшим (Magisk зовёт uninstall.sh при
# следующей загрузке, когда номер уже мог достаться чужому процессу) — убиваем,
# только если это и правда наш service.sh
for pf in /data/adb/nfqws2/state/watchdog.pid /data/adb/nfqws2/state/netwatch.pid /data/adb/nfqws2/state/pushfix.pid; do
  p=$(cat "$pf" 2>/dev/null)
  [ -n "$p" ] && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'service\.sh' && kill "$p" 2>/dev/null
done
sh "$MODDIR/service.sh" stop >/dev/null 2>&1
sh "$MODDIR/service.sh" firewall_stop >/dev/null 2>&1
killall -9 nfqws2 2>/dev/null
# DNS не зависит от службы, и stop() его не трогает — снимаем перехват
# отдельно, иначе после удаления DNS-запросы уходили бы в несуществующий dnsproxy
sh "$MODDIR/service.sh" dns_stop >/dev/null 2>&1
killall -9 dnsproxy 2>/dev/null
# Свой hosts смонтирован поверх системного — вернуть системный
sh "$MODDIR/service.sh" hosts_off >/dev/null 2>&1
# Ссылки на nfqws2-ctl для su-оболочек — только свои (оригинальный модуль ставит такие же)
for l in /data/adb/ap/bin/nfqws2-ctl /data/adb/ksu/bin/nfqws2-ctl; do
  [ "$(readlink "$l" 2>/dev/null)" = "$MODDIR/bin/nfqws2-ctl" ] && rm -f "$l"
done
# Настройки и списки в /data/adb/nfqws2 сохраняются. Полное удаление: rm -rf /data/adb/nfqws2
rm -rf /data/adb/nfqws2/state
exit 0
