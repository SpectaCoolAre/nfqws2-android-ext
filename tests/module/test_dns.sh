#!/bin/sh
# extended: DNS по профилям (lib/dns.sh).
#
# Без root и сети: iptables — мок из tests/lib/mock, dnsproxy — заглушка, которая
# просто живёт; dumpsys и settings отвечают как Android. Сквозная проверка на
# настоящих dnsproxy и iptables — в описании коммита, здесь — вся логика вокруг.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
[ -f "$MODDIR/lib/dns.sh" ] || { printf 'SKIP  lib/dns.sh only exists in the extended build\n'; sandbox_cleanup; exit 0; }

cat > "$MOCKBIN/dumpsys" <<'EOF'
#!/bin/sh
echo "Active default network: 101"
echo "  NetworkAgentInfo{network{100}  lp{{InterfaceName: rmnet0 DnsAddresses: [ /10.10.10.10 ] }}"
echo "  NetworkAgentInfo{network{101}  lp{{InterfaceName: wlan0 LinkAddresses: [ 192.168.1.5/24 ] DnsAddresses: [ /192.168.1.1,/fe80::1%wlan0 ] Domains: null}}"
EOF
printf '#!/bin/sh\ncase "$*" in *specifier*) echo "${STUB_PRIVATE_HOST:-}" ;; *) echo "${STUB_PRIVATE:-off}" ;; esac\n' > "$MOCKBIN/settings"
# dnsproxy-заглушка: записывает аргументы и живёт, пока её не убьют
cat > "$MODDIR/bin/dnsproxy" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$MOCK_DIR/dnsproxy.args"
exec sleep 600
EOF
chmod 0755 "$MOCKBIN/dumpsys" "$MOCKBIN/settings" "$MODDIR/bin/dnsproxy"
export STUB_PRIVATE STUB_PRIVATE_HOST
load_common
conf_reset
printf 'WATCHDOG=0\nIPV6_ENABLED=0\n' >> "$CONFFILE"

# ── обычная сборка ────────────────────────────────────────────────────────────
section "regular build: no dnsproxy, no DNS"

mv "$MODDIR/bin/dnsproxy" "$SANDBOX/dnsproxy.off"
mkdir -p "$CONFDIR/dns"; : > "$CONFDIR/dns/enabled"
dns_enabled; assert_rc 1 $? "an enabled flag left from extended is ignored without dnsproxy"
ctl json-status
assert_contains "$ctl_out" '"dns_available":0' "json-status tells the WebUI there is no DNS"
assert_eq "" "$(row() { printf '%s\n' "$*"; }; dns_doctor)" "the diagnostics say nothing about DNS"
svc start; svc stop
assert_no_file "$CONFDIR/state/dnsproxy.pid" "the service starts and stops without touching DNS"
assert_eq "" "$(ipt_rules OUTPUT nat | grep nfqws_dns)" "no interception"
rm -rf "$CONFDIR/dns"
mv "$SANDBOX/dnsproxy.off" "$MODDIR/bin/dnsproxy"
ctl json-status
assert_contains "$ctl_out" '"dns_available":1' "with dnsproxy (extended) json-status offers DNS"

# ── первый запуск ─────────────────────────────────────────────────────────────
section "presets are seeded as disabled profiles"

dns_init
n_pre=$(ls "$MODDIR/defaults/dns-presets" | grep -c '\.conf$')
assert_eq "$n_pre" "$(ls "$DNS_PROFILES_DIR" | grep -c '\.conf$')" "every preset becomes a profile"
assert_eq "0" "$(grep -l '^ENABLED=1' "$DNS_PROFILES_DIR"/*.conf 2>/dev/null | wc -l | tr -d ' ')" "all of them start disabled"
assert_eq "net" "$(dns_default)" "the default DNS is the network's"
for f in "$MODDIR"/defaults/dns-presets/*.conf; do
  dns_profile_check "$f" 2>/dev/null; assert_rc 0 $? "preset ${f##*/} passes the input check"
done

# ── проверка ввода ────────────────────────────────────────────────────────────
section "server addresses"

