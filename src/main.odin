package main

// Seoritsu: a translucent code editor that borrows Zed's settings, extensions and
// language servers. Pure Odin on raw Wayland (shared with Ame-FileManager).

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

Mode :: enum {Edit, Find, Replace, Line, Rename, Picker, New_File, New_Dir, Rename_File}

Node :: struct {
	path, name: string,
	depth:      int,
	dir:        bool,
}

app: struct {
	bufs:                    [dynamic]^Buffer,
	active:                  int,
	running:                 bool,
	S:                       f32,
	W, H:                    f32,
	// layout, px (recomputed every frame)
	fs, ui:                  i32,
	line_h, cell_w:          f32,
	titlebar, tabbar, crumbs: Rect,
	editor, gutter:          Rect,
	text, panel, status:     Rect,
	// mouse
	mx, my:                  f32,
	selecting:               bool,
	panel_on:                bool,
	panel_scroll:            f32,
	panel_focus:             bool, // arrow keys / a / r / Delete act on the project panel
	panel_sel:               int,
	panel_target:            string, // file op in progress: folder (new) or path (rename)
	trash_armed:             string,
	tree:                    [dynamic]Node,
	expanded:                map[string]bool,
	// popups
	comps:                   [dynamic]Completion_Item,
	shown:                   [dynamic]int,
	comp_sel:                int,
	comp_on:                 bool,
	hover:                   string,
	hover_pos:               Pos,
	hover_since:             i64,
	hover_asked:             bool,
	toast:                   string,
	toast_until:             i64,
	mode:                    Mode,
	input:                   [dynamic]u8,
	files:                   [dynamic]string,
	hits:                    [dynamic]int,
	sel_idx:                 int,
	preedit:                 string,
	saving:                  map[^Buffer]i64, // waiting for format-on-save, with a deadline
	format_only:             map[^Buffer]bool, // formatting without saving
	picks:                   [dynamic]Pick,
	pick_kind:               Picker_Kind,
	pick_title:              string,
	search_due:              i64,
	input2:                  [dynamic]u8, // replace-with field
	field:                   int,
	find_origin, rename_pos: Pos,
	nav:                     [dynamic]Loc,
	nav_i:                   int,
	sig:                     string, // signature help shown above the caret
	sig_line:                int,
	minimap:                 bool,
	minimap_drag:            bool,
	session_dirty:           bool,
	close_armed:             ^Buffer,
}

SKIP_DIRS :: []string{".git", "node_modules", "target", "zig-cache", ".zig-cache", "zig-out", ".next", ".turbo", "__pycache__", ".svn", ".hg", ".jj"}

// ---------------------------------------------------------------------------
// Callbacks used by the LSP client

cur_buf :: proc() -> ^Buffer {return app.bufs[app.active] if app.active < len(app.bufs) else nil}

buffer_alive :: proc(b: ^Buffer) -> bool {return slice.contains(app.bufs[:], b)}

find_buffer :: proc(path: string) -> ^Buffer {
	for b in app.bufs do if b.path == path do return b
	return nil
}

toast :: proc(msg: string) {
	delete(app.toast)
	app.toast = strings.clone(msg)
	app.toast_until = ticks_ms() + 4000
}

set_completions :: proc(list: [dynamic]Completion_Item) {
	for c in app.comps {
		delete(c.label); delete(c.detail); delete(c.insert)
		if raw_data(c.filter) != raw_data(c.label) do delete(c.filter)
		if raw_data(c.sort) != raw_data(c.label) do delete(c.sort)
	}
	delete(app.comps)
	app.comps = list
	app.comp_on = true
	filter_completions()
}

show_hover :: proc(text: string) {
	delete(app.hover)
	// drop markdown code fences, keep the content
	sb := strings.builder_make()
	for line in strings.split_lines(strings.trim_space(text), context.temp_allocator) {
		if strings.has_prefix(line, "```") do continue
		strings.write_string(&sb, line)
		strings.write_byte(&sb, '\n')
	}
	app.hover = strings.trim_space(strings.to_string(sb))
}

goto_location :: proc(path: string, line, col: int, utf16: bool) {
	push_nav()
	b := open_file(path)
	if b == nil do return
	clear(&b.extra)
	p := from_lsp_col(b, line, col, utf16)
	b.cur, b.anchor = p, p
	b.scroll_y = max(f32(p.line) - rows() / 3, 0)
	app.hover = ""
}

finish_save :: proc(b: ^Buffer) {
	delete_key(&app.saving, b)
	if buffer_save(b) {
		lsp_saved(b)
		git_refresh(b)
		git_status_refresh()
	} else {
		toast(fmt.tprintf("保存できませんでした: %s", b.path))
	}
}

// ---------------------------------------------------------------------------
// Files

open_file :: proc(path: string) -> ^Buffer {
	abs, _ := filepath.abs(path, context.temp_allocator)
	for b, i in app.bufs do if b.path == abs {
		app.active = i
		return b
	}
	b, ok := buffer_load(abs)
	if !ok {
		toast(fmt.tprintf("開けません: %s", path))
		return nil
	}
	append(&app.bufs, b)
	app.active = len(app.bufs) - 1
	git_refresh(b)
	lsp_open(b) // starts the server; the document is opened once it is ready
	return b
}

close_tab :: proc(i: int) {
	if i >= len(app.bufs) do return
	b := app.bufs[i]
	if b.dirty && app.close_armed != b {
		app.close_armed = b
		toast("未保存の変更があります。もう一度閉じると破棄します (Ctrl+S で保存)")
		return
	}
	app.close_armed = nil
	lsp_close(b)
	delete_key(&app.saving, b)
	ordered_remove(&app.bufs, i)
	if app.active >= len(app.bufs) do app.active = max(len(app.bufs) - 1, 0)
	app.comp_on = false
}

save :: proc(b: ^Buffer) {
	if zed.format_save && lsp_format(b) {
		app.saving[b] = ticks_ms() + 2000
	} else {
		finish_save(b)
	}
}

// Zed's "autosave": on focus loss / quit, write what changed.
autosave_all :: proc() {
	for b in app.bufs do if b.dirty && os.exists(b.path) do finish_save(b)
}

rebuild_tree :: proc() {
	clear(&app.tree)
	walk :: proc(dir: string, depth: int) {
		ents, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return
		slice.sort_by(ents, proc(a, b: os.File_Info) -> bool {
			ad, bd := a.type == .Directory, b.type == .Directory
			if ad != bd do return ad
			return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
		})
		for e in ents {
			if slice.contains(SKIP_DIRS, e.name) do continue
			dir := e.type == .Directory
			append(&app.tree, Node{strings.clone(e.fullpath), strings.clone(e.name), depth, dir})
			if dir && app.expanded[e.fullpath] do walk(e.fullpath, depth + 1)
		}
	}
	walk(project_root, 0)
}

