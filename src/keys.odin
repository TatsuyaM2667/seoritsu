package main

// Commands and key bindings. One table drives both the keyboard and the command
// palette (Ctrl+Shift+P), so every command is reachable and shows its shortcut.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Cmd :: struct {
	name:     string,
	key:      u32, // 0 = palette only
	mods:     Mods,
	run:      proc(b: ^Buffer),
	need_buf: bool,
}

K_F12 :: 0xffc9
K_F2_ :: 0xffbf

// key event being handled (each_caret callbacks can't capture it)
kev: Ev

COMMANDS := [?]Cmd {
	// files / view
	{"ファイルを開く", 'p', {.Ctrl}, proc(b: ^Buffer) {open_files_picker()}, false},
	{"コマンドパレット", 'p', {.Ctrl, .Shift}, proc(b: ^Buffer) {open_palette()}, false},
	{"プロジェクト内を検索", 'f', {.Ctrl, .Shift}, proc(b: ^Buffer) {open_search()}, false},
	{"保存", 's', {.Ctrl}, proc(b: ^Buffer) {save(b)}, true},
	{"すべて保存", 's', {.Ctrl, .Alt}, proc(b: ^Buffer) {for x in app.bufs do if x.dirty do save(x)}, false},
	{"タブを閉じる", 'w', {.Ctrl}, proc(b: ^Buffer) {close_tab(app.active)}, false},
	{"次のタブ", K_TAB, {.Ctrl}, proc(b: ^Buffer) {cycle_tab(1)}, false},
	{"前のタブ", K_ISO_LEFT_TAB, {.Ctrl, .Shift}, proc(b: ^Buffer) {cycle_tab(-1)}, false},
	{"プロジェクトパネルの表示切替", 'b', {.Ctrl}, proc(b: ^Buffer) {app.panel_on = !app.panel_on}, false},
	{"ミニマップの表示切替", 'm', {.Ctrl, .Alt}, proc(b: ^Buffer) {app.minimap = !app.minimap}, false},
	{"文字を大きく", '=', {.Ctrl}, proc(b: ^Buffer) {zed.font_size = min(zed.font_size + 1, 48)}, false},
	{"文字を大きく", '+', {.Ctrl, .Shift}, proc(b: ^Buffer) {zed.font_size = min(zed.font_size + 1, 48)}, false},
	{"文字を小さく", '-', {.Ctrl}, proc(b: ^Buffer) {zed.font_size = max(zed.font_size - 1, 8)}, false},
	{"戻る", K_LEFT, {.Alt}, proc(b: ^Buffer) {nav_back()}, false},
	{"進む", K_RIGHT, {.Alt}, proc(b: ^Buffer) {nav_forward()}, false},
	{"終了", 'q', {.Ctrl}, proc(b: ^Buffer) {app.running = false}, false},
	// editing
	{"元に戻す", 'z', {.Ctrl}, proc(b: ^Buffer) {clear(&b.extra); undo(b); ensure_visible(b)}, true},
	{"やり直し", 'z', {.Ctrl, .Shift}, proc(b: ^Buffer) {clear(&b.extra); undo(b, redo = true); ensure_visible(b)}, true},
	{"やり直し", 'y', {.Ctrl}, proc(b: ^Buffer) {clear(&b.extra); undo(b, redo = true); ensure_visible(b)}, true},
	{"すべて選択", 'a', {.Ctrl}, proc(b: ^Buffer) {
			clear(&b.extra)
			b.anchor = {}
			b.cur = {len(b.lines) - 1, len(b.lines[len(b.lines) - 1])}
		}, true},
	{"コピー", 'c', {.Ctrl}, proc(b: ^Buffer) {copy_sel(b, false)}, true},
	{"切り取り", 'x', {.Ctrl}, proc(b: ^Buffer) {copy_sel(b, true)}, true},
	{"貼り付け", 'v', {.Ctrl}, proc(b: ^Buffer) {paste(b)}, true},
	{"行コメントの切替", '/', {.Ctrl}, proc(b: ^Buffer) {each_caret(b, toggle_comment)}, true},
	{"行を削除", 'k', {.Ctrl, .Shift}, proc(b: ^Buffer) {each_caret(b, delete_line)}, true},
	{"行を複製", 'd', {.Ctrl, .Shift}, proc(b: ^Buffer) {each_caret(b, duplicate_line)}, true},
	{"行を上へ移動", K_UP, {.Alt}, proc(b: ^Buffer) {move_lines(b, -1)}, true},
	{"行を下へ移動", K_DOWN, {.Alt}, proc(b: ^Buffer) {move_lines(b, 1)}, true},
	{"次の一致もカーソルで選択", 'd', {.Ctrl}, proc(b: ^Buffer) {add_next_occurrence(b)}, true},
	{"すべての一致をカーソルで選択", 'l', {.Ctrl, .Shift}, proc(b: ^Buffer) {select_all_occurrences(b)}, true},
	{"上にカーソルを追加", K_UP, {.Ctrl, .Alt}, proc(b: ^Buffer) {add_caret_vertical(b, -1)}, true},
	{"下にカーソルを追加", K_DOWN, {.Ctrl, .Alt}, proc(b: ^Buffer) {add_caret_vertical(b, 1)}, true},
	{"フォーマット", 'i', {.Ctrl, .Shift}, proc(b: ^Buffer) {if !lsp_format_only(b) do toast("フォーマッタがありません")}, true},
	{"行末の空白を削除", 0, {}, proc(b: ^Buffer) {trim_trailing(b)}, true},
	// search
	{"検索", 'f', {.Ctrl}, proc(b: ^Buffer) {start_input(b, .Find)}, true},
	{"置換", 'h', {.Ctrl}, proc(b: ^Buffer) {start_input(b, .Replace)}, true},
	{"行へ移動", 'g', {.Ctrl}, proc(b: ^Buffer) {start_input(b, .Line)}, true},
	{"次を検索", K_F3, {}, proc(b: ^Buffer) {find_next(b, false)}, true},
	{"前を検索", K_F3, {.Shift}, proc(b: ^Buffer) {find_next(b, true)}, true},
	// language server
	{"定義へ移動", K_F12, {}, proc(b: ^Buffer) {if !lsp_definition(b, b.cur) do no_server()}, true},
	{"参照を検索", K_F12, {.Shift}, proc(b: ^Buffer) {if !lsp_references(b, b.cur) do no_server()}, true},
	{"シンボルの名前を変更", K_F2_, {}, proc(b: ^Buffer) {start_input(b, .Rename)}, true},
	{"コードアクション", '.', {.Ctrl}, proc(b: ^Buffer) {if !lsp_code_actions(b) do no_server()}, true},
	{"ファイル内のシンボル", 'o', {.Ctrl, .Shift}, proc(b: ^Buffer) {if !lsp_symbols(b) do no_server()}, true},
	{"診断の一覧", 'm', {.Ctrl, .Shift}, proc(b: ^Buffer) {diagnostics_picker(b)}, true},
	{"ホバー情報", 'k', {.Ctrl}, proc(b: ^Buffer) {app.hover_pos = b.cur; lsp_hover(b, b.cur)}, true},
	{"補完", ' ', {.Ctrl}, proc(b: ^Buffer) {if !lsp_completion(b) do no_server()}, true},
	{"引数のヒント", ' ', {.Ctrl, .Shift}, proc(b: ^Buffer) {lsp_signature(b)}, true},
}

