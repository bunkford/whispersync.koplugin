#!/bin/sh
# Run the plugin's desktop tests. Needs luajit (or lua5.1).
set -e
cd "$(dirname "$0")"
LUA=${LUA:-$(command -v luajit || command -v lua5.1 || command -v lua)}
for t in test_ws test_edge test_segment test_audio test_player test_main; do
    "$LUA" "$t.lua"
done
