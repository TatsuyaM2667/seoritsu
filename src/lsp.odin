package main

// Minimal Language Server Protocol client: stdio JSON-RPC, one process per server.
// Reads are non-blocking and driven by the main loop's poll() (no threads).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Req_Kind :: enum {Initialize, Tokens, Completion, Hover, Definition, Format, Rename, References, Code_Action, Execute, Signature, Inlay, Symbols, Outline}
Req :: struct {
	kind:    Req_Kind,
	buf:     ^Buffer,
	version: int,
}

Server :: struct {
	name:          string,
	pid:           posix.pid_t,
	in_fd, out_fd: posix.FD,
	rbuf:          [dynamic]u8,
	next_id:       int,
	pending:       map[int]Req,
	ready, dead:   bool,
	utf16:         bool,
	legend:        [dynamic]Style,
	legend_ok:     [dynamic]bool,
	can_format:    bool,
	can_tokens:    bool,
	can_inlay:     bool,
	incremental:   bool, // textDocumentSync.change == 2
	sig_triggers:  [dynamic]string,
	triggers:      [dynamic]string,
	settings:      json.Value,
	opened:        map[^Buffer]bool,
	status:        string, // last progress / log line, shown in the status bar
}

servers: map[string]^Server
project_root: string

Completion_Item :: struct {
	label, detail, insert, filter, sort: string,
	has_range:                           bool,
	a, z:                                Pos,
}

// ---------------------------------------------------------------------------

lsp_for :: proc(b: ^Buffer) -> ^Server {
	if b.lang == nil || len(b.lang.servers) == 0 do return nil
	// shortcut: only the language's first server is used (Zed can run several per language)
	name := b.lang.servers[0]
	if s, ok := servers[name]; ok do return nil if s == nil || s.dead else s
	servers[name] = nil // don't retry a server that can't be found
	cmd, ok := resolve_server(name)
	if !ok do return nil
	s := spawn_server(name, cmd)
	servers[name] = s
	return s
}

@(private = "file")
spawn_server :: proc(name: string, cmd: Server_Cmd) -> ^Server {
	to_child, from_child: [2]posix.FD
	if posix.pipe(&to_child) != .OK do return nil
	if posix.pipe(&from_child) != .OK do return nil
	argv := make([]cstring, len(cmd.argv) + 1)
	for a, i in cmd.argv do argv[i] = strings.clone_to_cstring(a)
	cwd := strings.clone_to_cstring(project_root)
	pid := posix.fork()
	if pid == 0 {
		posix.dup2(to_child[0], 0)
		posix.dup2(from_child[1], 1)
		devnull := posix.open("/dev/null", {.WRONLY})
		posix.dup2(devnull, 2)
		posix.chdir(cwd)
		posix.execv(argv[0], raw_data(argv))
		posix._exit(127)
	}
	posix.close(to_child[0])
	posix.close(from_child[1])
	if pid < 0 do return nil
	posix.fcntl(from_child[0], .SETFL, posix.fcntl(from_child[0], .GETFL) | i32(posix.O_NONBLOCK))
	posix.fcntl(from_child[0], .SETFD, i32(posix.FD_CLOEXEC))
	posix.fcntl(to_child[1], .SETFD, i32(posix.FD_CLOEXEC))
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN) // a crashed server must not kill the editor

	s := new(Server)
	s^ = {name = name, pid = pid, in_fd = to_child[1], out_fd = from_child[0], settings = cmd.settings, status = "starting"}
	root := uri(project_root)
	init_opts := "null"
	if cmd.init_opts != nil do init_opts = string(json.marshal(cmd.init_opts, allocator = context.temp_allocator) or_else transmute([]u8)string("null"))
	request(s, .Initialize, nil, "initialize", fmt.tprintf(`{{"processId":%d,"rootUri":%s,"rootPath":%s,
"workspaceFolders":[{{"uri":%s,"name":%s}}],"initializationOptions":%s,
"capabilities":{{"general":{{"positionEncodings":["utf-8","utf-16"]}},
"workspace":{{"configuration":true,"workspaceFolders":true,"applyEdit":true,"workspaceEdit":{{"documentChanges":true}}}},
"window":{{"workDoneProgress":true}},
"textDocument":{{"synchronization":{{"didSave":true}},
"completion":{{"completionItem":{{"snippetSupport":false}}}},
"hover":{{"contentFormat":["markdown","plaintext"]}},
"definition":{{}},"formatting":{{}},"publishDiagnostics":{{}},"rename":{{}},"references":{{}},
"codeAction":{{"codeActionLiteralSupport":{{"codeActionKind":{{"valueSet":["","quickfix","refactor","refactor.extract","refactor.inline","refactor.rewrite","source","source.organizeImports"]}}}}}},
"signatureHelp":{{"signatureInformation":{{"parameterInformation":{{"labelOffsetSupport":true}}}}}},
"inlayHint":{{}},"documentSymbol":{{"hierarchicalDocumentSymbolSupport":true}},
"semanticTokens":{{"requests":{{"full":true}},"formats":["relative"],
"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","enumMember","event","function","method","macro","keyword","modifier","comment","string","number","regexp","operator","decorator"],
"tokenModifiers":[]}}}}}}}}`, posix.getpid(), q(root), q(project_root), q(root), q(filepath_base(project_root)), init_opts))
	return s
}