for s in 1.1.1.1 1.1.1.1:53 '[2606:4700::1111]:53' 2606:4700::1111 'fe80::1%wlan0' udp://9.9.9.9 \
         tcp://1.1.1.1 tcp://dns.google:53 https://dns.google/dns-query 'https://dns.geohide.ru:8443/dns-query' \
         h3://dns.google/dns-query tls://dns.google tls://1.1.1.1:853 quic://dns.adguard-dns.com \
         sdns://AgcAAAAAAAAABzEuMC4wLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5; do
  dns_server_ok "$s"; assert_rc 0 $? "accepted: $s"
done
for s in '' 'https://a b' 'https://x/$(id)' 'tls://host/path' 'ftp://x' 'dns.google' '1.1.1' '"1.1.1.1"' 'tls://' ; do
  dns_server_ok "$s"; assert_rc 1 $? "rejected: [$s]"
done

section "domains"

for d in instagram.com cdninstagram.com ru xn--p1ai sub.example.co.uk _dmarc.example.com a-b.c; do
  dns_domain_ok "$d"; assert_rc 0 $? "accepted: $d"
done
for d in '' -bad.com bad-.com 'a b.com' 'UPPER.com' 'a..b' '.com' 'x/y'; do
  dns_domain_ok "$d"; assert_rc 1 $? "rejected: [$d]"
done

section "profile normalisation"

out=$(printf 'NAME=  Тест  \r\nENABLED=1\nSERVER=1.1.1.1\nSERVER=1.1.1.1\nDOMAIN=*.Example.COM.\nDOMAIN=example.com\nJUNK=1\n' | dns_profile_normalize)
assert_eq "NAME=Тест
ENABLED=1
SERVER=1.1.1.1
DOMAIN=example.com" "$out" "trimmed, lower-cased, deduplicated, junk dropped"
printf 'NAME=x\n' > "$SANDBOX/many"
i=0; while [ $i -le "$DNS_MAX_SERVERS" ]; do echo "SERVER=1.1.1.$i" >> "$SANDBOX/many"; i=$((i + 1)); done
dns_profile_save many < "$SANDBOX/many" 2>/dev/null
assert_rc 1 $? "more than $DNS_MAX_SERVERS servers are refused"
assert_no_file "$DNS_PROFILES_DIR/many.conf" "and nothing is written"

# ── конфиг dnsproxy ───────────────────────────────────────────────────────────
section "dnsproxy configuration"

dns_build
assert_rc 1 $? "nothing to apply while no profile is enabled and the default is the network"

printf 'NAME=Insta\nENABLED=1\nSERVER=https://ns2.opennameserver.org/dns-query\nSERVER=tls://dns.google\nDOMAIN=instagram.com\nDOMAIN=cdninstagram.com\n' | dns_profile_save insta
printf 'NAME=Off\nENABLED=0\nSERVER=9.9.9.9\nDOMAIN=off.example\n' | dns_profile_save off
dns_build
assert_rc 0 $? "an enabled profile with domains gives a configuration"
up=$(cat "$DNS_RUN_DIR/upstreams.txt")
assert_contains "$up" "192.168.1.1:53" "the default goes to the DNS of the active network"
assert_contains "$up" "[fe80::1%wlan0]:53" "an IPv6 network DNS is bracketed"
assert_not_contains "$up" "10.10.10.10" "not the DNS of an inactive network"
assert_contains "$up" "[/instagram.com/cdninstagram.com/]https://ns2.opennameserver.org/dns-query" "domains route to the first server"
assert_contains "$up" "[/instagram.com/cdninstagram.com/]tls://dns.google" "and to the second one"
assert_not_contains "$up" "off.example" "a disabled profile is not applied"
args=$(cat "$DNS_RUN_DIR/args")
assert_contains "$args" "$DNS_PORT" "the listening port is set"
assert_contains "$args" "77.88.8.8:53" "public bootstrap servers are there as a fallback"