collect_files :: proc() {
	if len(app.files) > 0 do return
	walk :: proc(dir: string) {
		ents, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return
		for e in ents {
			if len(app.files) > 50000 do return
			if slice.contains(SKIP_DIRS, e.name) do continue
			if e.type == .Directory {
				walk(e.fullpath)
			} else {
				append(&app.files, strings.clone(e.fullpath))
			}
		}
	}
	walk(project_root)
}

// Subsequence match; lower score is better (spread of the match + length).
fuzzy :: proc(hay, needle: string) -> (score: int, ok: bool) {
	if needle == "" do return len(hay), true
	h := strings.to_lower(hay, context.temp_allocator)
	n := strings.to_lower(needle, context.temp_allocator)
	j, first, last := 0, -1, 0
	for i in 0 ..< len(h) {
		if j < len(n) && h[i] == n[j] {
			if first < 0 do first = i
			last = i
			j += 1
		}
	}
	if j < len(n) do return 0, false
	return (last - first) * 4 + len(h) - (100 if strings.contains(h, n) else 0), true
}

filter_completions :: proc() {
	clear(&app.shown)
	b := cur_buf()
	if b == nil do return
	a, _ := word_at(b, b.cur)
	prefix := string(b.lines[b.cur.line][a.col:b.cur.col])
	for c, i in app.comps {
		if _, ok := fuzzy(c.filter, prefix); ok do append(&app.shown, i)
		if len(app.shown) >= 200 do break
	}
	app.comp_sel = 0
	if len(app.shown) == 0 do app.comp_on = false
}

// ---------------------------------------------------------------------------
// Geometry

rows :: proc() -> f32 {return max(app.text.h / app.line_h, 1)}

// Inlay hints of one line (b.hints is sorted).
hints_of :: proc(b: ^Buffer, line: int) -> []Hint {
	lo, hi := 0, len(b.hints)
	for lo < hi {
		m := (lo + hi) / 2
		if int(b.hints[m].line) < line do lo = m + 1
		else do hi = m
	}
	e := lo
	for e < len(b.hints) && int(b.hints[e].line) == line do e += 1
	return b.hints[lo:e]
}

hint_fs :: proc() -> i32 {return max(app.fs - i32(2 * app.S), 8)}
hint_w :: proc(h: Hint) -> f32 {return f32(text_width(h.label, hint_fs(), false)) + 6 * app.S}

// x of a column; inlay hints before that column take room, the caret sits before a hint
x_in_line :: proc(b: ^Buffer, line, col: int) -> f32 {
	x: f32
	tabw := f32(b.tab_size) * app.cell_w
	hs := hints_of(b, line)
	for r, i in line_str(b, line) {
		if i >= col do break
		for len(hs) > 0 && int(hs[0].col) <= i {
			if int(hs[0].col) == i do x += hint_w(hs[0])
			hs = hs[1:]
		}
		x = (math.floor(x / tabw) + 1) * tabw if r == '\t' else x + f32(get_glyph(r, app.fs).adv)
	}
	return x
}

col_at_x :: proc(b: ^Buffer, line: int, x: f32) -> int {
	cx: f32
	tabw := f32(b.tab_size) * app.cell_w
	hs := hints_of(b, line)
	for r, i in line_str(b, line) {
		for len(hs) > 0 && int(hs[0].col) <= i {
			if int(hs[0].col) == i do cx += hint_w(hs[0])
			hs = hs[1:]
		}
		nx := (math.floor(cx / tabw) + 1) * tabw if r == '\t' else cx + f32(get_glyph(r, app.fs).adv)
		if x < (cx + nx) / 2 do return i
		cx = nx
	}
	return len(b.lines[line])
}

pos_at :: proc(b: ^Buffer, x, y: f32) -> Pos {
	line := clamp(int(math.floor((y - app.text.y) / app.line_h + b.scroll_y)), 0, len(b.lines) - 1)
	return {line, col_at_x(b, line, x - app.text.x + b.scroll_x)}
}

ensure_visible :: proc(b: ^Buffer) {
	l := f32(b.cur.line)
	if l < b.scroll_y do b.scroll_y = l
	if l > b.scroll_y + rows() - 2 do b.scroll_y = l - rows() + 2
	cx := x_in_line(b, b.cur.line, b.cur.col)
	if cx - b.scroll_x > app.text.w - 3 * app.cell_w do b.scroll_x = cx - app.text.w + 6 * app.cell_w
	if cx < b.scroll_x do b.scroll_x = max(cx - 6 * app.cell_w, 0)
}

layout :: proc() {
	S := app.S
	app.fs = i32(f32(zed.font_size) * S)
	app.ui = i32(f32(zed.ui_font_size) * S)
	app.line_h = math.round(f32(app.fs) * 1.5)
	app.cell_w = f32(get_glyph('M', app.fs).adv)
	title_h, tab_h, crumb_h, status_h := math.round(34 * S), math.round(36 * S), math.round(28 * S), math.round(26 * S)
	pw: f32 = math.round(250 * S) if app.panel_on else 0
	app.titlebar = {0, 0, app.W, title_h}
	app.panel = {0, title_h, pw, app.H - title_h - status_h}
	app.tabbar = {pw, title_h, app.W - pw, tab_h}
	app.crumbs = {pw, title_h + tab_h, app.W - pw, crumb_h if len(app.bufs) > 0 else 0}
	app.status = {0, app.H - status_h, app.W, status_h}
	top := app.crumbs.y + app.crumbs.h
	app.editor = {pw, top, app.W - pw, app.H - top - status_h}
	digits := 3
	if b := cur_buf(); b != nil do digits = max(len(fmt.tprint(len(b.lines))), 3)
	gw := f32(digits + 3) * app.cell_w
	app.gutter = {app.editor.x, app.editor.y, gw, app.editor.h}
	app.text = {app.editor.x + gw + math.round(6 * S), app.editor.y, app.editor.w - gw - math.round(6 * S) - minimap_w(), app.editor.h}
}

// ---------------------------------------------------------------------------
// Editing commands

indent_unit :: proc(b: ^Buffer) -> string {
	return "\t" if b.hard_tabs else strings.repeat(" ", b.tab_size, context.temp_allocator)
}

go :: proc(b: ^Buffer, p: Pos, extend: bool, keep_x := false) {
	b.cur = clamp_pos(b, p)
	if !extend do b.anchor = b.cur
	if !keep_x do b.want_x = -1
	ensure_visible(b)
}

CLOSERS :: ")]}\"'`"

