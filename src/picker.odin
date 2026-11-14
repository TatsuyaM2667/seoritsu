package main

// One fuzzy picker for everything: files, commands, references, symbols,
// diagnostics, code actions and project-wide search (ripgrep).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

Picker_Kind :: enum {Files, Commands, List, Search, Actions}

Pick :: struct {
	label, detail, path: string,
	line, char:          int,
	utf16:               bool,
	cmd:                 int,
	raw:                 string,
	server:              ^Server,
}

Loc :: struct {
	path: string,
	pos:  Pos,
}

rel_path :: proc(p: string) -> string {
	return strings.trim_prefix(strings.trim_prefix(p, project_root), "/")
}

picker_open :: proc(kind: Picker_Kind, title: string, items: [dynamic]Pick) {
	for p in app.picks {
		delete(p.label); delete(p.detail); delete(p.path); delete(p.raw)
	}
	delete(app.picks)
	app.picks = items
	app.pick_kind = kind
	delete(app.pick_title)
	app.pick_title = strings.clone(title)
	app.mode = .Picker
	clear(&app.input)
	refilter_picker()
}

refilter_picker :: proc() {
	if app.pick_kind == .Search {
		app.search_due = ticks_ms() + 120 // run rg once typing pauses
		return
	}
	clear(&app.hits)
	Hit :: struct {i, score: int}
	hs := make([dynamic]Hit, context.temp_allocator)
	q := string(app.input[:])
	for p, i in app.picks {
		hay := p.label
		if app.pick_kind == .Files do hay = p.path // match on the relative path
		if s, ok := fuzzy(hay, q); ok do append(&hs, Hit{i, s})
	}
	// lists keep their order (references, symbols); the rest by match quality
	if q != "" || app.pick_kind == .Files do slice.stable_sort_by(hs[:], proc(a, b: Hit) -> bool {return a.score < b.score})
	for h in hs[:min(len(hs), 500)] do append(&app.hits, h.i)
	app.sel_idx = 0
}

picker_choose :: proc(row: int) {
	app.mode = .Edit
	if row < 0 || row >= len(app.hits) do return
	p := app.picks[app.hits[row]]
	switch app.pick_kind {
	case .Files:
		push_nav()
		open_file(filepath.join({project_root, p.path}, context.temp_allocator) or_else p.path)
	case .Commands:
		run_cmd(COMMANDS[p.cmd])
	case .List, .Search:
		goto_location(p.path, p.line, p.char, p.utf16)
	case .Actions:
		lsp_run_action(p.server, p.raw)
	}
}

open_files_picker :: proc() {
	collect_files()
	items := make([dynamic]Pick)
	for f in app.files do append(&items, Pick{label = strings.clone(filepath.base(f)), path = strings.clone(rel_path(f))})
	picker_open(.Files, "ファイルを検索…", items)
}

open_palette :: proc() {
	items := make([dynamic]Pick)
	seen := make(map[string]bool, context.temp_allocator)
	for c, i in COMMANDS {
		if seen[c.name] do continue // the first binding of a command is its shortcut
		seen[c.name] = true
		append(&items, Pick{label = strings.clone(c.name), detail = strings.clone(key_label(c)), cmd = i})
	}
	picker_open(.Commands, "コマンドを実行…", items)
}

open_search :: proc() {
	picker_open(.Search, "プロジェクト内を検索…", make([dynamic]Pick))
	if b := cur_buf(); b != nil && has_sel(b) && b.anchor.line == b.cur.line {
		append(&app.input, text_range(b, b.anchor, b.cur))
		app.search_due = ticks_ms()
	}
}