no_server :: proc() {toast("このファイルの言語サーバーが動いていません")}

key_label :: proc(c: Cmd) -> string {
	if c.key == 0 do return ""
	sb := strings.builder_make(context.temp_allocator)
	if .Ctrl in c.mods do strings.write_string(&sb, "Ctrl+")
	if .Alt in c.mods do strings.write_string(&sb, "Alt+")
	if .Shift in c.mods do strings.write_string(&sb, "Shift+")
	switch c.key {
	case K_TAB, K_ISO_LEFT_TAB: strings.write_string(&sb, "Tab")
	case K_UP: strings.write_string(&sb, "↑")
	case K_DOWN: strings.write_string(&sb, "↓")
	case K_LEFT: strings.write_string(&sb, "←")
	case K_RIGHT: strings.write_string(&sb, "→")
	case K_F3: strings.write_string(&sb, "F3")
	case K_F12: strings.write_string(&sb, "F12")
	case K_F2_: strings.write_string(&sb, "F2")
	case ' ': strings.write_string(&sb, "Space")
	case: strings.write_rune(&sb, rune(c.key) - 32 if c.key >= 'a' && c.key <= 'z' else rune(c.key))
	}
	return strings.to_string(sb)
}

run_cmd :: proc(c: Cmd) {
	b := cur_buf()
	if c.need_buf && b == nil do return
	c.run(b)
}