insert_text :: proc(b: ^Buffer, s: string) {
	typed_one := utf8.rune_count(s) == 1
	a, z := order(b.anchor, b.cur)
	line := b.lines[z.line][:]
	next: u8 = line[z.col] if z.col < len(line) else 0
	if typed_one && !has_sel(b) {
		c := s[0]
		// typing a closer that is already there just steps over it
		if strings.index_byte(CLOSERS, c) >= 0 && next == c {
			go(b, {z.line, z.col + 1}, false)
			return
		}
		OPEN :: "([{\"`"
		k := strings.index_byte(OPEN, c)
		CLOSE := ")]}\"`"
		close: u8 = CLOSE[k] if k >= 0 else 0
		if k >= 0 && (next == 0 || next == ' ' || strings.index_byte(CLOSERS, next) >= 0 || next == ';' || next == ',') {
			prev: u8 = line[z.col - 1] if z.col > 0 else 0
			if !(c == close && is_word_byte(prev)) {
				p := replace(b, a, z, fmt.tprintf("%c%c", c, close), merge = true)
				go(b, {p.line, p.col - 1}, false)
				return
			}
		}
	}
	p := replace(b, a, z, s, merge = typed_one && !has_sel(b))
	go(b, p, false)
}

newline :: proc(b: ^Buffer) {
	a, z := order(b.anchor, b.cur)
	ind := indent_of(b, a.line)
	if len(ind) > a.col do ind = ind[:a.col]
	line := b.lines[a.line][:]
	prev: u8 = line[a.col - 1] if a.col > 0 else 0
	next: u8 = line[z.col] if z.col < len(line) else 0
	if strings.index_byte("{[(", prev) >= 0 && prev != 0 {
		inner := strings.concatenate({ind, indent_unit(b)}, context.temp_allocator)
		if (prev == '{' && next == '}') || (prev == '[' && next == ']') || (prev == '(' && next == ')') {
			replace(b, a, z, strings.concatenate({"\n", inner, "\n", ind}, context.temp_allocator))
			go(b, {a.line + 1, len(inner)}, false)
			return
		}
		ind = inner
	}
	p := replace(b, a, z, strings.concatenate({"\n", ind}, context.temp_allocator))
	go(b, p, false)
}

backspace :: proc(b: ^Buffer, word: bool) {
	if has_sel(b) {
		go(b, replace(b, b.anchor, b.cur, ""), false)
		return
	}
	p := b.cur
	start := word_left(b, p) if word else prev_col(b, p)
	line := b.lines[p.line][:]
	if !word && p.col > 0 {
		// inside leading spaces: back to the previous tab stop
		ind := indent_of(b, p.line)
		if p.col <= len(ind) && !b.hard_tabs && strings.count(ind[:p.col], " ") == p.col {
			start.col = (p.col - 1) / b.tab_size * b.tab_size
		}
		// empty pair: () [] {} "" ''
		if p.col < len(line) {
			pr := string(line[p.col - 1:p.col + 1])
			if pr == "()" || pr == "[]" || pr == "{}" || pr == `""` || pr == "''" || pr == "``" {
				go(b, replace(b, {p.line, p.col - 1}, {p.line, p.col + 1}, ""), false)
				return
			}
		}
	}
	go(b, replace(b, start, p, "", merge = !word), false)
}

// Indent / outdent every line touched by the selection.
shift_lines :: proc(b: ^Buffer, out: bool) {
	a, z := order(b.anchor, b.cur)
	unit := indent_unit(b)
	first := true
	for l in a.line ..= z.line {
		if l == z.line && z.col == 0 && z.line > a.line do break
		if out {
			s := line_str(b, l)
			n := 0
			if strings.has_prefix(s, "\t") do n = 1
			else do for n < b.tab_size && n < len(s) && s[n] == ' ' do n += 1
			if n > 0 do replace(b, {l, 0}, {l, n}, "", merge = !first)
		} else if len(b.lines[l]) > 0 {
			replace(b, {l, 0}, {l, 0}, unit, merge = !first)
		}
		first = false
	}
	b.anchor = {a.line, 0}
	b.cur = {z.line, len(b.lines[z.line])}
}

toggle_comment :: proc(b: ^Buffer) {
	if b.lang == nil || b.lang.line_comment == "" do return
	a, z := order(b.anchor, b.cur)
	last := z.line if z.col > 0 || z.line == a.line else z.line - 1
	mark := b.lang.line_comment
	all := true
	for l in a.line ..= last {
		s := strings.trim_left_space(line_str(b, l))
		if s != "" && !strings.has_prefix(s, mark) do all = false
	}
	for l in a.line ..= last {
		ind := len(indent_of(b, l))
		s := line_str(b, l)
		if len(strings.trim_space(s)) == 0 do continue
		if all {
			n := len(mark)
			if ind + n < len(s) && s[ind + n] == ' ' do n += 1
			replace(b, {l, ind}, {l, ind + n}, "", merge = l > a.line)
		} else {
			replace(b, {l, ind}, {l, ind}, strings.concatenate({mark, " "}, context.temp_allocator), merge = l > a.line)
		}
	}
	b.cur, b.anchor = clamp_pos(b, b.cur), clamp_pos(b, b.anchor)
}

accept_completion :: proc(b: ^Buffer) {
	c := app.comps[app.shown[app.comp_sel]]
	a, z := word_at(b, b.cur)
	z = b.cur
	if c.has_range && c.a.line == b.cur.line {
		a = c.a
		z = Pos{b.cur.line, max(c.z.col, b.cur.col)}
	}
	go(b, replace(b, a, z, c.insert), false)
	app.comp_on = false
}

find_next :: proc(b: ^Buffer, back: bool, quiet := false) {
	needle := strings.to_lower(string(app.input[:]), context.temp_allocator)
	if needle == "" do return
	n := len(b.lines)
	start := b.cur if !back else b.anchor
	_, start = order(b.anchor, b.cur)
	if back do start, _ = order(b.anchor, b.cur)
	for k in 0 ..= n {
		l := (start.line + (n - k if back else k)) % n
		s := strings.to_lower(line_str(b, l), context.temp_allocator)
		i := -1
		if back {
			lim := start.col if k == 0 else len(s)
			i = strings.last_index(s[:min(lim, len(s))], needle)
		} else {
			from := start.col if k == 0 else 0
			if j := strings.index(s[from:], needle); j >= 0 do i = from + j
		}
		if i >= 0 {
			b.anchor = {l, i}
			b.cur = {l, i + len(needle)}
			ensure_visible(b)
			return
		}
	}
	if !quiet do toast("見つかりません")
}

delete_line :: proc(b: ^Buffer) {
	a, z := order(b.anchor, b.cur)
	if z.line + 1 < len(b.lines) {
		replace(b, {a.line, 0}, {z.line + 1, 0}, "")
	} else if a.line > 0 {
		replace(b, {a.line - 1, len(b.lines[a.line - 1])}, {z.line, len(b.lines[z.line])}, "")
	} else {
		replace(b, {0, 0}, {z.line, len(b.lines[z.line])}, "")
	}
	go(b, {min(a.line, len(b.lines) - 1), 0}, false)
}

