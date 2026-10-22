#!/bin/sh
# Hosts network policy with real ctl/service functions; all Android effects are mocked.
HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"
sandbox_init

# Native/Java cache APIs have a separate suite. Here record the *visible* hosts
# when the refresh happens, so a refresh before mount/umount cannot pass.
cat > "$MODDIR/lib/dns-cache.sh" <<'X'
dns_cache_flush() {
  cksum < "$HOSTS_TARGET" >> "$MOCK_DIR/flush.log"
  printf 'resolver=%s\napps=%s\n' "${MOCK_CACHE_RESOLVER:-ok}" "${MOCK_CACHE_APPS:-ok}"
  [ "${MOCK_CACHE_APPS:-ok}" != failed ] && [ "${MOCK_CACHE_RESOLVER:-ok}" != failed ]
}
X
cat > "$MOCKBIN/cmd" <<'X'
#!/bin/sh
[ "$1 $2" = 'wifi status' ] || exit 1
if [ -n "$MOCK_SSID" ]; then printf 'Wifi is connected to "%s"\n' "$MOCK_SSID"; else echo 'Wifi is not connected'; fi
X
cat > "$MOCKBIN/dumpsys" <<'X'
#!/bin/sh
[ "$1" = connectivity ] || exit 0
echo 'Active default network: 101'
if [ "$MOCK_DEFAULT" = mobile ]; then
  echo 'NetworkAgentInfo [MOBILE () - 101] network{101} ni{MOBILE CONNECTED}'
else
  echo 'NetworkAgentInfo [WIFI () - 101] network{101} ni{WIFI CONNECTED}'
fi
X
REAL_STAT=$(command -v stat); export REAL_STAT
cat > "$MOCKBIN/stat" <<'X'
#!/bin/sh
[ "${MOCK_STAT_FAIL:-0}" != 1 ] || exit 1
exec "$REAL_STAT" "$@"
X
chmod 0755 "$MOCKBIN/cmd" "$MOCKBIN/dumpsys" "$MOCKBIN/stat"
load_common
conf_reset
printf '\nAUTOSTART=0\nWATCHDOG=0\nHOME_WIFI=0\nVPN_PAUSE=0\n' >> "$CONFFILE"
reload_conf
# A live sentinel prevents real helper processes from being spawned by ctl.
printf '%s\n' "$$" > "$WD_PIDFILE"
HOSTS_MODULES_DIR="$SANDBOX/modules"
NFQWS_SYSNET="$SANDBOX/sysnet"
MOCK_SSID=Cafe
MOCK_DEFAULT=wifi
export HOSTS_MODULES_DIR NFQWS_SYSNET MOCK_SSID MOCK_DEFAULT
mkdir -p "$HOSTS_MODULES_DIR" "$NFQWS_SYSNET/tun0"
printf '0x1090\n' > "$NFQWS_SYSNET/tun0/flags"
printf 'Home\nHome 2\n' > "$HOME_FILE"
orig=$(cat "$HOSTS_TARGET")
orig_sum=$(cksum < "$HOSTS_TARGET")
flushes() { if [ -f "$MOCK_DIR/flush.log" ]; then wc -l < "$MOCK_DIR/flush.log" | tr -d ' '; else echo 0; fi; }
vpn_on() { printf '0x1091\n' > "$NFQWS_SYSNET/tun0/flags"; }
vpn_off() { printf '0x1090\n' > "$NFQWS_SYSNET/tun0/flags"; }
check() { svc hosts_check; assert_rc 0 "$svc_rc" "$1"; }

