#!/bin/sh
# Установка geodns на Keenetic (Entware). Запуск из распакованного архива:
#   cd /opt/tmp/geodns && sh install.sh
# Нужны пакеты: dnsmasq-full https-dns-proxy curl (opkg install …)
set -e
cd "$(dirname "$0")"
# nfqws2-helper — та сборка, что запускается на этом роутере. Не по uname:
# у mipsel он тоже «mips», и 10.11 встала сборка для mips — ядро её не
# запустило, а оболочка пыталась читать её как скрипт
# корневые сертификаты — без них проверка серверов (TLS) не пройдёт
[ -s /opt/etc/ssl/certs/ca-certificates.crt ] || opkg install ca-bundle ca-certificates >/dev/null 2>&1 ||
  echo "нет /opt/etc/ssl/certs/ca-certificates.crt — установите: opkg install ca-bundle"
a=""
for x in mipsle mips arm64 arm; do
  chmod 755 "nfqws2-helper.$x"
  "./nfqws2-helper.$x" -h 2>&1 | grep -q geoscan && { a=$x; break; }
done
[ -n "$a" ] || { echo "ни одна сборка nfqws2-helper не запускается на этом роутере ($(uname -m))"; exit 1; }
echo "nfqws2-helper: сборка $a"
cp -f "nfqws2-helper.$a" /opt/bin/nfqws2-helper
chmod 755 /opt/bin/nfqws2-helper
[ -f /opt/etc/init.d/S55geodns ] && /opt/etc/init.d/S55geodns stop || true
mkdir -p /opt/etc/geodns
cp -f geodns /opt/bin/geodns; chmod 755 /opt/bin/geodns
cp -f S55geodns /opt/etc/init.d/S55geodns; chmod 755 /opt/etc/init.d/S55geodns
cp -f geo-pool.awk geo-routes.awk geo-rel.awk groups.list prefer.list servers.list /opt/etc/geodns/
# настройки и списки пользователя не трогаем
[ -f /opt/etc/geodns/geodns.conf ] || cp geodns.conf /opt/etc/geodns/geodns.conf
[ -f /opt/etc/geodns/geoblock.list ] || cp geoblock.list /opt/etc/geodns/geoblock.list
# прежняя версия: группы были в sites.conf, теперь — groups.list
[ -f /opt/etc/geodns/sites.conf ] && mv -f /opt/etc/geodns/sites.conf /opt/etc/geodns/sites.conf.old
# dnsmasq должен читать наши файлы
grep -q 'geodns/dnsmasq-geo.conf' /opt/etc/dnsmasq.conf 2>/dev/null || {
  echo "conf-file=/opt/etc/geodns/upstream.conf" >> /opt/etc/dnsmasq.conf
  echo "conf-file=/opt/etc/geodns/dnsmasq-geo.conf" >> /opt/etc/dnsmasq.conf
  echo "no-resolv" >> /opt/etc/dnsmasq.conf
}
/opt/etc/init.d/S55geodns start
echo "Готово. Первая полная проверка серверов — через минуту-две: geodns status"
