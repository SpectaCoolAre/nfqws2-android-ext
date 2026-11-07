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
# CDN-экземпляр умного DNS (fastest_addr) — в свой файл
case "\$*" in *fastest_addr*) printf '%s\n' "\$@" > "$MOCK_DIR/dnsproxy.cdn.args" ;; *) printf '%s\n' "\$@" > "$MOCK_DIR/dnsproxy.args" ;; esac
exec sleep 600
EOF
chmod 0755 "$MOCKBIN/dumpsys" "$MOCKBIN/settings" "$MODDIR/bin/dnsproxy"
export STUB_PRIVATE STUB_PRIVATE_HOST
load_common
# проверка DNS обхода геоблока в фоне здесь не запускается: её раздел зовёт
# dns_geo_scan сам (иначе фоновая гонялась бы с заглушками других разделов)
dns_geo_scan_bg() { :; }
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

DNS_SMART=0 dns_build
assert_rc 1 $? "nothing to apply while no profile is enabled and the default is the network"
dns_build
assert_rc 0 $? "with smart DNS (on by default) there is: video and CDN get the fastest address even without profiles"
assert_eq "1" "$(grep -c . "$DNS_RUN_DIR/upstreams.txt" | awk '{ print ($1 > 0) }')" "the network DNS stays the default"

printf 'NAME=Insta\nENABLED=1\nSERVER=https://ns2.opennameserver.org/dns-query\nSERVER=tls://dns.google\nDOMAIN=instagram.com\nDOMAIN=cdninstagram.com\n' | dns_profile_save insta
printf 'NAME=Off\nENABLED=0\nSERVER=9.9.9.9\nDOMAIN=off.example\n' | dns_profile_save off
dns_build
assert_rc 0 $? "an enabled profile with domains gives a configuration"
up=$(cat "$DNS_RUN_DIR/upstreams.txt")
assert_contains "$up" "192.168.1.1:53" "the default goes to the DNS of the active network"
assert_not_contains "$(grep -v '^\[/' "$DNS_RUN_DIR/upstreams.txt")" "fe80::1" "with an IPv4 network DNS the IPv6 one is not asked by default: at home it can be another resolver (Keenetic: geodns on IPv4, the built-in DNS on IPv6)"
assert_contains "$(cat "$DNS_RUN_DIR/fallback.txt")" "[fe80::1%wlan0]:53" "it stays a fallback, bracketed"
assert_not_contains "$up" "10.10.10.10" "not the DNS of an inactive network"
assert_contains "$up" "[/instagram.com/cdninstagram.com/]https://ns2.opennameserver.org/dns-query" "domains route to the first server"
assert_contains "$up" "[/instagram.com/cdninstagram.com/]tls://dns.google" "and to the second one"
assert_not_contains "$up" "off.example" "a disabled profile is not applied"
args=$(cat "$DNS_RUN_DIR/args")
assert_contains "$args" "$DNS_PORT" "the listening port is set"
assert_contains "$args" "77.88.8.8:53" "public bootstrap servers are there as a fallback"

echo insta > "$DNS_DEFAULT_FILE"
dns_build
assert_contains "$(head -n 1 "$DNS_RUN_DIR/upstreams.txt")" "192.168.1.1:53" "smart mode: the rest goes to the network DNS whatever the default"
assert_not_contains "$(grep -v '^\[/' "$DNS_RUN_DIR/upstreams.txt")" "opennameserver" "the chosen default is not used for it"
assert_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "[/instagram.com/" "the profiles with domains still work"
assert_eq "net" "$(dns_default_used)" "the DNS in use is the network one"
assert_eq "insta" "$(dns_default)" "and the choice is kept for the profiles mode"
DNS_GEO=0; export DNS_GEO
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
unset DNS_GEO

# 250 доменов — три строки правил на сервер, по 100 доменов
printf 'NAME=Big\nENABLED=1\nSERVER=8.8.8.8\n' > "$SANDBOX/big"
i=0; while [ $i -lt 250 ]; do echo "DOMAIN=d$i.example" >> "$SANDBOX/big"; i=$((i + 1)); done
dns_profile_save big < "$SANDBOX/big"
dns_build
assert_eq "3" "$(grep -c '\]8\.8\.8\.8$' "$DNS_RUN_DIR/upstreams.txt")" "long domain lists are split into lines of 100"
rm -f "$DNS_PROFILES_DIR/big.conf"

section "smart DNS: video and CDN get the fastest address"
dns_build
up=$(cat "$DNS_RUN_DIR/upstreams.txt")
assert_match "$up" "\[/ytimg\.com/ggpht\.com/[^]]*\]127\.0\.0\.1:$DNS_CDN_PORT" "CDN domains go to the CDN dnsproxy"
assert_not_contains "$(grep "127.0.0.1:$DNS_CDN_PORT" "$DNS_RUN_DIR/upstreams.txt")" "googlevideo.com" "but not YouTube video: its names already pick the node, waiting for every server only delays it"
assert_not_contains "$(grep "127.0.0.1:$DNS_CDN_PORT" "$DNS_RUN_DIR/upstreams.txt")" "/cdninstagram.com/" "a CDN domain of an enabled profile keeps the profile's route"
cargs=$(cat "$DNS_RUN_DIR/cdn.args")
assert_contains "$cargs" "--upstream-mode=fastest_addr" "the CDN dnsproxy gives the fastest address"
assert_contains "$cargs" "--cache-optimistic" "with an optimistic cache"
assert_contains "$cargs" "--timeout=1s" "and a silent server holds an answer back for a second at most"
assert_contains "$cargs" "$DNS_CDN_PORT" "on its own port"
cup=$(cat "$DNS_RUN_DIR/cdn.upstreams.txt")
assert_contains "$cup" "192.168.1.1:53" "it asks the network DNS (the ISP has nearby caches)"
assert_contains "$cup" "77.88.8.8:53" "and public ones"
echo insta > "$DNS_DEFAULT_FILE"; dns_build
assert_not_contains "$(cat "$DNS_RUN_DIR/cdn.upstreams.txt")" "opennameserver" "not the default profile's DNS (bypass DNS answer with their proxies)"
echo net > "$DNS_DEFAULT_FILE"; dns_build
assert_contains "$(cat "$DNS_RUN_DIR/args")" "--cache-optimistic" "the main dnsproxy also answers from the cache at once"
DNS_SMART=0 dns_build
assert_no_file "$DNS_RUN_DIR/cdn.args" "off: no CDN dnsproxy"
assert_not_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "$DNS_CDN_PORT" "and no CDN rule"
assert_not_contains "$(cat "$DNS_RUN_DIR/args")" "--cache-optimistic" "and no optimistic cache"
dns_build

# ── перехват ──────────────────────────────────────────────────────────────────
section "interception follows the service"

