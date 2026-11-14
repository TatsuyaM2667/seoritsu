package main

// Zed-like workspace: title bar (project + git branch), breadcrumbs, git colors in the
// project panel, keyboard file operations in the panel, and an external terminal.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

git_branch: string
git_status: map[string]u8 // abs path -> 'M' modified, 'A' added/untracked, 'D' deleted (dirs: worst child)

git_status_refresh :: proc() {
	for k in git_status do delete(k)
	clear(&git_status)
	delete(git_branch)
	git_branch = ""
	_, top, _, err := os.process_exec({command = {"git", "-C", project_root, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"}}, context.temp_allocator)
	if err != nil do return
	lines := strings.split_lines(strings.trim_space(string(top)), context.temp_allocator)
	if len(lines) < 2 do return
	root := lines[0]
	git_branch = strings.clone(lines[1])
	_, out, _, serr := os.process_exec({command = {"git", "-C", project_root, "status", "--porcelain", "--untracked-files=all"}}, context.temp_allocator)
	if serr != nil do return
	for l in strings.split_lines(string(out), context.temp_allocator) {
		if len(l) < 4 do continue
		xy := l[:2]
		p := l[3:]
		if i := strings.index(p, " -> "); i >= 0 do p = p[i + 4:]
		p = strings.trim(p, "\"")
		kind: u8 = 'M'
		if xy == "??" || strings.contains_rune(xy, 'A') do kind = 'A'
		else if strings.contains_rune(xy, 'D') do kind = 'D'
		abs := pj(root, p)
		git_status[strings.clone(abs)] = kind
		// mark parent folders up to the project root
		for d := filepath.dir(abs); len(d) > len(project_root) && strings.has_prefix(d, project_root); d = filepath.dir(d) {
			if d not_in git_status do git_status[strings.clone(d)] = 'M'
		}
	}
}

git_color :: proc(path: string, fallback: Color) -> Color {
	switch git_status[path] {
	case 'M': return col("modified")
	case 'A': return col("created")
	case 'D': return col("deleted")
	}
	return fallback
}

// ---------------------------------------------------------------------------
// Title bar and breadcrumbs

draw_titlebar :: proc() {
	S := app.S
	r := app.titlebar
	fill(r, col("title_bar.background"))
	bl := baseline(r, app.ui)
	x := 14 * S
	x += text(x, bl, filepath.base(project_root), app.ui, col("text"), true) + 14 * S
	if git_branch != "" {
		draw_glyph_c(x, bl, 0xe725, app.ui, col("text.muted"))
		text(x + 20 * S, bl, git_branch, app.ui, col("text.muted"))
	}
	// window close (no server-side decorations on tiling compositors)
	cx := r.w - 40 * S
	if contains({cx, 0, 40 * S, r.h}, app.mx, app.my) do fill({cx, 0, 40 * S, r.h}, hex(0xf85149, 0x80))
	draw_glyph_c(cx + 14 * S, bl, 0xf00d, app.ui, col("text.muted"))
	fill({0, r.h - 1, r.w, 1}, col("border"))
}

draw_breadcrumbs :: proc() {
	S := app.S
	r := app.crumbs
	fill(r, col("toolbar.background"))
	b := cur_buf()
	if b == nil do return
	set_clip(r)
	sz := app.ui - i32(S)
	bl := baseline(r, sz)
	x := r.x + 14 * S
	parts := strings.split(rel_path(b.path), "/", context.temp_allocator)
	for p, i in parts {
		last := i == len(parts) - 1
		if last {
			g, gc := lang_glyph(p)
			draw_glyph_c(x, bl, g, sz, hex(gc))
			x += 18 * S
		}
		x += text(x, bl, p, sz, col("text") if last else col("text.muted"))
		if !last {
			x += 6 * S
			x += text(x, bl, "›", sz, col("text.muted")) + 6 * S
		}
	}
	reset_clip()
}

// ---------------------------------------------------------------------------
// Project panel: keyboard focus and file operations (Zed's keys)

PANEL_TOP :: 6 // px above the first row, unscaled
PANEL_ROW :: 26

panel_focus_toggle :: proc() {
	if app.panel_on && app.panel_focus {
		app.panel_focus = false
		return
	}
	app.panel_on, app.panel_focus = true, true
	if b := cur_buf(); b != nil do panel_reveal(b.path)
}

// Expands the folders above path and selects its row.
panel_reveal :: proc(path: string) {
	for d := filepath.dir(path); len(d) > len(project_root) && strings.has_prefix(d, project_root); d = filepath.dir(d) {
		if !app.expanded[d] do app.expanded[strings.clone(d)] = true
	}
	rebuild_tree()
	for n, i in app.tree do if n.path == path do app.panel_sel = i
	panel_scroll_to_sel()
}

panel_scroll_to_sel :: proc() {
	rh := PANEL_ROW * app.S
	y := f32(app.panel_sel) * rh
	if y < app.panel_scroll do app.panel_scroll = y
	if y + rh > app.panel_scroll + app.panel.h - PANEL_TOP * app.S do app.panel_scroll = y + rh - app.panel.h + PANEL_TOP * app.S
}

panel_set_expanded :: proc(path: string, open: bool) {
	if open do app.expanded[strings.clone(path)] = true
	else do delete_key(&app.expanded, path)
	sel := app.tree[app.panel_sel].path if app.panel_sel < len(app.tree) else ""
	rebuild_tree()
	for n, i in app.tree do if n.path == sel do app.panel_sel = i
}

// Folder new entries go in: the selected folder, or the selected file's folder.
panel_target_dir :: proc() -> string {
	if app.panel_sel >= len(app.tree) do return project_root
	n := app.tree[app.panel_sel]
	return n.path if n.dir else filepath.dir(n.path)
}

panel_key :: proc(ev: Ev) {
	app.panel_sel = clamp(app.panel_sel, 0, max(len(app.tree) - 1, 0))
	has := len(app.tree) > 0
	shift := .Shift in ev.mods
	switch {
	case ev.key == K_ESCAPE:
		app.panel_focus = false
	case ev.key == K_UP:
		app.panel_sel = max(app.panel_sel - 1, 0)
	case ev.key == K_DOWN:
		app.panel_sel = min(app.panel_sel + 1, max(len(app.tree) - 1, 0))
	case ev.key == K_RIGHT && has:
		n := app.tree[app.panel_sel]
		if n.dir && !app.expanded[n.path] do panel_set_expanded(n.path, true)
		else if n.dir do app.panel_sel = min(app.panel_sel + 1, len(app.tree) - 1)
	case ev.key == K_LEFT && has:
		n := app.tree[app.panel_sel]
		if n.dir && app.expanded[n.path] {
			panel_set_expanded(n.path, false)
		} else {
			parent := filepath.dir(n.path)
			for m, i in app.tree do if m.path == parent do app.panel_sel = i
		}
	case (ev.key == K_RETURN || ev.key == K_KP_ENTER) && has:
		n := app.tree[app.panel_sel]
		if n.dir {
			panel_set_expanded(n.path, !app.expanded[n.path])
		} else {
			push_nav()
			open_file(n.path)
			app.panel_focus = false
		}
	case ev.key == 'A' || (ev.key == 'a' && shift):
		panel_input(.New_Dir, "")
	case ev.key == 'a':
		panel_input(.New_File, "")
	case (ev.key == 'r' || ev.key == K_F2_) && has:
		panel_input(.Rename_File, app.tree[app.panel_sel].name)
	case (ev.key == K_DELETE || ev.key == K_BACKSPACE) && has:
		n := app.tree[app.panel_sel]
		if app.trash_armed != n.path {
			delete(app.trash_armed)
			app.trash_armed = strings.clone(n.path)
			toast(fmt.tprintf("もう一度押すと %s をゴミ箱へ移動します", n.name))
			return
		}
		if move_to_trash(n.path) {
			close_buffers_under(n.path)
			toast(fmt.tprintf("%s をゴミ箱へ移動しました", n.name))
			refresh_tree()
		} else {
			toast(fmt.tprintf("ゴミ箱へ移動できませんでした: %s", n.name))
		}
	}
	delete(app.trash_armed)
	app.trash_armed = ""
	panel_scroll_to_sel()
}

panel_input :: proc(m: Mode, initial: string) {
	app.panel_target = strings.clone(panel_target_dir() if m != .Rename_File else app.tree[app.panel_sel].path)
	app.mode = m
	clear(&app.input)
	append(&app.input, initial)
}

refresh_tree :: proc() {
	git_status_refresh()
	rebuild_tree()
	app.panel_sel = clamp(app.panel_sel, 0, max(len(app.tree) - 1, 0))
}

// Enter in the new file / folder / rename bar.
submit_file_op :: proc(name: string) {
	defer {
		delete(app.panel_target)
		app.panel_target = ""
	}
	mode := app.mode
	app.mode = .Edit
	name := strings.trim_space(name)
	if name == "" || strings.contains(name, "..") || strings.has_prefix(name, "/") {
		toast("その名前は使えません")
		return
	}
	switch mode {
	case .New_File, .New_Dir:
		p := pj(app.panel_target, name)
		if os.exists(p) {
			toast(fmt.tprintf("すでにあります: %s", name))
			return
		}
		if mode == .New_Dir {
			if os.make_directory_all(p) != nil do toast("フォルダを作れませんでした")
			refresh_tree()
			panel_reveal(p)
			return
		}
		os.make_directory_all(filepath.dir(p))
		if os.write_entire_file(p, []u8{}) != nil {
			toast("ファイルを作れませんでした")
			return
		}
		refresh_tree()
		panel_reveal(p)
		open_file(p)
		app.panel_focus = false
	case .Rename_File:
		old := app.panel_target
		p := pj(filepath.dir(old), name)
		if p == old do return
		if os.exists(p) {
			toast(fmt.tprintf("すでにあります: %s", name))
			return
		}
		if os.rename(old, p) != nil {
			toast("名前を変更できませんでした")
			return
		}
		// open tabs follow the file (or everything under a renamed folder)
		for b in app.bufs {
			if b.path != old && !strings.has_prefix(b.path, strings.concatenate({old, "/"}, context.temp_allocator)) do continue
			lsp_close(b)
			np := strings.concatenate({p, b.path[len(old):]})
			delete(b.path)
			b.path = np
			lsp_open(b)
		}
		refresh_tree()
		panel_reveal(p)
	case .Edit, .Find, .Replace, .Line, .Rename, .Picker:
	}
}

close_buffers_under :: proc(path: string) {
	for i := len(app.bufs) - 1; i >= 0; i -= 1 {
		b := app.bufs[i]
		if b.path != path && !strings.has_prefix(b.path, strings.concatenate({path, "/"}, context.temp_allocator)) do continue
		b.dirty = false // the file is in the trash now; nothing to keep
		close_tab(i)
	}
}

// freedesktop.org trash: ~/.local/share/Trash/{files,info}. Never deletes outright.
move_to_trash :: proc(path: string) -> bool {
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" do data = pj(os.get_env("HOME", context.temp_allocator), ".local/share")
	files, info := pj(data, "Trash/files"), pj(data, "Trash/info")
	os.make_directory_all(files)
	os.make_directory_all(info)
	base := filepath.base(path)
	name := base
	for i := 2; os.exists(pj(files, name)) || os.exists(pj(info, strings.concatenate({name, ".trashinfo"}, context.temp_allocator))); i += 1 {
		name = fmt.tprintf("%s.%d", base, i)
	}
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock(now)
	ti := fmt.tprintf("[Trash Info]\nPath=%s\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n", path, y, int(mo), d, h, mi, s)
	ip := pj(info, strings.concatenate({name, ".trashinfo"}, context.temp_allocator))
	if os.write_entire_file(ip, transmute([]u8)ti) != nil do return false
	if os.rename(path, pj(files, name)) != nil { // shortcut: no cross-filesystem trash ($topdir/.Trash), the file just stays
		os.remove(ip)
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Terminal: an external app opened in the project folder (kuraokami by default)

TERMINALS :: []string{"kuraokami", "ghostty", "foot", "kitty", "alacritty", "wezterm", "konsole", "gnome-terminal", "xterm"}

terminal_pref_path :: proc() -> string {
	dir := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if dir == "" do dir = pj(os.get_env("HOME", context.temp_allocator), ".local/state")
	return pj(dir, "seoritsu/terminal")
}

// The saved choice if it is still installed, else the first installed one.
terminal_app :: proc() -> string {
	if data, err := os.read_entire_file(terminal_pref_path(), context.temp_allocator); err == nil {
		if p := find_in_path(strings.trim_space(string(data))); p != "" do return p
	}
	for t in TERMINALS do if p := find_in_path(t); p != "" do return p
	return ""
}

open_terminal :: proc(dir := "") {
	term := terminal_app()
	if term == "" {
		toast("ターミナルアプリが見つかりません")
		return
	}
	spawn_detached({term}, dir if dir != "" else project_root)
}

choose_terminal :: proc() {
	items := make([dynamic]Pick)
	cur := filepath.base(terminal_app())
	for t in TERMINALS {
		if find_in_path(t) == "" do continue
		append(&items, Pick{label = strings.clone(t), detail = strings.clone("使用中" if t == cur else ""), path = strings.clone(t)})
	}
	picker_open(.Terminal, "ターミナルアプリを選ぶ…", items)
}

set_terminal :: proc(name: string) {
	os.make_directory_all(filepath.dir(terminal_pref_path()))
	_ = os.write_entire_file(terminal_pref_path(), transmute([]u8)name)
	toast(fmt.tprintf("ターミナル: %s", name))
}
