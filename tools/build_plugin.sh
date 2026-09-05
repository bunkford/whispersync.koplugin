#!/bin/sh
# Build the ZenPM/KOReader release asset: dist/whispersync.koplugin.zip whose
# single top-level directory is whispersync.koplugin/ (what ZenPM extracts
# into koreader/plugins/). Tests and scratch files are left out.
#
#   sh tools/build_plugin.sh            # writes dist/whispersync.koplugin.zip
#   sh tools/build_plugin.sh --print    # also prints size and sha256 as KEY=VALUE
set -eu
cd "$(dirname "$0")/.."
PLUGIN=whispersync.koplugin
OUT=dist/$PLUGIN.zip
rm -rf dist/stage
mkdir -p dist/stage
cp -R "$PLUGIN" dist/stage/
rm -rf "dist/stage/$PLUGIN/tests"
find dist/stage -name '*.part' -o -name '.DS_Store' | xargs rm -f 2>/dev/null || true
rm -f "$OUT"
( cd dist/stage && zip -q -r -X "../$PLUGIN.zip" "$PLUGIN" )
rm -rf dist/stage
SIZE=$(wc -c < "$OUT" | tr -d ' ')
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
VERSION=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' "$PLUGIN/_meta.lua" | head -1)
echo "built $OUT ($SIZE bytes, sha256 $SHA, version $VERSION)" >&2
if [ "${1:-}" = "--print" ]; then
    echo "ASSET=$OUT"
    echo "SIZE=$SIZE"
    echo "SHA256=$SHA"
    echo "VERSION=$VERSION"
fi
