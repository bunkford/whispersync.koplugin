#!/bin/sh
# Cut a plugin release: bump the version in its _meta.lua, commit, tag, push.
# GitHub Actions (.github/workflows/release.yml) then runs the tests, builds
# the zip, publishes the GitHub release and records it in zenpm/ so ZenPM sees
# the update.
#
#   sh tools/release.sh whispersync 0.2.3    # tag v0.2.3
#   sh tools/release.sh readaloud 0.1.1      # tag readaloud-v0.1.1
set -eu
cd "$(dirname "$0")/.."
PLUGIN=${1:?usage: release.sh <whispersync|readaloud> X.Y.Z}
VERSION=${2:?usage: release.sh <whispersync|readaloud> X.Y.Z}
case "$VERSION" in *[!0-9.]*|"") echo "version must be X.Y.Z" >&2; exit 2;; esac
case "$PLUGIN" in
    whispersync) PREFIX=v; NAME="Kindle Whispersync" ;;
    readaloud) PREFIX=readaloud-v; NAME="Read Aloud (Edge voices)" ;;
    *) echo "unknown plugin $PLUGIN" >&2; exit 2 ;;
esac
META=$PLUGIN.koplugin/_meta.lua
CHANGELOG=$PLUGIN.koplugin/CHANGELOG.md
grep -q "^## $VERSION" "$CHANGELOG" || { echo "add a '## $VERSION' section to $CHANGELOG first" >&2; exit 2; }
sed -i.bak "s/^\([[:space:]]*version[[:space:]]*=[[:space:]]*\)\"[^\"]*\"/\1\"$VERSION\"/" "$META" && rm -f "$META.bak"
grep -q "version = \"$VERSION\"" "$META" || { echo "failed to set version in $META" >&2; exit 1; }
git add "$META" "$CHANGELOG"
if ! git diff --cached --quiet; then
    git commit -m "$NAME $VERSION"
fi
git tag -a "$PREFIX$VERSION" -m "$NAME $VERSION"
git push origin HEAD "$PREFIX$VERSION"
echo "pushed $PREFIX$VERSION; watch the Actions tab for the release"
