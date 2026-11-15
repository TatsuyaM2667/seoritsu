package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// ---------------------------------------------------------------------------
// Git gutter: compare the file on disk with HEAD (`git diff -U0`)

git_refresh :: proc(b: ^Buffer) {
	clear(&b.git)
	dir := filepath.dir(b.path)
	_, out, _, err := os.process_exec({command = {"git", "-C", dir, "diff", "HEAD", "-U0", "--no-color", "--no-ext-diff", "--", b.path}}, context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(out), context.temp_allocator) {
		if !strings.has_prefix(line, "@@ ") do continue
		// @@ -a[,b] +c[,d] @@
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 3 do continue
		_, old_n := hunk(f[1])
		new_s, new_n := hunk(f[2])
		switch {
		case new_n == 0:
			append(&b.git, Git_Mark{i32(max(new_s, 0)), .Deleted}) // removed between new_s and new_s+1
		case old_n == 0:
			for l in new_s - 1 ..< new_s - 1 + new_n do append(&b.git, Git_Mark{i32(l), .Added})
		case:
			for l in new_s - 1 ..< new_s - 1 + new_n do append(&b.git, Git_Mark{i32(l), .Modified})
		}
	}
	hunk :: proc(s: string) -> (start, n: int) {
		s := s[1:]
		n = 1
		if i := strings.index_byte(s, ','); i >= 0 {
			n, _ = strconv.parse_int(s[i + 1:])
			s = s[:i]
		}
		start, _ = strconv.parse_int(s)
		return
	}
}

// ---------------------------------------------------------------------------
// Files changed by other programs: picked up when the window gets focus again

check_external_changes :: proc() {
	for b in all_bufs() {
		m := file_mtime(b.path)
		if m == 0 || m == b.mtime do continue
		if b.dirty {
			b.mtime = m
			toast(fmt.tprintf("%s は外部で変更されています (未保存の変更があるため再読み込みしません)", filepath.base(b.path)))
		} else if buffer_reload(b) {
			git_refresh(b)
		}
	}
	refresh_tree() // files added / removed / committed elsewhere
}

// ---------------------------------------------------------------------------
// Session: open tabs and caret per project, restored when started without files

@(private = "file")
session_path :: proc() -> string {
	return pj(state_dir(), fmt.tprintf("%x.session", hash.fnv64a(transmute([]u8)project_root)))
}

session_save :: proc() {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%d\n", app.active)
	for b in all_bufs() do fmt.sbprintf(&sb, "%d\t%d\t%d\t%s\n", b.cur.line, b.cur.col, int(b.scroll_y), b.path)
	_ = os.write_entire_file(session_path(), transmute([]u8)strings.to_string(sb))
}

session_restore :: proc() {
	data, err := os.read_entire_file(session_path(), context.temp_allocator)
	if err != nil do return
	lines := strings.split_lines(string(data), context.temp_allocator)
	active, _ := strconv.parse_int(lines[0])
	for l in lines[1:] {
		f := strings.split_n(l, "\t", 4, context.temp_allocator)
		if len(f) < 4 || !os.exists(f[3]) do continue
		b := open_file(f[3])
		if b == nil do continue
		ln, _ := strconv.parse_int(f[0])
		cl, _ := strconv.parse_int(f[1])
		sy, _ := strconv.parse_int(f[2])
		b.cur = clamp_pos(b, {ln, cl})
		b.anchor = b.cur
		b.scroll_y = f32(max(sy, 0))
		clamp_scroll(b)
	}
	app.active = clamp(active, 0, max(len(app.bufs) - 1, 0))
}

// ---------------------------------------------------------------------------
// Bracket under / before the caret and its partner

bracket_pair :: proc(b: ^Buffer) -> (a, z: Pos, ok: bool) {
	OPEN := "([{"
	CLOSE := ")]}"
	line := b.lines[b.cur.line][:]
	for p in ([2]Pos{b.cur, {b.cur.line, b.cur.col - 1}}) {
		if p.col < 0 || p.col >= len(line) do continue
		c := line[p.col]
		if i := strings.index_byte(OPEN, c); i >= 0 {
			if q, found := scan_bracket(b, p, c, CLOSE[i], 1); found do return p, q, true
		}
		if i := strings.index_byte(CLOSE, c); i >= 0 {
			if q, found := scan_bracket(b, p, c, OPEN[i], -1); found do return q, p, true
		}
	}
	return
}

