package main

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
test_buf :: proc(text: string) -> ^Buffer {
	b := new(Buffer)
	b.tab_size = 4
	b.want_x = -1
	b.active_caret = -1
	set_text(b, text)
	// globals from an earlier test hold that test's (gone) allocator
	app.bufs, app.input, app.input2 = nil, nil, nil
	append(&app.bufs, b)
	app.active = 0
	return b
}

@(test)
multi_caret_typing :: proc(t: ^testing.T) {
	b := test_buf("ab\nab\nab")
	b.cur, b.anchor = {0, 1}, {0, 1}
	append(&b.extra, [2]Pos{{1, 1}, {1, 1}}, [2]Pos{{2, 1}, {2, 1}})
	each_caret(b, proc(b: ^Buffer) {insert_text(b, "xy")})
	testing.expect_value(t, buffer_text(b), "axyb\naxyb\naxyb")
	testing.expect_value(t, b.cur, Pos{0, 3})
	testing.expect_value(t, len(b.extra), 2)
	kev = Ev{key = K_BACKSPACE}
	each_caret(b, caret_key)
	testing.expect_value(t, buffer_text(b), "axb\naxb\naxb")
	undo(b)
	testing.expect_value(t, buffer_text(b), "axyb\naxyb\naxyb")
	undo(b)
	testing.expect_value(t, buffer_text(b), "ab\nab\nab") // each round is one undo step
}

@(test)
multi_caret_same_line :: proc(t: ^testing.T) {
	// carets on one line: edits further left must not break the ones to the right
	b := test_buf("a a a")
	b.cur, b.anchor = {0, 0}, {0, 0}
	append(&b.extra, [2]Pos{{0, 2}, {0, 2}}, [2]Pos{{0, 4}, {0, 4}})
	each_caret(b, proc(b: ^Buffer) {insert_text(b, "\n")})
	testing.expect_value(t, buffer_text(b), "\na \na \na")
}

@(test)
next_occurrence :: proc(t: ^testing.T) {
	b := test_buf("foo bar foo\nfoo")
	b.cur, b.anchor = {0, 1}, {0, 1}
	add_next_occurrence(b) // selects the word
	testing.expect_value(t, text_range(b, b.anchor, b.cur), "foo")
	add_next_occurrence(b)
	add_next_occurrence(b)
	add_next_occurrence(b) // wrapped: nothing new
	testing.expect_value(t, len(b.extra), 2)
	each_caret(b, proc(b: ^Buffer) {insert_text(b, "X")})
	testing.expect_value(t, buffer_text(b), "X bar X\nX")
}

@(test)
replace_everything :: proc(t: ^testing.T) {
	b := test_buf("Foo foo\nxfoo")
	append(&app.input, "foo")
	append(&app.input2, "bar")
	replace_all(b)
	testing.expect_value(t, buffer_text(b), "bar bar\nxbar")
	undo(b)
	testing.expect_value(t, buffer_text(b), "Foo foo\nxfoo")
}

// The incremental changes we send, replayed on a copy of the old text, must give the new text.
@(test)
incremental_sync_replays :: proc(t: ^testing.T) {
	b := test_buf("line one\nline two\nthree")
	server := strings.clone(buffer_text(b))
	clear_changes(b)
	replace(b, {0, 5}, {1, 4}, "ONE\nTWO")
	replace(b, {2, 0}, {2, 0}, "😀 ")
	replace(b, {1, 0}, {2, 2}, "")
	for c in b.changes {
		lines := strings.split(server, "\n", context.temp_allocator)
		off :: proc(lines: []string, p: Pos) -> int {
			n := 0
			for l in lines[:p.line] do n += len(l) + 1
			return n + p.col
		}
		a, z := off(lines, c.a), off(lines, c.z)
		server = strings.concatenate({server[:a], c.text, server[z:]})
	}
	testing.expect_value(t, server, buffer_text(b))
}

@(test)
brackets_and_shift :: proc(t: ^testing.T) {
	b := test_buf("f(a, [b])\n{\n}")
	b.cur = {0, 1}
	a, z, ok := bracket_pair(b)
	testing.expect(t, ok)
	testing.expect_value(t, z, Pos{0, 8})
	b.cur = {2, 1} // just after "}"
	a, z, ok = bracket_pair(b)
	testing.expect_value(t, a, Pos{1, 0})
	testing.expect_value(t, shift_pos({3, 5}, {1, 0}, {2, 0}, {1, 3}), Pos{2, 5})
	testing.expect_value(t, shift_pos({2, 4}, {1, 0}, {2, 2}, {1, 3}), Pos{1, 5})
}

@(test)
project_search :: proc(t: ^testing.T) {
	dir := pj("/tmp", "seoritsu-searchproj", allocator = context.temp_allocator)
	os.make_directory_all(dir)
	_ = os.write_entire_file(pj(dir, "a.txt"), transmute([]u8)string("one\n  find: me here\n"))
	project_root = dir
	app.picks, app.hits, app.input, app.files = nil, nil, nil, nil
	append(&app.input, "find: me")
	run_search()
	testing.expect_value(t, len(app.hits), 1)
	if len(app.picks) == 1 {
		testing.expect_value(t, app.picks[0].line, 1)
		testing.expect_value(t, app.picks[0].char, 2)
		testing.expect_value(t, app.picks[0].label, "a.txt:2")
	}
}
