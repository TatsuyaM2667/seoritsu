package main

import "core:testing"

@(test)
replace_undo_redo :: proc(t: ^testing.T) {
	b := new(Buffer)
	b.tab_size = 4
	set_text(b, "fn main() {\n}\n")
	end := replace(b, {0, 11}, {0, 11}, "\n    x := 1")
	testing.expect_value(t, end, Pos{1, 10})
	testing.expect_value(t, buffer_text(b), "fn main() {\n    x := 1\n}\n")
	// multi-line delete across lines
	replace(b, {0, 10}, {2, 0}, "")
	testing.expect_value(t, buffer_text(b), "fn main() }\n")
	undo(b)
	testing.expect_value(t, buffer_text(b), "fn main() {\n    x := 1\n}\n")
	undo(b)
	testing.expect_value(t, buffer_text(b), "fn main() {\n}\n")
	testing.expect(t, !b.dirty)
	undo(b, redo = true)
	undo(b, redo = true)
	testing.expect_value(t, buffer_text(b), "fn main() }\n")
	testing.expect(t, b.dirty)
}

@(test)
lsp_columns :: proc(t: ^testing.T) {
	b := new(Buffer)
	set_text(b, "a😀b")
	// 😀 is 4 bytes in UTF-8 and 2 units in UTF-16
	testing.expect_value(t, to_lsp_col(b, {0, 5}, true), 3)
	testing.expect_value(t, from_lsp_col(b, 0, 3, true), Pos{0, 5})
	testing.expect_value(t, from_lsp_col(b, 0, 5, false), Pos{0, 5})
}

@(test)
highlights_words :: proc(t: ^testing.T) {
	words: map[string]Style
	scm_words(`
[ "const" "var" ] @keyword
"fn" @keyword.function
((identifier) @type.builtin (#any-of? @type.builtin "u8" "i32"))
[ "(" ")" ] @punctuation.bracket
; "ignored" @keyword
`, &words)
	testing.expect_value(t, words["const"], Style.Keyword)
	testing.expect_value(t, words["fn"], Style.Keyword)
	testing.expect_value(t, words["u8"], Style.Type)
	testing.expect(t, !("ignored" in words))
	testing.expect(t, !("(" in words))
}