on_mouse :: proc(ev: Ev) {
	S := app.S
	x, y := ev.x * S, ev.y * S
	b := cur_buf()
	#partial switch ev.kind {
	case .Motion:
		if abs(x - app.mx) > 2 || abs(y - app.my) > 2 {
			app.hover_since = ticks_ms()
			app.hover_asked = false
			if app.hover != "" && b != nil && pos_at(b, x, y).line != app.hover_pos.line do app.hover = ""
		}
		app.mx, app.my = x, y
		if app.minimap_drag && b != nil do minimap_click(b, y)
		if app.selecting && b != nil {
			b.cur = pos_at(b, x, y)
			ensure_visible(b)
		}
	case .Up:
		app.selecting = false
		app.minimap_drag = false
	case .Wheel:
		if app.panel_on && contains(app.panel, x, y) {
			app.panel_scroll = max(app.panel_scroll - ev.wheel * 3 * PANEL_ROW * S, 0)
		} else if b != nil {
			if .Shift in ev.mods do b.scroll_x = max(b.scroll_x - ev.wheel * 6 * app.cell_w, 0)
			else do b.scroll_y = clamp(b.scroll_y - ev.wheel * 3, 0, f32(len(b.lines) - 1))
			app.hover = ""
		}
	case .Down:
		app.hover = ""
		if app.mode == .Picker {
			if r, ok := picker_row_at(x, y); ok do picker_choose(r)
			else do app.mode = .Edit
			return
		}
		if app.comp_on {
			if r, ok := comp_row_at(x, y); ok && b != nil {
				app.comp_sel = r
				accept_completion(b)
				return
			}
			app.comp_on = false
		}
		if contains(app.titlebar, x, y) {
			if ev.button == 1 {
				if x > app.titlebar.w - 40 * S do app.running = false
				else do plat_move()
			}
			return
		}
		if contains(app.tabbar, x, y) {
			app.panel_focus = false
			if i, close, ok := tab_at(x); ok {
				if ev.button == 2 || close do close_tab(i)
				else if ev.button == 1 do app.active = i
			} else if ev.button == 1 {
				plat_move()
			}
			return
		}
		if app.panel_on && contains(app.panel, x, y) {
			app.panel_focus = true
			i := int((y - app.panel.y - PANEL_TOP * S + app.panel_scroll) / (PANEL_ROW * S))
			if y > app.panel.y + PANEL_TOP * S && i >= 0 && i < len(app.tree) {
				app.panel_sel = i
				n := app.tree[i]
				if n.dir {
					panel_set_expanded(n.path, !app.expanded[n.path])
				} else {
					open_file(n.path)
				}
			}
			return
		}
		app.panel_focus = false
		if b == nil || !contains(app.editor, x, y) || ev.button != 1 do return
		if app.minimap && x > app.text.x + app.text.w - minimap_w() {
			minimap_click(b, y)
			app.minimap_drag = true
			return
		}
		p := pos_at(b, x, y)
		if .Alt in ev.mods {
			add_caret(b, p)
			return
		}
		clear(&b.extra)
		if .Ctrl in ev.mods {
			b.cur, b.anchor = p, p
			lsp_definition(b, p)
			return
		}
		switch ev.clicks {
		case 2:
			b.anchor, b.cur = word_at(b, p)
		case 3:
			b.anchor = {p.line, 0}
			b.cur = {p.line + 1, 0} if p.line + 1 < len(b.lines) else {p.line, len(b.lines[p.line])}
		case:
			b.cur = p
			if .Shift not_in ev.mods do b.anchor = p
			app.selecting = true
		}
		b.want_x = -1
		app.comp_on = false
	}
}

tab_w :: proc(b: ^Buffer) -> f32 {
	return f32(text_width(filepath.base(b.path), app.ui, true)) + 64 * app.S
}

tab_at :: proc(x: f32) -> (idx: int, close, ok: bool) {
	tx := app.tabbar.x
	for b, i in app.bufs {
		w := tab_w(b)
		if x >= tx && x < tx + w do return i, x > tx + w - 26 * app.S, true
		tx += w
	}
	return
}

// ---------------------------------------------------------------------------
// Drawing

lang_glyph :: proc(path: string) -> (rune, u32) {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".zig", ".zon": return 0xe6a9, 0xf7a41d
	case ".odin": return 0xf0e7, 0x3882d2
	case ".rs": return 0xe7a8, 0xdea584
	case ".c", ".h": return 0xe61e, 0x599eff
	case ".cpp", ".cc", ".hpp": return 0xe61d, 0xf34b7d
	case ".go": return 0xe627, 0x00add8
	case ".py": return 0xe606, 0xffbc03
	case ".js", ".mjs": return 0xe74e, 0xf1e05a
	case ".ts", ".tsx": return 0xe628, 0x3178c6
	case ".json", ".jsonc": return 0xe60b, 0xcbcb41
	case ".md": return 0xe609, 0x9da7b3
	case ".toml": return 0xe6b2, 0x9c4221
	case ".nix": return 0xf313, 0x7ebae4
	case ".sh", ".bash", ".zsh": return 0xe795, 0x89e051
	case ".lua": return 0xe620, 0x51a0cf
	case ".html": return 0xe736, 0xe44d26
	case ".css", ".scss": return 0xe749, 0x563d7c
	}
	return 0xf15b, 0x9da7b3
}

draw_glyph_c :: proc(x, y: f32, r: rune, size: i32, c: Color) {
	glyph(i32(x), i32(y), r, size, c, true)
}

// Styles for one line: a small lexer driven by the language's Zed config and
// highlights.scm words, then the language server's semantic tokens on top.
lex_line :: proc(b: ^Buffer, l: int, in_block: ^bool) -> []Style {
	s := line_str(b, l)
	st := make([]Style, len(s), context.temp_allocator)
	lang := b.lang
	lc := lang.line_comment if lang != nil else ""
	bc := lang.block_comment if lang != nil else [2]string{}
	paint :: proc(st: []Style, a, z: int, v: Style) {for k in a ..< min(z, len(st)) do st[k] = v}
	i := 0
	for i < len(s) {
		if in_block^ {
			j := strings.index(s[i:], bc[1]) if bc[1] != "" else -1
			end := len(s) if j < 0 else i + j + len(bc[1])
			paint(st, i, end, .Comment)
			if j >= 0 do in_block^ = false
			i = end
			continue
		}
		c := s[i]
		if lc != "" && strings.has_prefix(s[i:], lc) {
			paint(st, i, len(s), .Comment)
			break
		}
		if bc[0] != "" && strings.has_prefix(s[i:], bc[0]) {
			in_block^ = true
			paint(st, i, i + len(bc[0]), .Comment)
			i += len(bc[0])
			continue
		}
		if c == '\\' && i + 1 < len(s) && s[i + 1] == '\\' && lang != nil && lang.name == "Zig" {
			paint(st, i, len(s), .String) // Zig multiline string
			break
		}
		switch {
		case c == '"' || c == '`' || (c == '\'' && !(lang != nil && lang.name == "Rust")):
			j := i + 1
			for j < len(s) && s[j] != c {
				if s[j] == '\\' do j += 1
				j += 1
			}
			paint(st, i, j + 1, .String)
			i = j + 1
			continue
		case c >= '0' && c <= '9':
			j := i
			for j < len(s) && (is_word_byte(s[j]) || s[j] == '.') do j += 1
			paint(st, i, j, .Number)
			i = j
			continue
		case is_word_byte(c) || c == '@' || c == '#':
			j := i + 1
			for j < len(s) && is_word_byte(s[j]) do j += 1
			w := s[i:j]
			k := j
			for k < len(s) && s[k] == ' ' do k += 1
			style := Style.Variable
			if lang != nil && w in lang.words do style = lang.words[w]
			else if k < len(s) && s[k] == '(' do style = .Function
			else if c >= 'A' && c <= 'Z' do style = .Type
			paint(st, i, j, style)
			i = j
			continue
		case strings.index_byte("+-*/%=<>!&|^~?:", c) >= 0:
			st[i] = .Operator
		case strings.index_byte("(){}[];,.", c) >= 0:
			st[i] = .Punct
		}
		i += 1
	}
	if l >= b.ts_lo && l < b.ts_hi {
		for v, k in b.ts_lines[l - b.ts_lo] do if b.ts_set[l - b.ts_lo][k] do st[k] = v
	}
	// semantic tokens (sorted by line): binary search to this line
	lo, hi := 0, len(b.toks)
	for lo < hi {
		m := (lo + hi) / 2
		if int(b.toks[m].line) < l do lo = m + 1
		else do hi = m
	}
	for k := lo; k < len(b.toks) && int(b.toks[k].line) == l; k += 1 {
		t := b.toks[k]
		paint(st, int(t.col), int(t.col + t.len), t.style)
	}
	return st
}

