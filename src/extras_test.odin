package main

import "core:os"
import "core:testing"

@(private = "file")
ebuf :: proc(text: string) -> ^Buffer {
	b := new(Buffer)
	b.tab_size, b.want_x, b.active_caret = 4, -1, -1
	set_text(b, text)
	app.bufs = nil
	append(&app.bufs, b)
	app.active = 0
	return b
}

@(test)
edit_commands :: proc(t: ^testing.T) {
	b := ebuf("b\n\tfoo(x)\na")
	b.cur, b.anchor = {1, 2}, {1, 2}
	select_line(b)
	testing.expect_value(t, b.anchor, Pos{1, 0})
	testing.expect_value(t, b.cur, Pos{2, 0})
	select_line(b) // grows by a line, clamped at the end
	testing.expect_value(t, b.cur, Pos{2, 1})

	b.cur, b.anchor = {0, 0}, {0, 0}
	join_lines(b)
	testing.expect_value(t, buffer_text(b), "b foo(x)\na")
	testing.expect_value(t, b.cur, Pos{0, 1})

	b.cur, b.anchor = {0, 0}, {0, 0}
	sort_lines(b) // no selection: whole file
	testing.expect_value(t, buffer_text(b), "a\nb foo(x)")

	b.cur, b.anchor = {1, 3}, {1, 3}
	change_case(b, true) // no selection: the word
	testing.expect_value(t, buffer_text(b), "a\nb FOO(x)")

	b.cur, b.anchor = {1, 3}, {1, 3}
	newline_above(b)
	testing.expect_value(t, buffer_text(b), "a\n\nb FOO(x)")
	testing.expect_value(t, b.cur, Pos{1, 0})

	// expand without a tree: word -> line -> all, shrink walks back
	b.cur, b.anchor = {2, 3}, {2, 3}
	expand_selection(b)
	testing.expect_value(t, [2]Pos{b.anchor, b.cur}, [2]Pos{{2, 2}, {2, 5}})
	expand_selection(b)
	testing.expect_value(t, [2]Pos{b.anchor, b.cur}, [2]Pos{{2, 0}, {2, 8}})
	expand_selection(b)
	testing.expect_value(t, [2]Pos{b.anchor, b.cur}, [2]Pos{{0, 0}, {2, 8}})
	shrink_selection(b)
	shrink_selection(b)
	testing.expect_value(t, [2]Pos{b.anchor, b.cur}, [2]Pos{{2, 2}, {2, 5}})
}

@(test)
file_transfer :: proc(t: ^testing.T) {
	root := "/tmp/seoritsu-transfer-test"
	os.remove_all(root)
	os.make_directory_all(pj(root, "d/inner"))
	_ = os.write_entire_file(pj(root, "f.txt"), transmute([]u8)string("hi"))
	project_root = root
	app.bufs = nil

	testing.expect(t, transfer(pj(root, "f.txt"), root, false), "duplicate in place")
	testing.expect(t, os.exists(pj(root, "f copy.txt")), "named like Zed")
	testing.expect(t, transfer(pj(root, "f.txt"), root, false), "second duplicate")
	testing.expect(t, os.exists(pj(root, "f copy 2.txt")), "numbered")

	testing.expect(t, transfer(pj(root, "f.txt"), pj(root, "d"), true), "move into folder")
	testing.expect(t, os.exists(pj(root, "d/f.txt")) && !os.exists(pj(root, "f.txt")), "moved")
	testing.expect(t, !transfer(pj(root, "d"), pj(root, "d/inner"), true), "no folder into itself")
	testing.expect(t, transfer(pj(root, "d"), root, false), "copy a folder")
	testing.expect(t, os.exists(pj(root, "d copy/f.txt")), "folder copied with contents")

	// a drop on the panel lands in the folder under the pointer (move = action 2)
	app.S, app.panel_on, app.panel, app.expanded = 1, true, {0, 30, 250, 500}, nil
	refresh_tree()
	row := -1
	for n, i in app.tree do if n.name == "d copy" do row = i
	y := 30 + PANEL_TOP + f32(row) * PANEL_ROW + 10
	on_dnd(Ev{kind = .Dnd_Motion, x = 40, y = y})
	on_dnd(Ev{kind = .Dnd_Drop, text = pj(root, "f copy.txt"), button = 2})
	testing.expect(t, os.exists(pj(root, "d copy/f copy.txt")), "dropped into the folder row")
	app.panel_on = false
	os.remove_all(root)
}

@(test)
security_helpers :: proc(t: ^testing.T) {
	testing.expect(t, is_under("/a/b", "/a"), "child")
	testing.expect(t, is_under("/a", "/a"), "itself")
	testing.expect(t, !is_under("/ab", "/a"), "sibling with the same prefix")
	testing.expect(t, is_under("/a/b", "/a/"), "trailing slash")

	// a program in the current folder must not be found through a relative PATH entry
	dir := "/tmp/seoritsu-path-test"
	os.make_directory_all(dir)
	exe := pj(dir, "seoritsu-fake-server")
	_ = os.write_entire_file(exe, transmute([]u8)string("#!/bin/sh\n"))
	os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	old := os.get_env("PATH", context.temp_allocator)
	old_wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_working_directory(dir)
	os.set_env("PATH", ".::")
	testing.expect_value(t, find_in_path("seoritsu-fake-server"), "")
	os.set_env("PATH", dir)
	testing.expect_value(t, find_in_path("seoritsu-fake-server"), exe)
	os.set_env("PATH", old)
	os.set_working_directory(old_wd)
	os.remove_all(dir)
}

@(test)
folding_rows :: proc(t: ^testing.T) {
	b := ebuf("a {\n\tb\n\tc\n}\nd")
	app.wrap = false
	testing.expect(t, foldable(b, 0), "indented block below")
	testing.expect(t, add_fold(b, 0), "fold")
	testing.expect_value(t, row_count(b), 3) // "a {", "}", "d"
	l, _, _ := row_info(b, 1)
	testing.expect_value(t, l, 3)
	testing.expect_value(t, row_of(b, {2, 0}), 0) // hidden line maps to the header
	replace(b, {4, 0}, {4, 0}, "x\n", record = false) // edit below: fold stays
	testing.expect_value(t, len(b.folds), 1)
	replace(b, {1, 1}, {1, 1}, "z", record = false) // edit inside: fold opens
	testing.expect_value(t, len(b.folds), 0)
	testing.expect_value(t, row_count(b), 6)
}
