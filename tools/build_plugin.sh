#!/bin/sh
# Build a ZenPM/KOReader release asset: dist/<plugin>.koplugin.zip whose single
# top-level directory is <plugin>.koplugin/ (what ZenPM extracts into
# koreader/plugins/). Tests and scratch files are left out.
#
#   sh tools/build_plugin.sh [whispersync|readaloud]   # default whispersync
#   sh tools/build_plugin.sh readaloud --print          # also prints KEY=VALUE facts
set -eu
cd "$(dirname "$0")/.."
NAME=whispersync
PRINT=
for arg in "$@"; do
    case "$arg" in
        --print) PRINT=1 ;;
        *) NAME=$arg ;;
    esac
done
PLUGIN=$NAME.koplugin
[ -f "$PLUGIN/_meta.lua" ] || { echo "no such plugin: $PLUGIN" >&2; exit 1; }
OUT=dist/$PLUGIN.zip
rm -rf dist/stage
mkdir -p dist/stage
cp -R "$PLUGIN" dist/stage/
rm -rf "dist/stage/$PLUGIN/tests"
find dist/stage -name '*.part' -o -name '.DS_Store' -o -name '__pycache__' | xargs rm -rf 2>/dev/null || true
rm -f "$OUT"
( cd dist/stage && zip -q -r -X "../$PLUGIN.zip" "$PLUGIN" )
rm -rf dist/stage
SIZE=$(wc -c < "$OUT" | tr -d ' ')
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
VERSION=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' "$PLUGIN/_meta.lua" | head -1)
echo "built $OUT ($SIZE bytes, sha256 $SHA, version $VERSION)" >&2
if [ -n "$PRINT" ]; then
    echo "PLUGIN=$NAME"
    echo "ASSET=$OUT"
    echo "ASSET_NAME=$PLUGIN.zip"
    echo "SIZE=$SIZE"
    echo "SHA256=$SHA"
    echo "VERSION=$VERSION"
fi
