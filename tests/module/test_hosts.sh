#!/bin/sh
# Редактор hosts без перезагрузки (lib/hosts.sh, логика bindhosts).
#
# hosts из двух частей: обход (bypass.txt) и блокировка рекламы (block.txt
# из источников и своих доменов), между ними строка-разделитель.
# mount/umount — заглушки (bind-монтирование изображает символьная ссылка),
# файл назначения — в песочнице; curl отдаёт $MOCK_DIR/web/<адрес, / → _>.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
conf_reset
HOSTS_MODULES_DIR="$SANDBOX/modules"; export HOSTS_MODULES_DIR
mkdir -p "$HOSTS_MODULES_DIR" "$MOCK_DIR/web"
cat > "$MOCKBIN/curl" <<'X'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
f="$MOCK_DIR/web/$(printf '%s' "$url" | sed 's#^[a-z]*://##; s#/#_#g')"
[ -f "$f" ] || exit 22
cat "$f" > "$out"
X
chmod 0755 "$MOCKBIN/curl"
WEB="$MOCK_DIR/web"
H="$CONFDIR/hosts"
SEP=$(sed -n 's/^HOSTS_SEP="\(.*\)"$/\1/p' "$REPO_DIR/lib/hosts.sh")
orig=$(cat "$HOSTS_TARGET")
# системный hosts с рекламной записью: при первом запуске она уйдёт в свои домены
printf '%s\n127.0.0.1 ad.sys.example\n' "$orig" > "$HOSTS_TARGET"
orig=$(cat "$HOSTS_TARGET")

section "first start: the parts come from the system hosts"
ctl hosts-state
assert_rc 0 "$ctl_rc" "hosts-state runs"
assert_contains "$ctl_out" "enabled=0" "the feature starts off"
assert_contains "$ctl_out" "#preset adaway" "presets are listed"
assert_contains "$ctl_out" "BYPASS=1" "with their kind"
assert_not_contains "$ctl_out" "built=" "and no build date"
assert_contains "$(cat "$H/bypass.txt")" "1.2.3.4 sys.example" "bypass entries are seeded from the current hosts"
assert_not_contains "$(cat "$H/bypass.txt")" "localhost" "without localhost"
assert_contains "$(cat "$H/block_custom.txt")" "ad.sys.example" "a blocked domain goes to the own block domains"
assert_not_contains "$(cat "$H/bypass.txt")" "ad.sys.example" "and not to the bypass"
assert_contains "$(cat "$H/bypass.txt")" "57.144.244.128 cdn.fbsbx.com" "the default Instagram entries are added on first start"
assert_eq 1 "$(grep -c 'graph.facebook.com' "$H/bypass.txt")" "once each"

section "switching on replaces the hosts file at once"
ctl hosts-set-enabled 1
assert_rc 0 "$ctl_rc" "it switches on"
ctl hosts-state
assert_contains "$ctl_out" "mounted=1" "our file is mounted over the system one"
assert_contains "$ctl_out" "differs=0" "and matches its parts"
h=$(cat "$HOSTS_TARGET")
assert_contains "$h" "1.2.3.4 sys.example" "it has the bypass entries"
assert_contains "$h" "127.0.0.1 localhost" "and localhost"
assert_contains "$h" "$SEP" "and the separator"
assert_eq "0.0.0.0 ad.sys.example" "$(printf '%s\n' "$h" | sed -n "/^$SEP\$/,\$p" | sed 1d)" "the block part follows the separator"

ctl hosts-save-b64 bypass "$(b64 '9.9.9.9 new.example
# comment
5.5.5.5 two.example three.example')"
assert_rc 0 "$ctl_rc" "bypass entries are saved"
assert_contains "$(cat "$HOSTS_TARGET")" "9.9.9.9 new.example" "and take effect without a remount (same file)"
assert_contains "$(cat "$HOSTS_TARGET")" "5.5.5.5 three.example" "a line with two names gives both"

ctl hosts-block-add "one.ads.example, two.ads.example" "https://x" "0.0.0.0 three.ads.example"
assert_rc 0 "$ctl_rc" "block domains are added in a batch"
assert_eq 3 "$ctl_out" "and counted"
assert_contains "$(cat "$HOSTS_TARGET")" "0.0.0.0 two.ads.example" "they are blocked at once"
ctl hosts-block-add "#"
assert_rc 1 "$ctl_rc" "an empty batch is refused"

