package main

// More of Zed: drag & drop (panel, tabs, files from other apps), file copy / cut / paste
// in the panel, recent projects, git branches / commit / push / pull, and editing
// commands (select line, join lines, expand selection, …).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// Generic one-line prompt (open folder, commit message, save as, new branch)

prompt: struct {
	hint:   string,
	icon:   rune,
	submit: proc(q: string),
}

prompt_open :: proc(hint: string, icon: rune, initial: string, submit: proc(q: string)) {
	prompt.hint, prompt.icon, prompt.submit = hint, icon, submit
	app.mode = .Prompt
	clear(&app.input)
	append(&app.input, initial)
}

// ---------------------------------------------------------------------------
// Mouse: click vs. drag in the panel, tab reordering, drops

panel_press := -1 // row pressed; becomes a click on release or a drag on motion
press_at: [2]f32
tab_drag := -1
dnd_on: bool
dnd_at: [2]f32

panel_click :: proc(i: int) {
	if i < 0 || i >= len(app.tree) do return
	app.panel_sel = i
	n := app.tree[i]
	if n.dir do panel_set_expanded(n.path, !app.expanded[n.path])
	else do open_file(n.path)
}

drag_motion :: proc(x, y: f32) {
	if panel_press >= 0 && abs(x - press_at.x) + abs(y - press_at.y) > 6 * app.S {
		i := panel_press
		panel_press = -1
		if i < len(app.tree) do plat_start_drag({app.tree[i].path})
	}
	if tab_drag >= 0 && contains(app.tabbar, x, y) {
		if j, _, ok := tab_at(x); ok && j != tab_drag && tab_drag < len(app.bufs) {
			b := app.bufs[tab_drag]
			ordered_remove(&app.bufs, tab_drag)
			inject_at(&app.bufs, j, b)
			app.active, tab_drag = j, j
		}
	}
}

drag_release :: proc() {
	if panel_press >= 0 do panel_click(panel_press)
	panel_press, tab_drag = -1, -1
}

// Folder a drop at panel height y lands in.
drop_dir_at :: proc(y: f32) -> string {
	i := int((y - app.panel.y - PANEL_TOP * app.S + app.panel_scroll) / (PANEL_ROW * app.S))
	if y < app.panel.y + PANEL_TOP * app.S || i < 0 || i >= len(app.tree) do return project_root
	n := app.tree[i]
	return n.path if n.dir else filepath.dir(n.path)
}

on_dnd :: proc(ev: Ev) {
	#partial switch ev.kind {
	case .Dnd_Motion:
		dnd_on, dnd_at = true, {ev.x * app.S, ev.y * app.S}
	case .Dnd_Leave:
		dnd_on = false
	case .Dnd_Drop:
		dnd_on = false
		paths := make([dynamic]string, context.temp_allocator)
		for l in strings.split_lines(ev.text, context.temp_allocator) do if l != "" do append(&paths, l)
		if len(paths) == 0 do return
		x, y := dnd_at.x, dnd_at.y
		if app.panel_on && contains(app.panel, x, y) {
			dir := drop_dir_at(y)
			n := 0
			for p in paths do if transfer(p, dir, ev.button == 2) do n += 1
			if n > 0 do toast(fmt.tprintf("%d 個を%sしました: %s/", n, "移動" if ev.button == 2 else "コピー", rel_path(dir)))
			refresh_tree()
		} else if len(paths) == 1 && os.is_dir(paths[0]) {
			switch_project(paths[0]) // a folder dropped on the editor opens it, like Zed
		} else {
			for p in paths do if !os.is_dir(p) do open_file(p)
		}
	}
}

// Ring around the folder a drop would land in.
draw_drop_target :: proc() {
	if !dnd_on || !app.panel_on || !contains(app.panel, dnd_at.x, dnd_at.y) do return
	S := app.S
	dir := drop_dir_at(dnd_at.y)
	if dir == project_root {
		rrect(shrink(app.panel, 2 * S), 6 * S, col("accent"), ring = max(S, 1))
		return
	}
	for n, i in app.tree do if n.path == dir {
		y := app.panel.y + PANEL_TOP * S + f32(i) * PANEL_ROW * S - app.panel_scroll
		rrect({app.panel.x + 4 * S, y, app.panel.w - 8 * S, PANEL_ROW * S}, 5 * S, col("accent"), ring = 2 * S)
	}
}

// "name copy.ext", "name copy 2.ext", … like Zed.
unique_name :: proc(dir, name: string) -> string {
	if !os.exists(pj(dir, name)) do return pj(dir, name)
	ext := filepath.ext(name)
	stem := name[:len(name) - len(ext)]
	if strings.has_prefix(name, ".") && strings.count(name, ".") == 1 do stem, ext = name, ""
	for i := 1; ; i += 1 {
		cand := fmt.tprintf("%s copy%s", stem, ext) if i == 1 else fmt.tprintf("%s copy %d%s", stem, i, ext)
		if !os.exists(pj(dir, cand)) do return pj(dir, cand)
	}
}

