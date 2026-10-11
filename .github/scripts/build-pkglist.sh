#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT="${1:-build/pkglist}"

D8="$(command -v d8 || true)"
if [ -z "$D8" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [ -n "$SDK" ] && D8="$(ls -d "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -n 1 || true)"
fi
[ -n "$D8" ] && [ -x "$D8" ] || { echo "d8 not found (Android SDK build-tools required)" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

javac --release 8 -Xlint:-options -d "$OUT/classes" $(find java/pkglist -name "*.java")
"$D8" --release --min-api 21 --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

cp "$OUT/dex/classes.dex" "$OUT/pkglist.dex"
(cd "$OUT/dex" && touch -d '2000-01-01 00:00:00' classes.dex && zip -q -X -9 ../pkglist.jar classes.dex)
unzip -l "$OUT/pkglist.jar"