section "bypass presets: one at a time"
printf '1.1.1.1 chatgpt.com\n1.1.1.2 api.chatgpt.com # comment\n0.0.0.0 junk.malw.example\nnot a line\n' > "$WEB/raw.githubusercontent.com_ImMALWARE_dns.malw.link_master_hosts"
printf '2.2.2.2 youtube.com\n' > "$WEB/geohide.ru_eu_hosts"
ctl hosts-bypass-preset malw
assert_rc 0 "$ctl_rc" "dns.malw.link is loaded into the bypass"
b=$(cat "$H/bypass.txt")
assert_contains "$b" "1.1.1.2 api.chatgpt.com" "with its bypass entries"
assert_not_contains "$b" "junk.malw.example" "but not its ad entries"
assert_not_contains "$b" "9.9.9.9" "it replaces the previous bypass"
assert_not_contains "$(cat "$HOSTS_TARGET")" "not a line" "garbage lines are dropped"
ctl hosts-state
assert_contains "$ctl_out" "bypass_preset=malw" "the state names the loaded preset"
ctl hosts-bypass-preset geohide
assert_rc 0 "$ctl_rc" "GeoHide replaces it"
assert_contains "$(cat "$H/bypass.txt")" "2.2.2.2 youtube.com" "with its entries"
assert_not_contains "$(cat "$H/bypass.txt")" "chatgpt.com" "and nothing of the other preset"
ctl hosts-bypass-preset adaway
assert_rc 1 "$ctl_rc" "a block-only preset is not a bypass"
ctl hosts-save-b64 bypass "$(b64 '9.9.9.9 new.example')"
ctl hosts-state
assert_contains "$ctl_out" "bypass_preset=" "editing the bypass by hand forgets the preset"
assert_not_contains "$ctl_out" "bypass_preset=geohide" "for good"

# raw.githubusercontent.com недоступен — пресет берётся с зеркала jsDelivr
mv "$WEB/raw.githubusercontent.com_ImMALWARE_dns.malw.link_master_hosts" "$WEB/cdn.jsdelivr.net_gh_ImMALWARE_dns.malw.link@master_hosts"
ctl hosts-bypass-preset malw
assert_rc 0 "$ctl_rc" "a preset on raw.githubusercontent.com comes from the jsDelivr mirror"
assert_contains "$(cat "$H/bypass.txt")" "1.1.1.2 api.chatgpt.com" "with the same entries"
mv "$WEB/cdn.jsdelivr.net_gh_ImMALWARE_dns.malw.link@master_hosts" "$WEB/raw.githubusercontent.com_ImMALWARE_dns.malw.link_master_hosts"
ctl hosts-save-b64 bypass "$(b64 '9.9.9.9 new.example')"

section "ad blocking sources"
printf '# AdAway\n127.0.0.1 ads.example\n127.0.0.1 tracker.ads.example\n0.0.0.0 new.example\n127.0.0.1 keep.example\r\n' > "$WEB/adaway.org_hosts.txt"
ctl hosts-preset adaway 1
assert_rc 0 "$ctl_rc" "a block preset is switched on and downloaded"
h=$(cat "$HOSTS_TARGET")
assert_contains "$h" "0.0.0.0 ads.example" "blocking entries become 0.0.0.0"
assert_contains "$h" "9.9.9.9 new.example" "a bypass entry wins over a source"
assert_not_contains "$h" "0.0.0.0 new.example" "and the source's one for the same domain is dropped"
assert_contains "$(cat "$H/block.txt")" "0.0.0.0 keep.example" "block.txt holds the block part"
ctl hosts-save-b64 whitelist "$(b64 'ads.example')"
h=$(cat "$HOSTS_TARGET")
assert_not_contains "$h" "ads.example" "the whitelist removes a domain and its subdomains"
assert_contains "$h" "keep.example" "other entries stay"
ctl hosts-preset malw 1
assert_rc 0 "$ctl_rc" "the ad part of dns.malw.link is a block source"
h=$(cat "$HOSTS_TARGET")
assert_contains "$h" "0.0.0.0 junk.malw.example" "its ad entries are blocked"
assert_not_contains "$h" "chatgpt.com" "its bypass entries stay out of the block part"
ctl hosts-preset geohide 1
assert_rc 1 "$ctl_rc" "a bypass-only preset is not a block source"
ctl hosts-state
assert_match "$ctl_out" "blocked=[1-9]" "the state counts blocked domains"
assert_contains "$ctl_out" "BLOCK_DESC=" "and describes the ad part of a mixed preset"

