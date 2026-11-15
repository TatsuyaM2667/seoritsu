package main

// Built-in terminal panel (Ctrl+`): the user's $SHELL on a pseudo-terminal, drawn below the
// panes. A small VT/xterm parser: cursor movement, erase, insert/delete, scroll regions,
// SGR colors (16 / 256 / truecolor), alternate screen, bracketed paste, DSR/DA replies.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

Cell :: struct {
	r:      rune,
	fg, bg: u32, // 0 = default, else 0x01RRGGBB
	attr:   u8, // 1 bold, 2 underline, 4 inverse
	cont:   bool, // right half of a wide character
}

ATTR_BOLD :: 1
ATTR_UNDER :: 2
ATTR_INV :: 4
SCROLLBACK :: 3000

Parse_State :: enum {Ground, Esc, Csi, Osc, Osc_Esc, Charset}

term: struct {
	on, focus, alive:  bool,
	fd:                posix.FD,
	pid:               posix.pid_t,
	cols, rows:        int,
	grid, alt:         []Cell,
	using_alt:         bool,
	scrollback:        [dynamic][]Cell,
	view_off:          int, // rows scrolled back into history
	cx, cy:            int,
	saved:             [2]int,
	wrap_pending:      bool,
	top, bot:          int, // scroll region (inclusive)
	fg, bg:            u32,
	attr:              u8,
	cursor_hidden:     bool,
	app_cursor:        bool, // DECCKM: arrows send ESC O x
	bracketed:         bool,
	// parser
	state:             Parse_State,
	params:            [dynamic]int,
	priv:              u8,
	inter:             u8,
	utf:               [4]u8,
	ulen, uneed:       int,
	// layout
	rect, body:        Rect,
	height:            f32, // panel height in px (unscaled)
}

term_on :: proc() -> bool {return term.on}

// Ctrl+`: show + focus, focus it if shown, hide if focused (like Zed).
term_toggle :: proc() {
	switch {
	case !term.on:
		if !term.alive && !term_start() {
			toast("ターミナルを起動できませんでした")
			return
		}
		term.on, term.focus = true, true
	case !term.focus:
		term.focus = true
	case:
		term.on, term.focus = false, false
	}
}

foreign import libc_t "system:c"
@(default_calling_convention = "c", private = "file")
foreign libc_t {
	ioctl :: proc(fd: c.int, req: c.ulong, arg: rawptr) -> c.int ---
}
TIOCSCTTY :: 0x540E
TIOCSWINSZ :: 0x5414

@(private = "file")
Winsize :: struct {
	row, col, xpixel, ypixel: u16,
}

term_start :: proc() -> bool {
	fd := posix.posix_openpt({.RDWR, .NOCTTY})
	if fd < 0 do return false
	if posix.grantpt(fd) != .OK || posix.unlockpt(fd) != .OK {
		posix.close(fd)
		return false
	}
	slave := strings.clone_to_cstring(string(posix.ptsname(fd)), context.temp_allocator)
	shell := os.get_env("SHELL", context.temp_allocator)
	if shell == "" do shell = "/bin/sh"
	cshell := strings.clone_to_cstring(shell, context.temp_allocator)
	argv := []cstring{cshell, nil}
	cwd := strings.clone_to_cstring(project_root, context.temp_allocator)
	if term.cols == 0 do term_resize(80, 24)
	ws := Winsize{u16(term.rows), u16(term.cols), 0, 0}
	pid := posix.fork()
	if pid < 0 {
		posix.close(fd)
		return false
	}
	if pid == 0 {
		posix.setsid()
		s := posix.open(slave, {.RDWR})
		ioctl(c.int(s), TIOCSCTTY, nil)
		ioctl(c.int(s), TIOCSWINSZ, &ws)
		posix.dup2(s, 0)
		posix.dup2(s, 1)
		posix.dup2(s, 2)
		if s > 2 do posix.close(s)
		posix.close(fd)
		posix.setenv("TERM", "xterm-256color", true)
		posix.setenv("COLORTERM", "truecolor", true)
		posix.setenv("TERM_PROGRAM", "seoritsu", true)
		posix.chdir(cwd)
		posix.execv(cshell, raw_data(argv))
		posix._exit(127)
	}
	posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | i32(posix.O_NONBLOCK))
	posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
	term.fd, term.pid, term.alive = fd, pid, true
	return true
}