// Block-comment state at the start of line l (cached, invalidated by edits).
block_state :: proc(b: ^Buffer, l: int) -> bool {
	if len(b.bstate) == 0 do append(&b.bstate, false)
	for len(b.bstate) <= l {
		k := len(b.bstate) - 1
		st := b.bstate[k]
		lex_line(b, k, &st)
		append(&b.bstate, st)
	}
	return b.bstate[l]
}

wave :: proc(x0, x1, y: f32, c: Color) {
	S := app.S
	for x := x0; x < x1; x += 1 {
		dy := math.sin((x - x0) / (2 * S)) * 1.2 * S
		fill({x, y + dy, 1, max(S, 1)}, c)
	}
}

diag_color :: proc(sev: int) -> Color {
	switch sev {
	case 1: return col("error")
	case 2: return col("warning")
	case 3: return col("info")
	}
	return col("hint")
}

draw_editor :: proc() {
	S := app.S
	fill(app.gutter, col("editor.gutter.background"))
	fill({app.gutter.x + app.gutter.w, app.editor.y, app.editor.w - app.gutter.w, app.editor.h}, col("editor.background"))
	b := cur_buf()
	if b == nil {
		set_clip(app.editor)
		y := app.editor.y + app.editor.h / 2 - 40 * S
		lines := []string{"Seoritsu", "Ctrl+P  ファイルを開く", "Ctrl+B  プロジェクトパネル", "Ctrl+Q  終了"}
		for s, i in lines {
			sz := app.ui * 2 if i == 0 else app.ui
			w := f32(text_width(s, sz, true))
			text(app.editor.x + (app.editor.w - w) / 2, y, s, sz, col("text.accent") if i == 0 else col("text.muted"))
			y += f32(sz) * 1.9
		}
		reset_clip()
		return
	}
	asc, desc := font_metrics(app.fs)
	base_off := math.round((app.line_h + f32(asc - desc)) / 2)
	first := int(b.scroll_y)
	y0 := app.text.y - (b.scroll_y - f32(first)) * app.line_h
	nrows := int(rows()) + 2
	ts_prepare(b, first, first + nrows)
	defer b.ts_lo, b.ts_hi = 0, 0 // ts_lines lives in the frame's temp memory
	sa, sz := order(b.anchor, b.cur)
	tabw := f32(b.tab_size) * app.cell_w
	needle := strings.to_lower(string(app.input[:]), context.temp_allocator) if app.mode == .Find || app.mode == .Replace else ""
	in_block := block_state(b, min(first, len(b.lines) - 1))
	cur_ind := len(indent_of(b, b.cur.line))
	// every caret as an ordered (start, end) pair
	sels := make([dynamic][2]Pos, context.temp_allocator)
	append(&sels, [2]Pos{sa, sz})
	for e in b.extra {
		x, y := order(e[0], e[1])
		append(&sels, [2]Pos{x, y})
	}
	// occurrences of the word under the caret (or of a one-line selection)
	same := ""
	if len(b.extra) == 0 && needle == "" {
		if has_sel(b) && sa.line == sz.line {
			same = string(b.lines[sa.line][sa.col:sz.col])
		} else if !has_sel(b) {
			wa, wz := word_at(b, b.cur)
			if wz.col - wa.col >= 2 do same = string(b.lines[wa.line][wa.col:wz.col])
		}
		if strings.trim_space(same) == "" do same = ""
	}
	br_a, br_z, br_ok := bracket_pair(b)
	gi := 0

	for k in 0 ..< nrows {
		l := first + k
		if l >= len(b.lines) do break
		y := y0 + f32(k) * app.line_h
		by := y + base_off
		s := line_str(b, l)
		tx := app.text.x - b.scroll_x
		// gutter
		set_clip(app.gutter)
		num := fmt.tprint(l + 1)
		nc := col("editor.active_line_number") if l == b.cur.line else col("editor.line_number")
		text(app.gutter.x + app.gutter.w - 2 * app.cell_w - f32(text_width(num, app.fs, false)), by, num, app.fs, nc, false)
		worst := 5
		for d in b.diags do if d.a.line == l do worst = min(worst, d.severity)
		if worst < 5 do rrect({app.gutter.x + app.gutter.w - 1.4 * app.cell_w, y + app.line_h / 2 - 3 * S, 6 * S, 6 * S}, 3 * S, diag_color(worst))
		// git: added / modified bar, deleted wedge
		for gi < len(b.git) && int(b.git[gi].line) < l do gi += 1
		for g := gi; g < len(b.git) && int(b.git[g].line) == l; g += 1 {
			switch b.git[g].kind {
			case .Added: fill({app.gutter.x + 2 * S, y, 3 * S, app.line_h}, col("created"))
			case .Modified: fill({app.gutter.x + 2 * S, y, 3 * S, app.line_h}, col("modified"))
			case .Deleted: rrect({app.gutter.x, y - 3 * S, 7 * S, 6 * S}, 3 * S, col("deleted"))
			}
		}

		set_clip(app.text)
		for c in sels do if c[0] == c[1] && c[1].line == l {
			fill({app.text.x, y, app.text.w, app.line_h}, col("editor.active_line.background"))
			break
		}
		// selections
		for c in sels {
			if c[0] == c[1] || lt(c[1], Pos{l, 0}) || lt(Pos{l, len(s)}, c[0]) do continue
			x0 := x_in_line(b, l, c[0].col) if c[0].line == l else 0
			x1 := x_in_line(b, l, c[1].col) if c[1].line == l else x_in_line(b, l, len(s)) + app.cell_w / 2
			rrect({tx + x0, y, x1 - x0, app.line_h}, 3 * S, col("selection"))
		}
		// same word elsewhere
		if same != "" {
			from := 0
			for {
				j := strings.index(s[from:], same)
				if j < 0 do break
				a := from + j
				e := a + len(same)
				whole := (a == 0 || !is_word_byte(s[a - 1])) && (e >= len(s) || !is_word_byte(s[e]))
				if whole && !(l == sa.line && a == sa.col && has_sel(b)) {
					x0, x1 := x_in_line(b, l, a), x_in_line(b, l, e)
					rrect({tx + x0, y + 1, x1 - x0, app.line_h - 2}, 3 * S, col("editor.document_highlight.read_background"))
				}
				from = e
			}
		}
		// matching brackets
		if br_ok {
			for p in ([2]Pos{br_a, br_z}) do if p.line == l {
				x0 := x_in_line(b, l, p.col)
				rrect({tx + x0, y + 1, f32(get_glyph(rune(s[p.col]), app.fs).adv), app.line_h - 2}, 3 * S, col("accent"), max(S, 1))
			}
		}
		// find matches
		if needle != "" {
			low := strings.to_lower(s, context.temp_allocator)
			from := 0
			for {
				j := strings.index(low[from:], needle)
				if j < 0 do break
				a := from + j
				x0, x1 := x_in_line(b, l, a), x_in_line(b, l, a + len(needle))
				rrect({tx + x0, y + 1, x1 - x0, app.line_h - 2}, 3 * S, col("editor.document_highlight.read_background"))
				from = a + len(needle)
			}
		}
		// indent guides
		ind := indent_of(b, l)
		if len(ind) > 0 {
			iw := x_in_line(b, l, len(ind))
			for gx := f32(0); gx < iw; gx += tabw {
				active := l != b.cur.line && cur_ind > 0 && gx + tabw >= x_in_line(b, b.cur.line, cur_ind) && gx < x_in_line(b, b.cur.line, cur_ind)
				fill({tx + gx, y, max(S, 1), app.line_h}, col("editor.indent_guide_active") if active else col("editor.indent_guide"))
			}
		}
		// text
		styles := lex_line(b, l, &in_block)
		x: f32
		hs := hints_of(b, l)
		draw_hint :: proc(h: Hint, tx, x, y, by: f32) -> f32 {
			S := app.S
			w := hint_w(h)
			rrect({tx + x + S, y + 3 * S, w - 2 * S, app.line_h - 6 * S}, 3 * S, col("element.hover"))
			text(tx + x + 3 * S, by - S, h.label, hint_fs(), col("text.muted"), false)
			return w
		}
		for r, i in s {
			for len(hs) > 0 && int(hs[0].col) <= i {
				if int(hs[0].col) == i do x += draw_hint(hs[0], tx, x, y, by)
				hs = hs[1:]
			}
			if r == '\t' {
				x = (math.floor(x / tabw) + 1) * tabw
				continue
			}
			if tx + x > app.text.x + app.text.w do break
			adv := f32(get_glyph(r, app.fs).adv)
			if tx + x + adv >= app.text.x && r != ' ' do glyph(i32(tx + x), i32(by), r, app.fs, syntax[styles[i]])
			x += adv
		}
		for h in hs do if int(h.col) >= len(s) do x += draw_hint(h, tx, x, y, by)
		// diagnostics: squiggles and the first message inline
		shown_msg := false
		for d in b.diags {
			if d.a.line > l || d.b.line < l do continue
			x0 := x_in_line(b, l, d.a.col) if d.a.line == l else 0
			x1 := x_in_line(b, l, d.b.col) if d.b.line == l else x
			if x1 <= x0 do x1 = x0 + app.cell_w
			wave(tx + x0, tx + x1, y + app.line_h - 3 * S, diag_color(d.severity))
			if zed.inline_diag && !shown_msg && d.a.line == l {
				shown_msg = true
				msg, _ := strings.replace_all(d.message, "\n", "  ", context.temp_allocator)
				c := diag_color(d.severity)
				text(tx + max(x, x1) + 3 * app.cell_w, by, msg, app.fs, with_alpha(c, 170), false)
			}
		}
	}
	// cursor + IME preedit
	if b.cur.line >= first && b.cur.line < first + nrows {
		set_clip(app.text)
		cx := app.text.x - b.scroll_x + x_in_line(b, b.cur.line, b.cur.col)
		cy := y0 + f32(b.cur.line - first) * app.line_h
		if app.preedit != "" {
			w := f32(text_width(app.preedit, app.fs))
			fill({cx, cy, w, app.line_h}, col("elevated_surface.background"))
			text(cx, cy + base_off, app.preedit, app.fs, col("text"), false)
			fill({cx, cy + app.line_h - 2 * S, w, max(S, 1)}, col("accent"))
			cx += w
		}
		fill({cx, cy + 2 * S, max(2 * S, 2), app.line_h - 4 * S}, col("cursor"))
		for e in b.extra {
			if e[1].line < first || e[1].line >= first + nrows do continue
			ex := app.text.x - b.scroll_x + x_in_line(b, e[1].line, e[1].col)
			fill({ex, y0 + f32(e[1].line - first) * app.line_h + 2 * S, max(2 * S, 2), app.line_h - 4 * S}, col("cursor"))
		}
		plat_text_input(app.mode == .Edit, {i32(cx / S), i32(cy / S), i32(2), i32(app.line_h / S)})
	}
	reset_clip()
	draw_minimap(b)
	// scrollbar
	total := f32(len(b.lines)) + rows() - 1
	if f32(len(b.lines)) > rows() {
		th := max(app.text.h * rows() / total, 24 * S)
		ty := app.text.y + (app.text.h - th) * b.scroll_y / (total - rows())
		rrect({app.text.x + app.text.w - 10 * S, ty, 7 * S, th}, 3.5 * S, col("scrollbar.thumb.background"))
	}
	// diagnostic marks on the scrollbar track
	for d in b.diags {
		my := app.text.y + app.text.h * f32(d.a.line) / max(f32(len(b.lines)), 1)
		fill({app.text.x + app.text.w - 4 * S, my, 3 * S, max(2 * S, 2)}, diag_color(d.severity))
	}
}

