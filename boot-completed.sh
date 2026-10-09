#!/system/bin/sh
# Lifecycle hook: вызывается Magisk/KernelSU/APatch при sys.boot_completed=1
umask 077
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android-ext
. "$MODDIR/lib/common.sh"
load_conf >/dev/null 2>&1

log_msg "boot-completed: запуск хука (sys.boot_completed=1)"

# Сначала даём service.sh закончить загрузочный запуск (он ждёт ещё 4 с после
# boot_completed): решать, запускать ли службу — пауза в домашней Wi‑Fi,
# автозапуск, $CONFDIR/disable — его дело. Иначе хук успевал запустить обход
# раньше (ручным start), и дома служба работала, хотя должна была стоять на паузе.
i=0
while [ ! -f "$STATE_DIR/boot_done" ] && [ "$i" -lt 90 ]; do sleep 1; i=$((i + 1)); done
[ -f "$CONFDIR/disable" ] && exit 0

# Защита от LMK: если служба должна работать, проверяем её состояние после завершения загрузки
if { [ "$AUTOSTART" = "1" ] || [ -f "$DESIRED_FILE" ]; } && [ ! -f "$HOME_PAUSED_FILE" ]; then
  if ! is_running; then
    log_msg "boot-completed: nfqws2 не активен после старта системы — восстанавливаю..."
    sh "$MODDIR/service.sh" boot_recover >/dev/null 2>&1
  else
    protect_process "$(cat "$PIDFILE" 2>/dev/null)"
    if ! firewall_ok; then
      log_msg "boot-completed: восстановление правил файрвола"
      firewall_start
    fi
  fi
fi

# Убеждаемся, что наблюдатели (watchdog и netwatch) активны
sh "$MODDIR/service.sh" ensure_watchdog >/dev/null 2>&1

exit 0