ctl hosts-save-b64 sources "$(b64 'preset:adaway
https://example.org/broken.txt')"
ctl hosts-update
assert_rc 0 "$ctl_rc" "an update with one source failing still succeeds"
assert_contains "$ctl_out" "$(printf 'S\tpreset:adaway\tok')" "the working source is reported"
assert_contains "$ctl_out" "$(printf 'S\thttps://example.org/broken.txt\tfail')" "and the broken one"
assert_not_contains "$(cat "$HOSTS_TARGET")" "junk.malw.example" "a source taken off the list leaves the hosts"
rm -f "$WEB/adaway.org_hosts.txt"
ctl hosts-update
assert_rc 1 "$ctl_rc" "when nothing downloads the update fails"

section "parts edited outside the WebUI"
sleep 1
printf 'mt.junk.example\n' >> "$H/block_custom.txt"
ctl hosts-state
assert_contains "$ctl_out" "differs=1" "an edited part file is noticed"
ctl hosts-sync apply
assert_rc 0 "$ctl_rc" "and applied"
assert_contains "$(cat "$HOSTS_TARGET")" "0.0.0.0 mt.junk.example" "into the hosts"
ctl hosts-state
assert_contains "$ctl_out" "differs=0" "after which they match"

# hosts правят напрямую: новая запись обхода, новый и удалённый домен блокировки
sed -i 's/^0\.0\.0\.0 keep\.example$//' "$H/hosts"
printf '0.0.0.0 hand.junk.example\n' >> "$H/hosts"
sed -i "s/^9\.9\.9\.9 new\.example\$/9.9.9.9 new.example\n8.8.8.8 hand.example/" "$H/hosts"
ctl hosts-state
assert_contains "$ctl_out" "differs=1" "an edited hosts is noticed"
ctl hosts-sync import
assert_rc 0 "$ctl_rc" "and taken into the parts"
assert_contains "$(cat "$H/bypass.txt")" "8.8.8.8 hand.example" "a new bypass entry goes to bypass.txt"
assert_contains "$(cat "$H/block_custom.txt")" "hand.junk.example" "a new block domain to the own ones"
assert_contains "$(cat "$H/whitelist.txt")" "keep.example" "a removed one to the exceptions"
assert_not_contains "$(cat "$H/block_custom.txt")" "two.ads.example
two.ads.example" "nothing is duplicated"
h=$(cat "$HOSTS_TARGET")
assert_contains "$h" "0.0.0.0 hand.junk.example" "the hosts keeps the hand edits"
assert_not_contains "$h" "keep.example" "including the removal"
ctl hosts-state
assert_contains "$ctl_out" "differs=0" "and matches the parts again"

section "conflicts, boot, backup, switching off"
mkdir -p "$HOSTS_MODULES_DIR/bindhosts"
ctl hosts-set-enabled 0
ctl hosts-set-enabled 1
assert_rc 1 "$ctl_rc" "another enabled hosts module blocks switching on"
assert_contains "$ctl_out" "bindhosts" "and is named"
: > "$HOSTS_MODULES_DIR/bindhosts/disable"
ctl hosts-set-enabled 1
assert_rc 0 "$ctl_rc" "a disabled one does not"

rm -f "$HOSTS_TARGET"; mv -f "$HOSTS_TARGET.orig" "$HOSTS_TARGET"   # «перезагрузка»
hosts_boot
assert_contains "$(cat "$HOSTS_TARGET")" "9.9.9.9 new.example" "at boot the file is mounted again"

hosts_backup_add "$SANDBOX/bk"
ctl hosts-save-b64 bypass "$(b64 '7.7.7.7 other.example')"
hosts_backup_restore "$SANDBOX/bk"
assert_contains "$(cat "$HOSTS_TARGET")" "9.9.9.9 new.example" "a backup brings the bypass back"