cycle_tab :: proc(d: int) {
	if len(app.bufs) == 0 do return
	app.active = (app.active + d + len(app.bufs)) % len(app.bufs)
	app.comp_on = false
}

// ---------------------------------------------------------------------------

on_key :: proc(ev: Ev) {
	kev = ev
	b := cur_buf()
	// popups that eat keys first
	if app.mode == .Edit && app.comp_on && b != nil {
		n := len(app.shown)
		switch ev.key {
		case K_UP: app.comp_sel = (app.comp_sel + n - 1) % n; return
		case K_DOWN: app.comp_sel = (app.comp_sel + 1) % n; return
		case K_RETURN, K_KP_ENTER, K_TAB: accept_completion(b); return
		case K_ESCAPE: app.comp_on = false; return
		}
	}
	mods := ev.mods
	for c in COMMANDS {
		if c.key != 0 && c.key == ev.key && c.mods == mods {
			// in an input bar, plain editing shortcuts belong to the bar
			if app.mode != .Edit && c.key != 'p' && c.key != 'q' && c.key != 'w' && c.key != 'b' do break
			app.hover = ""
			run_cmd(c)
			return
		}
	}
	if app.mode != .Edit {
		mode_key(ev, b)
		return
	}
	if b == nil do return
	app.hover = ""
	if ev.key != 'w' do app.close_armed = nil
	switch ev.key {
	case K_ESCAPE:
		if len(b.extra) > 0 do clear(&b.extra)
		else do b.anchor = b.cur
		app.sig = ""
	case K_LEFT, K_RIGHT, K_UP, K_DOWN, K_PAGEUP, K_PAGEDOWN, K_HOME, K_END, K_BACKSPACE, K_DELETE, K_RETURN, K_KP_ENTER, K_TAB, K_ISO_LEFT_TAB:
		if len(b.extra) > 0 do b.want_x = -1
		each_caret(b, caret_key)
		if b.cur.line != app.sig_line do app.sig = ""
	case:
		if .Ctrl in mods || .Alt in mods || ev.text == "" do return
		ktext = ev.text
		each_caret(b, proc(b: ^Buffer) {insert_text(b, ktext)})
		after_typing(b, ev.text)
	}
}

ktext: string