term_close :: proc() {
	if !term.alive do return
	posix.close(term.fd) // the shell gets SIGHUP
	posix.waitpid(term.pid, nil, {.NOHANG})
	term.alive, term.on, term.focus = false, false, false
}

term_write :: proc(s: string) {
	if !term.alive || len(s) == 0 do return
	data := transmute([]u8)s
	for len(data) > 0 {
		n := posix.write(term.fd, raw_data(data), uint(len(data)))
		if n <= 0 {
			if posix.errno() == .EAGAIN || posix.errno() == .EINTR do continue
			return
		}
		data = data[n:]
	}
}

// Reads what the shell wrote; true if the screen changed.
term_poll :: proc() -> bool {
	if !term.alive do return false
	buf: [16384]u8
	changed := false
	for {
		n := posix.read(term.fd, &buf[0], len(buf))
		if n > 0 {
			term_feed(buf[:n])
			changed = true
			continue
		}
		if n == 0 || (posix.errno() != .EAGAIN && posix.errno() != .EINTR) {
			term_close() // the shell exited
			// keep the next start clean
			term.cx, term.cy, term.using_alt, term.view_off = 0, 0, false, 0
			for &cl in term.grid do cl = {}
			for l in term.scrollback do delete(l)
			clear(&term.scrollback)
			return true
		}
		break
	}
	if changed do term.view_off = 0 // new output jumps back to the bottom
	return changed
}

term_resize :: proc(cols, rows: int) {
	cols, rows := max(cols, 2), max(rows, 1)
	if cols == term.cols && rows == term.rows do return
	remap :: proc(old: []Cell, oc, or_, nc, nr: int) -> []Cell {
		g := make([]Cell, nc * nr)
		if len(old) == 0 do return g
		// keep the bottom rows (where the prompt is)
		shift := max(or_ - nr, 0)
		for y in 0 ..< min(or_, nr) do for x in 0 ..< min(oc, nc) do g[y * nc + x] = old[(y + shift) * oc + x]
		delete(old)
		return g
	}
	shift := max(term.rows - rows, 0)
	term.grid = remap(term.grid, term.cols, term.rows, cols, rows)
	term.alt = remap(term.alt, term.cols, term.rows, cols, rows)
	term.cols, term.rows = cols, rows
	term.cy = clamp(term.cy - shift, 0, rows - 1)
	term.cx = clamp(term.cx, 0, cols - 1)
	term.top, term.bot = 0, rows - 1
	term.wrap_pending = false
	if term.alive {
		ws := Winsize{u16(rows), u16(cols), 0, 0}
		ioctl(c.int(term.fd), TIOCSWINSZ, &ws)
	}
}

@(private = "file")
screen :: proc() -> []Cell {return term.alt if term.using_alt else term.grid}

@(private = "file")
row_cells :: proc(y: int) -> []Cell {return screen()[y * term.cols:][:term.cols]}

@(private = "file")
blank :: proc() -> Cell {return {bg = term.bg}}

@(private = "file")
clear_cells :: proc(cells: []Cell) {for &cl in cells do cl = blank()}

@(private = "file")
scroll_up :: proc(n: int) {
	for _ in 0 ..< n {
		if term.top == 0 && !term.using_alt {
			append(&term.scrollback, slice_clone(row_cells(0)))
			if len(term.scrollback) > SCROLLBACK {
				delete(term.scrollback[0])
				ordered_remove(&term.scrollback, 0)
			}
		}
		for y in term.top ..< term.bot do copy(row_cells(y), row_cells(y + 1))
		clear_cells(row_cells(term.bot))
	}
}

