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
# Без проверки на пустой pidfile получается `kill ""` — ошибка подавлена, но поведение неявное.
wpid=$(cat /data/adb/nfqws2/state/watchdog.pid 2>/dev/null)
if [ -n "$wpid" ]; then kill "$wpid" 2>/dev/null; fi
wnpid=$(cat /data/adb/nfqws2/state/netwatch.pid 2>/dev/null)
if [ -n "$wnpid" ]; then kill "$wnpid" 2>/dev/null; fi
sh "$MODDIR/service.sh" stop >/dev/null 2>&1
sh "$MODDIR/service.sh" firewall_stop >/dev/null 2>&1
killall -9 nfqws2 2>/dev/null
# DNS «без службы» stop() не трогает — снимаем перехват отдельно,
# иначе после удаления DNS-запросы уходили бы в несуществующий dnsproxy
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