draw_tabbar :: proc() {
	S := app.S
	r := app.tabbar
	fill(r, col("tab_bar.background"))
	set_clip(r)
	x := r.x
	for b, i in app.bufs {
		w := tab_w(b)
		tr := Rect{x, r.y, w, r.h}
		active := i == app.active
		fill(tr, col("tab.active_background") if active else col("tab.inactive_background"))
		if active do fill({x, r.y + r.h - 2 * S, w, 2 * S}, col("accent"))
		g, gc := lang_glyph(b.path)
		draw_glyph_c(x + 12 * S, baseline(tr, app.ui), g, app.ui, hex(gc))
		name := filepath.base(b.path)
		text(x + 32 * S, baseline(tr, app.ui), name, app.ui, git_color(b.path, col("text") if active else col("text.muted")))
		hot := contains(tr, app.mx, app.my)
		cr := Rect{x + w - 26 * S, r.y + (r.h - 18 * S) / 2, 18 * S, 18 * S}
		if b.dirty && !hot {
			rrect({cr.x + 5 * S, cr.y + 5 * S, 8 * S, 8 * S}, 4 * S, col("modified"))
		} else if hot || active {
			if contains(cr, app.mx, app.my) do rrect(cr, 4 * S, col("element.hover"))
			draw_glyph_c(cr.x + 4 * S, baseline(cr, app.ui - 2), 0xf00d, app.ui - 2 * i32(S), col("text.muted"))
		}
		fill({x + w - 1, r.y + 8 * S, 1, r.h - 16 * S}, col("border"))
		x += w
	}
	reset_clip()
	fill({r.x, r.y + r.h - 1, r.w, 1}, col("border"))
}