: > "$DNS_ENABLED_FILE"
svc start
assert_rc 0 "$svc_rc" "the service starts"
assert_file "$DNS_PIDFILE" "dnsproxy is started with it"
assert_contains "$(cat "$MOCK_DIR/dnsproxy.args")" "$DNS_RUN_DIR/upstreams.run$(dns_slot).txt" "with the generated upstream list (the copy for its half of the ports)"
# фильтр журнала dnsproxy (читает FIFO) защищён так же, как сам dnsproxy:
# убьёт его система — dnsproxy завершится по SIGPIPE на первой же строке
: > "$MOCK_DIR/protected"
echo 0 > "$DNS_RUN_DIR/started_at"   # иначе свежий dnsproxy не перезапускается
( protect_process() { echo "$1" >> "$MOCK_DIR/protected"; }; dns_start "тест" force >/dev/null 2>&1 )
flt_pid=""
for f in /proc/[0-9]*/fd/0; do
  [ "$(readlink "$f" 2>/dev/null)" = "$DNS_RUN_DIR/log.fifo" ] || continue
  p=${f#/proc/}; p=${p%%/*}
  [ "$p" = "$(cat "$DNS_PIDFILE")" ] || { flt_pid=$p; break; }
done
assert_match "$flt_pid" "^[0-9]+$" "dnsproxy's output goes through the log filter"
grep -qx "$flt_pid" "$MOCK_DIR/protected"
assert_rc 0 $? "the filter is protected like dnsproxy, or its death would kill dnsproxy"
grep -qx "$(cat "$DNS_PIDFILE")" "$MOCK_DIR/protected"
assert_rc 0 $? "and dnsproxy itself"
nat=$(ipt_rules nfqws_dns nat)
assert_contains "$nat" "-m mark --mark 0x0/0xffff -j RETURN" "packets without a netd mark are left alone (no loop)"
assert_contains "$nat" "-p udp --dport 53 -j REDIRECT --to-ports $(dns_port_now)" "UDP DNS goes to dnsproxy"
assert_contains "$nat" "-p tcp --dport 53 -j REDIRECT --to-ports $(dns_port_now)" "TCP DNS too"
# ── перезапуск без пропуска DNS ───────────────────────────────────────────────
# Смена сети: новый dnsproxy — на другой половине портов, перехват переходит
# на него, не снимаясь, прежний гаснет потом. Раньше прежний гас до запуска
# нового, и 1,3–1,6 с запросы шли в закрытый порт («нет интернета» в
# приложениях, переподключавшихся после смены сети)
opid=$(cat "$DNS_PIDFILE"); oport=$(dns_port_now); ocdn=$(cat "$DNS_CDN_PIDFILE" 2>/dev/null)
echo 0 > "$DNS_RUN_DIR/started_at"
: > "$MOCK_DIR/swap.check"
( dns_listening() { ipt_rules nfqws_dns nat | grep -q REDIRECT || echo gap >> "$MOCK_DIR/swap.check"; return 0; }
  dns_start "смена сети" force >/dev/null 2>&1 )
npid=$(cat "$DNS_PIDFILE")
assert_eq "" "$(cat "$MOCK_DIR/swap.check")" "while the new dnsproxy starts the old interception stays in place"
[ "$npid" != "$opid" ] && kill -0 "$npid" 2>/dev/null
assert_rc 0 $? "a network change starts a new dnsproxy"
assert_eq "$([ "$oport" = "$DNS_PORT" ] && echo $((DNS_PORT + 10)) || echo $DNS_PORT)" "$(dns_port_now)" "on the other half of the ports"
nat=$(ipt_rules nfqws_dns nat)
assert_contains "$nat" "-p udp --dport 53 -j REDIRECT --to-ports $(dns_port_now)" "interception moves to it"
assert_not_contains "$nat" "--to-ports $oport" "and no rule is left for the old port"
assert_eq "1" "$(printf '%s\n' "$nat" | grep -c 'udp --dport 53 -j REDIRECT')" "one UDP rule, in the place of the old one"
assert_contains "$(ipt_rules nfqws_dns nat ip6tables)" "--to-ports $(dns_port_now)" "IPv6 interception moves too"
dns_alive "$opid"; assert_rc 1 $? "the old dnsproxy is stopped after the switch"
[ -n "$ocdn" ] && { dns_alive "$ocdn"; assert_rc 1 $? "and the old CDN one"; }
assert_contains "$(tail -n 20 "$DNS_LOG")" "прежний dnsproxy (PID $opid) остановлен" "the DNS log says so"
assert_contains "$(cat "$MOCK_DIR/dnsproxy.args")" "$(dns_port_now)" "the new one listens on its own port"
assert_not_contains "$(tail -n 20 "$DNS_LOG")" "перехват выключен" "interception is never switched off"
assert_contains "$(cat "$DNS_RUN_DIR/args")" "$DNS_PORT" "the built config keeps the main port: «same or changed» compares like before"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "OUTPUT jumps into the chain"
assert_contains "$(ipt_rules nfqws_dns nat ip6tables)" "REDIRECT" "IPv6 is redirected when ip6tables has nat"

pid=$(cat "$DNS_PIDFILE")
dns_start
assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "an unchanged configuration does not restart dnsproxy"
cpid=$(cat "$DNS_CDN_PIDFILE" 2>/dev/null)
kill -0 "$cpid" 2>/dev/null
assert_rc 0 $? "the CDN dnsproxy of smart DNS runs next to it"
assert_contains "$(cat "$MOCK_DIR/dnsproxy.cdn.args")" "$DNS_RUN_DIR/cdn.upstreams.txt" "with its own upstream list"
dns_kill_strays
kill -0 "$cpid" 2>/dev/null
assert_rc 0 $? "it is not taken for a stray dnsproxy"
kill "$cpid"; sleep 0.3
dns_check
kill -0 "$(cat "$DNS_CDN_PIDFILE" 2>/dev/null)" 2>/dev/null
assert_rc 0 $? "the watchdog restarts it when it dies"
assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "without touching the main dnsproxy"
assert_contains "$(cat "$DNS_LOG")" "умный DNS: видео и CDN — самый быстрый адрес" "the DNS log says it runs"

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

section "the watchdog asks dnsproxy, not only /proc"

# помощник-заглушка: отвечает dnsproxy или нет — по файлу; аргументы — в лог
cat > "$HELPER_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$MOCK_DIR/helper.calls"
[ -f "$MOCK_DIR/dns_hung" ] || exit 0
echo "nfqws2-helper: 2026/10/27 19:57:37 127.0.0.1:$DNS_PORT: нет ответа" >&2
exit 1
EOF
chmod 0755 "$HELPER_BIN"
pid=$(cat "$DNS_PIDFILE")
: > "$MOCK_DIR/helper.calls"
dns_check
assert_contains "$(cat "$MOCK_DIR/helper.calls")" "-probe 127.0.0.1:$(dns_port_now),127.0.0.1:$(dns_cdn_port_now)" "it asks the main and the CDN dnsproxy"
assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "an answering dnsproxy is left alone"
: > "$MOCK_DIR/dns_hung"
dns_check
assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "one missed answer is not enough to restart"
assert_file "$DNS_RUN_DIR/probe_fail" "but it is counted"
rm -f "$MOCK_DIR/dns_hung"
dns_check
assert_no_file "$DNS_RUN_DIR/probe_fail" "an answer in between resets the count"
: > "$MOCK_DIR/dns_hung"
dns_check; dns_check
npid=$(cat "$DNS_PIDFILE" 2>/dev/null)
[ -n "$npid" ] && [ "$npid" != "$pid" ] && kill -0 "$npid" 2>/dev/null
assert_rc 0 $? "two missed answers in a row restart dnsproxy"
kill -0 "$pid" 2>/dev/null; assert_rc 1 $? "the hung one is gone"
assert_contains "$(ipt_rules nfqws_dns nat)" "REDIRECT --to-ports $(dns_port_now)" "interception stays on"
assert_contains "$(tail -n 5 "$DNS_LOG")" "работает, но не отвечает на запросы (127.0.0.1:$DNS_PORT: нет ответа )" "the DNS log says it hung, with the helper's reason"
assert_contains "$(tail -n 3 "$SERVICE_LOG")" "DNS: dnsproxy завис" "and the service log too"
assert_no_file "$DNS_RUN_DIR/probe_fail" "the count starts over"
# dnsproxy отвечает сам, а ответы серверов до него не доходят: телефон без
# DNS («нет сети» в приложениях), а журнал пуст. Проверка — настоящим именем
cat > "$HELPER_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$MOCK_DIR/helper.calls"
case "\$*" in
  *"-probe 127.0.0.1:"*"-name "*) [ -f "$MOCK_DIR/up_dead" ] || exit 0; echo "nfqws2-helper: 2026/11/07 16:09:30 127.0.0.1:x: rcode 2" >&2; exit 1 ;;
  *"-name "*) [ -f "$MOCK_DIR/net_dead" ] && exit 1; exit 0 ;;
