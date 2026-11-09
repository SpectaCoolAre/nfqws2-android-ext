#!/bin/sh
# geodns для роутера (extras/keenetic) и умный DNS модуля — одна логика:
# на одних и тех же итогах проверки каждый домен списка у роутера и у
# телефона идёт к одному и тому же серверу. Данные — настоящая проверка
# телефона (МТС, 09.11), в которой Gemini получал геоблок.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
[ -f "$MODDIR/lib/dns.sh" ] || { printf 'SKIP  lib/dns.sh only exists in the extended build\n'; sandbox_cleanup; exit 0; }
load_common
FIX="$HERE/fixtures/geoscan-mts-0911.tsv"
# список геоблока — тот, что в модуле
cp "$REPO_DIR/lists/geoblock.list" "$DNS_GEO_LIST"; mkdir -p "$DNS_GEO_SCAN_DIR"

# ── роутер: песочница Entware ────────────────────────────────────────────────
RT="$SANDBOX/router"; G="$RT/opt/etc/geodns"
mkdir -p "$G" "$RT/opt/bin" "$RT/opt/etc/init.d"
cp "$REPO_DIR"/lib/geo-*.awk "$G/"
cp "$REPO_DIR/defaults/dns-geo-groups.list" "$G/groups.list"
cp "$REPO_DIR/defaults/dns-geo-prefer.list" "$G/prefer.list"
cp "$REPO_DIR/defaults/dns-geo-servers.list" "$G/servers.list"
cp "$DNS_GEO_LIST" "$G/geoblock.list"
printf 'PROVIDER_DNS="10.0.0.1"\nDEFAULT_DOH=""\n' > "$G/geodns.conf"
printf '#!/bin/sh\ngrep -v "^#" "%s"\n' "$FIX" > "$RT/opt/bin/nfqws2-helper"
printf '#!/bin/sh\necho "Name: x"; echo "Address 1: 1.2.3.4"\n' > "$MOCKBIN/nslookup"
for c in https-dns-proxy killall netstat; do printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/$c"; done
printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/pidof"
chmod 0755 "$RT/opt/bin/nfqws2-helper" "$MOCKBIN"/*
geodns() { GEODNS_ROOT="$RT" sh "$REPO_DIR/extras/keenetic/geodns" "$@"; }

section "router geodns: full check with the module's scanner and route code"
geodns scan > /dev/null 2>&1
S="$RT/opt/var/lib/geodns"
assert_file "$S/scan.tsv" "the check result is kept"
assert_contains "$(head -n 1 "$S/scan.tsv")" " v=$DNS_GEO_SCAN_VER" "in the module's format and version"
c="$G/dnsmasq-geo.conf"
port() { awk -v h="$1" '$1 == h { print $2 }' "$RT/opt/var/run/geodns/ports"; }
assert_contains "$(grep '/gemini.google.com/' "$c")" "#$(port dns.bezmezhau.com)" "09.11: Gemini goes to the server bypassing the whole group"
assert_contains "$(grep '/geminiweb-pa.clients.google.com/' "$c")" "#$(port dns.bezmezhau.com)" "with all of its domains"
assert_contains "$(grep '/claude.ai/' "$c")" "#$(port dns.wlrus.cfd)" "Claude — the server of its group"
assert_contains "$(cat "$S/groups.pin")" "@google dns.bezmezhau.com" "group servers are pinned"
assert_contains "$(geodns routes)" "gemini.google.com	dns.bezmezhau.com" "geodns routes prints routes as the module does"

section "router and phone choose the same servers on the same data"
f="$SANDBOX/phone.tsv"; dns_geo_scan_file() { echo "$f"; }
{ head -n 1 "$S/scan.tsv"; grep -v '^#' "$FIX"; } > "$f"
rm -f "$f.pin" "$f.rel" "$DNS_GEO_SCAN_DIR/groups.pin"
dns_geo_rel_update "$f"; dns_geo_pin_save
# телефон: сервер каждого домена списка (без маршрута — сервер пула)
phone=$(dns_geo_routes | awk -F'\t' -v p="$(dns_geo_pick)" -v lf="$DNS_GEO_LIST" '
  { T[$1] = $2 }
  END { while ((getline l < lf) > 0) { gsub(/[[:space:]]|#.*/, "", l); if (l == "") continue
    d = tolower(l); print d, ((d in T) ? T[d] : p) } }' | sort -u)
# роутер: тот же домен — по порту в конфиге dnsmasq; без строки — к провайдеру («-»)
router=$(awk -v pf="$RT/opt/var/run/geodns/ports" -v lf="$DNS_GEO_LIST" '
  BEGIN { while ((getline l < pf) > 0) { split(l, a, " "); H[a[2]] = a[1] } }
  { split($0, a, "/"); s = a[3]; sub(/.*#/, "", s); C[a[2]] = H[s] }
  END { while ((getline l < lf) > 0) { gsub(/[[:space:]]|#.*/, "", l); if (l == "") continue
    d = tolower(l); print d, ((d in C) ? C[d] : "-") } }' "$c" | sort -u)
n=$(echo "$phone" | grep -c .)
diff_n=$(printf '%s\n' "$phone" > "$SANDBOX/p"; printf '%s\n' "$router" > "$SANDBOX/r"; diff "$SANDBOX/p" "$SANDBOX/r" | grep -c '^[<>]')
[ "$n" -gt 500 ]; assert_rc 0 $? "the whole list is compared ($n domains)"
assert_eq "0" "$diff_n" "every domain goes to the same server on the router and on the phone"
[ "$diff_n" = 0 ] || diff "$SANDBOX/p" "$SANDBOX/r" | head -n 10
assert_eq "$(cat "$DNS_GEO_SCAN_DIR/groups.pin" | sort)" "$(sort "$S/groups.pin")" "and pins the same group servers"

harness_finish