echo insta > "$DNS_DEFAULT_FILE"
dns_build
assert_eq "https://ns2.opennameserver.org/dns-query" "$(head -n 1 "$DNS_RUN_DIR/upstreams.txt")" "a profile as the default puts its servers first"
assert_not_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "192.168.1.1:53" "the network DNS is then not a primary"
assert_contains "$(cat "$DNS_RUN_DIR/fallback.txt")" "192.168.1.1:53" "but stays a fallback"
# Push-уведомления Google: при DNS по умолчанию — профиль (Comss, GeoHide…)
# домены FCM идут в DNS Google, иначе FCM не переподключается
up=$(cat "$DNS_RUN_DIR/upstreams.txt")
assert_contains "$up" "/mtalk.google.com/" "with a profile as the default the FCM domains get their own rule"
assert_contains "$up" "/fcm.googleapis.com/" "fcm.googleapis.com among them"
assert_contains "$up" "/]tls://dns.google" "routed to Google DNS"
DNS_PUSH=0 dns_build
assert_not_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "mtalk.google.com" "the developer switch DNS_PUSH=0 turns the rule off"
dns_build
echo net > "$DNS_DEFAULT_FILE"
dns_build
assert_not_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "mtalk.google.com" "with the network DNS as the default no rule is needed"

# 250 доменов — три строки правил на сервер, по 100 доменов
printf 'NAME=Big\nENABLED=1\nSERVER=8.8.8.8\n' > "$SANDBOX/big"
i=0; while [ $i -lt 250 ]; do echo "DOMAIN=d$i.example" >> "$SANDBOX/big"; i=$((i + 1)); done
dns_profile_save big < "$SANDBOX/big"
dns_build
assert_eq "3" "$(grep -c '\]8\.8\.8\.8$' "$DNS_RUN_DIR/upstreams.txt")" "long domain lists are split into lines of 100"
rm -f "$DNS_PROFILES_DIR/big.conf"

# ── перехват ──────────────────────────────────────────────────────────────────
section "interception follows the service"

: > "$DNS_ENABLED_FILE"
svc start
assert_rc 0 "$svc_rc" "the service starts"
assert_file "$DNS_PIDFILE" "dnsproxy is started with it"
assert_contains "$(cat "$MOCK_DIR/dnsproxy.args")" "$DNS_RUN_DIR/upstreams.txt" "with the generated upstream list"
nat=$(ipt_rules nfqws_dns nat)
assert_contains "$nat" "-m mark --mark 0x0/0xffff -j RETURN" "packets without a netd mark are left alone (no loop)"
assert_contains "$nat" "-p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT" "UDP DNS goes to dnsproxy"
assert_contains "$nat" "-p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT" "TCP DNS too"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "OUTPUT jumps into the chain"
assert_contains "$(ipt_rules nfqws_dns nat ip6tables)" "REDIRECT" "IPv6 is redirected when ip6tables has nat"

pid=$(cat "$DNS_PIDFILE")
dns_start
assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "an unchanged configuration does not restart dnsproxy"

kill "$pid"; sleep 0.3
dns_check
assert_ne_pid=$(cat "$DNS_PIDFILE" 2>/dev/null)
[ -n "$assert_ne_pid" ] && [ "$assert_ne_pid" != "$pid" ] && kill -0 "$assert_ne_pid" 2>/dev/null
assert_rc 0 $? "the watchdog check restarts a dead dnsproxy"
log=$(cat "$DNS_LOG")
assert_contains "$log" "запуск службы: запуск dnsproxy" "the DNS log says why dnsproxy was started"
assert_contains "$log" "по умолчанию: DNS сети" "and what it was started with"
assert_contains "$log" "перехват включён: IPv4" "and that interception is on"
assert_match "$log" "не работает \\(PID $pid: (нет в /proc|есть в /proc, \\(sleep\\), состояние Z)" "a crash is logged with the dead PID and what was found"
assert_contains "$log" "watchdog: запуск dnsproxy" "followed by the restart"
assert_contains "$(cat "$SERVICE_LOG")" "DNS: dnsproxy перезапущен" "the service log confirms the restart"