section 'opt-in defaults and ordinary enable'
ctl hosts-state
assert_rc 0 "$ctl_rc" 'state loads'
assert_contains "$ctl_out" 'enabled=0' 'hosts starts disabled'
assert_contains "$ctl_out" 'pause_home=0' 'home pause is opt-in'
assert_contains "$ctl_out" 'pause_vpn=0' 'VPN pause is opt-in'
assert_eq 0 "$(flushes)" 'reading state does not flush DNS'
ctl hosts-set-enabled 1
assert_rc 0 "$ctl_rc" 'enable works outside pause conditions'
assert_rc 0 "$(hosts_mounted; echo $?)" 'our hosts is mounted'
assert_eq 1 "$(flushes)" 'enable refreshes once'
assert_eq "$(cksum < "$HOSTS_TARGET")" "$(tail -n 1 "$MOCK_DIR/flush.log")" 'cache notification sees the new file'
ctl hosts-set-pause home 1
assert_rc 0 "$ctl_rc" 'home policy can be configured independently'
assert_file "$HOSTS_ENABLED_FILE" 'configuring a pause preserves the master setting'
assert_eq 1 "$(flushes)" 'no condition change means no refresh'
assert_rc 0 "$(hosts_watch_wanted; echo $?)" 'hosts alone keeps watchers wanted'

section 'home pause, edits, reboot and resume'
MOCK_SSID=Home
check 'entering home is reconciled'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'home restores the whole system hosts'
assert_eq home "$(cat "$HOSTS_PAUSED_FILE")" 'the actual pause is recorded'
assert_file "$HOSTS_ENABLED_FILE" 'pausing does not disable the feature'
assert_eq "$orig_sum" "$(tail -n 1 "$MOCK_DIR/flush.log")" 'cache is refreshed after restoring system hosts'
before=$(flushes)
check 'repeated check succeeds'
check 'another repeated check succeeds'
ctl hosts-state
assert_contains "$ctl_out" 'paused=home' 'state distinguishes pause from mount failure'
assert_contains "$ctl_out" 'mounted=0' 'state reports the actual unmounted file'
assert_eq "$before" "$(flushes)" 'polls and status reads do not repeatedly flush'
ctl hosts-save-b64 bypass "$(b64 '203.0.113.7 paused.example')"
assert_rc 0 "$ctl_rc" 'bypass remains editable while paused'
ctl hosts-block-add ads.paused.example
assert_rc 0 "$ctl_rc" 'adblock custom entries remain editable while paused'
ctl hosts-save-b64 whitelist "$(b64 keep.paused.example)"
assert_rc 0 "$ctl_rc" 'exclusions remain editable while paused'
ctl hosts-sync apply
assert_rc 0 "$ctl_rc" 'apply while paused only updates the stored file'
ctl hosts-sync import
assert_rc 0 "$ctl_rc" 'import uses stored custom hosts, not the restored system file'
assert_contains "$(cat "$HOSTS_BYPASS")" 'paused.example' 'paused import does not erase custom bypass entries'
assert_contains "$(cat "$HOSTS_FILE")" '0.0.0.0 ads.paused.example' 'block entries are retained in assembled hosts'
assert_contains "$(cat "$HOSTS_WHITELIST")" 'keep.paused.example' 'exclusions are retained'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'editing never remounts while paused'
assert_eq "$before" "$(flushes)" 'editing inactive hosts does not invalidate system caches'
printf 'vpn\n' > "$HOSTS_PAUSED_FILE"
hosts_boot
assert_rc 0 "$?" 'boot checks current network instead of stale pause metadata'
assert_eq home "$(cat "$HOSTS_PAUSED_FILE")" 'stale boot reason is replaced'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'boot at home never mounts custom hosts temporarily'
MOCK_SSID=Cafe
check 'leaving home resumes'
assert_no_file "$HOSTS_PAUSED_FILE" 'resume clears the pause marker'
assert_contains "$(cat "$HOSTS_TARGET")" '203.0.113.7 paused.example' 'resume uses edits made while paused'
assert_contains "$(cat "$HOSTS_TARGET")" '0.0.0.0 ads.paused.example' 'resume also restores adblocking'
assert_eq "$((before + 1))" "$(flushes)" 'resume refreshes exactly once'
before=$(flushes)
ctl hosts-sync apply
assert_rc 0 "$ctl_rc" 'no-op apply succeeds'
assert_eq "$before" "$(flushes)" 'unchanged content is not rewritten or flushed'
ctl hosts-save-b64 bypass "$(b64 '203.0.113.8 live.example')"
assert_rc 0 "$ctl_rc" 'editing active hosts succeeds'
assert_eq "$((before + 1))" "$(flushes)" 'changed active content triggers one refresh'
assert_eq "$(cksum < "$HOSTS_TARGET")" "$(tail -n 1 "$MOCK_DIR/flush.log")" 'edit refresh sees the written content'

