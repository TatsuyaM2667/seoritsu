package main

// Display rows: what the editor draws top to bottom. Without soft wrap and folds a row is
// a line (no table, no cost). Otherwise b.disp lists (line, first byte) per row; folded
// lines have no row, a wrapped line has several. scroll_y counts rows.

import "core:math"
import "core:slice"

Disp_Row :: struct {
	line, c0: i32,
}

Fold :: struct {
	line, end: int, // line stays visible, line+1 ..= end are hidden
}

Disp_Key :: struct {
	gen, fold_gen: int,
	width:         f32,
	fs:            i32,
	wrap:          bool,
}

disp_on :: proc(b: ^Buffer) -> bool {return app.wrap || len(b.folds) > 0}

wrap_width :: proc() -> f32 {return max(app.text.w - 3 * app.cell_w, 10 * app.cell_w)}

// Rebuilds b.disp when the text, folds, width or font changed.
disp_update :: proc(b: ^Buffer) {
	if !disp_on(b) do return
	key := Disp_Key{b.edit_gen, b.fold_gen, wrap_width() if app.wrap else 0, app.fs, app.wrap}
	if key == b.disp_key && len(b.disp) > 0 do return
	b.disp_key = key
	clear(&b.disp)
	fi := 0
	W := key.width
	max_adv := f32(get_glyph('W', app.fs).adv) * 2 // wide glyphs: a byte never draws wider than this
	for l := 0; l < len(b.lines); l += 1 {
		append(&b.disp, Disp_Row{i32(l), 0})
		if app.wrap && f32(len(b.lines[l])) * max_adv > W do wrap_line(b, l, W)
		for fi < len(b.folds) && b.folds[fi].end < l do fi += 1
		if fi < len(b.folds) && b.folds[fi].line == l do l = b.folds[fi].end // skip the hidden lines
	}
}

// Extra rows for a line wider than W: break after the last space that fits, else mid-word.
@(private = "file")
wrap_line :: proc(b: ^Buffer, l: int, W: f32) {
	tabw := f32(b.tab_size) * app.cell_w
	s := line_str(b, l)
	x, start_x: f32
	c0, brk := 0, -1
	for r, i in s {
		nx := (math.floor(x / tabw) + 1) * tabw if r == '\t' else x + f32(get_glyph(r, app.fs).adv)
		if nx - start_x > W && i > c0 {
			at := brk if brk > c0 else i
			append(&b.disp, Disp_Row{i32(l), i32(at)})
			c0, brk = at, -1
			start_x = x_in_line(b, l, at)
		}
		x = nx
		if r == ' ' || r == '\t' do brk = i + 1
	}
}

row_count :: proc(b: ^Buffer) -> int {
	if !disp_on(b) do return len(b.lines)
	disp_update(b)
	return len(b.disp)
}

// Line and byte range [c0, c1) shown on row r (clamped).
row_info :: proc(b: ^Buffer, r: int) -> (line, c0, c1: int) {
	if !disp_on(b) {
		l := clamp(r, 0, len(b.lines) - 1)
		return l, 0, len(b.lines[l])
	}
	disp_update(b)
	r := clamp(r, 0, len(b.disp) - 1)
	d := b.disp[r]
	line, c0 = int(d.line), int(d.c0)
	c1 = len(b.lines[line])
	if r + 1 < len(b.disp) && int(b.disp[r + 1].line) == line do c1 = int(b.disp[r + 1].c0)
	return
}

// Row showing p (a hidden line maps to its fold's header row).
row_of :: proc(b: ^Buffer, p: Pos) -> int {
	if !disp_on(b) do return clamp(p.line, 0, len(b.lines) - 1)
	disp_update(b)
	i, _ := slice.binary_search_by(b.disp[:], p, proc(d: Disp_Row, p: Pos) -> slice.Ordering {
		if int(d.line) != p.line do return .Less if int(d.line) < p.line else .Greater
		if int(d.c0) != p.col do return .Less if int(d.c0) < p.col else .Greater
		return .Equal
	})
	// binary_search gives the insertion point: the row starting at or before p
	if i < len(b.disp) && int(b.disp[i].line) == p.line && int(b.disp[i].c0) == p.col do return i
	return max(i - 1, 0)
}

// Pixel x of byte col on its row, from the row's left edge.
row_x :: proc(b: ^Buffer, p: Pos) -> f32 {
	l, c0, _ := row_info(b, row_of(b, p))
	if l != p.line do return 0
	return x_in_line(b, p.line, p.col) - x_in_line(b, p.line, c0)
}

// Byte on row r nearest to x (row-relative).
col_on_row :: proc(b: ^Buffer, r: int, x: f32) -> Pos {
	l, c0, c1 := row_info(b, r)
	c := col_at_x(b, l, x + x_in_line(b, l, c0))
	last := c1 >= len(b.lines[l])
	if !last && c >= c1 do c = prev_col(b, {l, c1}).col // the break belongs to the next row
	return {l, clamp(c, c0, c1)}
}

// Screen y of the row showing p, in the current text area.
y_of :: proc(b: ^Buffer, p: Pos) -> f32 {
	return app.text.y + (f32(row_of(b, p)) - b.scroll_y) * app.line_h
}

// First line drawn at the top (for the minimap).
top_line :: proc(b: ^Buffer) -> int {
	l, _, _ := row_info(b, int(b.scroll_y))
	return l
}

