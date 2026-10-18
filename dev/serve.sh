#!/bin/sh
# Run the plugin's HTTP server on this computer (needs luajit + luasocket + lfs from luarocks --local).
cd "$(dirname "$0")/.." || exit 1
eval "$(luarocks --lua-version=5.1 path)"
LUA_PATH="./bookdrop.koplugin/?.lua;$LUA_PATH" exec luajit dev/run.lua "$@"