section "one DNS operation at a time"

pid=$(cat "$DNS_PIDFILE")
sleep 600 & holder=$!
mkdir "$DNS_LOCK"; echo "$holder" > "$DNS_LOCK/pid"
kill "$pid"; sleep 0.3
dns_check
kill -0 "$(cat "$DNS_PIDFILE" 2>/dev/null)" 2>/dev/null
assert_rc 1 $? "the watchdog does not touch DNS while another process holds the lock"
assert_not_contains "$(tail -n 3 "$DNS_LOG")" "не работает — перезапуск" "and does not report a crash"
( sleep 1; rm -rf "$DNS_LOCK" ) &
dns_start "тест"
assert_rc 0 $? "a start waits for the lock to be released"
kill -0 "$(cat "$DNS_PIDFILE")" 2>/dev/null
assert_rc 0 $? "and then brings dnsproxy back"
[ -d "$DNS_LOCK" ]; assert_rc 1 $? "the lock is released afterwards"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

mkdir "$DNS_LOCK"; echo 999999 > "$DNS_LOCK/pid"
pid=$(cat "$DNS_PIDFILE"); kill "$pid"; sleep 0.3
dns_check
kill -0 "$(cat "$DNS_PIDFILE" 2>/dev/null)" 2>/dev/null
assert_rc 0 $? "a lock left by a dead process is taken over"

# Работающий dnsproxy этого модуля, а PID-файл указывает не на него (так
# было после загрузки: watchdog счёл живой процесс упавшим) — не перезапуск
sleep 600 & stray=$!
printf '#!/bin/sh\necho %s\n' "$stray" > "$MOCKBIN/pidof"
printf '#!/bin/sh\n[ "$1" = /proc/%s/exe ] && { echo "%s"; exit 0; }\nexec /bin/readlink "$@"\n' "$stray" "$DNS_BIN" > "$MOCKBIN/readlink"
chmod 0755 "$MOCKBIN/pidof" "$MOCKBIN/readlink"
pid=$(cat "$DNS_PIDFILE"); kill "$pid"; sleep 0.3
dns_check
assert_eq "$stray" "$(cat "$DNS_PIDFILE")" "a running dnsproxy of this module is adopted instead of restarted"
assert_contains "$(tail -n 2 "$DNS_LOG")" "PID-файл исправлен" "and the log says why"

# Лишний dnsproxy без PID-файла (как от двух одновременных запусков) —
# завершается перед новым запуском
sleep 600 & stray2=$!
printf '#!/bin/sh\necho %s %s\n' "$stray" "$stray2" > "$MOCKBIN/pidof"
printf '#!/bin/sh\ncase "$1" in /proc/%s/exe|/proc/%s/exe) echo "%s"; exit 0 ;; esac\nexec /bin/readlink "$@"\n' "$stray" "$stray2" "$DNS_BIN" > "$MOCKBIN/readlink"
rm -f "$DNS_RUN_DIR/running.args"
dns_start "тест"
sleep 0.2
kill -0 "$stray2" 2>/dev/null
assert_rc 1 $? "a stray dnsproxy of this module is killed before a new one starts"
assert_contains "$(cat "$DNS_LOG")" "лишний dnsproxy (PID $stray2)" "and logged"
rm -f "$MOCKBIN/pidof" "$MOCKBIN/readlink"
wait "$stray" "$stray2" 2>/dev/null