esac
exit 0
EOF
chmod 0755 "$HELPER_BIN"
: > "$MOCK_DIR/helper.calls"
dns_check
assert_contains "$(cat "$MOCK_DIR/helper.calls")" "-name www.google.com" "the watchdog also resolves a real name through the module's DNS"
: > "$MOCK_DIR/up_dead"; : > "$MOCK_DIR/net_dead"
dns_check; dns_check; dns_check
assert_no_file "$DNS_RUN_DIR/up_fail" "the network's own DNS is silent too — the network is down, not the module's DNS"
assert_contains "$(ipt_rules nfqws_dns nat)" "REDIRECT" "and interception stays"
rm -f "$MOCK_DIR/net_dead"
if [ -n "$(dns_net_servers | tr ',' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')" ]; then
  pid=$(cat "$DNS_PIDFILE")
  dns_check
  assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "one failed real lookup is not enough"
  # перезапуск — заглушкой: настоящий ждёт порт заглушки dnsproxy по 4 с и
  # сдвигает время, а в песочнице с «interception follows the service» сам
  # работает watchdog и попадает в окна следующих проверок замка
  : > "$MOCK_DIR/restarts"
  ( dns_proxy_stop() { echo stop >> "$MOCK_DIR/restarts"; }; dns_proxy_start() { echo start >> "$MOCK_DIR/restarts"; }; dns_check )
  assert_contains "$(tail -n 5 "$DNS_LOG")" "DNS модуля не разрешает www.google.com (127.0.0.1:x: rcode 2), а DNS сети" "two in a row while the network's DNS answers: logged with the reason"
  assert_eq "stop start" "$(tr '\n' ' ' < "$MOCK_DIR/restarts" | sed 's/ $//')" "and dnsproxy is restarted"
  dns_check
  assert_not_contains "$(ipt_rules nfqws_dns nat)" "REDIRECT" "still dead after the restart: interception is lifted, the phone uses the network's DNS"
  assert_file "$DNS_RUN_DIR/failopen" "for a while"
  assert_contains "$(tail -n 3 "$SERVICE_LOG")" "перехват снят на 5 мин" "the service log says so"
  dns_check
  assert_not_contains "$(ipt_rules nfqws_dns nat)" "REDIRECT" "the watchdog does not put it back at once"
  rm -f "$MOCK_DIR/up_dead"
  echo $(( $(date +%s) - 400 )) > "$DNS_RUN_DIR/failopen"
  dns_check
  assert_contains "$(ipt_rules nfqws_dns nat)" "REDIRECT --to-ports $(dns_port_now)" "five minutes later, answering again: interception is back"
  assert_no_file "$DNS_RUN_DIR/failopen" "and the pause is over"
else
  echo "   skip  real-lookup restart: no IPv4 network DNS in the mock"
fi
rm -f "$MOCK_DIR/up_dead" "$MOCK_DIR/net_dead"
rm -f "$MOCK_DIR/dns_hung" "$HELPER_BIN"
: > "$MOCK_DIR/helper.calls"
dns_check
assert_eq "" "$(cat "$MOCK_DIR/helper.calls")" "without the helper there is no check"

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
assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "a dnsproxy started seconds ago with this config is not restarted for a network change"
echo 0 > "$DNS_RUN_DIR/started_at"   # запущен давно
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
assert_not_contains "$ctl_out" '"dns_push"' "the push switch is gone from the UI status"
ctl set DNS_PUSH 0
assert_rc 0 "$ctl_rc" "DNS_PUSH stays a setting for old configs"
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

section "geo-block bypass: domains from the list go to the bypass DNS"
# Как nameserver-policy в mihomo: маршрут — по списку доменов (geoblock.list),
# обычные правила dnsproxy; ничего перед ним, никакой догадки по ответу
: > "$DNS_ENABLED_FILE"
printf '# сервисы с геоблоком\nchatgpt.com\nClaude.ai\ninstagram.com\nvk.com\nmail.ru\ngooglevideo.com\nmtalk.google.com\nchatgpt.com\n4pda.to\n' > "$DNS_GEO_LIST"
: > "$DNS_RUN_DIR/geo.args"; : > "$DNS_RUN_DIR/main_port"
dns_build
geo=$(grep '/chatgpt.com/' "$DNS_RUN_DIR/upstreams.txt")
assert_contains "$geo" "[/chatgpt.com/claude.ai/]https://dns.comss.one/dns-query" "before the first check of the bypass DNS the list goes to Comss DoH — the same server as its Private DNS"
assert_eq "1" "$(printf '%s\n' "$geo" | grep -c .)" "only it: the first answer of several led Claude to a proxy that does not work here"
assert_eq "Comss — до первой проверки" "$(dns_geo_label)" "the DNS log names the bypass DNS"
# Profile overlap: an enabled profile of its own with domains of the list
# takes them away from the bypass — the screen warns
assert_contains "$(dns_geo_overlap)" "insta 1" "an enabled profile with a domain of the list is found, with how many it takes"
assert_contains "$(dns_state)" "geo_overlap_insta=1" "and the screen is told"
assert_eq "" "$(DNS_GEO=0 dns_geo_overlap)" "profiles mode: there is no bypass to take from"
dns_build
geo=$(grep '/chatgpt.com/' "$DNS_RUN_DIR/upstreams.txt")
assert_eq "1" "$(printf '%s\n' "$geo" | head -n 1 | grep -o '/chatgpt.com/' | grep -c .)" "a domain listed twice — once"
assert_not_contains "$geo" "instagram.com" "an enabled profile's domain keeps the profile's route"
assert_not_contains "$geo" "vk.com" "Russian services never go around"
assert_not_contains "$geo" "mail.ru" "nor anything in .ru"
assert_not_contains "$geo" "4pda" "nor 4pda: itdoginfo lists it, but in Russia it opens directly, and through a bypass proxy it did not open at all"
assert_not_contains "$geo" "googlevideo.com" "nor video and CDN"
assert_not_contains "$geo" "mtalk.google.com" "nor Google push notifications"
assert_contains "$(head -n 1 "$DNS_RUN_DIR/upstreams.txt")" "192.168.1.1:53" "everything else — the network DNS"
# проверка домена говорит, куда DNS модуля его отправит
sleep 30 & fake=$!; old_pid=$(cat "$DNS_PIDFILE" 2>/dev/null); echo "$fake" > "$DNS_PIDFILE"
assert_eq "geo" "$(dns_route chat.chatgpt.com)" "domain check: a listed service (and its subdomains) goes to the bypass DNS"
assert_eq "cdn" "$(dns_route i.ytimg.com)" "YouTube images go to the smart CDN DNS"
assert_eq "default" "$(dns_route rr1---sn-x.googlevideo.com)" "YouTube video — to the network DNS"
assert_eq "default" "$(dns_route example.org)" "anything else to the default DNS"
assert_match "$(dns_route instagram.com)" "^rule " "a profile's domain to the profile's server"
kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
assert_eq "off" "$(dns_route chatgpt.com)" "and «off» while dnsproxy is not running"
[ -n "$old_pid" ] && echo "$old_pid" > "$DNS_PIDFILE"
assert_eq "$DNS_PORT" "$(sed -n '/^-p$/{n;p;}' "$DNS_RUN_DIR/args")" "dnsproxy itself takes the interception port: nothing in front of it"
assert_no_file "$DNS_RUN_DIR/geo.args" "leftovers of the geodns arbiter are removed"
assert_no_file "$DNS_RUN_DIR/main_port" "all of them"
i=0; while [ $i -lt 250 ]; do echo "g$i.example"; i=$((i + 1)); done > "$DNS_GEO_LIST"
dns_build
assert_eq "1" "$(grep -c '/g1.example/' "$DNS_RUN_DIR/upstreams.txt")" "a long list — lines of 100 domains, one per server"
assert_eq "3" "$(grep -c 'example/\]https://' "$DNS_RUN_DIR/upstreams.txt")" "three lines per server"
DNS_GEO=0 dns_build
assert_not_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "g1.example" "profiles mode: the list is not used"
: > "$DNS_GEO_LIST"
dns_build
assert_not_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "eu.geohide.ru" "an empty list — no rules"

# Обновление списка: свежий geoblock + домены GeoHide к тому, что уже есть
printf '# шапка\nmy-service.example\nchatgpt.com\n' > "$DNS_GEO_LIST"
hosts_download() {
  case "$1" in
    *v2fly*) printf '# Gemini\ninclude:google-ai\nfull:geminiweb-pa.clients6.google.com\ngemini.google @cn\nregexp:^x.*$\n' > "$2"; return 0 ;;
  esac
  printf 'chatgpt.com\nOpenAI.com\n\n# comment\n' > "$2"; i=0; while [ $i -lt 60 ]; do echo "n$i.example"; i=$((i + 1)); done >> "$2"; }