section 'active network and overlapping conditions'
MOCK_SSID=Home; MOCK_DEFAULT=mobile
check 'a connected home SSID with cellular default is not treated as home'
assert_rc 0 "$(hosts_mounted; echo $?)" 'home pause uses existing active-network semantics'
MOCK_DEFAULT=wifi
check 'home Wi-Fi becoming default pauses'
ctl hosts-set-pause vpn 1
assert_rc 0 "$ctl_rc" 'VPN pause can be enabled separately'
before=$(flushes)
vpn_on
check 'VPN is detected even though nfqws VPN_PAUSE is zero'
assert_eq vpn "$(cat "$HOSTS_PAUSED_FILE")" 'VPN is the displayed reason when both conditions hold'
assert_eq "$before" "$(flushes)" 'reason-only change does not remount or refresh'
vpn_off
check 'VPN ending while still home keeps the pause'
assert_eq home "$(cat "$HOSTS_PAUSED_FILE")" 'home reason remains after VPN'
assert_eq "$before" "$(flushes)" 'remaining pause condition does not flush'
vpn_on; MOCK_SSID=Cafe
check 'leaving home with VPN still active keeps the pause'
assert_eq vpn "$(cat "$HOSTS_PAUSED_FILE")" 'VPN remains the reason'
assert_eq "$before" "$(flushes)" 'both conditions must end before resume'
vpn_off
check 'clearing the final condition resumes'
assert_rc 0 "$(hosts_mounted; echo $?)" 'custom hosts is restored'
assert_eq "$((before + 1))" "$(flushes)" 'the final transition refreshes once'
vpn_on
check 'VPN alone pauses'
ctl hosts-set-pause vpn 0
assert_rc 0 "$ctl_rc" 'turning off the currently active policy applies immediately'
assert_rc 0 "$(hosts_mounted; echo $?)" 'policy off resumes even while VPN stays up'
ctl hosts-set-pause vpn 1
assert_rc 0 "$ctl_rc" 'turning it back on pauses immediately'
assert_eq vpn "$(cat "$HOSTS_PAUSED_FILE")" 'the new policy is applied without an event'

section 'manual disable and validation'
before=$(flushes)
ctl hosts-set-enabled 0
assert_rc 0 "$ctl_rc" 'disable during pause succeeds'
assert_no_file "$HOSTS_PAUSED_FILE" 'disabled is not reported as paused'
assert_file "$HOSTS_HOME_FILE" 'home preference survives manual disable'
assert_file "$HOSTS_VPN_FILE" 'VPN preference survives manual disable'
assert_eq "$before" "$(flushes)" 'already-system hosts needs no redundant flush'
vpn_off
check 'later network changes keep manually disabled hosts off'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'a watcher never re-enables manually disabled hosts'
assert_rc 1 "$(hosts_watch_wanted; echo $?)" 'disabled preferences alone need no watcher'
ctl hosts-set-pause '../bad' 1
assert_rc 1 "$ctl_rc" 'unknown policy path is refused'
ctl hosts-set-pause home yes
assert_rc 1 "$ctl_rc" 'non-boolean policy is refused'
ctl hosts-set-pause home
assert_rc 1 "$ctl_rc" 'missing value is refused'
ctl hosts-set-pause home 1 extra
assert_rc 1 "$ctl_rc" 'extra policy arguments are refused'
ctl hosts-set-enabled 1 extra
assert_rc 1 "$ctl_rc" 'extra enable arguments are refused'
assert_no_file "$HOSTS_ENABLED_FILE" 'invalid commands do not enable hosts'
ctl hosts-set-enabled 1
assert_rc 0 "$ctl_rc" 'explicit re-enable works'

