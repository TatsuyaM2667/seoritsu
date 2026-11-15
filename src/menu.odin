package main

// Mouse UI like Zed: right-click menus (project panel, tabs, editor) and clickable
// status bar buttons. Everything here also exists as a key / palette command.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

Menu_Item :: struct {
	label, key: string,
	run:        proc(),
	cmd:        int, // > 0: run COMMANDS[cmd - 1] instead (0 = use run)
	sep:        bool, // line above
}

menu: struct {
	on:    bool,
	at:    [2]f32,
	items: [dynamic]Menu_Item,
	path:  string, // what the menu is about (panel row / tab file)
	tab:   int,
}

ROW_H :: 28

menu_open :: proc(x, y: f32, items: []Menu_Item, path := "", tab := -1) {
	clear(&menu.items)
	append(&menu.items, ..items)
	delete(menu.path)
	menu.path = strings.clone(path)
	menu.on, menu.at, menu.tab = true, {x, y}, tab
	app.comp_on, app.hover = false, ""
}

// Item that runs a palette command, showing its shortcut.
cmd_item :: proc(name: string, sep := false) -> Menu_Item {
	for c, i in COMMANDS do if c.name == name do return {label = c.name, cmd = i + 1, sep = sep}
	return {label = name, sep = sep}
}

// Shortcut shown on the right (built per frame: key_label uses temp memory).
item_key :: proc(it: Menu_Item) -> string {return key_label(COMMANDS[it.cmd - 1]) if it.cmd > 0 else it.key}

menu_rect :: proc() -> Rect {
	S := app.S
	w: f32 = 0
	h := 8 * S
	for it in menu.items {
		key := item_key(it)
		w = max(w, f32(text_width(it.label, app.ui, true)) + (f32(text_width(key, app.ui - i32(S), true)) + 40 * S if key != "" else 0))
		h += ROW_H * S + (9 * S if it.sep else 0)
	}
	w += 36 * S
	x := min(menu.at.x, app.W - w - 4 * S)
	y := min(menu.at.y, app.H - h - 4 * S)
	return {max(x, 4 * S), max(y, 4 * S), w, h}
}

// Row rects in order, so drawing and clicking agree.
menu_rows :: proc() -> []Rect {
	S := app.S
	r := menu_rect()
	out := make([]Rect, len(menu.items), context.temp_allocator)
	y := r.y + 4 * S
	for it, i in menu.items {
		if it.sep do y += 9 * S
		out[i] = {r.x + 4 * S, y, r.w - 8 * S, ROW_H * S}
		y += ROW_H * S
	}
	return out
}

draw_menu :: proc() {
	if !menu.on do return
	S := app.S
	r := menu_rect()
	popup(r)
	for row, i in menu_rows() {
		it := menu.items[i]
		if it.sep do fill({r.x + 8 * S, row.y - 5 * S, r.w - 16 * S, 1}, col("border"))
		if contains(row, app.mx, app.my) do rrect(row, 4 * S, col("element.hover"))
		bl := baseline(row, app.ui)
		text(row.x + 12 * S, bl, it.label, app.ui, col("text"))
		if key := item_key(it); key != "" {
			sz := app.ui - i32(S)
			text(row.x + row.w - 12 * S - f32(text_width(key, sz, true)), bl, key, sz, col("text.muted"))
		}
	}
}

// Returns true when the click belonged to the menu (or just closed it).
menu_click :: proc(x, y: f32) -> bool {
	if !menu.on do return false
	menu.on = false
	for row, i in menu_rows() do if contains(row, x, y) {
		it := menu.items[i]
		if it.cmd > 0 do run_cmd(COMMANDS[it.cmd - 1])
		else if it.run != nil do it.run()
		return true
	}
	return true
}

// ---------------------------------------------------------------------------
// The three menus

panel_menu :: proc(x, y: f32, row: int) {
	if row >= 0 && row < len(app.tree) {
		app.panel_sel = row
		menu_open(x, y, {
			{label = "新しいファイル", key = "A", run = proc() {panel_input(.New_File, "")}},
			{label = "新しいフォルダ", key = "Shift+A", run = proc() {panel_input(.New_Dir, "")}},
			{label = "ファイルマネージャで表示", run = proc() {reveal_in_file_manager(menu.path)}, sep = true},
			{label = "外部ターミナルで開く", run = proc() {open_terminal(dir_of(menu.path))}},
			{label = "コピー", key = "Ctrl+C", run = proc() {panel_copy(menu.path, false)}, sep = true},
			{label = "切り取り", key = "Ctrl+X", run = proc() {panel_copy(menu.path, true)}},
			{label = "貼り付け", key = "Ctrl+V", run = proc() {panel_paste()}},
			{label = "複製", key = "Ctrl+D", run = proc() {panel_duplicate(menu.path)}},
			{label = "パスをコピー", run = proc() {plat_set_clipboard_text(menu.path)}, sep = true},
			{label = "相対パスをコピー", run = proc() {plat_set_clipboard_text(rel_path(menu.path))}},
			{label = "名前を変更", key = "R", run = proc() {panel_input(.Rename_File, filepath.base(menu.path))}, sep = true},
			{label = "ゴミ箱へ移動", key = "Delete", run = proc() {trash_with_toast(menu.path)}},
		}, app.tree[row].path)
	} else {
		// empty space: new entries go in the project root
		app.panel_sel = len(app.tree)
		menu_open(x, y, {
			{label = "新しいファイル", key = "A", run = proc() {panel_input(.New_File, "")}},
			{label = "新しいフォルダ", key = "Shift+A", run = proc() {panel_input(.New_Dir, "")}},
			{label = "貼り付け", key = "Ctrl+V", run = proc() {panel_paste()}},
			{label = "ファイルマネージャで表示", run = proc() {reveal_in_file_manager(project_root)}, sep = true},
			{label = "外部ターミナルで開く", run = proc() {open_terminal(project_root)}},
		}, project_root)
	}
}