n=$(dns_geo_update)
assert_rc 0 $? "the list is updated"
assert_match "$(cat "$DNS_GEO_LIST")" "^my-service\.example$" "the user's own domains stay"
assert_match "$(cat "$DNS_GEO_LIST")" "^openai\.com$" "new ones are added (lower case)"
assert_match "$(cat "$DNS_GEO_LIST")" "^game\.brawlstarsgame\.com$" "GeoHide's own list too"
assert_match "$(cat "$DNS_GEO_LIST")" "^geminiweb-pa\.clients6\.google\.com$" "Google AI domains from v2fly (full: dropped)"
assert_match "$(cat "$DNS_GEO_LIST")" "^gemini\.google$" "and without their tags"
assert_not_contains "$(cat "$DNS_GEO_LIST")" "include:" "includes and regexps are skipped"
assert_not_contains "$(cat "$DNS_GEO_LIST")" "regexp" "(regexp too)"
assert_eq "1" "$(grep -c '^chatgpt.com$' "$DNS_GEO_LIST")" "without duplicates"
assert_match "$(head -n 1 "$DNS_GEO_LIST")" "^# шапка$" "the header stays on top"
assert_eq "$(list_count "$DNS_GEO_LIST")" "$n" "it answers with the number of domains"
assert_file "$DNS_DIR/geo_updated" "and remembers when"
cp "$DNS_GEO_LIST" "$SANDBOX/geo.before"
hosts_download() { return 1; }
dns_geo_update >/dev/null
assert_rc 1 $? "a failed download is an error"
cmp -s "$DNS_GEO_LIST" "$SANDBOX/geo.before"
assert_rc 0 $? "and leaves the list as it was"
hosts_download() { echo "<html>error</html>" > "$2"; }
dns_geo_update >/dev/null
assert_rc 1 $? "so does a page that is not a list"
unset -f hosts_download; . "$MODDIR/lib/hosts.sh"

svc start
ctl dns-state
assert_contains "$ctl_out" "geo=on" "dns-state reports the bypass"
assert_contains "$ctl_out" "geo_domains=$(list_count "$DNS_GEO_LIST")" "with the size of the list"
assert_match "$(grep '/my-service.example/' "$DNS_RUN_DIR/running.upstreams")" "comss" "the running dnsproxy has the rules"
ctl dns-mode profiles
assert_rc 0 "$ctl_rc" "the DNS mode switches to profiles"
assert_match "$(cat "$CONFFILE")" "^DNS_GEO=\"0\"$" "geo-block bypass off"
assert_match "$(cat "$CONFFILE")" "^DNS_SMART=\"0\"$" "and the fast CDN route too"
assert_not_contains "$(cat "$DNS_RUN_DIR/running.upstreams")" "my-service.example" "the rules are gone at once"
ctl json-status
assert_contains "$ctl_out" '"dns_geo":0' "json-status reports it"
ctl dns-mode smart
assert_match "$(cat "$CONFFILE")" "^DNS_GEO=\"1\"$" "smart mode turns both back on"
assert_contains "$(cat "$DNS_RUN_DIR/running.upstreams")" "my-service.example" "and the rules are back"
ctl dns-mode fast
assert_rc 1 "$ctl_rc" "an unknown mode is refused"
svc dns_stop
rm -f "$DNS_ENABLED_FILE"