filepath_base :: proc(p: string) -> string {
	i := strings.last_index_byte(strings.trim_right(p, "/"), '/')
	return p[i + 1:] if i >= 0 else p
}

lsp_fds :: proc(out: ^[dynamic]posix.FD) {
	for _, s in servers do if s != nil && !s.dead do append(out, s.out_fd)
}

lsp_shutdown :: proc() {
	for _, s in servers do if s != nil && !s.dead {
		posix.kill(s.pid, .SIGTERM)
	}
}

// ---------------------------------------------------------------------------
// Wire format

q :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"': strings.write_string(&sb, `\"`)
		case '\\': strings.write_string(&sb, `\\`)
		case '\n': strings.write_string(&sb, `\n`)
		case '\r': strings.write_string(&sb, `\r`)
		case '\t': strings.write_string(&sb, `\t`)
		case 0 ..< 0x20: fmt.sbprintf(&sb, `\u%04x`, c)
		case: strings.write_byte(&sb, c)
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

uri :: proc(path: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "file://")
	for c in transmute([]u8)path {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.index_byte("/-_.~", c) >= 0 {
			strings.write_byte(&sb, c)
		} else {
			fmt.sbprintf(&sb, "%%%02X", c)
		}
	}
	return strings.to_string(sb)
}

uri_path :: proc(u: string) -> string {
	s := strings.trim_prefix(u, "file://")
	out := make([dynamic]u8, context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_u64_of_base(s[i + 1:i + 3], 16); ok {
				append(&out, u8(v))
				i += 2
				continue
			}
		}
		append(&out, s[i])
	}
	return string(out[:])
}

@(private = "file")
write_all :: proc(s: ^Server, data: string) {
	d := transmute([]u8)data
	for len(d) > 0 && !s.dead {
		n := posix.write(s.in_fd, raw_data(d), len(d))
		if n <= 0 {
			if posix.errno() == .EINTR || posix.errno() == .EAGAIN do continue
			s.dead = true
			return
		}
		d = d[n:]
	}
}

@(private = "file")
send :: proc(s: ^Server, body: string) {
	write_all(s, fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body))
}

notify :: proc(s: ^Server, method, params: string) {
	send(s, fmt.tprintf(`{{"jsonrpc":"2.0","method":%s,"params":%s}}`, q(method), params))
}