tab_menu :: proc(x, y: f32, tab: int) {
	menu_open(x, y, {
		{label = "閉じる", key = "Ctrl+W", run = proc() {close_tab(menu.tab)}},
		{label = "ほかのタブを閉じる", run = proc() {close_tabs(proc(i: int) -> bool {return i != menu.tab})}},
		{label = "右側のタブを閉じる", run = proc() {close_tabs(proc(i: int) -> bool {return i > menu.tab})}},
		{label = "すべて閉じる", run = proc() {close_tabs(proc(i: int) -> bool {return true})}},
		{label = "パスをコピー", run = proc() {plat_set_clipboard_text(menu.path)}, sep = true},
		{label = "相対パスをコピー", run = proc() {plat_set_clipboard_text(rel_path(menu.path))}},
		{label = "プロジェクトパネルで表示", run = proc() {app.panel_on = true; panel_reveal(menu.path)}, sep = true},
		{label = "ファイルマネージャで表示", run = proc() {reveal_in_file_manager(menu.path)}},
	}, app.bufs[tab].path, tab)
}

editor_menu :: proc(x, y: f32) {
	b := cur_buf()
	menu_open(x, y, {
		cmd_item("定義へ移動"),
		cmd_item("参照を検索"),
		cmd_item("シンボルの名前を変更"),
		cmd_item("コードアクション"),
		cmd_item("フォーマット"),
		cmd_item("切り取り", sep = true),
		cmd_item("コピー"),
		cmd_item("貼り付け"),
		cmd_item("行コメントの切替", sep = true),
		cmd_item("git: この変更を元に戻す"),
		cmd_item("折りたたむ"),
		cmd_item("展開する"),
		{label = "プロジェクトパネルで表示", run = proc() {app.panel_on = true; panel_reveal(menu.path)}, sep = true},
		{label = "外部ターミナルで開く", run = proc() {open_terminal(dir_of(menu.path))}},
	}, b.path)
}

// Clean tabs matching keep_out are closed; tabs with unsaved changes stay open.
close_tabs :: proc(should_close: proc(i: int) -> bool) {
	kept := 0
	for i := len(app.bufs) - 1; i >= 0; i -= 1 {
		if !should_close(i) do continue
		if app.bufs[i].dirty {
			kept += 1
			continue
		}
		close_tab(i)
	}
	if kept > 0 do toast(fmt.tprintf("未保存の %d 個のタブは残しました", kept))
}

trash_with_toast :: proc(path: string) {
	name := filepath.base(path)
	for b in all_bufs() do if b.dirty && is_under(b.path, path) {
		toast(fmt.tprintf("%s に未保存の変更があります。保存するか閉じてから移動してください", filepath.base(b.path)))
		return
	}
	if move_to_trash(path) {
		close_buffers_under(path)
		toast(fmt.tprintf("%s をゴミ箱へ移動しました", name))
		refresh_tree()
	} else {
		toast(fmt.tprintf("ゴミ箱へ移動できませんでした: %s", name))
	}
}

dir_of :: proc(path: string) -> string {
	return path if os.is_dir(path) else filepath.dir(path)
}

reveal_in_file_manager :: proc(path: string) {
	if find_in_path("xdg-open") == "" {
		toast("xdg-open が見つかりません")
		return
	}
	spawn_detached({"xdg-open", dir_of(path)}, project_root)
}

// Starts a program that outlives us; double fork so it never becomes a zombie.
spawn_detached :: proc(args: []string, cwd: string) {
	exe := find_in_path(args[0]) if !strings.has_prefix(args[0], "/") else args[0]
	if exe == "" do return
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	argv[0] = strings.clone_to_cstring(exe, context.temp_allocator)
	for a, i in args[1:] do argv[i + 1] = strings.clone_to_cstring(a, context.temp_allocator)
	ccwd := strings.clone_to_cstring(cwd, context.temp_allocator)
	pid := posix.fork()
	if pid == 0 {
		posix.setsid()
		if posix.fork() == 0 {
			posix.chdir(ccwd)
			posix.execv(argv[0], raw_data(argv))
		}
		posix._exit(0)
	}
	if pid > 0 do posix.waitpid(pid, nil, {})
}

// ---------------------------------------------------------------------------
// Clickable status bar (rebuilt every frame by draw_status)

Ui_Button :: struct {
	r:   Rect,
	run: proc(),
}
status_buttons: [dynamic]Ui_Button

// Draws an icon (+ optional label) button at x; returns its width.
status_button :: proc(x: f32, icon: rune, label: string, c: Color, run: proc(), right := false) -> f32 {
	S := app.S
	r := app.status
	sz := app.ui - i32(S)
	w := (18 * S if icon != 0 else 0) + (f32(text_width(label, sz, true)) if label != "" else 0) + 12 * S
	bx := x - w if right else x
	br := Rect{bx, r.y + 3 * S, w, r.h - 6 * S}
	if contains(br, app.mx, app.my) do rrect(br, 4 * S, col("element.hover"))
	bl := baseline(r, sz)
	tx := bx + 6 * S
	if icon != 0 {
		draw_glyph_c(tx, bl, icon, sz, c)
		tx += 18 * S
	}
	if label != "" do text(tx, bl, label, sz, col("text.muted"))
	append(&status_buttons, Ui_Button{br, run})
	return w
}

status_click :: proc(x, y: f32) -> bool {
	for bt in status_buttons do if contains(bt.r, x, y) {
		bt.run()
		return true
	}
	return false
}
