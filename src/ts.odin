package main

// Syntax trees from Zed's grammar .wasm files: tree-sitter (C) runs them on our own
// wasm interpreter (wasm/wasm.zig). Highlighting uses the extension's highlights.scm,
// parsing is incremental and time-sliced so big files never freeze the window.

import "core:c"
import "core:os"
import "core:slice"
import "core:strings"
import "core:text/regex"

foreign import tslib {"../build/libts.a", "../build/libtsw.a"}

TSPoint :: struct {
	row, column: u32,
}
TSInputEdit :: struct {
	start_byte, old_end_byte, new_end_byte:      u32,
	start_point, old_end_point, new_end_point: TSPoint,
}
TSInput :: struct {
	payload:  rawptr,
	read:     proc "c" (payload: rawptr, byte_index: u32, position: TSPoint, bytes_read: ^u32) -> [^]u8,
	encoding: c.int,
	decode:   rawptr,
}
TSParseState :: struct {
	payload:             rawptr,
	current_byte_offset: u32,
	has_error:           bool,
}
TSParseOptions :: struct {
	payload:           rawptr,
	progress_callback: proc "c" (state: ^TSParseState) -> bool,
}
TSNode :: struct {
	ctx:  [4]u32,
	id:   rawptr,
	tree: rawptr,
}
TSQueryCapture :: struct {
	node:  TSNode,
	index: u32,
}
TSQueryMatch :: struct {
	id:            u32,
	pattern_index: u16,
	capture_count: u16,
	captures:      [^]TSQueryCapture,
}
TSQueryPredicateStep :: struct {
	type:     c.int, // 0 done, 1 capture, 2 string
	value_id: u32,
}
TSWasmError :: struct {
	kind:    c.int,
	message: cstring,
}

@(default_calling_convention = "c")
foreign tslib {
	ts_wasm_store_new :: proc(engine: rawptr, err: ^TSWasmError) -> rawptr ---
	ts_wasm_store_load_language :: proc(store: rawptr, name: cstring, wasm: [^]u8, len: u32, err: ^TSWasmError) -> rawptr ---
	ts_parser_new :: proc() -> rawptr ---
	ts_parser_delete :: proc(p: rawptr) ---
	ts_parser_set_wasm_store :: proc(p: rawptr, store: rawptr) ---
	ts_parser_set_language :: proc(p: rawptr, lang: rawptr) -> bool ---
	ts_parser_reset :: proc(p: rawptr) ---
	ts_parser_parse_with_options :: proc(p: rawptr, old: rawptr, input: TSInput, opts: TSParseOptions) -> rawptr ---
	ts_tree_delete :: proc(t: rawptr) ---
	ts_tree_edit :: proc(t: rawptr, edit: ^TSInputEdit) ---
	ts_tree_root_node :: proc(t: rawptr) -> TSNode ---
	ts_node_start_point :: proc(n: TSNode) -> TSPoint ---
	ts_node_end_point :: proc(n: TSNode) -> TSPoint ---
	ts_node_parent :: proc(n: TSNode) -> TSNode ---
	ts_node_is_null :: proc(n: TSNode) -> bool ---
	ts_node_descendant_for_point_range :: proc(n: TSNode, a, z: TSPoint) -> TSNode ---
	ts_query_new :: proc(lang: rawptr, src: [^]u8, len: u32, err_offset: ^u32, err_type: ^c.int) -> rawptr ---
	ts_query_pattern_count :: proc(q: rawptr) -> u32 ---
	ts_query_capture_count :: proc(q: rawptr) -> u32 ---
	ts_query_capture_name_for_id :: proc(q: rawptr, id: u32, len: ^u32) -> [^]u8 ---
	ts_query_string_value_for_id :: proc(q: rawptr, id: u32, len: ^u32) -> [^]u8 ---
	ts_query_predicates_for_pattern :: proc(q: rawptr, pattern: u32, n: ^u32) -> [^]TSQueryPredicateStep ---
	ts_query_cursor_new :: proc() -> rawptr ---
	ts_query_cursor_exec :: proc(qc: rawptr, q: rawptr, node: TSNode) ---
	ts_query_cursor_set_point_range :: proc(qc: rawptr, start, end: TSPoint) -> bool ---
	ts_query_cursor_next_match :: proc(qc: rawptr, m: ^TSQueryMatch) -> bool ---
}