request :: proc(s: ^Server, kind: Req_Kind, b: ^Buffer, method, params: string) -> int {
	s.next_id += 1
	s.pending[s.next_id] = {kind, b, b.version if b != nil else 0}
	send(s, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":%s,"params":%s}}`, s.next_id, q(method), params))
	return s.next_id
}

doc :: proc(b: ^Buffer) -> string {return fmt.tprintf(`{{"uri":%s}}`, q(uri(b.path)))}

pos_json :: proc(s: ^Server, b: ^Buffer, p: Pos) -> string {
	return fmt.tprintf(`{{"line":%d,"character":%d}}`, p.line, to_lsp_col(b, p, s.utf16))
}

doc_pos :: proc(s: ^Server, b: ^Buffer, p: Pos) -> string {
	return fmt.tprintf(`{{"textDocument":%s,"position":%s}}`, doc(b), pos_json(s, b, p))
}

// ---------------------------------------------------------------------------
// Document sync: full text on open, then only the edits (or full text if the server wants that)

clear_changes :: proc(b: ^Buffer) {
	for c in b.changes do delete(c.text)
	clear(&b.changes)
}

lsp_open :: proc(b: ^Buffer) {
	s := lsp_for(b)
	if s == nil || !s.ready || s.opened[b] do return
	s.opened[b] = true
	notify(s, "textDocument/didOpen", fmt.tprintf(`{{"textDocument":{{"uri":%s,"languageId":%s,"version":%d,"text":%s}}}}`,
		q(uri(b.path)), q(language_id(b)), b.version, q(buffer_text(b))))
	clear_changes(b)
	b.lsp_stale = false
	b.toks_due = ticks_ms()
}

language_id :: proc(b: ^Buffer) -> string {
	if b.lang == nil do return "plaintext"
	switch b.lang.name {
	case "C++": return "cpp"
	case "JavaScript": return "javascript"
	}
	return strings.to_lower(b.lang.name, context.temp_allocator)
}

lsp_sync :: proc(b: ^Buffer) {
	s := lsp_for(b)
	if s == nil do clear_changes(b) // nobody will ever read them
	if s == nil || !s.ready do return
	if !s.opened[b] {
		lsp_open(b)
		return
	}
	if !b.lsp_stale do return
	b.lsp_stale = false
	changes := ""
	if s.incremental && len(b.changes) > 0 {
		parts := make([dynamic]string, context.temp_allocator)
		for c in b.changes {
			ac, zc := c.a.col, c.z.col
			if s.utf16 do ac, zc = c.a16, c.z16
			append(&parts, fmt.tprintf(`{{"range":{{"start":{{"line":%d,"character":%d}},"end":{{"line":%d,"character":%d}}}},"text":%s}}`,
				c.a.line, ac, c.z.line, zc, q(c.text)))
		}
		changes = strings.join(parts[:], ",", context.temp_allocator)
	} else {
		changes = fmt.tprintf(`{{"text":%s}}`, q(buffer_text(b)))
	}
	clear_changes(b)
	notify(s, "textDocument/didChange", fmt.tprintf(`{{"textDocument":{{"uri":%s,"version":%d}},"contentChanges":[%s]}}`,
		q(uri(b.path)), b.version, changes))
	b.toks_due = ticks_ms() + 120
}

lsp_close :: proc(b: ^Buffer) {
	s := lsp_for(b)
	if s == nil || !s.opened[b] do return
	delete_key(&s.opened, b)
	notify(s, "textDocument/didClose", fmt.tprintf(`{{"textDocument":%s}}`, doc(b)))
}

lsp_saved :: proc(b: ^Buffer) {
	if s := lsp_for(b); s != nil && s.opened[b] do notify(s, "textDocument/didSave", fmt.tprintf(`{{"textDocument":%s}}`, doc(b)))
}

// Asks for semantic tokens when they are due.
lsp_tick :: proc(b: ^Buffer) {
	lsp_sync(b)
	s := lsp_for(b)
	if s != nil && s.ready && outline_wanted(b) {
		outline.pending = true
		request(s, .Outline, b, "textDocument/documentSymbol", fmt.tprintf(`{{"textDocument":%s}}`, doc(b)))
	}
	if s == nil || !s.ready || (!s.can_tokens && !s.can_inlay) || b.toks_due == 0 || ticks_ms() < b.toks_due do return
	b.toks_due = 0
	if s.can_tokens do request(s, .Tokens, b, "textDocument/semanticTokens/full", fmt.tprintf(`{{"textDocument":%s}}`, doc(b)))
	if s.can_inlay && zed.inlay_hints {
		last := len(b.lines) - 1
		request(s, .Inlay, b, "textDocument/inlayHint", fmt.tprintf(`{{"textDocument":%s,"range":{{"start":{{"line":0,"character":0}},"end":%s}}}}`,
			doc(b), pos_json(s, b, {last, len(b.lines[last])})))
	}
}

lsp_completion :: proc(b: ^Buffer) -> bool {
	s := lsp_for(b)
	if s == nil || !s.ready do return false
	lsp_sync(b)
	request(s, .Completion, b, "textDocument/completion", doc_pos(s, b, b.cur))
	return true
}

lsp_hover :: proc(b: ^Buffer, p: Pos) {
	s := lsp_for(b)
	if s == nil || !s.ready do return
	lsp_sync(b)
	request(s, .Hover, b, "textDocument/hover", doc_pos(s, b, p))
}

lsp_definition :: proc(b: ^Buffer, p: Pos) -> bool {
	s := lsp_for(b)
	if s == nil || !s.ready do return false
	lsp_sync(b)
	request(s, .Definition, b, "textDocument/definition", doc_pos(s, b, p))
	return true
}

// false = no formatter; the caller saves right away
lsp_format :: proc(b: ^Buffer) -> bool {
	s := lsp_for(b)
	if s == nil || !s.ready || !s.can_format do return false
	lsp_sync(b)
	tabs := b.lang != nil && b.lang.hard_tabs
	request(s, .Format, b, "textDocument/formatting", fmt.tprintf(`{{"textDocument":%s,"options":{{"tabSize":%d,"insertSpaces":%v}}}}`,
		doc(b), b.lang.tab_size if b.lang != nil else 4, !tabs))
	return true
}

lsp_rename :: proc(b: ^Buffer, p: Pos, name: string) {
	s := lsp_for(b)
	if s == nil || !s.ready do return
	lsp_sync(b)
	request(s, .Rename, b, "textDocument/rename", fmt.tprintf(`{{"textDocument":%s,"position":%s,"newName":%s}}`, doc(b), pos_json(s, b, p), q(name)))
}

lsp_references :: proc(b: ^Buffer, p: Pos) -> bool {
	s := lsp_for(b)
	if s == nil || !s.ready do return false
	lsp_sync(b)
	request(s, .References, b, "textDocument/references", fmt.tprintf(`{{"textDocument":%s,"position":%s,"context":{{"includeDeclaration":true}}}}`, doc(b), pos_json(s, b, p)))
	return true
}

lsp_symbols :: proc(b: ^Buffer) -> bool {
	s := lsp_for(b)
	if s == nil || !s.ready do return false
	lsp_sync(b)
	request(s, .Symbols, b, "textDocument/documentSymbol", fmt.tprintf(`{{"textDocument":%s}}`, doc(b)))
	return true
}

lsp_signature :: proc(b: ^Buffer) {
	s := lsp_for(b)
	if s == nil || !s.ready do return
	lsp_sync(b)
	request(s, .Signature, b, "textDocument/signatureHelp", doc_pos(s, b, b.cur))
}

is_sig_trigger :: proc(b: ^Buffer, t: string) -> bool {
	s := lsp_for(b)
	return s != nil && s.ready && slice.contains(s.sig_triggers[:], t)
}

lsp_code_actions :: proc(b: ^Buffer) -> bool {
	s := lsp_for(b)
	if s == nil || !s.ready do return false
	lsp_sync(b)
	a, z := order(b.anchor, b.cur)
	// the diagnostics under the cursor, as the server sent them (quick fixes need them)
	ds := make([dynamic]string, context.temp_allocator)
	for d in b.diags do if !lt(z, d.a) && !lt(d.b, a) && d.raw != "" do append(&ds, d.raw)
	request(s, .Code_Action, b, "textDocument/codeAction", fmt.tprintf(`{{"textDocument":%s,"range":{{"start":%s,"end":%s}},"context":{{"diagnostics":[%s]}}}}`,
		doc(b), pos_json(s, b, a), pos_json(s, b, z), strings.join(ds[:], ",", context.temp_allocator)))
	return true
}

// Runs a code action the picker returned (raw JSON of a CodeAction or Command).
lsp_run_action :: proc(s: ^Server, raw: string) {
	v, err := json.parse(transmute([]u8)raw, parse_integers = true)
	if err != .None do return
	defer json.destroy_value(v)
	if e := obj(v, "edit"); e != nil do apply_workspace_edit(s, e)
	cmd := obj(v, "command")
	if _, is_str := cmd.(json.String); is_str do cmd = v // a bare Command
	if cmd != nil && str(obj(cmd, "command")) != "" {
		args := string(json.marshal(obj(cmd, "arguments"), allocator = context.temp_allocator) or_else nil)
		if args == "" || args == "null" do args = "[]"
		request(s, .Execute, nil, "workspace/executeCommand", fmt.tprintf(`{{"command":%s,"arguments":%s}}`, q(str(obj(cmd, "command"))), args))
	}
}

// TextEdits for one buffer, applied bottom-up as one undo step.
apply_text_edits :: proc(s: ^Server, b: ^Buffer, edits: json.Array) {
	Te :: struct {a, z: Pos, text: string}
	list := make([dynamic]Te, context.temp_allocator)
	for e in edits {
		a, z := range_of(s, b, obj(e, "range"))
		append(&list, Te{a, z, str(obj(e, "newText"))})
	}
	slice.sort_by(list[:], proc(x, y: Te) -> bool {return lt(y.a, x.a)})
	cur := b.cur
	for e, i in list do replace(b, e.a, e.z, e.text, merge = i > 0)
	b.cur = clamp_pos(b, cur)
	b.anchor = b.cur
}

// WorkspaceEdit: `changes` map or `documentChanges` list; files not open are opened.
apply_workspace_edit :: proc(s: ^Server, e: json.Value) -> int {
	keep := app.active
	n := 0
	apply :: proc(s: ^Server, u: string, edits: json.Array, n: ^int) {
		p, _ := filepath.abs(uri_path(u), context.temp_allocator)
		if !is_under(p, project_root) && find_buffer(p) == nil {
			toast(fmt.tprintf("プロジェクト外のファイルへの編集を無視しました: %s", p))
			return
		}
		b := open_file(p)
		if b == nil do return
		apply_text_edits(s, b, edits)
		n^ += 1
	}
	if ch, ok := obj(e, "changes").(json.Object); ok {
		for u, edits in ch do if arr, ok := edits.(json.Array); ok do apply(s, u, arr, &n)
	}
	if dc, ok := obj(e, "documentChanges").(json.Array); ok {
		for d in dc do if arr, ok := obj(d, "edits").(json.Array); ok do apply(s, str(obj(obj(d, "textDocument"), "uri")), arr, &n)
	}
	app.active = min(keep, len(app.bufs) - 1)
	return n
}

// ---------------------------------------------------------------------------
// Incoming

// LSP capabilities are `true` or an options object
truthy :: proc(v: json.Value) -> bool {
	if b, ok := v.(json.Boolean); ok do return b
	return v != nil
}

num :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer: return int(x)
	case json.Float: return int(x)
	}
	return 0
}

