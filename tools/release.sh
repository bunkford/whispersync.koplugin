#!/bin/sh
# Cut a plugin release: bump the version in _meta.lua, commit, tag, push.
# GitHub Actions (.github/workflows/release.yml) then runs the
# tests, builds whispersync.koplugin.zip, publishes the GitHub release and
# regenerates zenpm/ so ZenPM sees the update.
#
#   sh tools/release.sh 0.1.1
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:?usage: release.sh X.Y.Z}
case "$VERSION" in *[!0-9.]*|"") echo "version must be X.Y.Z" >&2; exit 2;; esac
META=whispersync.koplugin/_meta.lua
CHANGELOG=whispersync.koplugin/CHANGELOG.md
grep -q "^## $VERSION" "$CHANGELOG" || { echo "add a '## $VERSION' section to $CHANGELOG first" >&2; exit 2; }
sed -i.bak "s/^\([[:space:]]*version[[:space:]]*=[[:space:]]*\)\"[^\"]*\"/\1\"$VERSION\"/" "$META" && rm -f "$META.bak"
grep -q "version = \"$VERSION\"" "$META" || { echo "failed to set version in $META" >&2; exit 1; }
git add "$META" "$CHANGELOG"
# The very first release of a version already in _meta.lua has nothing to commit.
if ! git diff --cached --quiet; then
    git commit -m "Whispersync plugin $VERSION"
fi
git tag -a "v$VERSION" -m "Kindle Whispersync $VERSION"
git push origin HEAD "v$VERSION"
echo "pushed v$VERSION; watch the Actions tab for the release"