Pred_Kind :: enum {Eq, Not_Eq, Match, Not_Match, Any_Of, Not_Any_Of}
Pred :: struct {
	kind:    Pred_Kind,
	capture: u32,
	other:   i32, // #eq? @a @b: the second capture, else -1
	values:  []string,
	re:      regex.Regular_Expression,
}

Grammar :: struct {
	lang:   rawptr,
	query:  rawptr,
	styles: []i16, // capture id -> Style, -1 = not a color
	preds:  [][]Pred, // per pattern
}

@(private = "file") grammars: map[string]^Grammar // by language name; nil = unavailable
@(private = "file") qcursor: rawptr
@(private = "file") parse_deadline: i64

// Grammar + highlight query of a language, loaded on first use.
grammar_for :: proc(l: ^Language) -> ^Grammar {
	if l == nil || l.wasm_path == "" do return nil
	if g, ok := grammars[l.name]; ok do return g
	grammars[l.name] = nil
	wasm, err := os.read_entire_file(l.wasm_path, context.temp_allocator)
	if err != nil do return nil
	werr: TSWasmError
	store := ts_wasm_store_new(nil, &werr)
	lang := ts_wasm_store_load_language(store, strings.clone_to_cstring(l.grammar, context.temp_allocator), raw_data(wasm), u32(len(wasm)), &werr)
	if lang == nil do return nil
	src, herr := os.read_entire_file(l.hl_path, context.temp_allocator)
	if herr != nil do return nil
	eoff: u32
	etype: c.int
	q := ts_query_new(lang, raw_data(src), u32(len(src)), &eoff, &etype)
	if q == nil do return nil // a query this tree-sitter version can't read: keep the lexer
	g := new(Grammar)
	g.lang, g.query = lang, q
	g.styles = make([]i16, ts_query_capture_count(q))
	for &st, i in g.styles {
		n: u32
		p := ts_query_capture_name_for_id(q, u32(i), &n)
		name := string(p[:n])
		s, ok := capture_style(name)
		st = i16(s) if ok else -1
	}
	g.preds = make([][]Pred, ts_query_pattern_count(q))
	for &ps, pi in g.preds do ps = parse_preds(q, u32(pi))
	grammars[l.name] = g
	return g
}

