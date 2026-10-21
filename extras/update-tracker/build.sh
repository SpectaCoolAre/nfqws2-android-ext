#!/bin/sh
# Сборка zip трекера: sh extras/update-tracker/build.sh [папка вывода]
# Копия upstreams.json кладётся внутрь — на случай, если GitHub недоступен
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
out=${1:-$root}; tmp=$(mktemp -d)
cp "$here/module.prop" "$tmp/"
mkdir -p "$tmp/webroot"
cp "$here/webroot/index.html" "$tmp/webroot/"
cp "$root/upstreams.json" "$tmp/webroot/upstreams.json"
cp "$root/webroot/icon.png" "$tmp/webroot/icon.png"
ver=$(sed -n 's/^version=//p' "$here/module.prop")
( cd "$tmp" && zip -q -r -9 -X "$out/nfqws2-ext-tracker-$ver.zip" . )
rm -rf "$tmp"
echo "$out/nfqws2-ext-tracker-$ver.zip"
