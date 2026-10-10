#!/bin/sh
# Packaging tests: what .github/workflows/release.yml puts into the archive.
#
# The archives are built from an explicit allow-list of module paths, so tests/,
# .github/, changelog.md and other repository files never reach a phone. The
# allow-list is read from release.yml itself and the archive is packed here the
# same way, so a path added to the module but forgotten in the workflow (or the
# other way round) shows up as a failure.
#
# Needs python 3 for reading the archive; skips itself without one.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

PY="${NFQWS_TEST_PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
if [ -z "$PY" ]; then
  printf 'SKIP  no python interpreter found (set NFQWS_TEST_PYTHON)\n'
  exit 0
fi

SANDBOX=$(mktemp -d "${NFQWS_TEST_TMP:-/tmp}/nfqws2-pack.XXXXXX") || exit 1
SANDBOX=$(cd "$SANDBOX" && pwd)
WF="$REPO_DIR/.github/workflows/release.yml"

MODULE_TOP="LICENSE README.md action.sh bin binaries blobs boot-completed.sh changelog.md customize.sh defaults lib licenses lists lua module.prop service.sh strategies system uninstall.sh webroot"

# ── allow-list in the workflow ────────────────────────────────────────────────
section "release.yml packs an allow-list of module paths"

# Строки после `zip ... "$out" \` до первой строки без «\» в конце
lists=$("$PY" - "$WF" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
out = []
for m in re.finditer(r'(zip -q -r -9 -X "\$out" \\|cp -R ([^\n]*?)\\)\n((?:[^\n]*\\\n)*[^\n]*)', text):
    body = (m.group(2) or '') + ' ' + m.group(3)
    body = body.replace('\\\n', ' ').replace('"$ext/"', ' ')
    out.append(' '.join(sorted(w for w in body.split() if not w.startswith('"'))))
print('\n'.join(out))
PY
)
regular=$(printf '%s\n' "$lists" | sed -n 1p)
assert_eq "$MODULE_TOP" "$regular" "the archive takes exactly the module top level"
assert_eq 1 "$(printf '%s\n' "$lists" | grep -c .)" "and there is one archive"
assert_contains "$(cat "$WF")" 'sha256sum -c' "dnsproxy downloads are checked against the lock file"
assert_contains "$(cat "$WF")" 'licenses/dnsproxy-LICENSE' "and ship with their licence"

# ── the archive itself ────────────────────────────────────────────────────────
section "the archive carries the module and nothing else"

WS="$SANDBOX/ws"
mkdir -p "$WS"
(cd "$REPO_DIR" && tar -cf - --exclude=.git .) | (cd "$WS" && tar -xf -)
for abi in android-arm android-arm64 android-x86 android-x86_64; do
  mkdir -p "$WS/binaries/$abi"; printf 'ELF' > "$WS/binaries/$abi/nfqws2"; printf 'ELF' > "$WS/binaries/$abi/dnsproxy"
done
mkdir -p "$WS/licenses"; printf 'Apache' > "$WS/licenses/dnsproxy-LICENSE"
OUT="$SANDBOX/module.zip"
# shellcheck disable=SC2086
(cd "$WS" && "$PY" - "$OUT" $regular <<'PY'
import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED)
for top in sys.argv[2:]:
    if os.path.isfile(top):
        z.write(top); continue
    for root, dirs, files in os.walk(top):
        for f in files:
            z.write(os.path.join(root, f))
z.close()
PY
)
assert_file "$OUT" "the archive is created"

"$PY" - "$OUT" > "$SANDBOX/tops.txt" <<'PY'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
print('TOPS ' + ' '.join(sorted({n.split('/')[0] for n in names})))
print('FILES ' + str(sum(1 for n in names if not n.endswith('/'))))
print('DEVS ' + ' '.join(sorted(n for n in names if n.split('/')[0] in
      ('tests', 'tools', '.github', '.git', 'CONTRIBUTING.md', 'update.json'))))
need = ('module.prop', 'customize.sh', 'service.sh', 'action.sh', 'boot-completed.sh', 'uninstall.sh',
        'bin/nfqws2-ctl', 'system/bin/nfqws2-ctl', 'lib/common.sh', 'lib/dns.sh', 'defaults/nfqws2.conf',
        'webroot/index.html', 'webroot/config.json',
        'binaries/android-arm/nfqws2', 'binaries/android-arm64/nfqws2',
        'binaries/android-x86/nfqws2', 'binaries/android-x86_64/nfqws2',
        'binaries/android-arm64/dnsproxy', 'licenses/dnsproxy-LICENSE')
print('MISSING ' + ' '.join(n for n in need if n not in names))
PY
assert_eq "$MODULE_TOP" "$(sed -n 's/^TOPS //p' "$SANDBOX/tops.txt")" "the archive holds exactly the module top level"
assert_eq "" "$(sed -n 's/^DEVS //p' "$SANDBOX/tops.txt")" "no repository-only file is archived"
assert_eq "" "$(sed -n 's/^MISSING //p' "$SANDBOX/tops.txt")" "every file the installer needs is present"
assert_ge "$(sed -n 's/^FILES //p' "$SANDBOX/tops.txt")" 110 "the archive carries the whole module"

# ── module.prop ───────────────────────────────────────────────────────────────
section "module.prop of the fork"

prop="$REPO_DIR/module.prop"
assert_contains "$(cat "$prop")" "id=nfqws2-android-ext" "the fork has its own module id"
assert_contains "$(cat "$prop")" "/SpectaCoolAre/nfqws2-android-ext/main/update.json" "updates come from the fork"
assert_contains "$(cat "$REPO_DIR/customize.sh")" 'ORIG=/data/adb/modules/nfqws2-android' "the installer knows the original module"
assert_contains "$(cat "$REPO_DIR/customize.sh")" 'binaries/$BIN/dnsproxy' "and requires dnsproxy"
assert_eq "" "$(grep -rn '/data/adb/modules/nfqws2-android\b' "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/webroot/js" "$REPO_DIR/service.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/action.sh" 2>/dev/null | grep -v 'nfqws2-android-ext')" \
  "no path points at the original module's directory"

harness_finish