@(private = "file")
scroll_down :: proc(n: int) {
	for _ in 0 ..< n {
		for y := term.bot; y > term.top; y -= 1 do copy(row_cells(y), row_cells(y - 1))
		clear_cells(row_cells(term.top))
	}
}

@(private = "file")
slice_clone :: proc(s: []Cell) -> []Cell {
	out := make([]Cell, len(s))
	copy(out, s)
	return out
}

@(private = "file")
linefeed :: proc() {
	if term.cy == term.bot do scroll_up(1)
	else if term.cy < term.rows - 1 do term.cy += 1
}

// East Asian wide characters and emoji take two cells; combining marks none.
rune_width :: proc(r: rune) -> int {
	switch r {
	case 0x0300 ..= 0x036F, 0x200B ..= 0x200F, 0xFE00 ..= 0xFE0F, 0x20D0 ..= 0x20FF: return 0
	case 0x1100 ..= 0x115F, 0x2E80 ..= 0x303E, 0x3041 ..= 0x33FF, 0x3400 ..= 0x4DBF, 0x4E00 ..= 0x9FFF,
	     0xA000 ..= 0xA4CF, 0xAC00 ..= 0xD7A3, 0xF900 ..= 0xFAFF, 0xFE30 ..= 0xFE4F, 0xFF00 ..= 0xFF60,
	     0xFFE0 ..= 0xFFE6, 0x1F300 ..= 0x1F64F, 0x1F900 ..= 0x1F9FF, 0x20000 ..= 0x3FFFD: return 2
	}
	return 1
}

@(private = "file")
put_char :: proc(r: rune) {
	w := rune_width(r)
	if w == 0 do return // shortcut: combining marks are dropped instead of merged into the previous cell
	if term.wrap_pending {
		term.cx = 0
		linefeed()
		term.wrap_pending = false
	}
	if w == 2 && term.cx == term.cols - 1 {
		row_cells(term.cy)[term.cx] = blank()
		term.cx = 0
		linefeed()
	}
	row := row_cells(term.cy)
	row[term.cx] = {r = r, fg = term.fg, bg = term.bg, attr = term.attr}
	if w == 2 do row[term.cx + 1] = {cont = true, bg = term.bg}
	term.cx += w
	if term.cx >= term.cols {
		term.cx = term.cols - 1
		term.wrap_pending = true
	}
}