@(private = "file")
parse_preds :: proc(q: rawptr, pattern: u32) -> []Pred {
	n: u32
	steps := ts_query_predicates_for_pattern(q, pattern, &n)
	out: [dynamic]Pred
	str_of :: proc(q: rawptr, id: u32) -> string {
		l: u32
		p := ts_query_string_value_for_id(q, id, &l)
		return string(p[:l])
	}
	i: u32 = 0
	for i < n {
		j := i
		for j < n && steps[j].type != 0 do j += 1
		args := steps[i:j]
		i = j + 1
		if len(args) < 2 || args[0].type != 2 || args[1].type != 1 do continue
		p := Pred{capture = args[1].value_id, other = -1}
		switch str_of(q, args[0].value_id) {
		case "eq?": p.kind = .Eq
		case "not-eq?": p.kind = .Not_Eq
		case "match?", "lua-match?": p.kind = .Match
		case "not-match?": p.kind = .Not_Match
		case "any-of?": p.kind = .Any_Of
		case "not-any-of?": p.kind = .Not_Any_Of
		case: continue // directives like #set! don't filter matches
		}
		vals: [dynamic]string
		for a in args[2:] {
			if a.type == 1 do p.other = i32(a.value_id)
			else do append(&vals, strings.clone(str_of(q, a.value_id)))
		}
		p.values = vals[:]
		if p.kind == .Match || p.kind == .Not_Match {
			if len(vals) == 0 do continue
			re, rerr := regex.create(vals[0])
			if rerr != nil do continue
			p.re = re
		}
		append(&out, p)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Parsing

@(private = "file")
newline := [1]u8{'\n'}

@(private = "file")
read_input :: proc "c" (payload: rawptr, byte_index: u32, pos: TSPoint, bytes_read: ^u32) -> [^]u8 {
	b := (^Buffer)(payload)
	row, col := int(pos.row), int(pos.column)
	if row >= len(b.lines) {
		bytes_read^ = 0
		return nil
	}
	line := b.lines[row]
	if col < len(line) {
		bytes_read^ = u32(len(line) - col)
		return raw_data(line[col:])
	}
	if row + 1 >= len(b.lines) {
		bytes_read^ = 0
		return nil
	}
	bytes_read^ = 1
	return &newline[0]
}

@(private = "file")
over_budget :: proc "c" (state: ^TSParseState) -> bool {
	return ticks_ms_c() > parse_deadline
}

@(private = "file")
ticks_ms_c :: proc "contextless" () -> i64 {
	ts: posix_timespec
	clock_gettime(1, &ts) // CLOCK_MONOTONIC
	return i64(ts.sec) * 1000 + i64(ts.nsec) / 1_000_000
}
posix_timespec :: struct {
	sec, nsec: c.long,
}
foreign import libc "system:c"
@(default_calling_convention = "c", private = "file")
foreign libc {
	clock_gettime :: proc(clk: c.int, ts: ^posix_timespec) -> c.int ---
}

// Brings the tree up to date, spending at most budget_ms. Returns true if it changed.
ts_update :: proc(b: ^Buffer, budget_ms: i64) -> bool {
	if !b.ts_dirty do return false
	g := grammar_for(b.lang)
	if g == nil {
		b.ts_dirty = false
		return false
	}
	if b.ts_parser == nil {
		werr: TSWasmError
		b.ts_parser = ts_parser_new()
		ts_parser_set_wasm_store(b.ts_parser, ts_wasm_store_new(nil, &werr))
		if !ts_parser_set_language(b.ts_parser, g.lang) {
			b.ts_dirty = false
			return false
		}
	}
	parse_deadline = ticks_ms() + budget_ms
	input := TSInput{payload = b, read = read_input}
	t := ts_parser_parse_with_options(b.ts_parser, b.ts_tree, input, {progress_callback = over_budget})
	if t == nil do return false // out of time: the next call resumes where this one stopped
	if b.ts_tree != nil do ts_tree_delete(b.ts_tree)
	b.ts_tree = t
	b.ts_dirty = false
	return true
}

// Called by `replace` before the text changes.
ts_edit :: proc(b: ^Buffer, a, z: Pos, text: string) {
	if b.ts_parser == nil && b.ts_tree == nil do return
	b.ts_dirty = true
	if b.ts_parser != nil do ts_parser_reset(b.ts_parser) // a halted parse can't resume after an edit
	if b.ts_tree == nil do return
	off :: proc(b: ^Buffer, p: Pos) -> u32 {
		n := 0
		for l in b.lines[:p.line] do n += len(l) + 1
		return u32(n + p.col)
	}
	sa := off(b, a)
	e := advance(a, text)
	edit := TSInputEdit {
		start_byte    = sa,
		old_end_byte  = sa + u32(len(text_range(b, a, z))),
		new_end_byte  = sa + u32(len(text)),
		start_point   = {u32(a.line), u32(a.col)},
		old_end_point = {u32(z.line), u32(z.col)},
		new_end_point = {u32(e.line), u32(e.col)},
	}
	ts_tree_edit(b.ts_tree, &edit)
}

// ---------------------------------------------------------------------------
// Highlighting

// Styles for lines lo..hi from the highlight query (later patterns win, like Zed),
// cached in the buffer until the next frame. ok=false: no tree, use the lexer.
ts_prepare :: proc(b: ^Buffer, lo, hi: int) {
	b.ts_lo, b.ts_hi = 0, 0
	g := grammar_for(b.lang)
	if g == nil || b.ts_tree == nil do return
	lo, hi := max(lo, 0), min(hi, len(b.lines))
	if hi <= lo do return
	if qcursor == nil do qcursor = ts_query_cursor_new()
	b.ts_lines = make([][]Style, hi - lo, context.temp_allocator)
	b.ts_set = make([][]bool, hi - lo, context.temp_allocator)
	for l in lo ..< hi {
		b.ts_lines[l - lo] = make([]Style, len(b.lines[l]), context.temp_allocator)
		b.ts_set[l - lo] = make([]bool, len(b.lines[l]), context.temp_allocator)
	}
	Span :: struct {a, z: TSPoint, pattern: u16, style: Style}
	spans := make([dynamic]Span, context.temp_allocator)
	ts_query_cursor_set_point_range(qcursor, {u32(lo), 0}, {u32(hi), 0})
	ts_query_cursor_exec(qcursor, g.query, ts_tree_root_node(b.ts_tree))
	m: TSQueryMatch
	for ts_query_cursor_next_match(qcursor, &m) {
		caps := m.captures[:m.capture_count]
		if !preds_ok(b, g.preds[m.pattern_index], caps) do continue
		for cp in caps {
			st := g.styles[cp.index]
			if st < 0 do continue
			append(&spans, Span{ts_node_start_point(cp.node), ts_node_end_point(cp.node), m.pattern_index, Style(st)})
		}
	}
	slice.stable_sort_by(spans[:], proc(x, y: Span) -> bool {return x.pattern < y.pattern})
	for sp in spans {
		for row in max(int(sp.a.row), lo) ..= min(int(sp.z.row), hi - 1) {
			line := b.ts_lines[row - lo]
			c0 := int(sp.a.column) if int(sp.a.row) == row else 0
			c1 := int(sp.z.column) if int(sp.z.row) == row else len(line)
			for k in max(c0, 0) ..< min(c1, len(line)) {
				line[k] = sp.style
				b.ts_set[row - lo][k] = true
			}
		}
	}
	b.ts_lo, b.ts_hi = lo, hi
}

@(private = "file")
node_text :: proc(b: ^Buffer, n: TSNode) -> string {
	a, z := ts_node_start_point(n), ts_node_end_point(n)
	return text_range(b, clamp_pos(b, {int(a.row), int(a.column)}), clamp_pos(b, {int(z.row), int(z.column)}))
}

@(private = "file")
preds_ok :: proc(b: ^Buffer, preds: []Pred, caps: []TSQueryCapture) -> bool {
	for p in preds {
		txt := ""
		found := false
		for cp in caps do if cp.index == p.capture {
			txt = node_text(b, cp.node)
			found = true
			break
		}
		if !found do continue
		ok := true
		switch p.kind {
		case .Eq, .Not_Eq:
			want := p.values[0] if len(p.values) > 0 else ""
			if p.other >= 0 {
				for cp in caps do if cp.index == u32(p.other) do want = node_text(b, cp.node)
			}
			ok = (txt == want) == (p.kind == .Eq)
		case .Match, .Not_Match:
			_, matched := regex.match_and_allocate_capture(p.re, txt, context.temp_allocator)
			ok = matched == (p.kind == .Match)
		case .Any_Of, .Not_Any_Of:
			ok = slice.contains(p.values, txt) == (p.kind == .Any_Of)
		}
		if !ok do return false
	}
	return true
}

// Smallest syntax node strictly larger than a..z (for "expand selection").
ts_enclosing :: proc(b: ^Buffer, a, z: Pos) -> (na, nz: Pos, ok: bool) {
	if b.ts_tree == nil || b.ts_dirty do return
	pa, pz := TSPoint{u32(a.line), u32(a.col)}, TSPoint{u32(z.line), u32(z.col)}
	n := ts_node_descendant_for_point_range(ts_tree_root_node(b.ts_tree), pa, pz)
	for !ts_node_is_null(n) {
		s, e := ts_node_start_point(n), ts_node_end_point(n)
		if s != pa || e != pz {
			return clamp_pos(b, {int(s.row), int(s.column)}), clamp_pos(b, {int(e.row), int(e.column)}), true
		}
		n = ts_node_parent(n)
	}
	return
}