# Фильтр журнала: двойные строки и одинаковые ошибки не забивают журнал
flt=$(awk "$DNS_LOG_FILTER" <<'EOF'
2026/10/09 00:41:04.17 INFO dnsproxy starting version=v0.86.0
2026/10/09 00:41:41.17 ERROR response received addr=5.175.161.3:53 proto=udp status="i/o timeout"
2026/10/09 00:41:41.17 ERROR exchange failed prefix=dnsproxy upstream=5.175.161.3:53 question=";a.com.\tIN\t HTTPS" duration=10.0s err="read udp 10.0.0.1:40034->5.175.161.3:53: i/o timeout"
2026/10/09 00:41:51.17 ERROR exchange failed prefix=dnsproxy upstream=5.175.161.3:53 question=";b.com.\tIN\t HTTPS" duration=10.0s err="read udp 10.0.0.1:41234->5.175.161.3:53: i/o timeout"
2026/10/09 00:42:01.17 ERROR exchange failed prefix=dnsproxy upstream=tls://x.ru:853 question=";a.com.\tIN\t A" duration=0.2s err="EOF"
2026/10/09 00:47:01.17 ERROR exchange failed prefix=dnsproxy upstream=5.175.161.3:53 question=";c.com.\tIN\t A" duration=10.0s err="read udp 10.0.0.1:1->5.175.161.3:53: i/o timeout"
EOF
)
assert_not_contains "$flt" "response received" "the duplicate «response received» line is dropped"
assert_contains "$flt" ";a.com." "the first timeout of a server is shown"
assert_not_contains "$flt" ";b.com." "the same error from the same server within 5 minutes is not"
assert_contains "$flt" "x.ru" "a different server's error still shows"
assert_contains "$flt" "скрыто повторов за 5 мин: 1" "after the window the skipped repeats are counted"
assert_contains "$flt" "dnsproxy starting" "other lines pass through"

# Сеть переподключилась, адрес телефона сменился: десятки недоставленных ответов
flt=$(awk "$DNS_LOG_FILTER" <<'EOF'
2026/10/14 10:25:23.947137 ERROR responding request prefix=dnsproxy proto=udp err="writing message: write udp 127.0.0.1:15353->100.107.161.52:42201: sendmsg: network is unreachable"
2026/10/14 10:25:23.947229 ERROR responding request prefix=dnsproxy proto=udp err="writing message: write udp 127.0.0.1:15353->100.107.161.52:22087: sendmsg: network is unreachable"
2026/10/14 10:25:23.948183 ERROR responding request prefix=dnsproxy proto=udp err="writing message: write udp 127.0.0.1:15353->100.107.161.52:35724: sendmsg: network is unreachable"
2026/10/14 10:29:00.749415 ERROR responding request prefix=dnsproxy proto=udp err="writing message: write udp 127.0.0.1:15353->100.127.249.142:48182: sendmsg: network is unreachable"
EOF
)
assert_eq 2 "$(printf '%s\n' "$flt" | grep -c 'ERROR responding request')" "one undelivered-answer line per vanished address, not one per query"
assert_contains "$flt" "ответ не доставлен на 100.107.161.52" "explained once"
assert_contains "$flt" "ответ не доставлен на 100.127.249.142" "and again for the next address"

ctl get-logs dns 300
assert_contains "$ctl_out" "лишний dnsproxy" "nfqws2-ctl get-logs dns shows the DNS log"

svc stop
assert_file "$DNS_PIDFILE" "stopping the service leaves dnsproxy running"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "with its interception"

rm -f "$DNS_ENABLED_FILE"
svc start
assert_no_file "$DNS_PIDFILE" "with the feature off the service starts without dnsproxy"
svc stop

section "DNS is independent of the bypass service"

ctl dns-set-enabled 1
assert_file "$DNS_PIDFILE" "dnsproxy starts at once, with the service stopped"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "and intercepts"
ctl dns-set-standalone 1
assert_rc 1 "$ctl_rc" "there is no standalone switch any more"
svc start
svc stop
assert_file "$DNS_PIDFILE" "stopping the service leaves DNS running"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "with its interception"
pid=$(cat "$DNS_PIDFILE"); kill "$pid"; sleep 0.3
dns_check
[ -f "$DNS_PIDFILE" ] && [ "$(cat "$DNS_PIDFILE")" != "$pid" ]
assert_rc 0 $? "the watchdog check restarts it without the service"
pid=$(cat "$DNS_PIDFILE")
ctl dns-restart
assert_rc 0 "$ctl_rc" "dns-restart (long press on «DNS профили») succeeds"
[ -f "$DNS_PIDFILE" ] && [ "$(cat "$DNS_PIDFILE")" != "$pid" ]
assert_rc 0 $? "and runs a new dnsproxy"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "with the interception back in place"
pid=$(cat "$DNS_PIDFILE")
dns_start "смена сети" force
[ -f "$DNS_PIDFILE" ] && [ "$(cat "$DNS_PIDFILE")" != "$pid" ]
assert_rc 0 $? "a network or VPN change restarts dnsproxy even with the same config"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "keeping the interception, so nothing leaks to the carrier DNS meanwhile"
assert_contains "$(cat "$DNS_LOG")" "сеть или VPN сменились" "and says why"
# Перехват — как в 2.1.0/2.1.1: весь трафик на порт 53, и приложений тоже
chain=$(ipt_rules nfqws_dns nat)
assert_eq "" "$(printf '%s\n' "$chain" | grep uid-owner)" "app traffic to port 53 is intercepted too, as before 2.1.2"