term_feed :: proc(data: []u8) {
	if term.cols == 0 do term_resize(80, 24)
	for ch in data {
		switch term.state {
		case .Ground:
			if term.uneed > 0 { // inside a UTF-8 sequence
				if ch & 0xC0 == 0x80 {
					term.utf[term.ulen] = ch
					term.ulen += 1
					if term.ulen == term.uneed {
						r, _ := utf8.decode_rune(term.utf[:term.ulen])
						put_char(r)
						term.uneed = 0
					}
					continue
				}
				term.uneed = 0 // broken sequence: start over with this byte
			}
			switch {
			case ch == 0x1B: term.state = .Esc
			case ch == '\r': term.cx, term.wrap_pending = 0, false
			case ch == '\n' || ch == 0x0B || ch == 0x0C: linefeed(); term.wrap_pending = false
			case ch == 0x08: term.cx, term.wrap_pending = max(term.cx - 1, 0), false
			case ch == '\t': term.cx = min((term.cx / 8 + 1) * 8, term.cols - 1)
			case ch < 0x20 || ch == 0x7F: // BEL, SO/SI, DEL: nothing to draw
			case ch < 0x80: put_char(rune(ch))
			case ch >= 0xC0:
				term.utf[0] = ch
				term.ulen = 1
				term.uneed = 2 if ch < 0xE0 else (3 if ch < 0xF0 else 4)
			}
		case .Esc:
			term.state = .Ground
			switch ch {
			case '[':
				term.state = .Csi
				clear(&term.params)
				append(&term.params, 0)
				term.priv, term.inter = 0, 0
			case ']', 'P', '_', '^': term.state = .Osc // OSC / DCS / APC / PM: skipped up to ST
			case '(', ')', '*', '+': term.state = .Charset
			case '7': term.saved = {term.cx, term.cy}
			case '8': term.cx, term.cy = clamp(term.saved[0], 0, term.cols - 1), clamp(term.saved[1], 0, term.rows - 1)
			case 'D': linefeed()
			case 'E': term.cx = 0; linefeed()
			case 'M':
				if term.cy == term.top do scroll_down(1)
				else do term.cy = max(term.cy - 1, 0)
			case 'c': term_reset()
			}
		case .Charset:
			term.state = .Ground
		case .Osc:
			if ch == 0x07 do term.state = .Ground
			else if ch == 0x1B do term.state = .Osc_Esc
		case .Osc_Esc:
			term.state = .Ground if ch == '\\' else .Osc
		case .Csi:
			switch ch {
			case '0' ..= '9':
				p := &term.params[len(term.params) - 1]
				p^ = min(p^ * 10 + int(ch - '0'), 100000)
			case ';', ':': append(&term.params, 0)
			case '?', '>', '=', '<': term.priv = ch
			case 0x20 ..= 0x2F: term.inter = ch
			case 0x40 ..= 0x7E:
				term.state = .Ground
				csi(ch)
			case 0x18, 0x1A: term.state = .Ground // CAN / SUB abort
			}
		}
	}
}

term_reset :: proc() {
	term.fg, term.bg, term.attr = 0, 0, 0
	term.top, term.bot = 0, term.rows - 1
	term.cx, term.cy, term.wrap_pending = 0, 0, false
	term.cursor_hidden, term.app_cursor, term.bracketed = false, false, false
	clear_cells(term.grid)
}