// ripgrep if installed, otherwise a plain scan of the project files.
run_search :: proc() {
	app.search_due = 0
	q := string(app.input[:])
	for p in app.picks {delete(p.label); delete(p.detail); delete(p.path)}
	clear(&app.picks)
	clear(&app.hits)
	app.sel_idx = 0
	if len(q) < 2 do return
	if rg := find_in_path("rg"); rg != "" {
		_, out, _, err := os.process_exec({command = {rg, "--vimgrep", "--smart-case", "--fixed-strings", "--max-columns", "300", "--max-count", "50", "--", q, project_root}}, context.temp_allocator)
		if err != nil do return
		for line in strings.split_lines(string(out), context.temp_allocator) {
			// path:line:col:text
			p1 := strings.index_byte(line, ':')
			if p1 < 0 do continue
			rest := line[p1 + 1:]
			p2 := strings.index_byte(rest, ':')
			if p2 < 0 do continue
			p3 := strings.index_byte(rest[p2 + 1:], ':')
			if p3 < 0 do continue
			ln, _ := strconv.parse_int(rest[:p2])
			cl, _ := strconv.parse_int(rest[p2 + 1:][:p3])
			add_hit(line[:p1], ln - 1, cl - 1, rest[p2 + 1 + p3 + 1:])
			if len(app.picks) >= 1000 do break
		}
	} else {
		collect_files()
		low := strings.to_lower(q, context.temp_allocator)
		for f in app.files {
			data, err := os.read_entire_file(f, context.temp_allocator)
			if err != nil || slice.contains(data[:min(len(data), 512)], 0) do continue // binary
			for l, i in strings.split_lines(string(data), context.temp_allocator) {
				if j := strings.index(strings.to_lower(l, context.temp_allocator), low); j >= 0 do add_hit(f, i, j, l)
			}
			if len(app.picks) >= 1000 do break
		}
	}
	for _, i in app.picks do append(&app.hits, i)
	add_hit :: proc(path: string, line, col: int, text: string) {
		append(&app.picks, Pick{
			label = fmt.aprintf("%s:%d", rel_path(path), line + 1),
			detail = strings.clone(strings.trim_space(text)),
			path = strings.clone(path), line = line, char = col,
		})
	}
}

diagnostics_picker :: proc(b: ^Buffer) {
	items := make([dynamic]Pick)
	SEV := [5]string{"", "エラー", "警告", "情報", "ヒント"}
	for d in b.diags {
		append(&items, Pick{
			label = fmt.aprintf("%d: %s", d.a.line + 1, d.message),
			detail = strings.clone(SEV[clamp(d.severity, 0, 4)]),
			path = strings.clone(b.path), line = d.a.line, char = d.a.col,
		})
	}
	picker_open(.List, "診断", items)
}

// ---------------------------------------------------------------------------
// Back / forward through jumps

push_nav :: proc() {
	b := cur_buf()
	if b == nil do return
	resize(&app.nav, app.nav_i)
	append(&app.nav, Loc{strings.clone(b.path), b.cur})
	if len(app.nav) > 100 do ordered_remove(&app.nav, 0)
	app.nav_i = len(app.nav)
}

@(private = "file")
jump :: proc(l: Loc) {
	b := open_file(l.path)
	if b == nil do return
	b.cur = clamp_pos(b, l.pos)
	b.anchor = b.cur
	clear(&b.extra)
	if f32(b.cur.line) < b.scroll_y || f32(b.cur.line) > b.scroll_y + rows() - 2 do b.scroll_y = max(f32(b.cur.line) - rows() / 3, 0)
}

nav_back :: proc() {
	if app.nav_i <= 0 do return
	if app.nav_i == len(app.nav) {
		push_nav() // so "forward" can come back here
		app.nav_i -= 1
	}
	app.nav_i -= 1
	jump(app.nav[app.nav_i])
}

nav_forward :: proc() {
	if app.nav_i + 1 >= len(app.nav) do return
	app.nav_i += 1
	jump(app.nav[app.nav_i])
}

// ---------------------------------------------------------------------------
// Drawing

picker_rect :: proc() -> Rect {
	S := app.S
	w := min(680 * S, app.W - 40 * S)
	n := min(len(app.hits), 14)
	return {(app.W - w) / 2, app.editor.y + 16 * S, w, 48 * S + f32(max(n, 1)) * 30 * S + 8 * S}
}

picker_row_at :: proc(x, y: f32) -> (int, bool) {
	r := picker_rect()
	if !contains(r, x, y) || y < r.y + 48 * app.S do return 0, false
	i := picker_top() + int((y - r.y - 52 * app.S) / (30 * app.S))
	return i, i >= 0 && i < len(app.hits)
}

picker_top :: proc() -> int {return max(app.sel_idx - 13, 0)}

