package main

// Text buffer: one byte array per line. Every change goes through `replace`,
// which records undo, keeps semantic tokens aligned and marks the LSP copy stale.

import "core:os"
import "core:strings"
import "core:unicode/utf8"

Pos :: struct {
	line, col: int, // col = byte offset in the line
}

Edit :: struct {
	at:       Pos,
	removed:  string,
	inserted: string,
	group:    int,
}

Tok :: struct {
	line, col, len: i32,
	style:          Style,
}

Diag :: struct {
	a, b:     Pos,
	severity: int, // 1 error, 2 warning, 3 info, 4 hint
	message:  string,
	raw:      string, // the diagnostic as the server sent it (for code actions)
}

Buffer :: struct {
	path:            string,
	lines:           [dynamic][dynamic]u8,
	crlf:            bool,
	lang:            ^Language,
	cur, anchor:     Pos, // selection = anchor..cur
	want_x:          f32, // remembered x for up/down
	scroll_y:        f32, // in lines (fractional for smooth wheel)
	scroll_x:        f32,
	undo, redo:      [dynamic]Edit,
	group:           int, // id of the newest applied undo group (0 = original text)
	next_group:      int, // ids are never reused, so saved_group stays meaningful
	last_edit_ms:    i64,
	saved_group:     int, // undo depth (group id) at last save
	dirty:           bool,
	hard_tabs:       bool,
	tab_size:        int,
	bstate:          [dynamic]bool, // "inside a block comment" at the start of each line
	// language server state
	version:         int,
	lsp_stale:       bool,
	toks:            [dynamic]Tok,
	toks_due:        i64, // when to ask for semantic tokens again
	diags:           [dynamic]Diag,
	changes:         [dynamic]Change, // edits not yet sent to the server (incremental sync)
	hints:           [dynamic]Hint,
	git:             [dynamic]Git_Mark,
	mtime:           i64,
	// multiple cursors: extra (anchor, cur) pairs besides anchor/cur
	extra:           [dynamic][2]Pos,
	carets:          [dynamic][2]Pos, // all carets while each_caret runs
	active_caret:    int,
	in_multi:        bool,
	// tree-sitter (ts.odin)
	ts_parser:       rawptr,
	ts_tree:         rawptr,
	ts_dirty:        bool, // tree is behind the text
	ts_lo, ts_hi:    int, // lines ts_lines covers this frame
	ts_lines:        [][]Style,
	ts_set:          [][]bool, // which bytes the query colored
}

Change :: struct {
	a, z:     Pos, // bytes, in the document as it was right before this change
	a16, z16: int, // the same columns in UTF-16 units
	text:     string,
}

Hint :: struct {
	line, col: i32,
	label:     string,
}

Git_Kind :: enum u8 {Added, Modified, Deleted}
Git_Mark :: struct {
	line: i32,
	kind: Git_Kind,
}

// Where position p ends up after a..z was replaced by text ending at e.
shift_pos :: proc(p, a, z, e: Pos) -> Pos {
	if lt(p, a) do return p
	if lt(p, z) do return e
	if p.line == z.line do return {e.line, e.col + p.col - z.col}
	return {p.line + e.line - z.line, p.col}
}

lt :: proc(a, b: Pos) -> bool {return a.line < b.line || (a.line == b.line && a.col < b.col)}
order :: proc(a, b: Pos) -> (Pos, Pos) {
	if lt(b, a) do return b, a
	return a, b
}
has_sel :: proc(b: ^Buffer) -> bool {return b.cur != b.anchor}

line_str :: proc(b: ^Buffer, l: int) -> string {return string(b.lines[l][:])}

buffer_load :: proc(path: string) -> (b: ^Buffer, ok: bool) {
	b = new(Buffer)
	b.path = strings.clone(path)
	b.lang = language_for(path)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil && os.exists(path) {
		free(b)
		return nil, false
	}
	text := string(data)
	b.crlf = strings.contains(text, "\r\n")
	if b.crlf do text, _ = strings.remove_all(text, "\r", context.temp_allocator)
	set_text(b, text)
	b.mtime = file_mtime(path)
	b.tab_size = b.lang.tab_size if b.lang != nil else 4
	b.hard_tabs = b.lang != nil && b.lang.hard_tabs
	for l in b.lines[:min(len(b.lines), 300)] {
		if len(l) > 1 && (l[0] == '\t' || (l[0] == ' ' && l[1] == ' ')) { // first indented line decides
			b.hard_tabs = l[0] == '\t'
			break
		}
	}
	b.want_x = -1
	return b, true
}

set_text :: proc(b: ^Buffer, text: string) {
	if b.ts_tree != nil do ts_tree_delete(b.ts_tree)
	b.ts_tree, b.ts_dirty = nil, true
	if b.ts_parser != nil do ts_parser_reset(b.ts_parser)
	for &l in b.lines do delete(l)
	clear(&b.lines)
	t := text
	for {
		i := strings.index_byte(t, '\n')
		line := make([dynamic]u8, 0, max(i if i >= 0 else len(t), 8))
		append(&line, ..transmute([]u8)(t[:i] if i >= 0 else t))
		append(&b.lines, line)
		if i < 0 do break
		t = t[i + 1:]
	}
}