@(private = "file")
scan_bracket :: proc(b: ^Buffer, from: Pos, self, other: u8, dir: int) -> (Pos, bool) {
	depth := 0
	l, c := from.line, from.col
	for steps := 0; steps < 200000; steps += 1 {
		line := b.lines[l][:]
		if c >= 0 && c < len(line) {
			switch line[c] {
			case self: depth += 1
			case other:
				depth -= 1
				if depth == 0 do return {l, c}, true
			}
		}
		c += dir
		if c < 0 || c >= len(line) {
			l += dir
			if l < 0 || l >= len(b.lines) do return {}, false
			c = 0 if dir > 0 else len(b.lines[l]) - 1
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Signature help

show_signature :: proc(b: ^Buffer, label: string) {
	delete(app.sig)
	app.sig = strings.clone(label)
	app.sig_line = b.cur.line
}

draw_signature :: proc() {
	b := cur_buf()
	if app.sig == "" || b == nil || app.mode != .Edit do return
	S := app.S
	w := min(f32(text_width(app.sig, app.fs)) + 24 * S, app.W - 16 * S)
	h := app.line_h + 12 * S
	x := app.text.x - b.scroll_x + x_in_line(b, b.cur.line, b.cur.col) - 20 * S
	y := y_of(b, b.cur) - h - 4 * S
	if y < app.editor.y do y = y_of(b, b.cur) + app.line_h + 4 * S
	r := Rect{clamp(x, 4 * S, app.W - w - 4 * S), y, w, h}
	popup(r)
	set_clip(shrink(r, 6 * S))
	text(r.x + 12 * S, baseline(r, app.fs, false), app.sig, app.fs, col("text"), false)
	reset_clip()
}

// ---------------------------------------------------------------------------
// Minimap

minimap_w :: proc() -> f32 {return math_round(96 * app.S) if app.minimap else 0}

@(private = "file")
math_round :: proc(x: f32) -> f32 {return f32(int(x + 0.5))}

@(private = "file")
mm_line_h :: proc() -> f32 {return 2 * app.S}

minimap_start :: proc(b: ^Buffer) -> int {
	vis := int(app.text.h / mm_line_h())
	total := len(b.lines)
	if total <= vis do return 0
	t := f32(top_line(b)) / max(f32(total) - rows(), 1)
	return clamp(int(t * f32(total - vis)), 0, total - vis)
}

minimap_click :: proc(b: ^Buffer, y: f32) {
	l := f32(minimap_start(b)) + (y - app.text.y) / mm_line_h()
	b.scroll_y = f32(row_of(b, {clamp(int(l), 0, len(b.lines) - 1), 0})) - rows() / 2
	clamp_scroll(b)
}

draw_minimap :: proc(b: ^Buffer) {
	if !app.minimap do return
	S := app.S
	mw := minimap_w()
	r := Rect{app.text.x + app.text.w, app.text.y, mw, app.text.h}
	fill({r.x, r.y, 1, r.h}, col("border.variant"))
	set_clip(r)
	lh := mm_line_h()
	first := minimap_start(b)
	n := int(r.h / lh) + 1
	// visible region
	fill({r.x, r.y + f32(top_line(b) - first) * lh, mw, rows() * lh}, col("element.hover"))
	in_block := block_state(b, first)
	cw := max(S, 1)
	tabw := b.tab_size
	for k in 0 ..< n {
		l := first + k
		if l >= len(b.lines) do break
		styles := lex_line(b, l, &in_block)
		x := 0
		y := r.y + f32(k) * lh
		for c, i in b.lines[l] {
			if c == '\t' {
				x = (x / tabw + 1) * tabw
				continue
			}
			if f32(x) * cw > mw - 4 * S do break
			if c != ' ' && (c < 0x80 || c >= 0xc0) do fill({r.x + 4 * S + f32(x) * cw, y, cw, lh - max(S / 2, 0)}, with_alpha(syntax[styles[i]], 150))
			if c < 0x80 || c >= 0xc0 do x += 1
		}
	}
	for d in b.diags {
		l := d.a.line - first
		if l >= 0 && l < n do fill({r.x + mw - 3 * S, r.y + f32(l) * lh, 3 * S, lh}, diag_color(d.severity))
	}
	reset_clip()
}