// Moves or copies src into dir. Copies never overwrite; moves refuse to.
transfer :: proc(src, dir: string, move: bool) -> bool {
	if !os.exists(src) do return false
	if is_under(dir, src) {
		toast("フォルダをそれ自身の中へは入れられません")
		return false
	}
	name := filepath.base(src)
	if move {
		dst := pj(dir, name)
		if dst == src do return false
		if os.exists(dst) {
			toast(fmt.tprintf("すでにあります: %s", name))
			return false
		}
		if os.rename(src, dst) != nil { // shortcut: no cross-filesystem move (needs copy + delete); add if drops from other disks matter
			toast(fmt.tprintf("移動できませんでした: %s", name))
			return false
		}
		retarget_buffers(src, dst)
		return true
	}
	dst := unique_name(dir, name)
	err := os.copy_directory_all(dst, src) if os.is_dir(src) else os.copy_file(dst, src)
	if err != nil {
		toast(fmt.tprintf("コピーできませんでした: %s", name))
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Panel clipboard: shared with file managers (x-special/gnome-copied-files)

panel_sel_path :: proc() -> string {
	return app.tree[app.panel_sel].path if app.panel_sel >= 0 && app.panel_sel < len(app.tree) else ""
}

panel_copy :: proc(path: string, cut: bool) {
	if path == "" do return
	plat_set_clipboard_files({path}, cut)
	toast(fmt.tprintf("%s を%sしました", filepath.base(path), "切り取り" if cut else "コピー"))
}

panel_paste :: proc() {
	paths, cut, ok := plat_get_clipboard_files()
	if !ok || len(paths) == 0 {
		toast("クリップボードにファイルがありません")
		return
	}
	dir := panel_target_dir()
	n := 0
	for p in paths do if transfer(p, dir, cut) do n += 1
	if n > 0 do toast(fmt.tprintf("%d 個を貼り付けました: %s/", n, rel_path(dir)))
	refresh_tree()
}

panel_duplicate :: proc(path: string) {
	if path == "" do return
	if transfer(path, filepath.dir(path), false) do refresh_tree()
}

// Ctrl+C / X / V / D while the panel has focus; true if handled.
panel_clip_key :: proc(ev: Ev) -> bool {
	if !(app.mode == .Edit && app.panel_focus && app.panel_on) || ev.mods != {.Ctrl} do return false
	switch ev.key {
	case 'c': panel_copy(panel_sel_path(), false)
	case 'x': panel_copy(panel_sel_path(), true)
	case 'v': panel_paste()
	case 'd': panel_duplicate(panel_sel_path())
	case: return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Recent projects and switching (re-exec into the other folder, like a fresh start)

switch_to: string

recent_file :: proc() -> string {
	return pj(state_dir(), "recent")
}

recent_list :: proc() -> []string {
	data, err := os.read_entire_file(recent_file(), context.temp_allocator)
	if err != nil do return nil
	out := make([dynamic]string, context.temp_allocator)
	for l in strings.split_lines(string(data), context.temp_allocator) do if l != "" && !slice.contains(out[:], l) do append(&out, l)
	return out[:]
}

recent_add :: proc(path: string) {
	list := make([dynamic]string, context.temp_allocator)
	append(&list, path)
	for p in recent_list() do if p != path && len(list) < 30 do append(&list, p)
	os.make_directory_all(filepath.dir(recent_file()))
	_ = os.write_entire_file(recent_file(), transmute([]u8)strings.join(list[:], "\n", context.temp_allocator))
}

recent_picker :: proc() {
	items := make([dynamic]Pick)
	home := os.get_env("HOME", context.temp_allocator)
	for p in recent_list() {
		if p == project_root || !os.is_dir(p) do continue
		d := strings.concatenate({"~", p[len(home):]}, context.temp_allocator) if home != "" && strings.has_prefix(p, home) else p
		append(&items, Pick{label = strings.clone(filepath.base(p)), detail = strings.clone(d), path = strings.clone(p)})
	}
	picker_open(.Projects, "最近のプロジェクトを開く…", items)
}

open_folder_prompt :: proc() {
	start := strings.concatenate({filepath.dir(project_root), "/"}, context.temp_allocator)
	prompt_open("開くフォルダのパス", 0xf07c, start, proc(q: string) {
		p := strings.trim_space(q)
		if strings.has_prefix(p, "~") do p = strings.concatenate({os.get_env("HOME", context.temp_allocator), p[1:]}, context.temp_allocator)
		abs, _ := filepath.abs(p, context.temp_allocator)
		if !os.is_dir(abs) {
			toast(fmt.tprintf("フォルダがありません: %s", p))
			return
		}
		switch_project(abs)
	})
}

// Quits the main loop; main re-executes us in that folder (session, autosave, .unsaved as on quit).
switch_project :: proc(path: string) {
	if path == project_root do return
	if !zed.autosave do for b in all_bufs() do if b.dirty {
		toast("未保存のファイルがあります。保存してから切り替えてください")
		return
	}
	switch_to = strings.clone(path)
	app.running = false
}

exec_switch :: proc() {
	if switch_to == "" do return
	argv := []cstring{strings.clone_to_cstring(os.args[0]), strings.clone_to_cstring(switch_to), nil}
	posix.execv("/proc/self/exe", raw_data(argv))
}

// ---------------------------------------------------------------------------
// git

// shortcut: runs synchronously (the window waits); fine for local commands, push/pull may pause a few seconds.
git_run :: proc(args: ..string) -> (ok: bool, msg: string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "env", "GIT_TERMINAL_PROMPT=0", "git", "-C", project_root)
	append(&cmd, ..args)
	st, out, errb, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil do return false, "git を実行できません"
	m := strings.trim_space(string(errb) if len(errb) > 0 else string(out))
	if i := strings.last_index_byte(m, '\n'); i >= 0 do m = m[i + 1:]
	return st.exit_code == 0, m
}

after_git :: proc() {
	check_external_changes() // also refreshes the tree and git colors
	for b in all_bufs() do git_refresh(b)
}

branch_picker :: proc() {
	_, out, _, err := os.process_exec({command = {"git", "-C", project_root, "branch", "--format=%(refname:short)"}}, context.temp_allocator)
	if err != nil || git_branch == "" {
		toast("git リポジトリではありません")
		return
	}
	items := make([dynamic]Pick)
	append(&items, Pick{label = strings.clone("＋ 新しいブランチを作成…"), path = strings.clone("")})
	for l in strings.split_lines(strings.trim_space(string(out)), context.temp_allocator) {
		if l == "" do continue
		append(&items, Pick{label = strings.clone(l), detail = strings.clone("現在" if l == git_branch else ""), path = strings.clone(l)})
	}
	picker_open(.Branches, "ブランチを切り替え…", items)
}

git_switch :: proc(name: string) {
	if name == "" {
		prompt_open("新しいブランチ名", 0xe725, "", proc(q: string) {
			name := strings.trim_space(q)
			if name == "" || strings.has_prefix(name, "-") {
				toast("そのブランチ名は使えません")
				return
			}
			ok, msg := git_run("switch", "-c", name)
			toast(fmt.tprintf("ブランチ %s を作成しました", q) if ok else msg)
			after_git()
		})
		return
	}
	if name == git_branch do return
	ok, msg := git_run("switch", name)
	toast(fmt.tprintf("%s に切り替えました", name) if ok else msg)
	after_git()
}

git_commit_prompt :: proc() {
	if git_branch == "" {
		toast("git リポジトリではありません")
		return
	}
	prompt_open("コミットメッセージ (すべての変更をステージしてコミット)", 0xe729, "", proc(q: string) {
		if strings.trim_space(q) == "" do return
		if ok, msg := git_run("add", "-A"); !ok {
			toast(msg)
			return
		}
		ok, msg := git_run("commit", "-m", q)
		toast("コミットしました" if ok else msg)
		after_git()
	})
}

git_push :: proc() {
	ok, msg := git_run("push")
	toast("プッシュしました" if ok else msg)
}

git_pull :: proc() {
	ok, msg := git_run("pull", "--ff-only")
	toast("プルしました" if ok else msg)
	after_git()
}

// ---------------------------------------------------------------------------
// Editing commands

select_line :: proc(b: ^Buffer) {
	a, z := order(b.anchor, b.cur)
	// already whole lines: grow by one more
	if a.col == 0 && z.col == 0 && z.line > a.line do z = {z.line + 1, 0}
	else do a, z = {a.line, 0}, {z.line + 1, 0}
	if z.line >= len(b.lines) do z = {len(b.lines) - 1, len(b.lines[len(b.lines) - 1])}
	b.anchor, b.cur = a, z
}

newline_below :: proc(b: ^Buffer) {
	go(b, {b.cur.line, len(b.lines[b.cur.line])}, false)
	newline(b)
}

newline_above :: proc(b: ^Buffer) {
	l := b.cur.line
	ind := strings.clone(indent_of(b, l), context.temp_allocator)
	replace(b, {l, 0}, {l, 0}, strings.concatenate({ind, "\n"}, context.temp_allocator))
	go(b, {l, len(ind)}, false)
}

join_lines :: proc(b: ^Buffer) {
	a, z := order(b.anchor, b.cur)
	n := max(z.line - a.line, 1)
	for _ in 0 ..< n {
		l := a.line
		if l + 1 >= len(b.lines) do break
		next := len(indent_of(b, l + 1))
		sep := "" if len(b.lines[l + 1]) == next || len(b.lines[l]) == 0 else " "
		end := len(strings.trim_right_space(line_str(b, l)))
		replace(b, {l, end}, {l + 1, next}, sep, merge = true)
		if a == z do go(b, {l, end}, false)
	}
}

goto_bracket :: proc(b: ^Buffer) {
	a, z, ok := bracket_pair(b)
	if !ok do return
	at_open := b.cur == a || b.cur == Pos{a.line, a.col + 1}
	go(b, z if at_open else a, false)
}

closed_tabs: [dynamic]Loc

remember_closed :: proc(b: ^Buffer) {
	append(&closed_tabs, Loc{strings.clone(b.path), b.cur})
	if len(closed_tabs) > 50 do ordered_remove(&closed_tabs, 0)
}

reopen_closed :: proc() {
	for len(closed_tabs) > 0 {
		l := pop(&closed_tabs)
		if !os.exists(l.path) do continue
		if b := open_file(l.path); b != nil {
			b.cur, b.anchor = clamp_pos(b, l.pos), clamp_pos(b, l.pos)
			ensure_visible(b)
		}
		return
	}
}

// Selected lines (or the whole file) sorted / case changed, as one undo step.
sort_lines :: proc(b: ^Buffer) {
	a, z := order(b.anchor, b.cur)
	if a == z do a, z = {0, 0}, {len(b.lines) - 1, len(b.lines[len(b.lines) - 1])}
	else do a, z = {a.line, 0}, {z.line, len(b.lines[z.line])}
	lines := strings.split(text_range(b, a, z), "\n", context.temp_allocator)
	slice.sort(lines)
	b.anchor = a
	b.cur = replace(b, a, z, strings.join(lines, "\n", context.temp_allocator))
}

change_case :: proc(b: ^Buffer, upper: bool) {
	if !has_sel(b) do b.anchor, b.cur = word_at(b, b.cur)
	a, z := order(b.anchor, b.cur)
	t := text_range(b, a, z)
	t = strings.to_upper(t, context.temp_allocator) if upper else strings.to_lower(t, context.temp_allocator)
	b.anchor = a
	b.cur = replace(b, a, z, t)
}

sel_stack: [dynamic][2]Pos
sel_owner: ^Buffer

// Grows the selection to the enclosing syntax node (tree-sitter), else word → line → all.
expand_selection :: proc(b: ^Buffer) {
	if sel_owner != b do clear(&sel_stack)
	sel_owner = b
	a, z := order(b.anchor, b.cur)
	append(&sel_stack, [2]Pos{b.anchor, b.cur})
	na, nz, ok := ts_enclosing(b, a, z)
	if !ok {
		wa, wz := word_at(b, a)
		la, lz := Pos{a.line, 0}, Pos{z.line, len(b.lines[z.line])}
		switch {
		case a == z && wa != wz: na, nz = wa, wz
		case a != la || z != lz: na, nz = la, lz
		case: na, nz = {}, {len(b.lines) - 1, len(b.lines[len(b.lines) - 1])}
		}
	}
	b.anchor, b.cur = na, nz
}

shrink_selection :: proc(b: ^Buffer) {
	if sel_owner != b || len(sel_stack) == 0 do return
	s := pop(&sel_stack)
	b.anchor, b.cur = s[0], s[1]
}

new_file_prompt :: proc() {
	b := cur_buf()
	app.panel_target = strings.clone(filepath.dir(b.path) if b != nil else project_root)
	app.mode = .New_File
	clear(&app.input)
}

save_as_prompt :: proc(b: ^Buffer) {
	prompt_open("名前を付けて保存 (プロジェクトからの相対パスも可)", 0xf0c7, rel_path(b.path), proc(q: string) {
		b := cur_buf()
		if b == nil || strings.trim_space(q) == "" do return
		p := strings.trim_space(q)
		if !strings.has_prefix(p, "/") do p = pj(project_root, p)
		if p == b.path {
			save(b)
			return
		}
		if os.exists(p) {
			toast(fmt.tprintf("すでにあります: %s", rel_path(p)))
			return
		}
		os.make_directory_all(filepath.dir(p))
		lsp_close(b)
		delete(b.path)
		b.path = strings.clone(p)
		finish_save(b)
		lsp_open(b)
		refresh_tree()
	})
}
