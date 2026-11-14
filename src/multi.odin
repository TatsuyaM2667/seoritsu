package main

// Multiple cursors. Every single-cursor command runs once per caret, bottom-up,
// while `replace` shifts the other carets; the whole round is one undo step.

import "core:slice"
import "core:strings"

each_caret :: proc(b: ^Buffer, f: proc(b: ^Buffer)) {
	if len(b.extra) == 0 {
		f(b)
		return
	}
	clear(&b.carets)
	append(&b.carets, [2]Pos{b.anchor, b.cur})
	append(&b.carets, ..b.extra[:])
	idx := make([]int, len(b.carets), context.temp_allocator)
	for &v, i in idx do v = i
	slice.sort_by(idx, proc(x, y: int) -> bool {
		b := cur_buf()
		return lt(b.carets[y][1], b.carets[x][1])
	})
	b.next_group += 1
	b.group = b.next_group
	b.in_multi = true
	for i in idx {
		b.active_caret = i
		b.anchor, b.cur = b.carets[i][0], b.carets[i][1]
		f(b)
		b.carets[i] = {b.anchor, b.cur}
	}
	b.in_multi = false
	b.active_caret = -1
	b.anchor, b.cur = b.carets[0][0], b.carets[0][1]
	clear(&b.extra)
	// carets that ran into each other become one
	outer: for c in b.carets[1:] {
		if c[1] == b.cur do continue
		for e in b.extra do if e[1] == c[1] do continue outer
		append(&b.extra, c)
	}
	clear(&b.carets)
	b.last_edit_ms = 0 // the next typing round starts a new undo group only if needed
}

add_caret :: proc(b: ^Buffer, p: Pos) {
	for e, i in b.extra do if e[1] == p {
		unordered_remove(&b.extra, i) // alt+click on a caret removes it
		return
	}
	if p == b.cur do return
	append(&b.extra, [2]Pos{b.anchor, b.cur})
	b.anchor, b.cur = p, p
}

// Ctrl+D: select the word, then add the next occurrence of the selection.
add_next_occurrence :: proc(b: ^Buffer) {
	if !has_sel(b) {
		b.anchor, b.cur = word_at(b, b.cur)
		return
	}
	a, z := order(b.anchor, b.cur)
	if a.line != z.line do return
	needle := string(b.lines[a.line][a.col:z.col])
	p := z
	n := len(b.lines)
	for k in 0 ..= n {
		l := (p.line + k) % n
		s := line_str(b, l)
		from := p.col if k == 0 else 0
		if k == n do s = s[:min(a.col + len(needle), len(s))]
		if from > len(s) do continue
		if j := strings.index(s[from:], needle); j >= 0 {
			q := Pos{l, from + j}
			if q == a do return // wrapped around to the start: everything is selected
			for e in b.extra do if e[0] == q do return
			append(&b.extra, [2]Pos{b.anchor, b.cur})
			b.anchor, b.cur = q, Pos{l, q.col + len(needle)}
			ensure_visible(b)
			return
		}
	}
}

// Ctrl+Shift+L: a caret on every occurrence of the selection (or word).
select_all_occurrences :: proc(b: ^Buffer) {
	if !has_sel(b) do b.anchor, b.cur = word_at(b, b.cur)
	a, z := order(b.anchor, b.cur)
	if a.line != z.line || a == z do return
	needle := strings.clone(string(b.lines[a.line][a.col:z.col]), context.temp_allocator)
	clear(&b.extra)
	for l in 0 ..< len(b.lines) {
		s := line_str(b, l)
		from := 0
		for {
			j := strings.index(s[from:], needle)
			if j < 0 do break
			q := Pos{l, from + j}
			if q != a do append(&b.extra, [2]Pos{q, Pos{l, q.col + len(needle)}})
			from = q.col + len(needle)
		}
	}
}

// Ctrl+Alt+Up/Down: a caret on the line above / below, same x.
add_caret_vertical :: proc(b: ^Buffer, dir: int) {
	edge := b.cur
	for e in b.extra {
		if (dir < 0 && e[1].line < edge.line) || (dir > 0 && e[1].line > edge.line) do edge = e[1]
	}
	l := edge.line + dir
	if l < 0 || l >= len(b.lines) do return
	x := x_in_line(b, edge.line, edge.col)
	q := Pos{l, col_at_x(b, l, x)}
	append(&b.extra, [2]Pos{b.anchor, b.cur})
	b.anchor, b.cur = q, q
	ensure_visible(b)
}
