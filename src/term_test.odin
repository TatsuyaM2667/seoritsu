package main

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
row_text :: proc(y: int) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	cells := (term.alt if term.using_alt else term.grid)[y * term.cols:][:term.cols]
	for cl in cells {
		if cl.cont do continue
		r := cl.r if cl.r != 0 else ' '
		buf, n := encode(r)
		append(&out, ..buf[:n])
	}
	s := string(out[:])
	for len(s) > 0 && s[len(s) - 1] == ' ' do s = s[:len(s) - 1]
	return s
	encode :: proc(r: rune) -> ([4]u8, int) {
		b: [4]u8
		switch {
		case r < 0x80: b[0] = u8(r); return b, 1
		case r < 0x800: b[0], b[1] = u8(0xC0 | r >> 6), u8(0x80 | r & 0x3F); return b, 2
		case r < 0x10000: b[0], b[1], b[2] = u8(0xE0 | r >> 12), u8(0x80 | (r >> 6) & 0x3F), u8(0x80 | r & 0x3F); return b, 3
		}
		b[0], b[1], b[2], b[3] = u8(0xF0 | r >> 18), u8(0x80 | (r >> 12) & 0x3F), u8(0x80 | (r >> 6) & 0x3F), u8(0x80 | r & 0x3F)
		return b, 4
	}
}

@(test)
vt_parser :: proc(t: ^testing.T) {
	term.grid, term.alt, term.cols, term.rows, term.scrollback, term.params = nil, nil, 0, 0, nil, nil
	term.using_alt, term.alive, term.state = false, false, .Ground
	term_resize(10, 3)
	term_reset()
	term_feed(transmute([]u8)string("hello\r\nworld"))
	testing.expect_value(t, row_text(0), "hello")
	testing.expect_value(t, row_text(1), "world")
	// cursor movement, erase to end of line, colors
	term_feed(transmute([]u8)string("\x1b[1;3H\x1b[K\x1b[31mX\x1b[0m"))
	testing.expect_value(t, row_text(0), "heX")
	testing.expect_value(t, term.grid[2].fg, ansi(1))
	// wide characters take two cells; wrapping and scrolling into history
	term_feed(transmute([]u8)string("\x1b[3;1H日本語abcdefg"))
	testing.expect_value(t, row_text(1), "日本語abcd")
	testing.expect_value(t, row_text(2), "efg")
	testing.expect_value(t, len(term.scrollback), 1)
	// alternate screen keeps the main one
	term_feed(transmute([]u8)string("\x1b[?1049h\x1b[2J\x1b[Halt"))
	testing.expect_value(t, row_text(0), "alt")
	term_feed(transmute([]u8)string("\x1b[?1049l"))
	testing.expect_value(t, row_text(2), "efg")
	// OSC title is skipped, split UTF-8 across reads is joined
	term_feed(transmute([]u8)string("\x1b]0;title\x07\r\n"))
	b := transmute([]u8)string("é")
	term_feed(b[:1])
	term_feed(b[1:])
	testing.expect_value(t, row_text(2), "é")
}

@(test)
split_panes :: proc(t: ^testing.T) {
	a, b := new(Buffer), new(Buffer)
	set_text(a, "aaa\nbbb")
	set_text(b, "x")
	a.path, b.path = "/tmp/a", "/tmp/b"
	app.bufs, panes, pane_i = nil, nil, 0
	append(&app.bufs, a, b)
	app.active = 0
	app.W, app.H, app.panel_on = 1000, 600, false

	split_right()
	testing.expect_value(t, pane_count(), 2)
	testing.expect_value(t, pane_i, 1)
	testing.expect_value(t, len(app.bufs), 1) // the new pane starts with the same file
	testing.expect(t, cur_buf() == a, "same document")
	a.cur = {1, 2}
	focus_pane(0)
	testing.expect_value(t, a.cur, Pos{0, 0}) // each pane keeps its own caret
	focus_pane(1)
	testing.expect_value(t, a.cur, Pos{1, 2})
	testing.expect_value(t, len(all_bufs()), 2)
	testing.expect(t, open_elsewhere(a), "a is in the other pane too")

	close_tab(0) // last tab of pane 1: the pane goes away
	testing.expect_value(t, pane_count(), 1)
	testing.expect_value(t, len(app.bufs), 2)
	panes = nil
}

// A real shell on a real pty: run a command and see its output on the grid.
@(test)
pty_shell :: proc(t: ^testing.T) {
	term.grid, term.alt, term.cols, term.rows, term.scrollback, term.params = nil, nil, 0, 0, nil, nil
	term.using_alt, term.state = false, .Ground
	old_shell := os.get_env("SHELL", context.temp_allocator)
	os.set_env("SHELL", "/bin/sh")
	defer os.set_env("SHELL", old_shell)
	project_root = "/tmp"
	term_resize(40, 5)
	testing.expect(t, term_start(), "pty + fork")
	term_write("echo hi-$((1+2))\n")
	found := false
	for _ in 0 ..< 200 {
		term_poll()
		for y in 0 ..< term.rows do if strings.contains(row_text(y), "hi-3") && !strings.contains(row_text(y), "echo") do found = true
		if found do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, found, "command output reached the grid")
	term_write("exit\n")
	for _ in 0 ..< 200 {
		term_poll()
		if !term.alive do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, !term.alive, "shell exit closes the terminal")
}