ctl hosts-save-b64 bypass ""
ctl hosts-state
assert_contains "$ctl_out" "bypass=0" "the bypass can be emptied"
assert_not_contains "$(cat "$H/bypass.txt")" "new.example" "and is not re-imported from the hosts"

ctl hosts-set-enabled 0
assert_rc 0 "$ctl_rc" "it switches off"
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" "and the system hosts is back"
ctl hosts-get block_custom
assert_contains "$ctl_out" "hand.junk.example" "the parts are kept for next time"

section "the one-part format of earlier test builds is migrated"
printf '1.1.1.1 old.example\n' > "$H/custom.txt"
printf 'preset:geohide\npreset:adaway\n' > "$H/sources.txt"
printf '5.5.5.5 redirect.example\n' > "$H/cache/adaway.txt"
ctl hosts-state
assert_rc 0 "$ctl_rc" "the state still loads"
assert_eq "preset:adaway" "$(cat "$H/sources.txt")" "a bypass preset leaves the block sources"
assert_no_file "$H/custom.txt" "the old file is gone"
assert_not_contains "$(cat "$H/block.txt")" "redirect.example" "and no bypass entry is blocked"

section "extra lists: rkn.list and the Flowseal ipset are downloaded on demand"
RKN="$WEB/raw.githubusercontent.com_IndeecFOX_zapret4rocket_master_extra_strats_TCP_RKN_List.txt"
FS="$WEB/raw.githubusercontent.com_Flowseal_zapret-discord-youtube_main_.service_ipset-service.txt"
i=0; : > "$RKN"; while [ $i -lt 150 ]; do printf 'Site%s.Example\r\n' "$i" >> "$RKN"; i=$((i + 1)); done
printf '# comment\nbad line here\n' >> "$RKN"
i=0; : > "$FS"; while [ $i -lt 120 ]; do printf '10.%s.0.0/16\n' "$i" >> "$FS"; i=$((i + 1)); done
printf '2606:4700::/32\n' >> "$FS"
ctl set EXTRA_RKN 1
assert_rc 0 "$ctl_rc" "enabling rkn.list downloads it"
assert_eq "150" "$(list_count "$LISTS_DIR/rkn.list")" "only the domains, without CR, comments or junk"
assert_contains "$(cat "$LISTS_DIR/rkn.list")" "site7.example" "lowercased"
ctl set EXTRA_FLOWSEAL 1
assert_rc 0 "$ctl_rc" "enabling the Flowseal ipset downloads it"
assert_eq "121" "$(list_count "$LISTS_DIR/ipset_flowseal.list")" "with IPv6 subnets too"
ctl json-status
assert_contains "$ctl_out" '"extra_rkn":1,"extra_flowseal":1' "json-status reports both switches"
assert_contains "$ctl_out" '"rkn":150,"flowseal":121' "and their sizes"
reload_conf
NFQWS_EXTRA_ARGS='--hostlist=$LISTS_DIR/user.list'; NFQWS_ARGS_IPSET=""
args=$(_startup_args)
assert_contains "$args" "--hostlist=$LISTS_DIR/rkn.list" "rkn.list joins the hostlist profile"
assert_contains "$args" "--ipset=$LISTS_DIR/ipset_flowseal.list" "the Flowseal ipset gets an IP profile"
NFQWS_EXTRA_ARGS='--filter-tcp=80'
assert_not_contains "$(_startup_args)" "rkn.list" "a profile without hostlists (all traffic) does not get it"
printf 'only.example\n' > "$RKN"
ctl extra-list-update rkn
assert_rc 1 "$ctl_rc" "a broken download fails"
assert_eq "150" "$(list_count "$LISTS_DIR/rkn.list")" "and keeps the old list"
ctl extra-list-update nope
assert_rc 1 "$ctl_rc" "an unknown list is refused"
rm -f "$LISTS_DIR/ipset_flowseal.list" "$FS"
ctl set EXTRA_FLOWSEAL 0
ctl set EXTRA_FLOWSEAL 1
assert_rc 1 "$ctl_rc" "nothing to download: the switch stays off"
assert_contains "$(cat "$CONFFILE")" 'EXTRA_FLOWSEAL="0"' "and the config says so"
ctl set EXTRA_RKN 0

harness_finish