buffer_text :: proc(b: ^Buffer, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	nl := "\r\n" if b.crlf else "\n"
	for l, i in b.lines {
		if i > 0 do strings.write_string(&sb, nl)
		strings.write_bytes(&sb, l[:])
	}
	return strings.to_string(sb)
}

buffer_save :: proc(b: ^Buffer) -> bool {
	if os.write_entire_file(b.path, transmute([]u8)buffer_text(b)) != nil do return false
	b.dirty = false
	b.saved_group = b.group
	b.mtime = file_mtime(b.path)
	return true
}

file_mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	return 0 if err != nil else fi.modification_time._nsec
}

// The file changed on disk (another program, git checkout…): take the new text as
// one undoable edit, so cursors, tokens and the server copy stay consistent.
buffer_reload :: proc(b: ^Buffer) -> bool {
	data, err := os.read_entire_file(b.path, context.temp_allocator)
	if err != nil do return false
	text, _ := strings.remove_all(string(data), "\r", context.temp_allocator)
	b.mtime = file_mtime(b.path)
	if text == buffer_text(b) && !b.crlf do return false
	last := len(b.lines) - 1
	cur := b.cur
	replace(b, {}, {last, len(b.lines[last])}, text)
	b.cur = clamp_pos(b, cur)
	b.anchor = b.cur
	b.dirty = false
	b.saved_group = b.group
	return true
}

text_range :: proc(b: ^Buffer, a, z: Pos, allocator := context.temp_allocator) -> string {
	a, z := order(a, z)
	if a.line == z.line do return strings.clone(string(b.lines[a.line][a.col:z.col]), allocator)
	sb := strings.builder_make(allocator)
	strings.write_bytes(&sb, b.lines[a.line][a.col:])
	for l in a.line + 1 ..< z.line {
		strings.write_byte(&sb, '\n')
		strings.write_bytes(&sb, b.lines[l][:])
	}
	strings.write_byte(&sb, '\n')
	strings.write_bytes(&sb, b.lines[z.line][:z.col])
	return strings.to_string(sb)
}

clamp_pos :: proc(b: ^Buffer, p: Pos) -> Pos {
	l := clamp(p.line, 0, len(b.lines) - 1)
	return {l, clamp(p.col, 0, len(b.lines[l]))}
}

// Replaces a..z with text, returns the end of the inserted text.
// record=false is used by undo/redo themselves.
replace :: proc(b: ^Buffer, a, z: Pos, text: string, record := true, merge := false) -> Pos {
	a, z := order(clamp_pos(b, a), clamp_pos(b, z))
	removed := text_range(b, a, z, context.allocator)
	if record {
		now := ticks_ms()
		if b.in_multi {
			// every caret's edit joins the group each_caret opened
		} else if !merge || now - b.last_edit_ms > 800 || len(b.undo) == 0 || b.undo[len(b.undo) - 1].group != b.group {
			b.next_group += 1
			b.group = b.next_group
		}
		b.last_edit_ms = now
		append(&b.undo, Edit{a, removed, strings.clone(text), b.group})
		for e in b.redo {delete(e.removed); delete(e.inserted)}
		clear(&b.redo)
	} else {
		delete(removed)
	}
	append(&b.changes, Change{a, z, to_lsp_col(b, a, true), to_lsp_col(b, z, true), strings.clone(text)})
	ts_edit(b, a, z, text)
	suffix := strings.clone(string(b.lines[z.line][z.col:]), context.temp_allocator)
	resize(&b.lines[a.line], a.col)
	// drop lines a+1..z
	for l in a.line + 1 ..= z.line do delete(b.lines[l])
	remove_range(&b.lines, a.line + 1, z.line + 1)
	parts := strings.split(text, "\n", context.temp_allocator)
	append(&b.lines[a.line], ..transmute([]u8)parts[0])
	for p, i in parts[1:] {
		nl := make([dynamic]u8, 0, len(p) + 8)
		append(&nl, ..transmute([]u8)p)
		inject_at(&b.lines, a.line + 1 + i, nl)
	}
	end := Pos{a.line + len(parts) - 1, len(b.lines[a.line + len(parts) - 1])}
	append(&b.lines[end.line], ..transmute([]u8)suffix)

	// keep semantic tokens below the edit aligned until the server sends fresh ones
	delta := i32(len(parts) - 1 - (z.line - a.line))
	j := 0
	for t in b.toks {
		if int(t.line) >= a.line && int(t.line) <= z.line do continue
		nt := t
		if int(t.line) > z.line do nt.line += delta
		b.toks[j] = nt
		j += 1
	}
	resize(&b.toks, j)
	j = 0
	for h in b.hints {
		if int(h.line) >= a.line && int(h.line) <= z.line {
			delete(h.label)
			continue
		}
		nh := h
		if int(h.line) > z.line do nh.line += delta
		b.hints[j] = nh
		j += 1
	}
	resize(&b.hints, j)
	for &g in b.git do if int(g.line) > z.line do g.line += delta
	for &d in b.diags {
		d.a = shift_pos(d.a, a, z, end)
		d.b = shift_pos(d.b, a, z, end)
	}
	for &c, i in b.carets do if i != b.active_caret {
		c[0] = shift_pos(c[0], a, z, end)
		c[1] = shift_pos(c[1], a, z, end)
	}
	if len(b.bstate) > a.line + 1 do resize(&b.bstate, a.line + 1)
	b.dirty = true
	b.lsp_stale = true
	b.version += 1
	return end
}