# При VPN DNS модуля на паузе — как «Частный DNS» Android: DNS идёт через VPN
NFQWS_SYSNET="$SANDBOX/sysnet"; export NFQWS_SYSNET
mkdir -p "$NFQWS_SYSNET/wlan0"; echo up > "$NFQWS_SYSNET/wlan0/operstate"
dns_start "смена сети" force
assert_file "$DNS_PIDFILE" "on Wi‑Fi DNS runs"
mkdir -p "$NFQWS_SYSNET/tun0"; printf '0x1091\n' > "$NFQWS_SYSNET/tun0/flags"
dns_start "смена сети" force
assert_no_file "$DNS_PIDFILE" "a VPN pauses dnsproxy"
assert_eq "" "$(ipt_rules OUTPUT nat | grep nfqws_dns)" "and removes the interception"
assert_contains "$(cat "$DNS_LOG")" "включён VPN — DNS модуля на паузе" "the log says why"
ctl dns-state
assert_contains "$ctl_out" "paused=vpn" "dns-state reports the pause"
ctl json-status
assert_contains "$ctl_out" '"dns_paused":"vpn"' "and so does json-status"
ctl dns-restart
assert_rc 1 "$ctl_rc" "a manual DNS restart refuses meanwhile"
assert_no_file "$DNS_PIDFILE" "and does not start it"
rm -rf "$NFQWS_SYSNET/tun0"
dns_start "смена сети" force
assert_file "$DNS_PIDFILE" "the VPN gone, DNS is back"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "with its interception"
ctl json-status
assert_contains "$ctl_out" '"dns_paused":""' "and the pause is over"
assert_contains "$ctl_out" '"dns_push":1' "json-status reports the push rule switch (on by default)"
ctl set DNS_PUSH 0
assert_rc 0 "$ctl_rc" "DNS_PUSH is a setting"
ctl json-status
assert_contains "$ctl_out" '"dns_push":0' "and it is saved"
ctl set DNS_PUSH 1

# Домашний Wi‑Fi: DNS не трогается, пока на его экране не включена пауза DNS
printf 'Home\n' > "$HOME_FILE"; HOME_WIFI=1
printf 'HOME_WIFI=1\n' >> "$CONFFILE"
# телефон в «Home»: cmd wifi отвечает её SSID
printf '#!/bin/sh\necho "Wifi is enabled"; echo "Wifi is connected to \\"Home\\""\n' > "$MOCKBIN/cmd"; chmod 0755 "$MOCKBIN/cmd"
printf 'Home' > "$HOME_AT_FILE"
dns_start "смена сети"
assert_file "$DNS_PIDFILE" "at home DNS keeps running by default"
ctl dns-set-home 1
assert_rc 0 "$ctl_rc" "the home DNS pause is a switch"
assert_no_file "$DNS_PIDFILE" "on: at home DNS pauses"
ctl json-status
assert_contains "$ctl_out" '"dns_paused":"home"' "json-status says so"
assert_contains "$ctl_out" '"dns_home_pause":1' "with the switch on"
printf '#!/bin/sh\necho "Wifi is enabled"; echo "Wifi is disconnected"\n' > "$MOCKBIN/cmd"
svc home_check
assert_no_file "$HOME_AT_FILE" "home_check sees the phone leave home"
assert_file "$DNS_PIDFILE" "and DNS resumes away from home"
printf '#!/bin/sh\necho "Wifi is enabled"; echo "Wifi is connected to \\"Home\\""\n' > "$MOCKBIN/cmd"
svc home_check
assert_eq "Home" "$(cat "$HOME_AT_FILE" 2>/dev/null)" "home_check sees it come back"
assert_no_file "$DNS_PIDFILE" "and DNS pauses again"
ctl dns-set-home 0
assert_file "$DNS_PIDFILE" "switch off: DNS runs at home again"
svc stop
rm -f "$HOME_AT_FILE" "$HOME_FILE" "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE" "$MOCKBIN/cmd"; HOME_WIFI=0
conf_reset; printf 'WATCHDOG=0\nIPV6_ENABLED=0\n' >> "$CONFFILE"