range_of :: proc(s: ^Server, b: ^Buffer, r: json.Value) -> (a, z: Pos) {
	st, en := obj(r, "start"), obj(r, "end")
	a = from_lsp_col(b, num(obj(st, "line")), num(obj(st, "character")), s.utf16)
	z = from_lsp_col(b, num(obj(en, "line")), num(obj(en, "character")), s.utf16)
	return
}

// Reads whatever the servers sent. Returns true if something changed on screen.
lsp_poll :: proc() -> bool {
	changed := false
	for _, s in servers {
		if s == nil || s.dead do continue
		buf: [65536]u8
		for {
			n := posix.read(s.out_fd, &buf[0], len(buf))
			if n > 0 {
				append(&s.rbuf, ..buf[:n])
				continue
			}
			if n == 0 || (posix.errno() != .EAGAIN && posix.errno() != .EINTR) {
				s.dead = true
				s.status = "stopped"
				changed = true
			}
			break
		}
		for {
			body, ok := next_message(s)
			if !ok do break
			v, err := json.parse(transmute([]u8)body, parse_integers = true)
			if err == .None {
				handle(s, v)
				changed = true
			}
			json.destroy_value(v)
		}
	}
	return changed
}

@(private = "file")
next_message :: proc(s: ^Server) -> (string, bool) {
	data := string(s.rbuf[:])
	hdr_end := strings.index(data, "\r\n\r\n")
	if hdr_end < 0 do return "", false
	length := -1
	for line in strings.split_lines(data[:hdr_end], context.temp_allocator) {
		if strings.has_prefix(strings.to_lower(line, context.temp_allocator), "content-length:") {
			length, _ = strconv.parse_int(strings.trim_space(line[15:]))
		}
	}
	start := hdr_end + 4
	if length < 0 { // malformed header: drop it, or nothing after it is ever read
		remove_range(&s.rbuf, 0, start)
		return next_message(s)
	}
	if len(data) < start + length do return "", false
	body := strings.clone(data[start:start + length], context.temp_allocator)
	remove_range(&s.rbuf, 0, start + length)
	return body, true
}