scroll_center :: proc(b: ^Buffer, p: Pos) {
	unfold_at(b, p)
	r := f32(row_of(b, p))
	if r < b.scroll_y || r > b.scroll_y + rows() - 2 do b.scroll_y = max(r - rows() / 3, 0)
}

clamp_scroll :: proc(b: ^Buffer) {
	b.scroll_y = clamp(b.scroll_y, 0, f32(max(row_count(b) - 1, 0)))
}

// Up/down by n rows keeping the remembered x.
vert_rows :: proc(b: ^Buffer, n: int, shift: bool) {
	want := b.want_x if b.want_x >= 0 else row_x(b, b.cur)
	p := col_on_row(b, row_of(b, b.cur) + n, want)
	go(b, p, shift, keep_x = true)
	b.want_x = want
}

// ---------------------------------------------------------------------------
// Folding (by indentation, like Zed's indent folds)

@(private = "file")
indent_w :: proc(b: ^Buffer, l: int) -> (w: int, blank: bool) {
	for c in b.lines[l] {
		switch c {
		case ' ': w += 1
		case '\t': w = (w / b.tab_size + 1) * b.tab_size
		case '\r', '\n':
		case: return w, false
		}
	}
	return w, true
}

// Lines below l that are indented deeper than l (blank lines inside count, trailing ones don't).
fold_range :: proc(b: ^Buffer, l: int) -> (end: int, ok: bool) {
	if l < 0 || l >= len(b.lines) do return
	base, blank := indent_w(b, l)
	if blank do return
	end = l
	for k := l + 1; k < len(b.lines); k += 1 {
		w, bl := indent_w(b, k)
		if bl do continue
		if w <= base do break
		end = k
	}
	return end, end > l
}

foldable :: proc(b: ^Buffer, l: int) -> bool {
	base, blank := indent_w(b, l)
	if blank do return false
	for k := l + 1; k < len(b.lines); k += 1 {
		w, bl := indent_w(b, k)
		if !bl do return w > base
	}
	return false
}

fold_at_line :: proc(b: ^Buffer, l: int) -> int {
	for f, i in b.folds do if f.line == l do return i
	return -1
}

add_fold :: proc(b: ^Buffer, l: int) -> bool {
	end, ok := fold_range(b, l)
	if !ok || fold_at_line(b, l) >= 0 do return false
	// a fold swallows the folds inside it
	for i := len(b.folds) - 1; i >= 0; i -= 1 do if b.folds[i].line > l && b.folds[i].line <= end do ordered_remove(&b.folds, i)
	append(&b.folds, Fold{l, end})
	slice.sort_by(b.folds[:], proc(x, y: Fold) -> bool {return x.line < y.line})
	b.fold_gen += 1
	// carets inside go to the header
	if b.cur.line > l && b.cur.line <= end do b.cur, b.anchor = {l, len(b.lines[l])}, {l, len(b.lines[l])}
	return true
}

toggle_fold_line :: proc(b: ^Buffer, l: int) {
	if i := fold_at_line(b, l); i >= 0 {
		ordered_remove(&b.folds, i)
		b.fold_gen += 1
	} else {
		add_fold(b, l)
	}
}

// Fold the innermost block around the caret.
fold_here :: proc(b: ^Buffer) {
	l := b.cur.line
	if foldable(b, l) && fold_at_line(b, l) < 0 {
		add_fold(b, l)
		return
	}
	for k := l - 1; k >= 0; k -= 1 {
		if end, ok := fold_range(b, k); ok && end >= l && fold_at_line(b, k) < 0 {
			add_fold(b, k)
			return
		}
	}
}

unfold_here :: proc(b: ^Buffer) {
	unfold_at(b, b.cur)
	if i := fold_at_line(b, b.cur.line); i >= 0 {
		ordered_remove(&b.folds, i)
		b.fold_gen += 1
	}
}

// Opens any fold hiding p.
unfold_at :: proc(b: ^Buffer, p: Pos) {
	for i := len(b.folds) - 1; i >= 0; i -= 1 {
		f := b.folds[i]
		if p.line > f.line && p.line <= f.end {
			ordered_remove(&b.folds, i)
			b.fold_gen += 1
		}
	}
}

fold_all :: proc(b: ^Buffer) {
	for l := 0; l < len(b.lines); l += 1 {
		if end, ok := fold_range(b, l); ok {
			add_fold(b, l)
			l = end
		}
	}
}

unfold_all :: proc(b: ^Buffer) {
	clear(&b.folds)
	b.fold_gen += 1
}

// Called by replace before the text changes: shift folds below, drop folds the edit touches.
folds_edit :: proc(b: ^Buffer, a, z: Pos, text: string) {
	b.edit_gen += 1
	if len(b.folds) == 0 do return
	delta := 0
	for c in text do if c == '\n' do delta += 1
	delta -= z.line - a.line
	for i := len(b.folds) - 1; i >= 0; i -= 1 {
		f := &b.folds[i]
		switch {
		case a.line > f.end: // above the edit: untouched
		case z.line < f.line:
			f.line += delta
			f.end += delta
		case a.line == f.line && z.line == f.line && delta == 0: // typing on the header line
		case:
			ordered_remove(&b.folds, i)
		}
	}
	b.fold_gen += 1
}