section 'mount failures stay visible and are retried safely'
before=$(flushes)
MOCK_MOUNT_FAIL=1; export MOCK_MOUNT_FAIL
vpn_on
svc hosts_check
assert_rc 1 "$svc_rc" 'failed unmount is not a successful pause'
assert_no_file "$HOSTS_PAUSED_FILE" 'failed unmount does not write a pause marker'
assert_file "$HOSTS_ERROR_FILE" 'failed unmount is exposed'
assert_rc 0 "$(hosts_mounted; echo $?)" 'failure leaves the actual mounted file visible'
assert_eq "$before" "$(flushes)" 'failure does not claim to invalidate a changed file'
ctl hosts-state
assert_contains "$ctl_out" 'umount' 'state contains the real error'
unset MOCK_MOUNT_FAIL
check 'later check retries unmount'
assert_eq vpn "$(cat "$HOSTS_PAUSED_FILE")" 'successful retry records the pause'
assert_no_file "$HOSTS_ERROR_FILE" 'successful retry clears the error'
before=$(flushes)
vpn_off; MOCK_MOUNT_FAIL=1; export MOCK_MOUNT_FAIL
svc hosts_check
assert_rc 1 "$svc_rc" 'failed resume is reported'
assert_no_file "$HOSTS_PAUSED_FILE" 'resume failure is not disguised as an active pause'
assert_file "$HOSTS_ENABLED_FILE" 'failed resume preserves the requested enabled state'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'failed resume leaves system hosts intact'
assert_eq "$before" "$(flushes)" 'failed mount does not refresh'
ctl hosts-set-pause home 0
ctl hosts-set-pause vpn 0
assert_rc 0 "$(hosts_watch_wanted; echo $?)" 'a pending error keeps retries alive even with pause options off'
unset MOCK_MOUNT_FAIL
check 'resume retry succeeds'
assert_no_file "$HOSTS_ERROR_FILE" 'successful resume clears its error'
assert_rc 1 "$(hosts_watch_wanted; echo $?)" 'idle custom hosts without policies no longer needs a watcher'

section 'conflicts and unreadable mount state'
ctl hosts-set-pause vpn 1
vpn_on
check 'pause before introducing another hosts module'
mkdir -p "$HOSTS_MODULES_DIR/bindhosts"
vpn_off; before=$(flushes)
svc hosts_check
assert_rc 1 "$svc_rc" 'resume refuses an active conflicting module'
assert_contains "$(cat "$HOSTS_ERROR_FILE")" bindhosts 'the conflicting module is identified'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'a conflict does not stack a new mount'
assert_eq "$before" "$(flushes)" 'conflict causes no cache refresh'
: > "$HOSTS_MODULES_DIR/bindhosts/disable"
check 'resume works after the conflict is removed'
MOCK_STAT_FAIL=1; export MOCK_STAT_FAIL
before=$(flushes)
svc hosts_check
assert_rc 1 "$svc_rc" 'unknown inode state is an error, not an unmounted success'
assert_file "$HOSTS_ERROR_FILE" 'inaccessible stat is surfaced'
assert_eq "$before" "$(flushes)" 'unknown mount state triggers no refresh'
unset MOCK_STAT_FAIL
check 'inode-state recovery clears the error'
assert_no_file "$HOSTS_ERROR_FILE" 'stat error is cleared after verification'

section 'cache errors do not undo a successful hosts transition'
MOCK_CACHE_APPS=failed; MOCK_CACHE_RESOLVER=unsupported
export MOCK_CACHE_APPS MOCK_CACHE_RESOLVER
vpn_on
check 'a soft cache failure does not revert the effective hosts policy'
ctl hosts-state
assert_contains "$ctl_out" 'paused=vpn' 'pause is still applied'
assert_contains "$ctl_out" 'cache_apps=failed' 'app notification failure is observable'
assert_contains "$ctl_out" 'cache_resolver=unsupported' 'unsupported native API is not called successful'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'system file remains in effect'
unset MOCK_CACHE_APPS MOCK_CACHE_RESOLVER

