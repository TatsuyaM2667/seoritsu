#!/bin/sh
# Builds ./seoritsu (needs odin, zig for build/libts*.a, wayland-client, wayland-cursor, xkbcommon, freetype)
set -e
cd "$(dirname "$0")"
ODIN="${ODIN:-odin}"
[ -x "$HOME/.cache/ame-shell/toolchain/odin-dev-2026-08/odin" ] && ODIN="$HOME/.cache/ame-shell/toolchain/odin-dev-2026-08/odin"
[ -f build/libts.a ] && [ -f build/libtsw.a ] || ./wasm/build.sh # tree-sitter + wasm runtime (needs zig)
"$ODIN" build src -out:seoritsu -o:speed
[ "$1" = test ] && "$ODIN" test src -define:ODIN_TEST_THREADS=1 # tests share the app state
echo "built ./seoritsu"