@(private = "file")
csi :: proc(final: u8) {
	p := term.params[:]
	arg :: proc(p: []int, i: int, def: int) -> int {return p[i] if i < len(p) && p[i] != 0 else def}
	n := arg(p, 0, 1)
	if term.inter != 0 do return // DECSCUSR (cursor shape) and friends
	if term.priv == '?' {
		set := final == 'h'
		if final != 'h' && final != 'l' do return
		for m in p do switch m {
		case 1: term.app_cursor = set
		case 25: term.cursor_hidden = !set
		case 2004: term.bracketed = set
		case 47, 1047, 1049:
			if set == term.using_alt do continue
			if set do term.saved = {term.cx, term.cy}
			term.using_alt = set
			if set do for &cl in term.alt do cl = {}
			else do term.cx, term.cy = term.saved[0], term.saved[1]
		}
		return
	}
	if term.priv == '>' {
		if final == 'c' do term_write("\x1b[>0;0;0c")
		return
	}
	term.wrap_pending = false
	cols, rows := term.cols, term.rows
	switch final {
	case 'A': term.cy = max(term.cy - n, term.top if term.cy >= term.top else 0)
	case 'B', 'e': term.cy = min(term.cy + n, term.bot if term.cy <= term.bot else rows - 1)
	case 'C', 'a': term.cx = min(term.cx + n, cols - 1)
	case 'D': term.cx = max(term.cx - n, 0)
	case 'E': term.cx, term.cy = 0, min(term.cy + n, rows - 1)
	case 'F': term.cx, term.cy = 0, max(term.cy - n, 0)
	case 'G', '`': term.cx = clamp(n - 1, 0, cols - 1)
	case 'd': term.cy = clamp(n - 1, 0, rows - 1)
	case 'H', 'f': term.cy, term.cx = clamp(arg(p, 0, 1) - 1, 0, rows - 1), clamp(arg(p, 1, 1) - 1, 0, cols - 1)
	case 'J':
		cells := screen()
		at := term.cy * cols + term.cx
		switch p[0] {
		case 0: clear_cells(cells[at:])
		case 1: clear_cells(cells[:at + 1])
		case 2: clear_cells(cells)
		case 3:
			for l in term.scrollback do delete(l)
			clear(&term.scrollback)
		}
	case 'K':
		row := row_cells(term.cy)
		switch p[0] {
		case 0: clear_cells(row[term.cx:])
		case 1: clear_cells(row[:term.cx + 1])
		case 2: clear_cells(row)
		}
	case 'X': clear_cells(row_cells(term.cy)[term.cx:][:min(n, cols - term.cx)])
	case '@':
		row := row_cells(term.cy)
		n := min(n, cols - term.cx)
		copy(row[term.cx + n:], row[term.cx:cols - n])
		clear_cells(row[term.cx:][:n])
	case 'P':
		row := row_cells(term.cy)
		n := min(n, cols - term.cx)
		copy(row[term.cx:], row[term.cx + n:])
		clear_cells(row[cols - n:])
	case 'L', 'M':
		if term.cy < term.top || term.cy > term.bot do return
		saved_top := term.top
		term.top = term.cy
		if final == 'L' do scroll_down(min(n, term.bot - term.cy + 1))
		else do for _ in 0 ..< min(n, term.bot - term.cy + 1) { // no scrollback for deleted lines
			for y in term.top ..< term.bot do copy(row_cells(y), row_cells(y + 1))
			clear_cells(row_cells(term.bot))
		}
		term.top = saved_top
	case 'S': scroll_up(n)
	case 'T': scroll_down(n)
	case 'r':
		t, b := arg(p, 0, 1) - 1, arg(p, 1, rows) - 1
		if t < b && b < rows {
			term.top, term.bot = t, b
			term.cx, term.cy = 0, 0
		}
	case 's': term.saved = {term.cx, term.cy}
	case 'u': term.cx, term.cy = clamp(term.saved[0], 0, cols - 1), clamp(term.saved[1], 0, rows - 1)
	case 'm': sgr(p)
	case 'n':
		if p[0] == 6 do term_write(fmt.tprintf("\x1b[%d;%dR", term.cy + 1, term.cx + 1))
		else if p[0] == 5 do term_write("\x1b[0n")
	case 'c': term_write("\x1b[?1;2c")
	}
}

@(private = "file")
sgr :: proc(p: []int) {
	for i := 0; i < len(p); i += 1 {
		switch v := p[i]; v {
		case 0: term.fg, term.bg, term.attr = 0, 0, 0
		case 1: term.attr |= ATTR_BOLD
		case 4: term.attr |= ATTR_UNDER
		case 7: term.attr |= ATTR_INV
		case 22: term.attr &~= ATTR_BOLD
		case 24: term.attr &~= ATTR_UNDER
		case 27: term.attr &~= ATTR_INV
		case 30 ..= 37: term.fg = ansi(v - 30)
		case 90 ..= 97: term.fg = ansi(v - 90 + 8)
		case 39: term.fg = 0
		case 40 ..= 47: term.bg = ansi(v - 40)
		case 100 ..= 107: term.bg = ansi(v - 100 + 8)
		case 49: term.bg = 0
		case 38, 48:
			c: u32
			if i + 2 < len(p) && p[i + 1] == 5 {
				c = ansi(p[i + 2])
				i += 2
			} else if i + 4 < len(p) && p[i + 1] == 2 {
				c = 0x01000000 | u32(p[i + 2] & 255) << 16 | u32(p[i + 3] & 255) << 8 | u32(p[i + 4] & 255)
				i += 4
			} else {
				continue
			}
			if v == 38 do term.fg = c
			else do term.bg = c
		}
	}
}