draw_panel :: proc() {
	S := app.S
	r := app.panel
	fill(r, col("panel.background"))
	fill({r.x + r.w - 1, r.y, 1, r.h}, col("border"))
	top := r.y + PANEL_TOP * S
	set_clip({r.x, top, r.w, r.h - PANEL_TOP * S})
	rh := PANEL_ROW * S
	cur := cur_buf()
	for n, i in app.tree {
		y := top + f32(i) * rh - app.panel_scroll
		if y + rh < top do continue
		if y > r.y + r.h do break
		row := Rect{r.x + 4 * S, y, r.w - 8 * S, rh}
		if app.panel_focus && i == app.panel_sel {
			rrect(row, 5 * S, col("element.selected"))
			rrect(row, 5 * S, col("accent"), ring = max(S, 1))
		} else if cur != nil && cur.path == n.path {
			rrect(row, 5 * S, col("element.selected"))
		} else if contains(row, app.mx, app.my) {
			rrect(row, 5 * S, col("element.hover"))
		}
		x := r.x + 12 * S + f32(n.depth) * 14 * S
		bl := baseline(row, app.ui)
		if n.dir {
			open := app.expanded[n.path]
			draw_glyph_c(x, bl, 0xf078 if open else 0xf054, app.ui - 4 * i32(S), col("text.muted"))
			draw_glyph_c(x + 16 * S, bl, 0xf07c if open else 0xf07b, app.ui, col("text.accent"))
		} else {
			g, gc := lang_glyph(n.name)
			draw_glyph_c(x + 16 * S, bl, g, app.ui, hex(gc))
		}
		text(x + 36 * S, bl, n.name, app.ui, git_color(n.path, col("text")))
	}
	reset_clip()
}

draw_status :: proc() {
	S := app.S
	r := app.status
	fill(r, col("status_bar.background"))
	fill({0, r.y, r.w, 1}, col("border"))
	bl := baseline(r, app.ui - 1)
	sz := app.ui - i32(S)
	x := 12 * S
	b := cur_buf()
	if b != nil {
		errs, warns := 0, 0
		for d in b.diags {
			if d.severity == 1 do errs += 1
			if d.severity == 2 do warns += 1
		}
		draw_glyph_c(x, bl, 0xf057, sz, col("error") if errs > 0 else col("text.muted"))
		x += 18 * S + text(x + 18 * S, bl, fmt.tprint(errs), sz, col("text.muted"))
		x += 12 * S
		draw_glyph_c(x, bl, 0xf071, sz, col("warning") if warns > 0 else col("text.muted"))
		x += 18 * S + text(x + 18 * S, bl, fmt.tprint(warns), sz, col("text.muted"))
		x += 20 * S
		if b.lang != nil && len(b.lang.servers) > 0 {
			name := b.lang.servers[0]
			s := servers[name] if name in servers else nil
			state := "未検出" if name in servers && s == nil else (s.status if s != nil else "")
			if s != nil && s.dead do state = "停止"
			label := name if state == "" else fmt.tprintf("%s · %s", name, state)
			x += text(x, bl, label, sz, col("text.muted")) + 20 * S
		}
		right := fmt.tprintf("Ln %d, Col %d    %s", b.cur.line + 1, utf8.rune_count(b.lines[b.cur.line][:b.cur.col]) + 1, b.lang.name if b.lang != nil else "Plain Text")
		text(r.w - 14 * S - f32(text_width(right, sz, true)), bl, right, sz, col("text.muted"))
	}
	if app.toast != "" && ticks_ms() < app.toast_until do text(x, bl, app.toast, sz, col("text.accent"))
}

popup :: proc(r: Rect) {
	S := app.S
	rrect({r.x, r.y + 4 * S, r.w, r.h}, 8 * S, hex(0, 70)) // soft shadow
	rrect(r, 8 * S, col("elevated_surface.background"))
	rrect(r, 8 * S, col("border"), 1)
}

comp_rect :: proc() -> Rect {
	b := cur_buf()
	S := app.S
	n := min(len(app.shown), 10)
	w := 420 * S
	cx := app.text.x - b.scroll_x + x_in_line(b, b.cur.line, b.cur.col)
	cy := app.text.y + (f32(b.cur.line) - b.scroll_y + 1) * app.line_h + 4 * S
	h := f32(n) * app.line_h + 8 * S
	if cy + h > app.editor.y + app.editor.h do cy -= h + app.line_h + 8 * S
	return {min(cx, app.W - w - 8 * S), cy, w, h}
}

comp_row_at :: proc(x, y: f32) -> (int, bool) {
	r := comp_rect()
	if !contains(r, x, y) do return 0, false
	top := max(app.comp_sel - 9, 0)
	i := top + int((y - r.y - 4 * app.S) / app.line_h)
	return i, i < len(app.shown)
}

draw_completion :: proc() {
	b := cur_buf()
	if !app.comp_on || b == nil || len(app.shown) == 0 do return
	S := app.S
	r := comp_rect()
	popup(r)
	set_clip(shrink(r, 2 * S))
	top := max(app.comp_sel - 9, 0)
	for k in 0 ..< min(len(app.shown) - top, 10) {
		i := top + k
		c := app.comps[app.shown[i]]
		row := Rect{r.x + 4 * S, r.y + 4 * S + f32(k) * app.line_h, r.w - 8 * S, app.line_h}
		if i == app.comp_sel do rrect(row, 5 * S, col("element.selected"))
		bl := baseline(row, app.fs, false)
		lw := text(row.x + 8 * S, bl, c.label, app.fs, col("text"), false)
		if c.detail != "" {
			dw := f32(text_width(c.detail, app.ui, true))
			dx := max(row.x + row.w - dw - 8 * S, row.x + lw + 24 * S)
			text(dx, baseline(row, app.ui), c.detail, app.ui, col("text.muted"))
		}
	}
	reset_clip()
}