# Остатки «мимо VPN» версии 2.1.2 снимаются вместе с правилами DNS
iptables -w -t mangle -N nfqws_dnsm; iptables -w -t mangle -I OUTPUT 1 -j nfqws_dnsm
iptables -w -t nat -N nfqws_dnss; iptables -w -t nat -I POSTROUTING 1 -j nfqws_dnss
dns_rules_del
assert_eq "" "$(ipt_rules OUTPUT mangle | grep nfqws_dnsm)" "a 2.1.2 bypass mark chain is removed"
assert_eq "" "$(ipt_rules POSTROUTING nat | grep nfqws_dnss)" "and its MASQUERADE"
dns_start "запуск"
rm -rf "$NFQWS_SYSNET"; unset NFQWS_SYSNET

ctl dns-set-enabled 0
assert_no_file "$DNS_PIDFILE" "the main switch is what turns it off"
assert_eq "" "$(ipt_rules OUTPUT nat | grep nfqws_dns)" "interception included"
ctl dns-restart
assert_rc 1 "$ctl_rc" "dns-restart refuses while DNS is off"
assert_no_file "$DNS_PIDFILE" "and does not start it"
ctl dns-set-enabled 1
assert_file "$DNS_PIDFILE" "switching back on restarts it without the service"
svc dns_stop
assert_no_file "$DNS_PIDFILE" "service.sh dns_stop (uninstall) stops it regardless"
assert_eq "" "$(ipt_rules OUTPUT nat | grep nfqws_dns)" "and removes the interception"

echo 999999 > "$DNS_PIDFILE"; : > "$DNS_RUN_DIR/active"
dns_boot_reset
assert_no_file "$DNS_PIDFILE" "a pidfile from the previous boot is dropped"
assert_no_file "$DNS_RUN_DIR/active" "as is the running marker"
: > "$DNS_DIR/standalone"; dns_boot_reset
assert_no_file "$DNS_DIR/standalone" "the standalone flag of older versions is cleaned up"
rm -f "$DNS_ENABLED_FILE"

# ── команды WebUI ─────────────────────────────────────────────────────────────
section "interception skips VPN tunnels"
: > "$DNS_ENABLED_FILE"
dns_rules_add
nat=$(ipt_rules nfqws_dns nat)
assert_contains "$nat" "-o tun+ -j RETURN" "queries into a VPN tunnel are not redirected"
assert_contains "$nat" "-o wg+ -j RETURN" "WireGuard included"
first=$(printf '%s\n' "$nat" | grep -n -- '-o tun+' | cut -d: -f1); redir=$(printf '%s\n' "$nat" | grep -n REDIRECT | head -n1 | cut -d: -f1)
[ "$first" -lt "$redir" ]
assert_rc 0 $? "before the REDIRECT"
dns_rules_del 2>/dev/null
rm -f "$DNS_ENABLED_FILE"
assert_contains "$(sed -n '/upstream-mode/p' "$MODDIR/lib/dns.sh")" "parallel" "dnsproxy asks all servers of a profile at once"

section "nfqws2-ctl dns-*"