section "geo-block bypass: the module picks the bypass DNS itself"
# Проверка — nfqws2-helper -geoscan (helper/geoscan.go); здесь поддельный
# помощник печатает её итог: сервер ok|fail мс обходит доменов своим-адресом
# протокол, затем маршруты «=домен<TAB>серверы»
cat > "$HELPER_BIN" <<'EOF'
#!/bin/sh
[ "$1" = -geoscan ] || exit 2
echo "$@" > "$MOCK_DIR/geoscan.args"
cat "${4#@}" > "$MOCK_DIR/geoscan.list"
printf 'slow.example\tok\t300\t7\t7\t0\ttls\n'
printf 'fast.example\tok\t40\t7\t7\t0\ttls\n'
printf 'ai.example\tok\t20\t3\t7\t3\ttls\n'
printf 'mid.example\tok\t90\t7\t7\t0\thttps\n'
printf 'next.example\tok\t120\t7\t7\t0\ttls\n'
printf 'dead.example\tfail\t0\t0\t7\t0\t-\ttimeout\n'
EOF
chmod 0755 "$HELPER_BIN"
printf 'chatgpt.com\nclaude.ai\n' > "$DNS_GEO_LIST"
rm -rf "$DNS_GEO_SCAN_DIR"
assert_eq "" "$(dns_geo_pick)" "no check yet — no pool"
dns_geo_scan_due
assert_rc 0 $? "so a check is due"
dns_apply_now() { echo applied >> "$MOCK_DIR/geo.applied"; }
dns_geo_scan
assert_contains "$(cat "$MOCK_DIR/geoscan.args")" "-boot 192.168.1.1:53" "server addresses come from the network DNS"
assert_contains "$(cat "$MOCK_DIR/geoscan.args")" "-ref https://common.dot.dns.yandex.net/dns-query,77.88.8.8:53" "reference «real» answers come from an honest DNS, not the network one (a router that bypasses geo-blocks answers with proxies)"
assert_contains "$(cat "$MOCK_DIR/geoscan.args")" "dns.zapret.moe" "all the DoT servers of the list are checked"
assert_eq "chatgpt.com claude.ai" "$(tr '\n' ' ' < "$MOCK_DIR/geoscan.list" | sed 's/ $//')" "on every domain of the list, not on a few samples"
assert_contains "$(cat "$MOCK_DIR/geoscan.args")" "-asncache $DNS_GEO_SCAN_DIR/asn.cache" "network numbers are cached"
assert_eq "fast.example" "$(dns_geo_pick)" "the common pool: one server — the fastest of those that bypass the most domains (several at once gave a site different exit addresses in one session)"
assert_not_contains "$(dns_geo_pick)" "ai.example" "a faster server that bypasses fewer stays out of it"
assert_eq "applied" "$(cat "$MOCK_DIR/geo.applied")" "a new pool is applied at once"
# Ручная проверка (кнопка) — в фоне: ответ команды сразу, итог — ожиданием
sed -i '1s/^#time=[0-9]*/#time=1/' "$(dns_geo_scan_file)"; rm -f "$DNS_RUN_DIR/geoscan.req" "$DNS_RUN_DIR/geoscan.result"
ctl dns-geo-scan
assert_rc 0 "$ctl_rc" "the button starts a check"
req=$ctl_out
assert_match "$req" "^[0-9][0-9]*$" "and returns at once with the request time (the check takes longer than the screen waits for a command)"
ctl dns-geo-scan-wait "$req"
assert_rc 0 "$ctl_rc" "waiting gets its result"
assert_eq "fast.example" "$ctl_out" "the pool, for the toast"
ctl dns-geo-scan
assert_rc 3 "$ctl_rc" "a manual check right after one is refused (calls to the servers only make things worse)"
sed -i '1s/^#time=[0-9]*/#time=1/' "$(dns_geo_scan_file)"
ctl dns-geo-scan
assert_rc 3 "$ctl_rc" "a check that gave nothing new counts too: the cooldown runs from the request"
rm -f "$DNS_RUN_DIR/geoscan.req"
mkdir -p "$DNS_RUN_DIR/geoscan.lock"
req=$(dns_geo_scan_req)
( sleep 2; rmdir "$DNS_RUN_DIR/geoscan.lock" ) &
dns_geo_scan_wait "$req" >/dev/null 2>&1
assert_rc 0 $? "another check is running — the full one follows it, not silently skipped"
cp "$(dns_geo_scan_file)" "$MOCK_DIR/geo.keep"
cat > "$MOCK_DIR/helper.ok" < "$HELPER_BIN"
printf '#!/bin/sh\nprintf "fast.example\\tfail\\t0\\t0\\t7\\t0\\t-\\n"\n' > "$HELPER_BIN"
rm -f "$DNS_RUN_DIR/geoscan.req"
req=$(dns_geo_scan_req)
ctl dns-geo-scan-wait "$req"
assert_rc 1 "$ctl_rc" "no server answered — the screen hears it"
assert_contains "$ctl_out" "Ни один сервер не ответил — оставлен прежний выбор: fast.example" "and the old choice stays"
cat "$MOCK_DIR/helper.ok" > "$HELPER_BIN"; cp "$MOCK_DIR/geo.keep" "$(dns_geo_scan_file)"; rm -f "$(dns_geo_scan_file).fail"
# фоновая проверка погибла, не дав итога (менеджер снял её вместе с
# командой WebUI) — ожидание не молчит три минуты, а кулдаун не держит
echo "$(date +%s)" > "$DNS_RUN_DIR/geoscan.req"; rm -f "$DNS_RUN_DIR/geoscan.result"; echo 999999 > "$DNS_RUN_DIR/geoscan.pid"
ctl dns-geo-scan-wait "$(cat "$DNS_RUN_DIR/geoscan.req")"
assert_rc 1 "$ctl_rc" "a check that died without a result is reported"
assert_contains "$ctl_out" "Проверка не запустилась" "in words"
assert_eq "" "$(cat "$DNS_RUN_DIR/geoscan.req" 2>/dev/null)" "and the button may be pressed again at once"
assert_contains "$(sed -n '/^dns_geo_scan_req()/,/^}/p' "$MODDIR/lib/dns.sh")" "setsid" "the check runs in its own session (the manager kills the command's group)"
date +%s > "$DNS_RUN_DIR/geoscan.req"
ctl dns-geo-scan
assert_rc 3 "$ctl_rc" "still within the cooldown"
assert_contains "$ctl_out" "Слишком часто — повторить можно через 5 мин" "the screen says so"
date +%s > "$DNS_DIR/geo_updated"
ctl dns-geo-update
assert_rc 3 "$ctl_rc" "updating the list again so soon is refused too"
assert_contains "$ctl_out" "через 30 мин" "for half an hour"
rm -f "$DNS_DIR/geo_updated"
dns_geo_scan_due
assert_rc 1 $? "after a check nothing is due for hours"
dns_build
geo=$(grep '/chatgpt.com/' "$DNS_RUN_DIR/upstreams.txt")
assert_contains "$geo" "]tls://fast.example" "a domain without a route goes to the pool over DoT"
assert_eq "1" "$(printf '%s\n' "$geo" | grep -c .)" "to it alone"
assert_eq "fast.example" "$(dns_geo_label)" "the log and the screen name the pool"
# Закреплённый сервер пула остаётся, пока обходит не меньше 90% от лучшего
echo "* mid.example" > "$(dns_geo_scan_file).pin"
assert_eq "mid.example" "$(dns_geo_pick)" "the pinned server stays, though another is faster"
dns_build
assert_contains "$(grep '/chatgpt.com/' "$DNS_RUN_DIR/upstreams.txt")" "]https://mid.example/dns-query" "a server that got through only over DoH on this network goes there over DoH"
echo "* ai.example" > "$(dns_geo_scan_file).pin"
assert_eq "fast.example" "$(dns_geo_pick)" "a pinned server far behind the best is let go"
dns_geo_pin_save
assert_contains "$(cat "$(dns_geo_scan_file).pin")" "* fast.example" "and the new one is pinned"
dns_build
rm -f "$MOCK_DIR/geo.applied"; dns_geo_scan
assert_no_file "$MOCK_DIR/geo.applied" "the same pool again — nothing to apply"
sed -i '1s/^#time=[0-9]*/#time=1/' "$(dns_geo_scan_file)"
dns_geo_scan_due
assert_rc 0 $? "an old check is due again"
printf '#time=%s boot=x v=%s\nfast.example\tfail\t0\t0\t7\t0\t-\n' "$(date +%s)" "$DNS_GEO_SCAN_VER" > "$(dns_geo_scan_file)"
assert_eq "" "$(dns_geo_pick)" "no server answered (the network was not up yet)"
assert_contains "$(dns_geo_servers)" "https://dns.comss.one/dns-query" "Comss for now"
dns_geo_scan_due
assert_rc 1 $? "and a new check — not at once"
sed -i '1s/^#time=[0-9]*/#time='"$(( $(date +%s) - 700 ))"'/' "$(dns_geo_scan_file)"
dns_geo_scan_due
assert_rc 0 $? "but ten minutes later"
a=$(dns_net_servers() { printf '192.168.1.2,192.168.1.1'; }; dns_geo_scan_file)
b=$(dns_net_servers() { printf '192.168.1.1,192.168.1.2'; }; dns_geo_scan_file)
assert_eq "$a" "$b" "the same network DNS in another order is the same network (its check is not lost)"
# После загрузки сеть появляется не сразу: проверка без единого ответа не
# затирает рабочий итог, а повторяется через минуту, две, четыре…
dns_geo_scan >/dev/null
good=$(cat "$(dns_geo_scan_file)")
mv "$HELPER_BIN" "$HELPER_BIN.ok"
printf '#!/bin/sh\nprintf "fast.example\\tfail\\t0\\t0\\t2\\t0\\t-\\tnetwork is unreachable\\n"\n' > "$HELPER_BIN"; chmod 0755 "$HELPER_BIN"
dns_geo_scan >/dev/null
assert_eq "$good" "$(cat "$(dns_geo_scan_file)")" "a check nobody answered keeps the working result (no errors on the screen)"
assert_eq "fast.example" "$(dns_geo_pick)" "and the pool"
assert_contains "$(tail -n 1 "$DNS_LOG")" "ни один сервер не ответил" "the DNS log says why"
dns_geo_scan_due
assert_rc 1 $? "no new check at once"
echo "1 $(( $(date +%s) - 61 ))" > "$(dns_geo_scan_file).fail"
dns_geo_scan_due
assert_rc 0 $? "but a minute later — not in ten"
echo "2 $(( $(date +%s) - 61 ))" > "$(dns_geo_scan_file).fail"
dns_geo_scan_due
assert_rc 1 $? "the second failure waits two minutes"
(dns_net_servers() { :; }; rm -f "$(dns_geo_scan_file).fail"; rm -f "$(dns_geo_scan_file)"; dns_geo_scan_due)
assert_rc 1 $? "while the network DNS is unknown (network not up yet) there is nothing to check"
mv -f "$HELPER_BIN.ok" "$HELPER_BIN"
dns_geo_scan >/dev/null
assert_no_file "$(dns_geo_scan_file).fail" "a check with answers clears the failure count"
printf '#time=%s boot=x\nfast.example\tok\t40\t7\t7\tchatgpt.com=p\n' "$(date +%s)" > "$(dns_geo_scan_file)"
dns_geo_scan_due
assert_rc 0 $? "a fresh check of an older version (samples only) is redone"
DNS_GEO=0 dns_geo_scan_due
assert_rc 1 $? "profiles mode needs no check"
dns_geo_scan >/dev/null
# Маршруты по доменам: каждый — к своим серверам (свой адрес прокси —
# только к ним), никем не обходимый — в DNS сети, без данных — общий пул
printf 'chatgpt.com\nab.chatgpt.com\nclashofclans.com\nintel.com\nmistral.ai\n' > "$DNS_GEO_LIST"
{ printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'zapret.example\tok\t20\t2\t4\t0\ttls\n'
  printf 'comss.example\tok\t60\t3\t4\t1\thttps\n'
  printf 'dead.example\tfail\t0\t0\t4\t0\t-\ttimeout\n'
  printf '=chatgpt.com\tzapret.example,comss.example\n'
  printf '=clashofclans.com\tcomss.example\n'
  printf '=intel.com\t-\n'
  printf '=gone.example\tdead.example\n'
  printf '?whoami\tnet=93.1.1.1/8359\tgoogle=93.1.1.1/8359\tcloudflare=-\tintercept=1\n'
} > "$(dns_geo_scan_file)"
assert_eq "ab.chatgpt.com	zapret.example	tls|chatgpt.com	zapret.example	tls|clashofclans.com	comss.example	https|intel.com	-" "$(dns_geo_routes | sort | tr '\n' '|' | sed 's/|$//')" "routes come from the check, one server a domain, with its protocol (a dead one is dropped; a group domain the check missed follows its group)"
assert_eq "comss.example" "$(dns_geo_pick)" "the common pool: the one that bypasses the most (route lines are not servers)"
dns_build
up=$(cat "$DNS_RUN_DIR/upstreams.txt")
assert_contains "$(grep '/ab.chatgpt.com/' "$DNS_RUN_DIR/upstreams.txt")" "]tls://zapret.example" "ChatGPT and its subdomains — to its servers"
assert_contains "$(grep '/clashofclans.com/' "$DNS_RUN_DIR/upstreams.txt")" "]https://comss.example/dns-query" "the game — only to the one with its own proxy address"
assert_eq "1" "$(grep -c '/clashofclans.com/' "$DNS_RUN_DIR/upstreams.txt")" "and to no one else"
assert_not_contains "$up" "/intel.com/" "a domain no server bypasses goes to the network DNS"
assert_contains "$(grep '/mistral.ai/' "$DNS_RUN_DIR/upstreams.txt")" "]https://comss.example/dns-query" "a domain without data — to the common pool"
assert_eq "geo" "$(dns_pid() { echo 1; }; dns_route chatgpt.com)" "a per-domain route still counts as the geo-block bypass"
st=$(dns_state)
assert_contains "$st" "geo_for_comss.example=1" "the screen learns how many domains go to a server"
assert_contains "$st" "geo_direct=1" "and how many to the network DNS"
assert_contains "$st" "geo_intercept=1" "and that the network intercepts plain DNS"
assert_contains "$st" "geo_who_google=93.1.1.1/8359" "with who really answered"
assert_not_contains "$(printf '%s\n' "$st" | sed -n '/^#geoscan/,/^#/p')" "=chatgpt.com" "route lines stay out of the server list"
# Частая проверка: домены списка, которыми пользуются, — раз в полчаса;
# полная — раз в 4 часа; в спячке — ни та ни другая
mkdir -p "$SMART_DIR"
now=$(date +%s)
{ printf '#v4 slot\thost\tcur\tok\terr\tcool\tseen\tflags\n'
  printf 'tls_as\tgamea.clashofclans.com\t1\t\t\t\t%s\t\n' "$now"
  printf 'tls\tapi.mistral.ai\t1\t\t\t\t%s\t\n' "$((now - 60))"
  printf 'tls\told.mistral.ai\t1\t\t\t\t%s\t\n' "$((now - 30 * 86400))"
  printf 'tls\texample.org\t1\t\t\t\t%s\t\n' "$now"
} > "$SMART_DIR/mobile-1.tsv"
hot=$(dns_geo_hot_list | tr '\n' ' ')
assert_contains "$hot" "gamea.clashofclans.com" "a site the phone used, by its own name (the game server, not the list entry)"
assert_contains "$hot" "api.mistral.ai" "under any list domain"
assert_contains "$hot" "chatgpt.com" "the main services are always there"
assert_not_contains "$hot" "old.mistral.ai" "not one unused for a month"
assert_not_contains "$hot" "example.org" "not a site outside the geo-block list"
assert_not_contains "$hot" "claude.ai" "nor a main service outside this list"
assert_eq "" "$(dns_geo_due)" "right after the check nothing is due"
sed -i '1s/^#time=[0-9]*/#time='"$((now - 1900))"'/' "$(dns_geo_scan_file)"
assert_eq "hot" "$(dns_geo_due)" "half an hour later — the frequent check, not the full one"
: > "$IDLE_FILE"
assert_eq "" "$(dns_geo_due)" "the phone sleeps (no traffic) — no check at all"
rm -f "$IDLE_FILE"
mv "$HELPER_BIN" "$HELPER_BIN.full"
cat > "$HELPER_BIN" <<'EOF'
#!/bin/sh
echo "$@" > "$MOCK_DIR/geoscan.args"
cat "${4#@}" > "$MOCK_DIR/geoscan.list"
printf 'zapret.example\tok\t20\t1\t4\t1\ttls\n'
printf '=gamea.clashofclans.com\tzapret.example\n'
printf '!zapret.example\t2/3\t1\n'
EOF
chmod 0755 "$HELPER_BIN"
rm -f "$MOCK_DIR/geo.applied"
dns_geo_scan hot
assert_contains "$(cat "$MOCK_DIR/geoscan.args")" "-shared $(dns_geo_scan_file)" "it knows the shared proxy addresses of the full check"
assert_eq "$hot" "$(tr '\n' ' ' < "$MOCK_DIR/geoscan.list")" "only the used domains are checked"
assert_contains "$(cat "$MOCK_DIR/geoscan.args")" "-verify" "and by the fact: the site's certificate through the proxy"
st=$(dns_state)
assert_contains "$st" "geo_try_zapret.example=2/3" "the screen learns a server answers now and then"
assert_contains "$st" "geo_cert_zapret.example=1" "and where its proxy gave no real certificate"
assert_not_contains "$(printf '%s\n' "$st" | sed -n '/^#geoscan/,/^#/p')" "!zapret" "info lines stay out of the server list"
r=$(dns_geo_routes | sort | tr '\n' '|')
assert_contains "$r" "gamea.clashofclans.com	zapret.example	tls|" "its routes are added"
assert_contains "$r" "chatgpt.com	zapret.example	tls|" "the full check's routes stay"
assert_eq "applied" "$(cat "$MOCK_DIR/geo.applied")" "a changed route is applied"
assert_eq "" "$(dns_geo_due)" "and the next frequent check is in half an hour"
mv -f "$HELPER_BIN.full" "$HELPER_BIN"
dns_geo_scan >/dev/null
assert_no_file "$(dns_geo_scan_file).hot" "a full check replaces the frequent one"
assert_contains "$(cat "$MOCK_DIR/geoscan.list")" "gamea.clashofclans.com" "and checks the used names too"
rm -rf "$SMART_DIR"
# Все домены одного сайта — через один сервер: разные прокси в одной сессии —
# разные адреса выхода, и Google отвечает «unusual traffic». Закреплённый
# сервер сайта остаётся, пока годится; отключённый вручную не берётся
{ printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t3\t3\t0\ttls\n'
  printf 'b.example\tok\t30\t3\t3\t0\ttls\n'
  printf '=bard.google.com\ta.example,b.example\n'
  printf '=aistudio.google.com\tb.example,a.example\n'
  printf '=accounts.google.com\tb.example\n'
} > "$(dns_geo_scan_file)"
rm -f "$(dns_geo_scan_file).pin" "$(dns_geo_scan_file).hot"
assert_eq "accounts.google.com	b.example	tls|aistudio.google.com	b.example	tls|bard.google.com	b.example	tls" "$(dns_geo_routes | sort | tr '\n' '|' | sed 's/|$//')" "the whole site goes through the server most of its domains can use"
echo "@google a.example" > "$(dns_geo_scan_file).pin"
assert_eq "accounts.google.com	b.example	tls|aistudio.google.com	b.example	tls|bard.google.com	b.example	tls" "$(dns_geo_routes | sort | tr '\n' '|' | sed 's/|$//')" "a pin serving far fewer domains of the site gives way"
printf '=accounts.google.com\tb.example,a.example\n' >> "$(dns_geo_scan_file)"
assert_eq "accounts.google.com	a.example	tls|aistudio.google.com	a.example	tls|bard.google.com	a.example	tls" "$(dns_geo_routes | sort | tr '\n' '|' | sed 's/|$//')" "a pin as good as the best keeps the site"
dns_geo_pin_save
assert_contains "$(cat "$(dns_geo_scan_file).pin")" "@google a.example" "the pin is kept"
# Группа сайтов (dns-geo-groups.list): Gemini — и google.com, и googleapis.com,
# и gemini.google — один сервер на все, прежде всего на те, которыми
# пользуются (частая проверка); сервер, не ответивший в частой, не берётся
rm -f "$(dns_geo_scan_file).pin"
{ printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t3\t3\t0\ttls\n'
  printf 'b.example\tok\t30\t3\t3\t0\ttls\n'
  printf 'c.example\tok\t40\t3\t3\t0\ttls\n'
  printf '=gemini.google\tc.example,a.example\n'
  printf '=signaler-pa.clients6.google.com\ta.example,b.example\n'
  printf '=generativelanguage.googleapis.com\ta.example,b.example\n'
  printf '=alkalimakersuite-pa.clients6.google.com\tc.example,a.example\n'
  printf '=gemini.google.com\ta.example,b.example\n'
} > "$(dns_geo_scan_file)"
assert_eq "a.example" "$(dns_geo_routes | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')" "a group of sites goes through one server"
# Роутер сам обходит основные домены Gemini (geodns): вся группа остаётся
# DNS сети — иначе домены не из списка шли через прокси роутера, а из
# списка — через прокси модуля, и у Gemini два адреса выхода
cp "$(dns_geo_scan_file)" "$SANDBOX/scan.keep"
sed -i 's/^=gemini.google.com\t.*/=gemini.google.com\t-\tnet/' "$(dns_geo_scan_file)"
r=$(dns_geo_routes | sort | tr '\n' '|')
assert_contains "$r" "gemini.google.com	-|" "a domain the network DNS already bypasses stays with it"
assert_contains "$r" "signaler-pa.clients6.google.com	-|" "and so does its whole group"
dns_geo_pin_save
assert_not_contains "$(cat "$DNS_GEO_SCAN_DIR/groups.pin" 2>/dev/null)" "@google -" "the network DNS is not pinned as a server"
cp "$SANDBOX/scan.keep" "$(dns_geo_scan_file)"; rm -f "$DNS_GEO_SCAN_DIR/groups.pin" "$(dns_geo_scan_file).pin"
# Прокси сервера проходит проверку DNS, а соединения приложений на нём рвутся
# (умный режим пишет исходы по адресам): сайты группы уходят на другой сервер
printf '+a.example\t198.51.100.1\t3\n' >> "$(dns_geo_scan_file)"
printf '198.51.100.1 1 7 %s\n' "$(date +%s)" > "$DNS_GEO_IPSTAT"
r=$(dns_geo_routes | cut -f2 | sort -u | tr '\n' ' ')
assert_not_contains "$r" "a.example" "a server whose proxy takes almost no connections (1 of 8) is not used"
assert_contains "$(dns_geo_bad)" "a.example	198.51.100.1	1/8" "and it is named with its address and counts"
dns_geo_bad_check
assert_contains "$(tail -n 3 "$DNS_LOG")" "a.example — 1/8 удач" "the DNS log says why the routes change"
printf '198.51.100.1 1 7 %s\n' "$(( $(date +%s) - 4000 ))" > "$DNS_GEO_IPSTAT"
assert_contains "$(dns_geo_routes | cut -f2 | sort -u | tr '\n' ' ')" "a.example" "old counts (over half an hour) do not count"
printf '198.51.100.1 3 7 %s\n' "$(date +%s)" > "$DNS_GEO_IPSTAT"
assert_contains "$(dns_geo_routes | cut -f2 | sort -u | tr '\n' ' ')" "a.example" "nor does a proxy that works a third of the time"
printf '198.51.100.1 0 9 %s\n' "$(date +%s)" > "$DNS_GEO_IPSTAT"
printf '+b.example\t198.51.100.2\t3\n+c.example\t198.51.100.3\t3\n' >> "$(dns_geo_scan_file)"
printf '198.51.100.1 0 9 %s\n198.51.100.2 0 9 %s\n198.51.100.3 0 9 %s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$DNS_GEO_IPSTAT"
assert_contains "$(dns_geo_routes | cut -f2 | sort -u | tr '\n' ' ')" "a.example" "all of them failing is the network, not the proxies: nothing is dropped"
rm -f "$DNS_GEO_IPSTAT"
cp "$SANDBOX/scan.keep" "$(dns_geo_scan_file)"; rm -f "$DNS_GEO_SCAN_DIR/groups.pin" "$(dns_geo_scan_file).pin" "$DNS_RUN_DIR/geo-bad.last"
{ printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t1\t1\t0\ttls\n'
  printf 'b.example\tok\t30\t1\t1\t0\ttls\n'
  printf 'c.example\tfail\t0\t0\t1\t0\t-\tDoT: i/o timeout\n'
  printf '=gemini.google.com\tb.example\n'
} > "$(dns_geo_scan_file).hot"
touch -d "@$(( $(date +%s) + 60 ))" "$(dns_geo_scan_file).hot" 2>/dev/null || { sleep 1; touch "$(dns_geo_scan_file).hot"; }
r=$(dns_geo_routes | sort | tr '\n' '|')
assert_contains "$r" "gemini.google.com	b.example" "the used domain decides the group's server"
assert_contains "$r" "signaler-pa.clients6.google.com	b.example" "and the rest of the group follows it"
assert_contains "$r" "gemini.google	b.example" "even a domain it was not seen serving: the group has no exceptions"
printf 'geminiweb-pa.clients6.google.com\nchatgpt.com\n' > "$SANDBOX/geo.saved"; cp "$DNS_GEO_LIST" "$SANDBOX/geo.keep"; cp "$SANDBOX/geo.saved" "$DNS_GEO_LIST"
r=$(dns_geo_routes | sort | tr '\n' '|')
assert_contains "$r" "geminiweb-pa.clients6.google.com	b.example" "a group domain the check does not know yet goes to the group server too"
assert_not_contains "$r" "chatgpt.com" "an unknown domain outside groups stays with the pool"
cp "$SANDBOX/geo.keep" "$DNS_GEO_LIST"
# Сервер группы — общий для всех сетей: с Wi‑Fi на мобильную и обратно
# Gemini не должен менять адрес выхода посреди чата
dns_geo_pin_save
assert_contains "$(cat "$DNS_GEO_SCAN_DIR/groups.pin")" "@google b.example" "the group server is remembered for every network"
cp "$(dns_geo_scan_file).hot" "$SANDBOX/hot.keep"
printf '=gemini.google.com\tb.example,a.example\n' >> "$(dns_geo_scan_file).hot"
echo "@google a.example" > "$DNS_GEO_SCAN_DIR/groups.pin"
assert_contains "$(dns_geo_routes)" "gemini.google.com	a.example" "another network's group server is kept while it serves the used domains here"
cp "$SANDBOX/hot.keep" "$(dns_geo_scan_file).hot"
touch -d "@$(( $(date +%s) + 60 ))" "$(dns_geo_scan_file).hot" 2>/dev/null || touch "$(dns_geo_scan_file).hot"
assert_contains "$(dns_geo_routes)" "gemini.google.com	b.example" "but not one that cannot serve them here"
rm -f "$DNS_GEO_SCAN_DIR/groups.pin" "$(dns_geo_scan_file).pin"
assert_not_contains "$r" "c.example" "a server down in the frequent check is not used"
dns_geo_routes > "$SANDBOX/routes.before"
printf '=gemini.google.com\ta.example\n' >> "$(dns_geo_scan_file).hot"
assert_contains "$(dns_geo_routes_diff "$SANDBOX/routes.before")" "gemini.google.com b.example → a.example" "a route change is spelled out for the log"
rm -f "$(dns_geo_scan_file).hot"
# С мобильной на Wi‑Fi: частой проверки Wi‑Fi ещё нет (или она старее полной),
# общий сервер обходит Gemini, но меньше доменов группы, чем другой, — он всё
# равно остаётся: иначе сервер сменился бы сразу после подключения, а через
# полминуты частая проверка вернула бы прежний — два адреса выхода подряд
{ printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t3\t3\t0\ttls\n'
  printf 'b.example\tok\t30\t3\t3\t0\ttls\n'
  printf '=gemini.google.com\ta.example,b.example\n'
  printf '=signaler-pa.clients6.google.com\ta.example\n'
  printf '=waa-pa.clients6.google.com\ta.example\n'
  printf '=generativelanguage.googleapis.com\ta.example\n'
} > "$(dns_geo_scan_file)"
rm -f "$(dns_geo_scan_file).hot" "$(dns_geo_scan_file).pin"
echo "@google b.example" > "$DNS_GEO_SCAN_DIR/groups.pin"
assert_contains "$(dns_geo_routes)" "gemini.google.com	b.example" "the group server stays on a network without a frequent check while it serves the main services there"
# данные сети старые (больше часа) — общий сервер держится, пока отвечает
{ printf '#time=%s boot=x v=%s\n' "$(( $(date +%s) - 7200 ))" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t3\t3\t0\ttls\n'
  printf 'b.example\tok\t30\t3\t3\t0\ttls\n'
  printf '=gemini.google.com\ta.example\n'
  printf '=signaler-pa.clients6.google.com\ta.example\n'
} > "$(dns_geo_scan_file)"
assert_contains "$(dns_geo_routes)" "gemini.google.com	b.example" "and on stale data of a network it is kept while it answers there"
# Стабильность, а не скорость: надёжность серверов по истории проверок
# (<файл>.rel) — серия неудач и скользящая доля удач для основных доменов
# группы. Одна неудачная проверка сервер группы не снимает, две подряд —
# снимают, и новый выбирается самый надёжный, а не обходящий больше доменов
cp "$(dns_geo_scan_file)" "$SANDBOX/scan.keep"
hotf="$(dns_geo_scan_file).hot"
mkhot() { { printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t3\t3\t0\ttls\n'; printf 'b.example\tok\t30\t3\t3\t0\ttls\n'; printf 'c.example\tok\t10\t3\t3\t0\ttls\n'
  printf '=gemini.google.com\t%s\n' "$1"; } > "$hotf"; touch -d "@$(( $(date +%s) + 60 ))" "$hotf" 2>/dev/null || touch "$hotf"; }
{ printf '#time=%s boot=x v=%s\n' "$(date +%s)" "$DNS_GEO_SCAN_VER"
  printf 'a.example\tok\t20\t3\t3\t0\ttls\n'; printf 'b.example\tok\t30\t3\t3\t0\ttls\n'; printf 'c.example\tok\t10\t3\t3\t0\ttls\n'
  printf '=gemini.google.com\ta.example,b.example,c.example\n'
  printf '=signaler-pa.clients6.google.com\ta.example,b.example,c.example\n'
  printf '=waa-pa.clients6.google.com\tc.example\n'
} > "$(dns_geo_scan_file)"
rm -f "$(dns_geo_scan_file).rel" "$(dns_geo_scan_file).pin"
echo "@google b.example" > "$DNS_GEO_SCAN_DIR/groups.pin"
mkhot "a.example,b.example,c.example"; dns_geo_rel_update "$hotf" hot
mkhot "a.example,c.example"; dns_geo_rel_update "$hotf" hot
assert_contains "$(cat "$(dns_geo_scan_file).rel")" "@google	b.example	0.469	1" "a check where the server did not serve the main service is counted: lower reliability, a miss in a row"
assert_contains "$(dns_geo_routes)" "gemini.google.com	b.example" "one missed check does not change the group server (a new exit address would be worse)"
mkhot "a.example,c.example"; dns_geo_rel_update "$hotf" hot
printf '@google\ta.example\t0.900\t0\n@google\tc.example\t0.400\t0\n@google\tb.example\t0.200\t2\n' > "$(dns_geo_scan_file).rel"
r=$(dns_geo_routes)
assert_contains "$r" "gemini.google.com	a.example" "two misses in a row do; the new one is the most reliable by history, not the one serving more domains"
# Предпочтительные серверы группы (dns-geo-prefer.list, набор роутера): пока
# хоть один обходит основные домены — только они, даже закреплённый другой
# и более надёжный по истории уступает; не обходит никто — все
pkeep=$DNS_GEO_PREFER; DNS_GEO_PREFER="$SANDBOX/prefer.list"
echo "google c.example b.example" > "$DNS_GEO_PREFER"
echo "@google a.example" > "$DNS_GEO_SCAN_DIR/groups.pin"
mkhot "a.example,c.example"
r=$(dns_geo_routes)
assert_contains "$r" "gemini.google.com	c.example" "a preferred server that serves the main service wins over the pinned and more reliable other one"
assert_contains "$r" "signaler-pa.clients6.google.com	c.example" "for the whole group"
dns_geo_pin_save
assert_contains "$(cat "$DNS_GEO_SCAN_DIR/groups.pin")" "@google c.example" "and becomes the group pin"
mkhot "a.example"
assert_contains "$(dns_geo_routes)" "gemini.google.com	c.example" "a preferred group server missing one check is still kept (two misses in a row change it)"
printf '@google\tc.example\t0.300\t2\n@google\tb.example\t0.300\t2\n' > "$(dns_geo_scan_file).rel"
assert_contains "$(dns_geo_routes)" "gemini.google.com	a.example" "no preferred one serves it — any server, the site keeps working"
mkhot "a.example,b.example,c.example"
echo "@google b.example" > "$DNS_GEO_SCAN_DIR/groups.pin"
assert_contains "$(dns_geo_routes)" "gemini.google.com	b.example" "a pinned preferred server stays among the preferred"
DNS_GEO_PREFER=$pkeep; rm -f "$DNS_GEO_SCAN_DIR/groups.pin"
assert_contains "$(cat "$DNS_GEO_PREFER")" "google router.comss.one dns.comss.one dns.magicdns.ru dns.zapret.moe" "the module ships the router's set for Google"
rm -f "$hotf" "$(dns_geo_scan_file).rel"
cp "$SANDBOX/scan.keep" "$(dns_geo_scan_file)"
rm -f "$DNS_GEO_SCAN_DIR/groups.pin" "$(dns_geo_scan_file).pin"
echo a.example > "$DNS_GEO_OFF"
assert_not_contains "$(dns_geo_routes)" "a.example" "a server switched off by hand is not used"
assert_eq "b.example" "$(dns_geo_pick)" "nor in the pool"
ctl dns-geo-off a.example 0
assert_rc 0 "$ctl_rc" "it is switched back on from the screen"
assert_contains "$(dns_geo_routes)" "a.example" "and used again"
ctl dns-geo-off b.example 1
assert_eq "b.example" "$(cat "$DNS_GEO_OFF")" "switching off is remembered"
st=$(dns_state)
assert_contains "$st" "geo_off=b.example" "and shown on the screen"
ctl dns-geo-off b.example 0
ctl dns-geo-off 'bad host' 1
assert_rc 1 "$ctl_rc" "a bad name is refused"
rm -f "$(dns_geo_scan_file).pin" "$DNS_GEO_OFF"
printf 'chatgpt.com\nclaude.ai\n' > "$DNS_GEO_LIST"
dns_geo_scan >/dev/null
unset -f dns_apply_now
# Профили обхода геоблока в умном режиме: свои правила не ставят, их домены —
# в обход геоблока (иначе включённый GeoHide уводил Claude на свои прокси)
printf 'NAME=GeoHide\nENABLED=1\nSERVER=https://eu.geohide.ru/dns-query\nDOMAIN=claude.ai\nDOMAIN=only-geohide.example\n' > "$DNS_PROFILES_DIR/geohide.conf"
dns_build
up=$(cat "$DNS_RUN_DIR/upstreams.txt")
assert_not_contains "$up" "eu.geohide.ru" "smart mode: the enabled GeoHide profile sets no rules of its own"
assert_contains "$(grep '/only-geohide.example/' "$DNS_RUN_DIR/upstreams.txt")" "]tls://fast.example" "its domains go to the bypass pool"
DNS_GEO=0 dns_build
assert_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "[/claude.ai/only-geohide.example/]https://eu.geohide.ru/dns-query" "profiles mode: it is a profile like any other"
rm -f "$DNS_PROFILES_DIR/geohide.conf" "$HELPER_BIN" "$MOCK_DIR/geoscan.args"
rm -rf "$DNS_GEO_SCAN_DIR"

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
