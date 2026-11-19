#!/usr/bin/env bash
# Syntax-check every file and run the tests under Lua 5.1 (the version the game
# embeds). Uses a local lua5.1 when there is one, otherwise Docker.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

script='for f in *.lua tests/*.lua; do luac -p "$f" || exit 1; done; lua tests/run.lua'

if command -v lua5.1 >/dev/null 2>&1 && command -v luac5.1 >/dev/null 2>&1; then
    for f in *.lua tests/*.lua; do luac5.1 -p "$f"; done
    lua5.1 tests/run.lua
else
    docker run --rm -v "$PWD":/addon -w /addon nickblah/lua:5.1 sh -c "$script"
fi