draw_hover :: proc() {
	b := cur_buf()
	if app.hover == "" || b == nil do return
	S := app.S
	lines := strings.split_lines(app.hover, context.temp_allocator)
	lines = lines[:min(len(lines), 14)]
	w: f32 = 0
	for l in lines do w = max(w, f32(text_width(l, app.fs)))
	w = min(w + 24 * S, 640 * S)
	lh := app.line_h * 0.9
	h := f32(len(lines)) * lh + 16 * S
	p := app.hover_pos
	x := app.text.x - b.scroll_x + x_in_line(b, p.line, p.col)
	y := app.text.y + (f32(p.line) - b.scroll_y) * app.line_h - h - 6 * S
	if y < app.editor.y do y = app.text.y + (f32(p.line) - b.scroll_y + 1) * app.line_h + 6 * S
	r := Rect{clamp(x, 4 * S, app.W - w - 4 * S), y, w, h}
	popup(r)
	set_clip(shrink(r, 8 * S))
	for l, i in lines {
		row := Rect{r.x, r.y + 8 * S + f32(i) * lh, r.w, lh}
		text(r.x + 12 * S, baseline(row, app.fs, false), l, app.fs, col("text"), false)
	}
	reset_clip()
}

frame :: proc() {
	clear_canvas({}) // fully transparent: each region paints its own translucent color
	layout()
	draw_editor()
	draw_titlebar()
	draw_tabbar()
	draw_breadcrumbs()
	if app.panel_on do draw_panel()
	draw_status()
	draw_hover()
	draw_completion()
	draw_signature()
	draw_inputbar()
	draw_picker()
}

dump_frame :: proc(path: string) {
	// debug: raw premultiplied ARGB with an 8-byte w/h header (tools/dump2png.py)
	buf := make([]u8, 8 + int(cv.w * cv.h) * 4, context.temp_allocator)
	(^[2]i32)(&buf[0])^ = {cv.w, cv.h}
	for y in 0 ..< cv.h do copy(buf[8 + int(y * cv.w) * 4:][:cv.w * 4], ([^]u8)(&cv.px[y * cv.stride])[:cv.w * 4])
	_ = os.write_entire_file(path, buf)
}

main :: proc() {
	zed_load()
	if !font_init(zed.font_family) {
		fmt.eprintln("seoritsu: no usable font found")
		os.exit(1)
	}
	if !plat_init("Seoritsu", "seoritsu", 1200, 780) {
		fmt.eprintln("seoritsu: cannot open a Wayland window")
		os.exit(1)
	}
	app.running, app.S, app.panel_on = true, 1, true
	project_root = os.get_working_directory(context.allocator) or_else "/"
	open_list: [dynamic]string
	for a in os.args[1:] {
		abs, _ := filepath.abs(a)
		if os.is_dir(abs) do project_root = abs
		else do append(&open_list, abs)
	}
	if len(open_list) > 0 && len(os.args) == 2 do project_root = filepath.dir(open_list[0])
	refresh_tree()
	for p in open_list do open_file(p)
	app.active = 0
	if len(os.args) == 1 || (len(open_list) == 0 && len(os.args) == 2) do session_restore()

	dump := os.get_env("SEORITSU_DUMP", context.allocator)
	if dump != "" do zed.autosave = false // test runs must never write files
	dump_cmd := os.get_env("SEORITSU_DUMP_CMD", context.allocator) // debug: run this command (palette name) after 2.5 s
	dirty := true
	for app.running && !plat_closed() {
		now := ticks_ms()
		if b := cur_buf(); b != nil {
			lsp_tick(b)
			// mouse resting over code: ask for hover info
			if !app.hover_asked && app.mode == .Edit && contains(app.text, app.mx, app.my) && now - app.hover_since > 600 && !app.selecting {
				app.hover_asked = true
				p := pos_at(b, app.mx, app.my)
				if p.col < len(b.lines[p.line]) && is_word_byte(b.lines[p.line][p.col]) {
					app.hover_pos = p
					lsp_hover(b, p)
				}
			}
		}
		for b in app.bufs do if b != cur_buf() && b.lsp_stale do lsp_sync(b)
		for b, deadline in app.saving do if now > deadline {
			finish_save(b) // formatter too slow: save anyway
			dirty = true
		}
		if dump_cmd != "" && now > 2500 {
			for c in COMMANDS do if c.name == dump_cmd {
				run_cmd(c)
				break
			}
			dump_cmd = ""
			dirty = true
		}
		if app.search_due != 0 && now >= app.search_due {
			run_search()
			dirty = true
		}
		if b := cur_buf(); b != nil && ts_update(b, 8) do dirty = true
		if dirty && plat_can_draw() {
			buf, bw, bh := plat_begin()
			if buf != nil {
				app.S = f32(plat_scale())
				app.W, app.H = f32(bw), f32(bh)
				cv = Canvas{buf.px, bw, bh, bw, {0, 0, bw, bh}}
				frame()
				plat_present(buf)
				dirty = false
				if dump != "" {
					dump_frame(dump)
					if now > 6000 do break
					dirty = true
				}
			}
		}
		free_all(context.temp_allocator)

		fds := make([dynamic]posix.FD, context.temp_allocator)
		lsp_fds(&fds)
		timeout := -1
		hover_wait := !app.hover_asked && contains(app.text, app.mx, app.my)
		if hover_wait || app.toast != "" || len(app.saving) > 0 || dump != "" || app.search_due != 0 do timeout = 100
		if b := cur_buf(); b != nil && b.toks_due > 0 do timeout = 50
		if b := cur_buf(); b != nil && b.ts_dirty do timeout = 0 // keep parsing in slices
		alive, redraw, timed_out := plat_wait(timeout, fds[:])
		if !alive do break
		if lsp_poll() do dirty = true
		// buffer releases / frame callbacks also wake us: only real input means a redraw
		if redraw || len(events) > 0 do dirty = true
		_ = timed_out
		if app.toast != "" && now > app.toast_until {
			delete(app.toast)
			app.toast = ""
			dirty = true
		}
		for ev in events {
			#partial switch ev.kind {
			case .Key:
				on_key(ev)
			case .Text:
				on_text(ev.text)
			case .Preedit:
				app.preedit = ev.text
				continue
			case .Focus:
				if ev.button == 1 && zed.autosave do autosave_all()
				if ev.button == 0 do check_external_changes()
			case .Motion, .Down, .Up, .Wheel:
				on_mouse(ev)
			}
			if ev.kind != .Preedit do delete(ev.text)
		}
		clear(&events)
	}
	// quitting: Zed-style autosave, otherwise keep unsaved work next to the file
	if dump == "" do for b in app.bufs do if b.dirty {
		if zed.autosave && os.exists(b.path) do buffer_save(b)
		else do _ = os.write_entire_file(strings.concatenate({b.path, ".unsaved"}), transmute([]u8)buffer_text(b))
	}
	if dump == "" do session_save()
	lsp_shutdown()
}