@(private = "file")
handle :: proc(s: ^Server, v: json.Value) {
	method := str(obj(v, "method"))
	id := obj(v, "id")
	if method != "" {
		if id != nil {
			// a request from the server: answer everything (unanswered ones can stall servers)
			result := "null"
			if method == "workspace/applyEdit" {
				apply_workspace_edit(s, obj(obj(v, "params"), "edit"))
				result = `{"applied":true}`
			} else if method == "workspace/configuration" {
				items, _ := obj(obj(v, "params"), "items").(json.Array)
				parts := make([dynamic]string, context.temp_allocator)
				for it in items {
					val := s.settings
					if sec := str(obj(it, "section")); sec != "" && obj(s.settings, sec) != nil do val = obj(s.settings, sec)
					append(&parts, string(json.marshal(val, allocator = context.temp_allocator) or_else transmute([]u8)string("null")))
				}
				result = fmt.tprintf("[%s]", strings.join(parts[:], ",", context.temp_allocator))
			}
			send(s, fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, string(json.marshal(id, allocator = context.temp_allocator) or_else nil), result))
			return
		}
		switch method {
		case "textDocument/publishDiagnostics":
			p := obj(v, "params")
			b := find_buffer(uri_path(str(obj(p, "uri"))))
			if b == nil do return
			for d in b.diags {delete(d.message); delete(d.raw)}
			clear(&b.diags)
			ds, _ := obj(p, "diagnostics").(json.Array)
			for d in ds {
				a, z := range_of(s, b, obj(d, "range"))
				sev := num(obj(d, "severity"))
				raw := string(json.marshal(d, allocator = context.temp_allocator) or_else nil)
				append(&b.diags, Diag{a = a, b = z, severity = sev if sev > 0 else 1, message = strings.clone(str(obj(d, "message"))), raw = strings.clone(raw)})
			}
		case "$/progress":
			val := obj(obj(v, "params"), "value")
			msg := str(obj(val, "title"))
			if m := str(obj(val, "message")); m != "" do msg = m
			if str(obj(val, "kind")) == "end" do msg = ""
			delete(s.status)
			s.status = strings.clone(msg)
		case "window/showMessage":
			toast(str(obj(obj(v, "params"), "message")))
		}
		return
	}
	req, known := s.pending[num(id)]
	if !known do return
	delete_key(&s.pending, num(id))
	result := obj(v, "result")
	switch req.kind {
	case .Initialize:
		caps := obj(result, "capabilities")
		s.utf16 = str(obj(caps, "positionEncoding")) != "utf-8"
		s.can_format = truthy(obj(caps, "documentFormattingProvider"))
		stp := obj(caps, "semanticTokensProvider")
		s.can_tokens = truthy(obj(stp, "full"))
		s.can_inlay = truthy(obj(caps, "inlayHintProvider"))
		sync := obj(caps, "textDocumentSync")
		s.incremental = num(sync) == 2 || num(obj(sync, "change")) == 2
		strig, _ := obj(obj(caps, "signatureHelpProvider"), "triggerCharacters").(json.Array)
		for t in strig do append(&s.sig_triggers, strings.clone(str(t)))
		types, _ := obj(obj(stp, "legend"), "tokenTypes").(json.Array)
		for t in types {
			st, ok := token_style(str(t))
			append(&s.legend, st)
			append(&s.legend_ok, ok)
		}
		trig, _ := obj(obj(caps, "completionProvider"), "triggerCharacters").(json.Array)
		for t in trig do append(&s.triggers, strings.clone(str(t)))
		notify(s, "initialized", "{}")
		if s.settings != nil {
			notify(s, "workspace/didChangeConfiguration", fmt.tprintf(`{{"settings":%s}}`, string(json.marshal(s.settings, allocator = context.temp_allocator) or_else nil)))
		}
		s.ready = true
		s.status = ""
		for b in all_bufs() do if lsp_for(b) == s do lsp_open(b)
	case .Tokens:
		b := req.buf
		if !buffer_alive(b) || req.version != b.version do return
		data, _ := obj(result, "data").(json.Array)
		clear(&b.toks)
		line, col := 0, 0
		for i := 0; i + 4 < len(data); i += 5 {
			dl, dc, ln, ty := num(data[i]), num(data[i + 1]), num(data[i + 2]), num(data[i + 3])
			line += dl
			col = dc if dl > 0 else col + dc
			if ty >= len(s.legend) || !s.legend_ok[ty] || line >= len(b.lines) do continue
			a := from_lsp_col(b, line, col, s.utf16)
			z := from_lsp_col(b, line, col + ln, s.utf16)
			append(&b.toks, Tok{i32(a.line), i32(a.col), i32(z.col - a.col), s.legend[ty]})
		}
	case .Completion:
		b := req.buf
		if !buffer_alive(b) || b != cur_buf() do return
		items, is_arr := result.(json.Array)
		if !is_arr do items, _ = obj(result, "items").(json.Array)
		list := make([dynamic]Completion_Item)
		for it in items {
			c := Completion_Item {
				label  = strings.clone(str(obj(it, "label"))),
				detail = strings.clone(str(obj(it, "detail"))),
				filter = strings.clone(str(obj(it, "filterText"))),
				sort   = strings.clone(str(obj(it, "sortText"))),
			}
			c.insert = strings.clone(str(obj(it, "insertText")))
			if te := obj(it, "textEdit"); te != nil {
				r := obj(te, "range")
				if r == nil do r = obj(te, "replace")
				c.a, c.z = range_of(s, b, r)
				c.has_range = c.a.line == c.z.line // multi-line edits are rare here; fall back to the word
				delete(c.insert)
				c.insert = strings.clone(str(obj(te, "newText")))
			}
			if c.insert == "" do c.insert = strings.clone(c.label)
			if c.filter == "" do c.filter = c.label
			if c.sort == "" do c.sort = c.label
			append(&list, c)
		}
		slice.sort_by(list[:], proc(x, y: Completion_Item) -> bool {return x.sort < y.sort})
		set_completions(list)
	case .Hover:
		sb := strings.builder_make(context.temp_allocator)
		hover_text(&sb, obj(result, "contents"))
		show_hover(strings.to_string(sb))
	case .Definition:
		loc := result
		if arr, ok := result.(json.Array); ok {
			if len(arr) == 0 do return
			loc = arr[0]
		}
		u := str(obj(loc, "uri"))
		r := obj(loc, "range")
		if u == "" {
			u = str(obj(loc, "targetUri"))
			r = obj(loc, "targetSelectionRange")
		}
		if u == "" do return
		st := obj(r, "start")
		goto_location(uri_path(u), num(obj(st, "line")), num(obj(st, "character")), s.utf16)
	case .Format:
		b := req.buf
		if !buffer_alive(b) do return
		if req.version == b.version {
			edits, _ := result.(json.Array)
			apply_text_edits(s, b, edits)
		}
		if app.format_only[b] do delete_key(&app.format_only, b)
		else do finish_save(b)
	case .Execute:
	case .Rename:
		if result == nil {
			toast("名前を変更できません")
			return
		}
		n := apply_workspace_edit(s, result)
		toast(fmt.tprintf("%d ファイルで名前を変更しました", n))
	case .References:
		locs, _ := result.(json.Array)
		items := make([dynamic]Pick)
		for l in locs {
			path := uri_path(str(obj(l, "uri")))
			st := obj(obj(l, "range"), "start")
			line, ch := num(obj(st, "line")), num(obj(st, "character"))
			append(&items, Pick{
				label = fmt.aprintf("%s:%d", rel_path(path), line + 1),
				detail = strings.clone(strings.trim_space(file_line(path, line))),
				path = strings.clone(path), line = line, char = ch, utf16 = s.utf16,
			})
		}
		picker_open(.List, fmt.tprintf("参照 (%d)", len(items)), items)
	case .Symbols:
		b := req.buf
		if !buffer_alive(b) do return
		items := make([dynamic]Pick)
		add_symbols(s, b, result, 0, &items)
		picker_open(.List, "シンボル", items)
	case .Outline:
		outline.pending = false
		b := req.buf
		if !buffer_alive(b) do return
		items := make([dynamic]Pick)
		add_symbols(s, b, result, 0, &items)
		outline_set(b, req.version, items)
	case .Code_Action:
		acts, _ := result.(json.Array)
		if len(acts) == 0 {
			toast("ここで使えるコードアクションはありません")
			return
		}
		items := make([dynamic]Pick)
		for a in acts {
			raw := string(json.marshal(a, allocator = context.temp_allocator) or_else nil)
			append(&items, Pick{label = strings.clone(str(obj(a, "title"))), detail = strings.clone(str(obj(a, "kind"))), raw = strings.clone(raw), server = s})
		}
		picker_open(.Actions, "コードアクション", items)
	case .Signature:
		b := req.buf
		sigs, _ := obj(result, "signatures").(json.Array)
		if !buffer_alive(b) || len(sigs) == 0 do return
		active := clamp(num(obj(result, "activeSignature")), 0, len(sigs) - 1)
		show_signature(b, str(obj(sigs[active], "label")))
	case .Inlay:
		b := req.buf
		if !buffer_alive(b) || req.version != b.version do return
		for h in b.hints do delete(h.label)
		clear(&b.hints)
		hs, _ := result.(json.Array)
		for h in hs {
			label := ""
			#partial switch l in obj(h, "label") {
			case json.String: label = l
			case json.Array:
				sb := strings.builder_make(context.temp_allocator)
				for part in l do strings.write_string(&sb, str(obj(part, "value")))
				label = strings.to_string(sb)
			}
			if b2, ok := obj(h, "paddingLeft").(json.Boolean); ok && b2 do label = strings.concatenate({" ", label}, context.temp_allocator)
			if b2, ok := obj(h, "paddingRight").(json.Boolean); ok && b2 do label = strings.concatenate({label, " "}, context.temp_allocator)
			p := obj(h, "position")
			at := from_lsp_col(b, num(obj(p, "line")), num(obj(p, "character")), s.utf16)
			append(&b.hints, Hint{i32(at.line), i32(at.col), strings.clone(label)})
		}
		slice.sort_by(b.hints[:], proc(x, y: Hint) -> bool {return x.line < y.line || (x.line == y.line && x.col < y.col)})
	}
}

