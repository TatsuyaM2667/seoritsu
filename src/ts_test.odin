package main

import "core:os"
import "core:testing"

// Parses with the installed Zed Odin grammar (skipped when it isn't installed),
// then edits and reparses incrementally.
@(test)
ts_highlight_and_edit :: proc(t: ^testing.T) {
	ext := os.get_env("HOME", context.temp_allocator)
	ext = pj(ext, ".var/app/dev.zed.Zed/data/zed/extensions/installed/odin", allocator = context.temp_allocator)
	if !os.exists(pj(ext, "grammars/odin.wasm", allocator = context.temp_allocator)) do return
	lang := new(Language)
	lang.name, lang.grammar = "Odin-test", "odin"
	lang.wasm_path = pj(ext, "grammars/odin.wasm", allocator = context.temp_allocator)
	lang.hl_path = pj(ext, "languages/odin/highlights.scm", allocator = context.temp_allocator)
	testing.expect(t, grammar_for(lang) != nil, "grammar or highlights.scm failed to load")

	b := new(Buffer)
	b.lang = lang
	set_text(b, "P :: struct {}\n")
	for i := 0; b.ts_dirty && i < 1000; i += 1 do ts_update(b, 50)
	testing.expect(t, b.ts_tree != nil, "no tree")
	ts_prepare(b, 0, 2)
	testing.expect_value(t, b.ts_set[0][5], true) // "struct"
	testing.expect_value(t, b.ts_lines[0][5], Style.Keyword)

	replace(b, {1, 0}, {1, 0}, "f :: proc() {}", record = false)
	testing.expect(t, b.ts_dirty, "edit should mark the tree stale")
	for i := 0; b.ts_dirty && i < 1000; i += 1 do ts_update(b, 50)
	ts_prepare(b, 0, 2)
	testing.expect_value(t, b.ts_lines[1][5], Style.Keyword) // "proc"
}