undo :: proc(b: ^Buffer, redo := false) {
	from, to := &b.undo, &b.redo
	if redo do from, to = &b.redo, &b.undo
	if len(from) == 0 do return
	g := from[len(from) - 1].group
	for len(from) > 0 && from[len(from) - 1].group == g {
		e := pop(from)
		// undo: remove `inserted`, put back `removed`; redo the opposite
		put, take := e.removed, e.inserted
		if redo do put, take = e.inserted, e.removed
		end := advance(e.at, take)
		p := replace(b, e.at, end, put, record = false)
		b.cur, b.anchor = p, p
		append(to, e)
	}
	b.group = g if redo else (b.undo[len(b.undo) - 1].group if len(b.undo) > 0 else 0)
	b.dirty = b.group != b.saved_group
}

// Position after walking over text starting at p.
advance :: proc(p: Pos, text: string) -> Pos {
	n := strings.count(text, "\n")
	if n == 0 do return {p.line, p.col + len(text)}
	return {p.line + n, len(text) - strings.last_index_byte(text, '\n') - 1}
}

// ---------------------------------------------------------------------------
// Cursor helpers

is_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80
}

next_col :: proc(b: ^Buffer, p: Pos) -> Pos {
	if p.col >= len(b.lines[p.line]) {
		return {p.line + 1, 0} if p.line + 1 < len(b.lines) else p
	}
	_, n := utf8.decode_rune(b.lines[p.line][p.col:])
	return {p.line, p.col + n}
}

prev_col :: proc(b: ^Buffer, p: Pos) -> Pos {
	if p.col == 0 do return {p.line - 1, len(b.lines[p.line - 1])} if p.line > 0 else p
	_, n := utf8.decode_last_rune(b.lines[p.line][:p.col])
	return {p.line, p.col - n}
}

word_left :: proc(b: ^Buffer, p: Pos) -> Pos {
	p := prev_col(b, p)
	l := b.lines[p.line][:]
	for p.col > 0 && l[p.col] == ' ' do p.col -= 1
	if p.col < len(l) && is_word_byte(l[p.col]) {
		for p.col > 0 && is_word_byte(l[p.col - 1]) do p.col -= 1
	}
	return p
}

word_right :: proc(b: ^Buffer, p: Pos) -> Pos {
	l := b.lines[p.line][:]
	if p.col >= len(l) do return next_col(b, p)
	p := p
	for p.col < len(l) && l[p.col] == ' ' do p.col += 1
	if p.col < len(l) && is_word_byte(l[p.col]) {
		for p.col < len(l) && is_word_byte(l[p.col]) do p.col += 1
	} else if p.col < len(l) {
		p.col += 1
	}
	return p
}

word_at :: proc(b: ^Buffer, p: Pos) -> (a, z: Pos) {
	l := b.lines[p.line][:]
	a, z = p, p
	for a.col > 0 && is_word_byte(l[a.col - 1]) do a.col -= 1
	for z.col < len(l) && is_word_byte(l[z.col]) do z.col += 1
	return
}

indent_of :: proc(b: ^Buffer, l: int) -> string {
	s := line_str(b, l)
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') do i += 1
	return s[:i]
}

// LSP positions: we ask for utf-8, but servers may insist on utf-16.
to_lsp_col :: proc(b: ^Buffer, p: Pos, utf16: bool) -> int {
	if !utf16 do return p.col
	n := 0
	p := clamp_pos(b, p)
	for r in string(b.lines[p.line][:p.col]) do n += 2 if r > 0xffff else 1
	return n
}

from_lsp_col :: proc(b: ^Buffer, line, col: int, utf16: bool) -> Pos {
	if line >= len(b.lines) do return {len(b.lines) - 1, len(b.lines[len(b.lines) - 1])}
	if line < 0 do return {}
	if !utf16 do return {line, min(col, len(b.lines[line]))}
	n := 0
	for r, i in string(b.lines[line][:]) {
		if n >= col do return {line, i}
		n += 2 if r > 0xffff else 1
	}
	return {line, len(b.lines[line])}
}