// DocumentSymbol tree (or flat SymbolInformation list) -> picker rows.
@(private = "file")
add_symbols :: proc(s: ^Server, b: ^Buffer, v: json.Value, depth: int, items: ^[dynamic]Pick) {
	KINDS := [?]string{"", "file", "module", "namespace", "package", "class", "method", "property", "field", "constructor", "enum", "interface", "function", "variable", "constant", "string", "number", "boolean", "array", "object", "key", "null", "enum member", "struct", "event", "operator", "type param"}
	arr, _ := v.(json.Array)
	for sym in arr {
		r := obj(sym, "selectionRange")
		if r == nil do r = obj(obj(sym, "location"), "range")
		st := obj(r, "start")
		k := num(obj(sym, "kind"))
		append(items, Pick{
			label = strings.concatenate({strings.repeat("  ", depth, context.temp_allocator), str(obj(sym, "name"))}),
			detail = strings.clone(KINDS[k] if k < len(KINDS) else ""),
			path = strings.clone(b.path), line = num(obj(st, "line")), char = num(obj(st, "character")), utf16 = s.utf16,
		})
		add_symbols(s, b, obj(sym, "children"), depth + 1, items)
	}
}

// One line of a file (for reference rows), from the open buffer if there is one.
@(private = "file")
file_line :: proc(path: string, line: int) -> string {
	if b := find_buffer(path); b != nil do return line < len(b.lines) ? line_str(b, line) : ""
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	for l, i in strings.split_lines(string(data), context.temp_allocator) do if i == line do return l
	return ""
}

@(private = "file")
hover_text :: proc(sb: ^strings.Builder, v: json.Value) {
	#partial switch x in v {
	case json.String:
		strings.write_string(sb, x)
	case json.Array:
		for e in x {
			hover_text(sb, e)
			strings.write_string(sb, "\n")
		}
	case json.Object:
		strings.write_string(sb, str(x["value"]))
	}
}

@(private = "file")
token_style :: proc(t: string) -> (Style, bool) {
	switch t {
	case "namespace": return .Namespace, true
	case "type", "class", "enum", "interface", "struct", "typeParameter", "builtinType": return .Type, true
	case "parameter", "variable": return .Variable, true
	case "property", "field": return .Property, true
	case "enumMember", "keywordLiteral", "errorTag", "boolean": return .Constant, true
	case "function", "method", "macro", "builtin": return .Function, true
	case "keyword", "modifier": return .Keyword, true
	case "comment": return .Comment, true
	case "string", "regexp": return .String, true
	case "number": return .Number, true
	case "operator": return .Operator, true
	case "decorator", "attribute": return .Attribute, true
	case "label": return .Label, true
	}
	return .Text, false
}