// One caret's reaction to a navigation / editing key (kev).
caret_key :: proc(b: ^Buffer) {
	ctrl, shift := .Ctrl in kev.mods, .Shift in kev.mods
	want := b.want_x if b.want_x >= 0 else x_in_line(b, b.cur.line, b.cur.col)
	vert :: proc(b: ^Buffer, line: int, want: f32, shift: bool) {
		line := clamp(line, 0, len(b.lines) - 1)
		go(b, {line, col_at_x(b, line, want)}, shift, keep_x = true)
		b.want_x = want
	}
	a, z := order(b.anchor, b.cur)
	switch kev.key {
	case K_LEFT:
		p := word_left(b, b.cur) if ctrl else prev_col(b, b.cur)
		if has_sel(b) && !shift && !ctrl do p = a
		go(b, p, shift)
	case K_RIGHT:
		p := word_right(b, b.cur) if ctrl else next_col(b, b.cur)
		if has_sel(b) && !shift && !ctrl do p = z
		go(b, p, shift)
	case K_UP:
		if ctrl do b.scroll_y = max(b.scroll_y - 1, 0)
		else do vert(b, b.cur.line - 1, want, shift)
	case K_DOWN:
		if ctrl do b.scroll_y = min(b.scroll_y + 1, f32(len(b.lines) - 1))
		else do vert(b, b.cur.line + 1, want, shift)
	case K_PAGEUP:
		vert(b, b.cur.line - int(rows()) + 2, want, shift)
	case K_PAGEDOWN:
		vert(b, b.cur.line + int(rows()) - 2, want, shift)
	case K_HOME:
		if ctrl do go(b, {}, shift)
		else {
			ind := len(indent_of(b, b.cur.line))
			go(b, {b.cur.line, 0 if b.cur.col == ind else ind}, shift) // smart home
		}
	case K_END:
		if ctrl do go(b, {len(b.lines) - 1, len(b.lines[len(b.lines) - 1])}, shift)
		else do go(b, {b.cur.line, len(b.lines[b.cur.line])}, shift)
	case K_BACKSPACE:
		backspace(b, ctrl)
	case K_DELETE:
		if has_sel(b) do go(b, replace(b, b.anchor, b.cur, ""), false)
		else do go(b, replace(b, b.cur, word_right(b, b.cur) if ctrl else next_col(b, b.cur), ""), false)
	case K_RETURN, K_KP_ENTER:
		newline(b)
	case K_TAB, K_ISO_LEFT_TAB:
		if shift || kev.key == K_ISO_LEFT_TAB do shift_lines(b, true)
		else if a.line != z.line do shift_lines(b, false)
		else if b.hard_tabs do insert_text(b, "\t")
		else {
			c := int(x_in_line(b, b.cur.line, b.cur.col) / app.cell_w)
			insert_text(b, strings.repeat(" ", b.tab_size - c % b.tab_size, context.temp_allocator))
		}
	}
}

after_typing :: proc(b: ^Buffer, s: string) {
	if is_sig_trigger(b, s) {
		app.sig_line = b.cur.line
		lsp_signature(b)
	}
	if s == ")" do app.sig = ""
	if len(b.extra) > 0 do return // completion with several carets: not supported
	srv := lsp_for(b)
	if srv == nil || !srv.ready do return
	trigger := slice.contains(srv.triggers[:], s)
	if trigger || (is_word_byte(s[0]) && !app.comp_on) {
		lsp_completion(b)
	} else if app.comp_on {
		if is_word_byte(s[0]) do filter_completions()
		else do app.comp_on = false
	}
}

// ---------------------------------------------------------------------------
// Clipboard with several carets: one line per caret, pasted back one per caret.

copy_sel :: proc(b: ^Buffer, cut: bool) {
	if len(b.extra) > 0 {
		all := make([dynamic][2]Pos, context.temp_allocator)
		append(&all, [2]Pos{b.anchor, b.cur})
		append(&all, ..b.extra[:])
		slice.sort_by(all[:], proc(x, y: [2]Pos) -> bool {return lt(x[1], y[1])})
		parts := make([dynamic]string, context.temp_allocator)
		for c in all do append(&parts, text_range(b, c[0], c[1]))
		plat_set_clipboard_text(strings.join(parts[:], "\n", context.temp_allocator))
		if cut do each_caret(b, proc(b: ^Buffer) {go(b, replace(b, b.anchor, b.cur, ""), false)})
		return
	}
	if has_sel(b) {
		plat_set_clipboard_text(text_range(b, b.anchor, b.cur))
		if cut do go(b, replace(b, b.anchor, b.cur, ""), false)
		return
	}
	// no selection: the whole line, like Zed
	plat_set_clipboard_text(strings.concatenate({line_str(b, b.cur.line), "\n"}, context.temp_allocator))
	if cut do delete_line(b)
}

paste_parts: []string

