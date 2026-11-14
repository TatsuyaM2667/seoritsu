#!/bin/sh
# tree-sitter (C) + our wasm runtime (Zig) -> build/libts.a, build/libtsw.a
set -e
cd "$(dirname "$0")/.."
ZIG="${ZIG:-zig}"
[ -x "$HOME/.cache/ame-shell/toolchain/zig-x86_64-linux-0.17.0/zig" ] && ZIG="$HOME/.cache/ame-shell/toolchain/zig-x86_64-linux-0.17.0/zig"
mkdir -p build/obj
TS=third_party/tree-sitter
for f in alloc get_changed_ranges language lexer node parser query stack subtree tree_cursor tree; do
	"$ZIG" cc -c -O2 -fPIC -std=c11 -D_DEFAULT_SOURCE -I$TS/src -I$TS/include $TS/src/$f.c -o build/obj/$f.o
done
"$ZIG" cc -c -O2 -fPIC -std=c11 -D_DEFAULT_SOURCE -I$TS/src -I$TS/include wasm/ts_wasm_store.c -o build/obj/ts_wasm_store.o
rm -f build/libts.a
"$ZIG" ar rcs build/libts.a build/obj/*.o
"$ZIG" build-lib -O ReleaseFast -lc -fPIC wasm/wasm.zig -femit-bin=build/libtsw.a
