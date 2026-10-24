#!/bin/sh
# Цвета системы для темы WebUI (nfqws2-ctl monet-system): роли Material You у
# Android через cmd overlay lookup, стиль и сид из theme_customization, кэш.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
cat > "$MOCKBIN/settings" <<'X'
#!/bin/sh
[ "$1 $2 $3" = "get secure theme_customization_overlay_packages" ] && printf '%s\n' "${MOCK_THEME:-null}"
exit 0
X
# cmd overlay lookup: цвет — по имени ресурса; *_fixed и тёмные — свои, а
# error_container_light «нет» (Android до 14 — ни одного)
cat > "$MOCKBIN/cmd" <<'X'
#!/bin/sh
echo "$*" >> "$MOCK_DIR/cmd.log"
[ "$1 $2 $3" = "overlay lookup android" ] || exit 1
[ -n "$MOCK_OLD" ] && { echo "Error: resource not found" >&2; exit 1; }
case "$4" in
  android:color/system_background_dark) echo "#ff2A1340" ;;
  android:color/system_surface_container_dark) echo "#FF3B2552" ;;
  android:color/system_primary_light) echo "#ff6f4a8e" ;;
  android:color/system_primary_fixed) echo "#ffEBDCFF" ;;
  android:color/system_error_container_light) exit 1 ;;
  android:color/system_*) echo "#ff101010" ;;
  *) exit 1 ;;
esac
X
chmod 0755 "$MOCKBIN/settings" "$MOCKBIN/cmd"
export MOCK_THEME MOCK_OLD

section "the system's own Material You colours"
MOCK_THEME='{"android.theme.customization.system_palette":"FFD4BEE9","android.theme.customization.theme_style":"VIBRANT","android.theme.customization.color_source":"home_wallpaper"}'
ctl monet-system
assert_rc 0 "$ctl_rc" "monet-system runs"
assert_contains "$ctl_out" "style VIBRANT" "the style comes from theme_customization"
assert_contains "$ctl_out" "seed #d4bee9" "and the seed, without its alpha"
assert_contains "$ctl_out" "background dark #2a1340" "dark roles are read from Android, lowercased"
assert_contains "$ctl_out" "surface_container dark #3b2552" "containers too"
assert_contains "$ctl_out" "primary light #6f4a8e" "light roles as well"
assert_contains "$ctl_out" "primary_fixed fixed #ebdcff" "and the fixed ones"
printf '%s\n' "$ctl_out" | grep -q '^error_container light'
assert_rc 1 $? "a missing resource is just left out"
n=$(grep -c . "$MOCK_DIR/cmd.log")
assert_eq "74" "$n" "31 roles × 2 modes and 12 fixed colours are asked once each"

section "the answer is cached until the wallpaper or style changes"
ctl monet-system
assert_eq "$n" "$(grep -c . "$MOCK_DIR/cmd.log")" "the same theme: straight from the cache"
assert_contains "$ctl_out" "background dark #2a1340" "with the same colours"
MOCK_THEME='{"android.theme.customization.system_palette":"FF7BD0FF","android.theme.customization.theme_style":"TONAL_SPOT"}'
ctl monet-system
assert_contains "$ctl_out" "style TONAL_SPOT" "a new wallpaper: asked again"
assert_contains "$ctl_out" "seed #7bd0ff" "with the new seed"

section "Android before 14: no roles, but the seed and style are still there"
MOCK_THEME='{"android.theme.customization.system_palette":"A8C7FA","android.theme.customization.theme_style":"EXPRESSIVE"}'
MOCK_OLD=1
ctl monet-system
assert_rc 0 "$ctl_rc" "it still answers"
assert_contains "$ctl_out" "style EXPRESSIVE" "the style"
assert_contains "$ctl_out" "seed #a8c7fa" "the seed (here without alpha)"
assert_not_contains "$ctl_out" " dark #" "and no roles — the WebUI computes them"
assert_contains "$(head -n 1 "$STATE_DIR/monet.cache")" "A8C7FA" "this answer is cached too"
MOCK_OLD=

harness_finish