paste :: proc(b: ^Buffer) {
	t := plat_get_clipboard_text()
	if t == "" do return
	t, _ = strings.remove_all(t, "\r", context.temp_allocator)
	paste_parts = {t}
	if parts := strings.split(strings.trim_suffix(t, "\n"), "\n", context.temp_allocator); len(b.extra) > 0 && len(parts) == len(b.extra) + 1 {
		paste_parts = parts
	}
	each_caret(b, proc(b: ^Buffer) {
		text := paste_parts[0]
		if len(paste_parts) > 1 {
			// this caret's rank from the top picks its line
			rank := 0
			for c, i in b.carets do if i != b.active_caret && lt(c[1], b.cur) do rank += 1
			text = paste_parts[min(rank, len(paste_parts) - 1)]
		}
		go(b, replace(b, b.anchor, b.cur, text), false)
	})
}

duplicate_line :: proc(b: ^Buffer) {
	l := b.cur.line
	replace(b, {l, len(b.lines[l])}, {l, len(b.lines[l])}, strings.concatenate({"\n", line_str(b, l)}, context.temp_allocator))
	go(b, {l + 1, b.cur.col}, false)
}

move_lines :: proc(b: ^Buffer, d: int) {
	clear(&b.extra)
	a, z := order(b.anchor, b.cur)
	last := z.line if z.col > 0 || z.line == a.line else z.line - 1
	if (d < 0 && a.line == 0) || (d > 0 && last + 1 >= len(b.lines)) do return
	block := text_range(b, {a.line, 0}, {last, len(b.lines[last])})
	if d < 0 {
		above := strings.clone(line_str(b, a.line - 1), context.temp_allocator)
		replace(b, {a.line - 1, 0}, {last, len(b.lines[last])}, strings.concatenate({block, "\n", above}, context.temp_allocator))
	} else {
		below := strings.clone(line_str(b, last + 1), context.temp_allocator)
		replace(b, {a.line, 0}, {last + 1, len(b.lines[last + 1])}, strings.concatenate({below, "\n", block}, context.temp_allocator))
	}
	b.anchor.line += d
	b.cur.line += d
	ensure_visible(b)
}

trim_trailing :: proc(b: ^Buffer) {
	first := true
	for l in 0 ..< len(b.lines) {
		s := line_str(b, l)
		t := strings.trim_right(s, " \t")
		if len(t) < len(s) {
			replace(b, {l, len(t)}, {l, len(s)}, "", merge = !first)
			first = false
		}
	}
	b.cur, b.anchor = clamp_pos(b, b.cur), clamp_pos(b, b.anchor)
}

lsp_format_only :: proc(b: ^Buffer) -> bool {
	if !lsp_format(b) do return false
	app.format_only[b] = true
	return true
}

// ---------------------------------------------------------------------------
// Input bars: find, replace, go to line, rename

start_input :: proc(b: ^Buffer, m: Mode) {
	app.mode = m
	app.field = 0
	clear(&app.input)
	switch m {
	case .Find, .Replace:
		if has_sel(b) && b.anchor.line == b.cur.line do append(&app.input, text_range(b, b.anchor, b.cur))
		app.find_origin = b.cur
	case .Rename:
		a, z := word_at(b, b.cur)
		app.rename_pos = a
		append(&app.input, text_range(b, a, z))
	case .Line, .Edit, .Picker:
	}
}

field_buf :: proc() -> ^[dynamic]u8 {return &app.input2 if app.mode == .Replace && app.field == 1 else &app.input}