section 'backup preserves preferences, not transient state'
vpn_off; MOCK_SSID=Home
ctl hosts-set-pause home 1
check 'home pause before backup'
hosts_backup_add "$SANDBOX/backup"
assert_rc 0 "$?" 'backup succeeds'
assert_file "$SANDBOX/backup/enabled" 'backup keeps master state'
assert_file "$SANDBOX/backup/pause_home" 'backup keeps home choice'
assert_file "$SANDBOX/backup/pause_vpn" 'backup keeps VPN choice'
assert_no_file "$SANDBOX/backup/hosts_paused" 'pause reason is not backed up'
assert_no_file "$SANDBOX/backup/hosts_dns_cache" 'last refresh status is not backed up'
saved=$(cat "$HOSTS_BYPASS")
ctl hosts-save-b64 bypass "$(b64 '198.51.100.8 temporary.example')"
before=$(flushes)
hosts_backup_restore "$SANDBOX/backup"
assert_rc 0 "$?" 'restore succeeds while home'
assert_eq "$saved" "$(cat "$HOSTS_BYPASS")" 'restore returns the custom bypass data'
assert_eq home "$(cat "$HOSTS_PAUSED_FILE")" 'restore recomputes the pause from current network'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'restore while paused does not temporarily mount custom hosts'
assert_eq "$before" "$(flushes)" 'restoring inactive contents needs no cache refresh'
mkdir -p "$SANDBOX/legacy"
cp "$HOSTS_BYPASS" "$SANDBOX/legacy/bypass.txt"
: > "$SANDBOX/legacy/enabled"
hosts_backup_restore "$SANDBOX/legacy"
assert_rc 0 "$?" 'a legacy backup remains restorable'
assert_no_file "$HOSTS_HOME_FILE" 'legacy backup defaults home pause to off'
assert_no_file "$HOSTS_VPN_FILE" 'legacy backup defaults VPN pause to off'
assert_rc 0 "$(hosts_mounted; echo $?)" 'legacy enabled behavior remains active even at home'

section 'existing service home-check and stopped-service watchers'
# Evaluate the exact service functions; no daemon/firewall/monitor is started.
eval "$(sed -n '/^home_check()/,/^}/p' "$MODDIR/service.sh")"
eval "$(sed -n '/^watchers_wanted()/,/^}/p' "$MODDIR/service.sh")"
is_running() { return 1; }
dns_enabled() { return 1; }
start() { echo start >> "$MOCK_DIR/unwanted-service.log"; }
stop() { echo stop >> "$MOCK_DIR/unwanted-service.log"; }
MOCK_SSID=Cafe
ctl hosts-set-pause home 1
HOME_WIFI=0; VPN_PAUSE=0; WATCHDOG=0
assert_rc 0 "$(watchers_wanted; echo $?)" 'hosts-only pause keeps existing watchers alive'
MOCK_SSID=Home
home_check
assert_eq home "$(cat "$HOSTS_PAUSED_FILE")" 'home_check detects hosts home policy while nfqws pause is off'
assert_no_file "$MOCK_DIR/unwanted-service.log" 'hosts policy does not start or stop nfqws2'
MOCK_SSID=Cafe
home_check
assert_rc 0 "$(hosts_mounted; echo $?)" 'home_check resumes hosts independently'
ctl hosts-set-enabled 0
assert_rc 1 "$(watchers_wanted; echo $?)" 'no enabled consumer leaves watchers idle'

