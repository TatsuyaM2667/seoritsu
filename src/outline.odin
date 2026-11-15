package main

// Outline: the current file's symbols (LSP documentSymbol) as the second tab of the left
// panel (Ctrl+Shift+B, like Zed's outline panel). Click to jump; the symbol around the
// caret is highlighted. Refreshed a moment after typing stops.

import "core:strings"

Panel_Mode :: enum {Files, Outline}

outline: struct {
	items:   [dynamic]Pick,
	buf:     ^Buffer,
	version: int,
	pending: bool,
}

PANEL_TABS :: 30 // header with the Files / Outline tabs, unscaled

outline_toggle :: proc() {
	if app.panel_on && app.panel_mode == .Outline {
		app.panel_mode = .Files
		return
	}
	app.panel_on, app.panel_mode = true, .Outline
	app.panel_scroll = 0
}

// Asked by lsp_tick: does the outline need a fresh documentSymbol?
outline_wanted :: proc(b: ^Buffer) -> bool {
	if !app.panel_on || app.panel_mode != .Outline || outline.pending do return false
	if outline.buf == b && outline.version == b.version do return false
	return ticks_ms() - b.last_edit_ms > 300
}

outline_set :: proc(b: ^Buffer, version: int, items: [dynamic]Pick) {
	for p in outline.items {delete(p.label); delete(p.detail); delete(p.path)}
	delete(outline.items)
	outline.items, outline.buf, outline.version, outline.pending = items, b, version, false
}

// The symbol starting nearest above the caret (servers don't always list them in order).
outline_current :: proc(b: ^Buffer) -> int {
	if outline.buf != b do return -1
	cur, best := -1, -1
	for p, i in outline.items do if p.line <= b.cur.line && p.line >= best {
		cur, best = i, p.line
	}
	return cur
}

outline_click :: proc(i: int) {
	if i < 0 || i >= len(outline.items) do return
	p := outline.items[i]
	push_nav()
	goto_location(p.path, p.line, p.char, p.utf16)
}

draw_panel_tabs :: proc() {
	S := app.S
	r := app.panel
	x := r.x + 8 * S
	for m in Panel_Mode {
		label := "ファイル" if m == .Files else "アウトライン"
		w := f32(text_width(label, app.ui - i32(S), true)) + 20 * S
		br := Rect{x, r.y + 4 * S, w, (PANEL_TABS - 8) * S}
		on := app.panel_mode == m
		if on do rrect(br, 5 * S, col("element.selected"))
		else if contains(br, app.mx, app.my) do rrect(br, 5 * S, col("element.hover"))
		text(x + 10 * S, baseline(br, app.ui - i32(S)), label, app.ui - i32(S), col("text") if on else col("text.muted"))
		append(&status_buttons, Ui_Button{br, proc() {app.panel_mode = .Files} if m == .Files else proc() {app.panel_mode = .Outline; app.panel_scroll = 0}})
		x += w + 4 * S
	}
	fill({r.x, r.y + PANEL_TABS * S - 1, r.w - 1, 1}, col("border.variant"))
}

draw_outline :: proc() {
	S := app.S
	r := app.panel
	top := r.y + PANEL_TOP * S
	b := cur_buf()
	if b == nil || outline.buf != b || len(outline.items) == 0 {
		msg := "ファイルを開いてください"
		if b != nil do msg = "シンボルを読み込み中…" if lsp_for(b) != nil else "このファイルには言語サーバーがありません"
		text(r.x + 14 * S, top + 20 * S, msg, app.ui - i32(S), col("text.muted"))
		return
	}
	set_clip({r.x, top, r.w, r.h - PANEL_TOP * S})
	rh := PANEL_ROW * S
	cur := outline_current(b)
	for p, i in outline.items {
		y := top + f32(i) * rh - app.panel_scroll
		if y + rh < top do continue
		if y > r.y + r.h do break
		row := Rect{r.x + 4 * S, y, r.w - 8 * S, rh}
		if i == cur do rrect(row, 5 * S, col("element.selected"))
		else if contains(row, app.mx, app.my) do rrect(row, 5 * S, col("element.hover"))
		bl := baseline(row, app.ui)
		name := strings.trim_left_space(p.label)
		depth := (len(p.label) - len(name)) / 2
		x := r.x + 14 * S + f32(depth) * 14 * S
		x += text(x, bl, name, app.ui, col("text")) + 8 * S
		text(x, bl, p.detail, app.ui - 2 * i32(S), col("text.muted"))
	}
	reset_clip()
}