draw_picker :: proc() {
	if app.mode != .Picker do return
	S := app.S
	r := picker_rect()
	popup(r)
	field := Rect{r.x + 8 * S, r.y + 8 * S, r.w - 16 * S, 34 * S}
	q := string(app.input[:])
	set_clip(r)
	bl := baseline(field, app.ui)
	if q == "" do text(field.x + 10 * S, bl, app.pick_title, app.ui, col("text.placeholder"))
	qw := text(field.x + 10 * S, bl, q, app.ui, col("text"))
	fill({field.x + 11 * S + qw, field.y + 8 * S, 2 * S, field.h - 16 * S}, col("cursor"))
	count := fmt.tprintf("%d", len(app.hits))
	text(field.x + field.w - 10 * S - f32(text_width(count, app.ui - i32(S), true)), bl, count, app.ui - i32(S), col("text.muted"))
	fill({r.x, r.y + 48 * S, r.w, 1}, col("border"))
	if len(app.hits) == 0 {
		msg := "見つかりません" if q != "" || app.pick_kind != .Search else "2 文字以上入力"
		text(r.x + 20 * S, r.y + 52 * S + 20 * S, msg, app.ui, col("text.muted"))
	}
	top := picker_top()
	for k in 0 ..< min(len(app.hits) - top, 14) {
		i := top + k
		p := app.picks[app.hits[i]]
		row := Rect{r.x + 4 * S, r.y + 52 * S + f32(k) * 30 * S, r.w - 8 * S, 30 * S}
		if i == app.sel_idx do rrect(row, 5 * S, col("element.selected"))
		else if contains(row, app.mx, app.my) do rrect(row, 5 * S, col("element.hover"))
		bl := baseline(row, app.ui)
		x := row.x + 10 * S
		if p.path != "" && app.pick_kind == .Files {
			g, gc := lang_glyph(p.path)
			draw_glyph_c(x, bl, g, app.ui, hex(gc))
			x += 22 * S
		}
		x += text(x, bl, p.label, app.ui, col("text")) + 12 * S
		if p.detail != "" {
			if app.pick_kind == .Commands {
				dw := f32(text_width(p.detail, app.ui - i32(S), true))
				kr := Rect{row.x + row.w - dw - 22 * S, row.y + 5 * S, dw + 12 * S, row.h - 10 * S}
				rrect(kr, 4 * S, col("element.hover"))
				text(kr.x + 6 * S, bl, p.detail, app.ui - i32(S), col("text.muted"))
			} else if app.pick_kind == .Search || app.pick_kind == .List {
				text(x, baseline(row, app.fs, false), p.detail, app.fs, col("text.muted"), false)
			} else {
				text(x, bl, p.detail, app.ui - i32(S), col("text.muted"))
			}
		}
	}
	reset_clip()
}

// Find / replace / go-to-line / rename bar.
draw_inputbar :: proc() {
	if app.mode == .Edit || app.mode == .Picker do return
	S := app.S
	two := app.mode == .Replace
	w := 380 * S
	r := Rect{app.editor.x + app.editor.w - w - 24 * S, app.editor.y + 8 * S, w, (72 if two else 36) * S}
	popup(r)
	set_clip(r)
	draw_field :: proc(r: Rect, icon: rune, value, hint: string, focused: bool) {
		S := app.S
		bl := baseline(r, app.ui)
		draw_glyph_c(r.x + 12 * S, bl, icon, app.ui, col("text.accent") if focused else col("text.muted"))
		if value == "" do text(r.x + 34 * S, bl, hint, app.ui, col("text.placeholder"))
		qw := text(r.x + 34 * S, bl, value, app.ui, col("text"))
		if focused do fill({r.x + 35 * S + qw, r.y + 9 * S, 2 * S, r.h - 18 * S}, col("cursor"))
	}
	row := Rect{r.x, r.y, r.w, 36 * S}
	q := string(app.input[:])
	switch app.mode {
	case .Find:
		draw_field(row, 0xf002, q, "検索 (Enter: 次 / Shift+Enter: 前)", true)
	case .Replace:
		draw_field(row, 0xf002, q, "検索", app.field == 0)
		draw_field({r.x, r.y + 36 * S, r.w, 36 * S}, 0xf044, string(app.input2[:]), "置換 (Enter: 1 件 / Ctrl+Enter: すべて / Tab: 切替)", app.field == 1)
	case .Line:
		draw_field(row, 0xf0cb, q, "行番号 (行:列 も可)", true)
	case .Rename:
		draw_field(row, 0xf044, q, "新しい名前", true)
	case .Edit, .Picker:
	}
	reset_clip()
}