// xterm's 256-color palette (first 16 tuned for a dark translucent background).
ansi :: proc(n: int) -> u32 {
	BASE := [16]u32{
		0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
		0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xf0f6fc,
	}
	switch {
	case n < 0: return 0
	case n < 16: return 0x01000000 | BASE[n]
	case n < 232:
		k := n - 16
		lv :: proc(x: int) -> u32 {return 0 if x == 0 else u32(55 + x * 40)}
		return 0x01000000 | lv(k / 36) << 16 | lv(k / 6 % 6) << 8 | lv(k % 6)
	case n < 256:
		g := u32(8 + (n - 232) * 10)
		return 0x01000000 | g << 16 | g << 8 | g
	}
	return 0
}

// ---------------------------------------------------------------------------
// Input

// Keys while the terminal has focus; true if consumed.
term_key :: proc(ev: Ev) -> bool {
	ctrl, alt, shift := .Ctrl in ev.mods, .Alt in ev.mods, .Shift in ev.mods
	term.view_off = 0
	mod_param := 1 + (1 if shift else 0) + (2 if alt else 0) + (4 if ctrl else 0)
	arrow :: proc(ch: u8, m: int) -> string {
		if m > 1 do return fmt.tprintf("\x1b[1;%d%c", m, ch)
		return fmt.tprintf("\x1bO%c", ch) if term.app_cursor else fmt.tprintf("\x1b[%c", ch)
	}
	s := ""
	switch ev.key {
	case K_RETURN, K_KP_ENTER: s = "\r"
	case K_BACKSPACE: s = "\x17" if ctrl else "\x7f"
	case K_TAB: s = "\t"
	case K_ISO_LEFT_TAB: s = "\x1b[Z"
	case K_ESCAPE: s = "\x1b"
	case K_UP: s = arrow('A', mod_param)
	case K_DOWN: s = arrow('B', mod_param)
	case K_RIGHT: s = arrow('C', mod_param)
	case K_LEFT: s = arrow('D', mod_param)
	case K_HOME: s = arrow('H', mod_param)
	case K_END: s = arrow('F', mod_param)
	case K_PAGEUP:
		if shift {
			term_wheel(1)
			return true
		}
		s = "\x1b[5~"
	case K_PAGEDOWN:
		if shift {
			term_wheel(-1)
			return true
		}
		s = "\x1b[6~"
	case K_DELETE: s = "\x1b[3~"
	case:
		if ctrl && ev.key >= 'a' && ev.key <= 'z' {
			s = string([]u8{u8(ev.key - 'a' + 1)})
		} else if ctrl && (ev.key == '[' || ev.key == ' ' || ev.key == '\\' || ev.key == ']') {
			s = string([]u8{0x1b if ev.key == '[' else (0 if ev.key == ' ' else (0x1c if ev.key == '\\' else 0x1d))})
		} else if ev.text != "" {
			s = ev.text
		} else {
			return false
		}
		if alt do s = strings.concatenate({"\x1b", s}, context.temp_allocator)
	}
	term_write(s)
	return true
}

term_paste :: proc(t: string) {
	if t == "" do return
	if term.bracketed do term_write("\x1b[200~")
	term_write(t)
	if term.bracketed do term_write("\x1b[201~")
}

term_wheel :: proc(d: f32) {
	if term.using_alt { // full-screen apps get arrow keys, like most terminals
		for _ in 0 ..< 3 do term_write("\x1bOA" if d > 0 else "\x1bOB")
		return
	}
	term.view_off = clamp(term.view_off + int(d * 3), 0, len(term.scrollback))
}

// ---------------------------------------------------------------------------
// Drawing

TERM_HEADER :: 28

// Height of the terminal panel (0 when hidden).
term_h :: proc() -> f32 {
	if !term.on do return 0
	if term.height == 0 do term.height = 280
	return min(term.height * app.S, (app.H - 200 * app.S) * 0.8)
}

term_layout :: proc() {
	S := app.S
	x0 := app.panel.w if app.panel_on else 0
	h := term_h()
	term.rect = {x0, app.status.y - h, app.W - x0, h}
	term.body = {term.rect.x + 8 * S, term.rect.y + TERM_HEADER * S, term.rect.w - 16 * S, h - TERM_HEADER * S - 4 * S}
	if term.on do term_resize(int(term.body.w / app.cell_w), int(term.body.h / app.line_h))
}

