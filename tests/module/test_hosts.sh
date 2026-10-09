#!/bin/sh
# Редактор hosts без перезагрузки (lib/hosts.sh, логика bindhosts).
#
# mount/umount — заглушки (bind-монтирование изображает символьная ссылка),
# файл назначения — в песочнице; curl отдаёт файлы из $MOCK_DIR/web.

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
f="$MOCK_DIR/web/$(printf '%s' "$url" | sed 's#.*/##')"
[ -f "$f" ] || exit 22
cat "$f" > "$out"
X
chmod 0755 "$MOCKBIN/curl"
orig=$(cat "$HOSTS_TARGET")

section "first start: own entries come from the system hosts"
ctl hosts-state
assert_rc 0 "$ctl_rc" "hosts-state runs"
assert_contains "$ctl_out" "enabled=0" "the feature starts off"
assert_contains "$ctl_out" "#preset adaway" "presets are listed"
assert_contains "$(cat "$CONFDIR/hosts/custom.txt")" "1.2.3.4 sys.example" "own entries are seeded from the current hosts"
assert_not_contains "$(cat "$CONFDIR/hosts/custom.txt")" "localhost" "without localhost"

section "switching on replaces the hosts file at once"
ctl hosts-set-enabled 1
assert_rc 0 "$ctl_rc" "it switches on"
ctl hosts-state
assert_contains "$ctl_out" "mounted=1" "our file is mounted over the system one"
assert_contains "$(cat "$HOSTS_TARGET")" "1.2.3.4 sys.example" "and has the own entries"
assert_contains "$(cat "$HOSTS_TARGET")" "127.0.0.1 localhost" "and localhost"

ctl hosts-save-b64 custom "$(b64 '9.9.9.9 new.example
# comment
5.5.5.5 two.example three.example')"
assert_rc 0 "$ctl_rc" "own entries are saved"
assert_contains "$(cat "$HOSTS_TARGET")" "9.9.9.9 new.example" "and take effect without a remount (same file)"
assert_contains "$(cat "$HOSTS_TARGET")" "5.5.5.5 three.example" "a line with two names gives both"

section "presets and sources"
printf '# AdAway\n127.0.0.1 ads.example\n127.0.0.1 tracker.ads.example\n0.0.0.0 new.example\n127.0.0.1 keep.example\r\n' > "$MOCK_DIR/web/hosts.txt"
printf '1.1.1.1 chatgpt.com\n1.1.1.2 api.chatgpt.com # comment\nnot a line\n' > "$MOCK_DIR/web/hosts"
ctl hosts-preset adaway 1
assert_rc 0 "$ctl_rc" "a preset is switched on and downloaded"
h=$(cat "$HOSTS_TARGET")
assert_contains "$h" "0.0.0.0 ads.example" "blocking entries become 0.0.0.0"
assert_contains "$h" "9.9.9.9 new.example" "an own entry wins over a source"
assert_not_contains "$h" "0.0.0.0 new.example" "and the source's one for the same domain is dropped"
ctl hosts-save-b64 whitelist "$(b64 'ads.example')"
h=$(cat "$HOSTS_TARGET")
assert_not_contains "$h" "ads.example" "the whitelist removes a domain and its subdomains from sources"
assert_contains "$h" "keep.example" "other entries stay"
ctl hosts-preset malw 1
assert_contains "$(cat "$HOSTS_TARGET")" "1.1.1.2 api.chatgpt.com" "a redirect source keeps its addresses"
assert_not_contains "$(cat "$HOSTS_TARGET")" "not a line" "garbage lines are dropped"
ctl hosts-state
assert_contains "$ctl_out" "redirects=" "the state counts redirects"
assert_match "$ctl_out" "blocked=[1-9]" "and blocked domains"

ctl hosts-save-b64 sources "$(b64 'preset:adaway
https://example.org/broken.txt')"
ctl hosts-update
assert_rc 0 "$ctl_rc" "an update with one source failing still succeeds"
assert_contains "$ctl_out" "$(printf 'S\tpreset:adaway\tok')" "the working source is reported"
assert_contains "$ctl_out" "$(printf 'S\thttps://example.org/broken.txt\tfail')" "and the broken one"
assert_not_contains "$(cat "$HOSTS_TARGET")" "chatgpt.com" "a source taken off the list leaves the hosts"
rm -f "$MOCK_DIR/web/hosts.txt"
before=$(cat "$HOSTS_TARGET")
ctl hosts-update
assert_rc 1 "$ctl_rc" "when nothing downloads the update fails"

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
ctl hosts-save-b64 custom "$(b64 '7.7.7.7 other.example')"
hosts_backup_restore "$SANDBOX/bk"
assert_contains "$(cat "$HOSTS_TARGET")" "9.9.9.9 new.example" "a backup brings the own entries back"

ctl hosts-set-enabled 0
assert_rc 0 "$ctl_rc" "it switches off"
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" "and the system hosts is back"
ctl hosts-get custom
assert_contains "$ctl_out" "9.9.9.9 new.example" "own entries are kept for next time"

harness_finish