ctl dns-state
assert_contains "$ctl_out" "#status" "dns-state has a status section"
assert_contains "$ctl_out" "enabled=0" "it reports the feature as off"
assert_contains "$ctl_out" "private=off" "and the Private DNS mode"
assert_contains "$ctl_out" "#profile insta" "profiles follow"
assert_contains "$ctl_out" "#preset google" "and presets"

STUB_PRIVATE=hostname; STUB_PRIVATE_HOST=dns.google
ctl dns-state
assert_contains "$ctl_out" "private=hostname" "Private DNS with a host is detected"
assert_contains "$ctl_out" "private_host=dns.google" "with the host name"
STUB_PRIVATE=off; STUB_PRIVATE_HOST=

ctl dns-save-b64 new1 "$(b64 'NAME=Новый
ENABLED=1
SERVER=tls://dns.comss.one
DOMAIN=chatgpt.com')"
assert_rc 0 "$ctl_rc" "a profile is saved"
assert_file "$DNS_PROFILES_DIR/new1.conf" "under its id"
ctl dns-save-b64 new2 "$(b64 'NAME=Плохой
SERVER=tls://a b')"
assert_rc 1 "$ctl_rc" "a bad server address is refused"
assert_contains "$ctl_out" "Неверный адрес" "with a reason"
ctl dns-save-b64 '../evil' "$(b64 'NAME=x')"
assert_rc 1 "$ctl_rc" "a path in the id is refused"

ctl dns-profile-enable new1 0
assert_contains "$(cat "$DNS_PROFILES_DIR/new1.conf")" "ENABLED=0" "a profile can be switched off"
ctl dns-set-default new1
assert_eq "new1" "$(dns_default)" "a profile can be the default"
ctl dns-set-default nosuch
assert_rc 1 "$ctl_rc" "an unknown default is refused"
ctl dns-delete new1
assert_no_file "$DNS_PROFILES_DIR/new1.conf" "a profile is deleted"
assert_eq "net" "$(dns_default)" "deleting the default profile falls back to the network DNS"
ctl dns-save-b64 m1 "$(b64 'NAME=Один')"; ctl dns-save-b64 m2 "$(b64 'NAME=Два')"
ctl dns-delete m1 m2 nosuch
assert_rc 1 "$ctl_rc" "a batch delete with an unknown id is refused"
assert_file "$DNS_PROFILES_DIR/m1.conf" "and deletes nothing"
ctl dns-set-default m2
ctl dns-delete m1 m2
assert_rc 0 "$ctl_rc" "several profiles are deleted at once"
[ -f "$DNS_PROFILES_DIR/m1.conf" ] || [ -f "$DNS_PROFILES_DIR/m2.conf" ]
assert_rc 1 $? "both of them"
assert_eq "net" "$(dns_default)" "the default falls back when it was among them"
ctl dns-set-enabled 1
assert_file "$DNS_ENABLED_FILE" "the feature is switched on"
ctl dns-set-enabled 0
assert_no_file "$DNS_ENABLED_FILE" "and off"

section "backup carries the profiles"

: > "$DNS_ENABLED_FILE"; echo insta > "$DNS_DEFAULT_FILE"
BACKUP_DIR_OLD="${NFQWS_BACKUP_DIR:-}"
NFQWS_BACKUP_DIR="$SANDBOX/dl"; export NFQWS_BACKUP_DIR
ctl backup-create
assert_rc 0 "$ctl_rc" "a backup is created"
name=$(printf '%s' "$ctl_out" | head -n 1 | cut -f1)
svc dns_stop
rm -f "$DNS_PROFILES_DIR/insta.conf" "$DNS_ENABLED_FILE"; echo net > "$DNS_DEFAULT_FILE"
ctl backup-restore "$name"
assert_rc 0 "$ctl_rc" "and restored"
assert_file "$DNS_PROFILES_DIR/insta.conf" "the profile is back"
assert_file "$DNS_ENABLED_FILE" "the feature state is back"
assert_eq "insta" "$(dns_default)" "the default is back"

harness_finish