mode_key :: proc(ev: Ev, b: ^Buffer) {
	f := field_buf()
	changed := false
	switch ev.key {
	case K_ESCAPE:
		app.mode = .Edit
		return
	case K_BACKSPACE:
		if len(f) > 0 {
			_, n := utf8.decode_last_rune(f[:])
			resize(f, len(f) - n)
			changed = true
		}
	case K_TAB, K_ISO_LEFT_TAB:
		if app.mode == .Replace do app.field = 1 - app.field
	case K_UP, K_PAGEUP:
		app.sel_idx = max(app.sel_idx - (10 if ev.key == K_PAGEUP else 1), 0)
	case K_DOWN, K_PAGEDOWN:
		app.sel_idx = min(app.sel_idx + (10 if ev.key == K_PAGEDOWN else 1), max(len(app.hits) - 1, 0))
	case K_RETURN, K_KP_ENTER:
		submit_input(b, ev.mods)
		return
	case:
		if .Ctrl in ev.mods && ev.key == 'v' {
			t := plat_get_clipboard_text()
			if i := strings.index_byte(t, '\n'); i >= 0 do t = t[:i]
			append(f, t)
			changed = true
		} else if ev.text != "" && .Ctrl not_in ev.mods {
			append(f, ev.text)
			changed = true
		}
	}
	if changed do input_changed(b)
}

input_changed :: proc(b: ^Buffer) {
	switch app.mode {
	case .Picker:
		refilter_picker()
	case .Find, .Replace:
		// incremental search from where the search started
		if b != nil && app.field == 0 {
			b.cur, b.anchor = app.find_origin, app.find_origin
			if len(app.input) > 0 do find_next(b, false, quiet = true)
		}
	case .Line, .Rename, .Edit:
	}
}

on_text :: proc(t: string) {
	if app.mode != .Edit {
		append(field_buf(), t)
		input_changed(cur_buf())
		return
	}
	if b := cur_buf(); b != nil {
		ktext = t
		each_caret(b, proc(b: ^Buffer) {insert_text(b, ktext)})
	}
}

submit_input :: proc(b: ^Buffer, mods: Mods) {
	q := string(app.input[:])
	switch app.mode {
	case .Picker:
		picker_choose(app.sel_idx)
	case .Find:
		if b != nil do find_next(b, .Shift in mods)
	case .Replace:
		if b == nil do return
		if .Ctrl in mods do replace_all(b)
		else do replace_one(b)
	case .Line:
		app.mode = .Edit
		if b == nil do return
		parts := strings.split(q, ":", context.temp_allocator)
		l, ok := strconv.parse_int(strings.trim_space(parts[0]))
		if !ok do return
		c := 0
		if len(parts) > 1 do c, _ = strconv.parse_int(strings.trim_space(parts[1]))
		push_nav()
		line := clamp(l - 1, 0, len(b.lines) - 1)
		col_ := 0
		// column counts characters, like the status bar
		for _, i in line_str(b, line) {
			if c <= 1 do break
			c -= 1
			col_ = i
		}
		if c > 1 || col_ > 0 do col_ = min(next_col(b, {line, col_}).col, len(b.lines[line]))
		go(b, {line, col_}, false)
		b.scroll_y = max(f32(line) - rows() / 3, 0)
	case .Rename:
		app.mode = .Edit
		if b != nil && q != "" do lsp_rename(b, app.rename_pos, q)
	case .Edit:
	}
}

replace_one :: proc(b: ^Buffer) {
	needle := strings.to_lower(string(app.input[:]), context.temp_allocator)
	if needle == "" do return
	if has_sel(b) && strings.to_lower(text_range(b, b.anchor, b.cur), context.temp_allocator) == needle {
		go(b, replace(b, b.anchor, b.cur, string(app.input2[:])), false)
	}
	find_next(b, false)
}

replace_all :: proc(b: ^Buffer) {
	needle := strings.to_lower(string(app.input[:]), context.temp_allocator)
	if needle == "" do return
	with := string(app.input2[:])
	n := 0
	// bottom-up so earlier matches keep their positions; one undo step
	for l := len(b.lines) - 1; l >= 0; l -= 1 {
		low := strings.to_lower(line_str(b, l), context.temp_allocator)
		end := len(low)
		for {
			j := strings.last_index(low[:end], needle)
			if j < 0 do break
			replace(b, {l, j}, {l, j + len(needle)}, with, merge = n > 0)
			n += 1
			end = j
		}
	}
	b.cur, b.anchor = clamp_pos(b, b.cur), clamp_pos(b, b.cur)
	toast(fmt.tprintf("%d 件置換しました", n))
}
