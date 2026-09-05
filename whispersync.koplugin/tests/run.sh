#!/bin/sh
# Run the plugin's desktop tests. Needs luajit (or lua5.1) and, for the
# signing fixtures, a Python with the `cryptography` package.
set -e
cd "$(dirname "$0")"
LUA=${LUA:-$(command -v luajit || command -v lua5.1 || command -v lua)}
PY=${PY:-python3}
[ -f fixture/fixture.mobi ] || $PY make_fixture.py
[ -f fixture/adp_key.pem ] || $PY fixture/gen_adp.py
for t in test_mobi test_adp test_amazon test_posmap test_booksync test_catalog test_shelf test_zenos test_connectpage test_main; do
    "$LUA" "$t.lua"
done
