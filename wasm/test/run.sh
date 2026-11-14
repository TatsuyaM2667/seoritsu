#!/bin/sh
# Differential test: ops.c natively vs. compiled to wasm and run on wasm.zig (grammars are PIC side modules; zig's linker can't make those, the plain build covers the instructions)
set -e
cd "$(dirname "$0")"
ZIG="${ZIG:-$HOME/.cache/ame-shell/toolchain/zig-x86_64-linux-0.17.0/zig}"
OUT="${TMPDIR:-/tmp}/seoritsu-wasm-test"
mkdir -p "$OUT"
"$ZIG" cc -O2 -DNATIVE ops.c -o "$OUT/native"
"$ZIG" cc -O2 run.c ../../build/libtsw.a -o "$OUT/run"
"$ZIG" cc -target wasm32-freestanding -O2 -nostdlib -Wl,--no-entry -Wl,--export=tree_sitter_test ops.c -o "$OUT/plain.wasm"
want=$("$OUT/native")
for m in plain; do
	got=$("$OUT/run" "$OUT/$m.wasm")
	if [ "$got" = "$want" ]; then echo "ok   $m ($got)"; else echo "FAIL $m: got $got, want $want"; fi
done