term_draw :: proc() {
	if !term.on do return
	S := app.S
	r := term.rect
	fill(r, col("panel.background"))
	fill({r.x, r.y, r.w, 1}, col("accent") if term.focus else col("border"))
	hr := Rect{r.x, r.y, r.w, TERM_HEADER * S}
	bl := baseline(hr, app.ui - i32(S))
	draw_glyph_c(r.x + 12 * S, bl, 0xf120, app.ui - i32(S), col("text.muted"))
	shell := os.get_env("SHELL", context.temp_allocator)
	text(r.x + 32 * S, bl, fmt.tprintf("ターミナル — %s", shell[strings.last_index_byte(shell, '/') + 1:]), app.ui - i32(S), col("text") if term.focus else col("text.muted"))
	cx := r.x + r.w - 34 * S
	cr := Rect{cx, r.y + 4 * S, 26 * S, hr.h - 8 * S}
	if contains(cr, app.mx, app.my) do rrect(cr, 4 * S, col("element.hover"))
	draw_glyph_c(cx + 8 * S, bl, 0xf00d, app.ui - 2 * i32(S), col("text.muted"))
	append(&status_buttons, Ui_Button{cr, proc() {term.on, term.focus = false, false}})

	set_clip(term.body)
	asc, desc := font_metrics(app.fs)
	base_off := f32(int((app.line_h + f32(asc - desc)) / 2))
	cw, ch := app.cell_w, app.line_h
	def_fg := col("text")
	to_color :: proc(v: u32, def: Color) -> Color {return def if v == 0 else hex(v & 0xFFFFFF)}
	for y in 0 ..< term.rows {
		// rows from history when scrolled back
		src: []Cell
		hist := len(term.scrollback) - term.view_off + y
		if term.view_off > 0 && hist < len(term.scrollback) {
			if hist < 0 do continue
			src = term.scrollback[hist]
		} else {
			gy := y - term.view_off
			if gy < 0 || gy >= term.rows do continue
			src = row_cells(gy)
		}
		py := term.body.y + f32(y) * ch
		for cl, x in src {
			if x >= term.cols do break
			if cl.cont do continue
			px := term.body.x + f32(x) * cw
			fg, bg := cl.fg, cl.bg
			if cl.attr & ATTR_INV != 0 do fg, bg = (bg if bg != 0 else 0x01000000 | 0x0d1117), (fg if fg != 0 else 0x01e6edf3)
			w := cw * (2 if cl.r != 0 && rune_width(cl.r) == 2 else 1)
			if bg != 0 do fill({px, py, w, ch}, hex(bg & 0xFFFFFF))
			if cl.r > ' ' do glyph(i32(px), i32(py + base_off), cl.r, app.fs, to_color(fg, def_fg))
			if cl.attr & ATTR_UNDER != 0 do fill({px, py + ch - 3 * S, w, max(S, 1)}, to_color(fg, def_fg))
		}
	}
	if !term.cursor_hidden && term.view_off == 0 && term.alive {
		px := term.body.x + f32(term.cx) * cw
		py := term.body.y + f32(term.cy) * ch
		if term.focus {
			fill({px, py, cw, ch}, with_alpha(col("cursor"), 160))
			plat_text_input(true, {i32(px / S), i32(py / S), 2, i32(ch / S)})
		} else {
			rrect({px, py, cw, ch}, 0, col("cursor"), ring = max(S, 1))
		}
	}
	reset_clip()
	if term.view_off > 0 {
		label := fmt.tprintf("履歴 −%d 行 (Shift+PgDn で戻る)", term.view_off)
		text(r.x + r.w - 40 * S - f32(text_width(label, app.ui - i32(S), true)), bl, label, app.ui - i32(S), col("text.accent"))
	}
}
