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

	// expand selection walks up the syntax tree: "{}" -> the struct type -> ...
	a, z, ok := ts_enclosing(b, {0, 12}, {0, 12})
	testing.expect(t, ok, "a node encloses the caret")
	a2, z2, ok2 := ts_enclosing(b, a, z)
	testing.expect(t, ok2 && (lt(a2, a) || lt(z, z2)), "parent is strictly larger")
}

// New file / rename / trash from the project panel, in a throwaway folder.
@(test)
panel_file_ops :: proc(t: ^testing.T) {
	root := "/tmp/seoritsu-ws-test"
	os.remove_all(root)
	os.make_directory_all(pj(root, "sub"))
	os.set_env("XDG_DATA_HOME", pj(root, "data"))
	project_root = root
	app.bufs, app.input, app.tree, app.expanded, app.panel_target, app.trash_armed = nil, nil, nil, nil, "", ""
	git_status, git_branch = nil, ""
	refresh_tree()

	for n, i in app.tree do if n.name == "sub" do app.panel_sel = i
	panel_input(.New_File, "")
	submit_file_op("a/b.txt")
	testing.expect(t, os.exists(pj(root, "sub/a/b.txt")), "new file in the selected folder")
	testing.expect_value(t, len(app.bufs), 1)

	for n, i in app.tree do if n.name == "b.txt" do app.panel_sel = i
	panel_input(.Rename_File, "b.txt")
	submit_file_op("c.txt")
	testing.expect(t, os.exists(pj(root, "sub/a/c.txt")) && !os.exists(pj(root, "sub/a/b.txt")), "renamed")
	testing.expect_value(t, app.bufs[0].path, pj(root, "sub/a/c.txt"))

	testing.expect(t, move_to_trash(pj(root, "sub/a/c.txt")), "trash")
	testing.expect(t, os.exists(pj(root, "data/Trash/files/c.txt")) && os.exists(pj(root, "data/Trash/info/c.txt.trashinfo")), "in trash with info")
	os.remove_all(root)
}

// Menu items without a command must not fall back to COMMANDS[0] (it opens the file picker).
@(test)
menu_items_dispatch :: proc(t: ^testing.T) {
	plain := Menu_Item{label = "閉じる", key = "Ctrl+W", run = proc() {}}
	testing.expect_value(t, plain.cmd, 0)
	testing.expect_value(t, item_key(plain), "Ctrl+W")
	c := cmd_item("コピー")
	testing.expect(t, c.cmd > 0 && COMMANDS[c.cmd - 1].name == "コピー", "cmd_item points at its command")
}