section 'lock ownership and racing watchers'
hosts_lock 1
assert_rc 0 "$?" 'lock can be acquired'
hosts_check
assert_rc 2 "$?" 'watcher does not interfere with an active editor lock'
assert_rc 0 "$([ -d "$HOSTS_LOCK/$$" ]; echo $?)" 'the live owner is preserved'
hosts_unlock
mkdir -p "$HOSTS_LOCK/99999999"
_hosts_locked 1 true
assert_rc 0 "$?" 'a dead owner lock is reclaimed'
assert_rc 1 "$([ -d "$HOSTS_LOCK" ]; echo $?)" 'completed operation releases its lock'
mkdir "$HOSTS_LOCK"; : > "$HOSTS_LOCK/unexpected"
hosts_check
assert_rc 2 "$?" 'a malformed lock is bounded rather than spun on'
rm -f "$HOSTS_LOCK/unexpected"; rmdir "$HOSTS_LOCK"
_hosts_locked 1 false
assert_rc 1 "$?" 'operation failure is preserved'
assert_rc 1 "$([ -d "$HOSTS_LOCK" ]; echo $?)" 'operation failure also releases its lock'
ctl hosts-set-pause vpn 1
ctl hosts-set-enabled 1
vpn_on; before=$(flushes)
sh "$MODDIR/service.sh" hosts_check > "$MOCK_DIR/race1" 2>&1 & p1=$!
sh "$MODDIR/service.sh" hosts_check > "$MOCK_DIR/race2" 2>&1 & p2=$!
wait "$p1"; assert_rc 0 "$?" 'first simultaneous watcher finishes'
wait "$p2"; assert_rc 0 "$?" 'second simultaneous watcher finishes'
assert_eq vpn "$(cat "$HOSTS_PAUSED_FILE")" 'simultaneous checks agree on pause state'
assert_eq "$((before + 1))" "$(flushes)" 'simultaneous checks refresh only the single actual transition'

section 'lock filesystem failures are bounded'
# A finite failure injection keeps even a regressed spin from hanging the suite.
# A broken implementation retries six times and reports success; correct is 1:1.
out=$(
  attempts=0
  mkdir() {
    attempts=$((attempts + 1))
    [ "$attempts" -le 5 ] && return 1
    command mkdir "$@"
  }
  _hosts_locked 1 true 2>/dev/null; rc=$?
  printf '%s:%s' "$rc" "$attempts"
)
assert_eq '1:1' "$out" 'mkdir failure with no competing lock returns immediately'

section 'manual disable retries without reversing user intent'
vpn_off
check 'resume before manual-disable failure'
MOCK_MOUNT_FAIL=1; export MOCK_MOUNT_FAIL
before=$(flushes)
ctl hosts-set-enabled 0
assert_rc 1 "$ctl_rc" 'failed manual disable is reported'
assert_no_file "$HOSTS_ENABLED_FILE" 'the requested off state is retained despite umount failure'
assert_file "$HOSTS_ERROR_FILE" 'failed disable remains visible'
assert_no_file "$HOSTS_PAUSED_FILE" 'failed disable is not called a pause'
assert_eq "$before" "$(flushes)" 'failed disable has not changed effective hosts'
unset MOCK_MOUNT_FAIL
check 'disabled state is retried'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'retry returns system hosts'
assert_no_file "$HOSTS_ENABLED_FILE" 'retry never turns the master switch back on'
mkdir "$HOSTS_ENABLED_FILE"
ctl hosts-set-enabled 1
assert_rc 1 "$ctl_rc" 'failure to persist enabled state cannot report success'
rmdir "$HOSTS_ENABLED_FILE"
ctl hosts-set-pause home 0
mkdir "$HOSTS_HOME_FILE"
ctl hosts-set-pause home 1
assert_rc 1 "$ctl_rc" 'failure to persist a pause preference cannot report success'
rmdir "$HOSTS_HOME_FILE"

