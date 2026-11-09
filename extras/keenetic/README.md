# geodns для Keenetic

Обход геоблока через DNS на роутере (Entware): dnsmasq отправляет домены
списка геоблока к серверам обхода через https-dns-proxy, остальное — к DNS
провайдера или к честному DoH.

Выбор серверов — тот же, что в умном DNS модуля, тем же кодом:

- проверка — `nfqws2-helper -geoscan -doh` (по всему списку, только DoH);
- выбор — `lib/geo-pool.awk`, `lib/geo-routes.awk`, `lib/geo-rel.awk`;
- серверы, группы и предпочтения — `defaults/dns-geo-*.list` модуля.

Тест `tests/module/test_router.sh` проверяет, что на одних и тех же итогах
проверки роутер и телефон направляют каждый домен к одному серверу.

Установка: распаковать архив на роутер и запустить `sh install.sh`
(нужны `dnsmasq-full https-dns-proxy curl`). Команды: `geodns status`,
`geodns scan`, `geodns check`, `geodns routes`, `geodns test <домен>`.