section 'real backup commands propagate hosts lock failures'
NFQWS_BACKUP_DIR="$SANDBOX/cli-backups"; export NFQWS_BACKUP_DIR
ctl backup-create ''
assert_rc 0 "$ctl_rc" 'a real CLI backup can be created'
backup_name=$(printf '%s' "$ctl_out" | cut -f1)
assert_file "$NFQWS_BACKUP_DIR/$backup_name" 'the complete backup exists'
cp "$MODDIR/lib/hosts.sh" "$SANDBOX/hosts-original.sh"
printf '\nhosts_lock() { return 2; }\n' >> "$MODDIR/lib/hosts.sh"
NFQWS_BACKUP_DIR="$SANDBOX/busy-backups"
ctl backup-create ''
assert_rc 1 "$ctl_rc" 'a busy hosts helper makes backup creation fail'
assert_contains "$ctl_out" 'не создана' 'incomplete backup is explicitly refused'
assert_eq '' "$(ls "$NFQWS_BACKUP_DIR"/*.tar 2>/dev/null)" 'no hosts-less archive is published'
NFQWS_BACKUP_DIR="$SANDBOX/cli-backups"
printf '\n# after backup\n' >> "$CONFFILE"
conf_before=$(cksum < "$CONFFILE")
ctl backup-restore "$backup_name"
assert_rc 2 "$ctl_rc" 'busy restore propagates the lock result'
assert_contains "$ctl_out" 'не начато' 'busy restore is not advertised as success'
assert_eq "$conf_before" "$(cksum < "$CONFFILE")" 'busy restore does not partially change other settings'
cp "$SANDBOX/hosts-original.sh" "$MODDIR/lib/hosts.sh"

section 'DNS ordering, shared-list semantics, and an unsampled SSID race'
MOCK_SSID=Cafe
ctl hosts-set-pause home 1
ctl hosts-set-enabled 1
mkdir -p "${DNS_HOME_FILE%/*}"; : > "$DNS_HOME_FILE"
dns_enabled() { return 0; }
dns_start() { echo dns_start >> "$MOCK_DIR/order.log"; }
dns_check() { echo dns_check >> "$MOCK_DIR/order.log"; }
dns_cache_flush() {
  echo cache >> "$MOCK_DIR/order.log"
  echo resolver=ok; echo apps=ok
}
HOME_WIFI=1; MOCK_SSID=Home
: > "$MOCK_DIR/order.log"
home_check
assert_eq "$(printf 'dns_start\ndns_check\ncache')" "$(cat "$MOCK_DIR/order.log")" 'home DNS is reconciled before the hosts cache refresh'
assert_file "$HOME_AT_FILE" 'existing DNS home indicator is set when nfqws home pause is enabled'
HOME_WIFI=0
: > "$MOCK_DIR/order.log"
home_check
assert_no_file "$HOME_AT_FILE" 'hosts-only home pause does not change existing DNS-home gating'
assert_eq home "$(cat "$HOSTS_PAUSED_FILE")" 'hosts can stay paused independently of DNS home mode'
assert_eq "$(printf 'dns_start\ndns_check')" "$(cat "$MOCK_DIR/order.log")" 'unchanged hosts still does not flush after a DNS-only decision'
ctl hosts-set-pause home 0
assert_rc 0 "$(hosts_mounted; echo $?)" 'hosts is active with home policy off'
# Simulate another ctl enabling home pause while home_check is in its DNS step.
# The earlier home_check read no SSID, which must not be mistaken for a real ''.
dns_check() { : > "$HOSTS_HOME_FILE"; hosts_boot; }
home_check
assert_eq home "$(cat "$HOSTS_PAUSED_FILE")" 'late-enabled home policy uses a fresh SSID'
assert_eq "$orig" "$(cat "$HOSTS_TARGET")" 'an unsampled empty SSID cannot undo a just-applied pause'
vpn_on; VPN_PAUSE=1
printf '@vpn\n' > "$HOME_OVERRIDE_FILE"
dns_check() { return 0; }
home_check
assert_eq vpn "$(cat "$HOSTS_PAUSED_FILE")" 'a manual nfqws VPN override does not override hosts policy'
assert_eq '@vpn' "$(cat "$HOME_OVERRIDE_FILE")" 'hosts does not rewrite the nfqws manual override'

harness_finish
