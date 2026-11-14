package main

// Everything borrowed from an installed Zed: settings.json (theme overrides, fonts,
// lsp binaries / options), installed extensions (languages, their language servers,
// keywords from highlights.scm) and the servers Zed already downloaded.

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

Language :: struct {
	name:          string,
	suffixes:      [dynamic]string,
	line_comment:  string,
	block_comment: [2]string,
	hard_tabs:     bool,
	tab_size:      int,
	servers:       [dynamic]string,
	words:         map[string]Style, // keywords / builtins from highlights.scm
	grammar:       string, // tree-sitter grammar name (config.toml `grammar`)
	wasm_path:     string, // <ext>/grammars/<grammar>.wasm
	hl_path:       string, // highlights.scm next to config.toml
}

Style :: enum u8 {
	Text, Comment, Keyword, String, Number, Constant, Type, Function, Variable,
	Property, Operator, Punct, Namespace, Label, Attribute, Preproc,
}

zed: struct {
	data, config: string, // ~/.local/share/zed, ~/.config/zed (or the Flatpak copies)
	settings:     json.Value,
	langs:        [dynamic]Language,
	server_ext:   map[string]string, // server name -> extension id (for its work dir)
	font_family:  string,
	font_size:    i32,
	ui_font_size: i32,
	autosave:     bool,
	format_save:  bool,
	inline_diag:  bool,
	inlay_hints:  bool,
}

theme: map[string]Color
syntax: [Style]Color

// Defaults: the transparent GitHub-Dark look of the user's Zed overrides.
@(private = "file")
DEFAULT_THEME := [][2]string {
	{"background", "#0d111799"},
	{"title_bar.background", "#0d1117cc"},
	{"tab_bar.background", "#0d111799"},
	{"status_bar.background", "#0d111799"},
	{"toolbar.background", "#0d1117b8"},
	{"tab.inactive_background", "#0d111733"},
	{"tab.active_background", "#161b22d9"},
	{"panel.background", "#0d1117a6"},
	{"editor.background", "#0d1117b8"},
	{"editor.active_line.background", "#58a6ff1a"},
	{"editor.gutter.background", "#0d1117b8"},
	{"editor.line_number", "#8b949ecc"},
	{"editor.active_line_number", "#c9d1d9ee"},
	{"editor.indent_guide", "#30363d66"},
	{"editor.indent_guide_active", "#58a6ff80"},
	{"editor.document_highlight.read_background", "#58a6ff1f"},
	{"element.hover", "#58a6ff1a"},
	{"element.selected", "#58a6ff2e"},
	{"elevated_surface.background", "#0d1117fa"},
	{"text", "#c9d1d9"},
	{"text.muted", "#9da7b3"},
	{"text.placeholder", "#6e7681"},
	{"text.accent", "#58a6ff"},
	{"editor.foreground", "#c9d1d9"},
	{"border", "#30363d80"},
	{"border.variant", "#30363d4d"},
	{"accent", "#58a6ff"},
	{"scrollbar.thumb.background", "#58a6ff33"},
	{"scrollbar.thumb.hover_background", "#58a6ff66"},
	{"error", "#f85149"},
	{"warning", "#d29922"},
	{"info", "#58a6ff"},
	{"hint", "#8b949e"},
	{"modified", "#d29922"},
	{"created", "#3fb950"},
	{"deleted", "#f85149"},
	{"cursor", "#58a6ffff"},
	{"selection", "#1f6feb40"},
}

@(private = "file")
DEFAULT_SYNTAX := [Style]string {
	.Text      = "#c9d1d9",
	.Comment   = "#8b949e",
	.Keyword   = "#ff7b72",
	.String    = "#a5d6ff",
	.Number    = "#79c0ff",
	.Constant  = "#79c0ff",
	.Type      = "#ffa657",
	.Function  = "#d2a8ff",
	.Variable  = "#c9d1d9",
	.Property  = "#79c0ff",
	.Operator  = "#ff7b72",
	.Punct     = "#c9d1d9",
	.Namespace = "#ffa657",
	.Label     = "#ffa657",
	.Attribute = "#79c0ff",
	.Preproc   = "#ff7b72",
}

// Zed syntax capture name -> our style (the first dotted part decides).
capture_style :: proc(capture: string) -> (Style, bool) {
	head := capture
	if i := strings.index_byte(head, '.'); i >= 0 do head = head[:i]
	switch head {
	case "comment": return .Comment, true
	case "keyword", "conditional", "repeat", "include", "exception": return .Keyword, true
	case "preproc": return .Preproc, true
	case "string", "character": return .String, true
	case "number", "float": return .Number, true
	case "boolean", "constant": return .Constant, true
	case "function", "method": return .Function, true
	case "type", "constructor": return .Type, true
	case "variable", "parameter": return .Variable, true
	case "property", "field": return .Property, true
	case "attribute": return .Attribute, true
	case "operator": return .Operator, true
	case "punctuation": return .Punct, true
	case "label": return .Label, true
	case "namespace", "module": return .Namespace, true
	case "primary": return .Text, true
	}
	return .Text, false
}

parse_color :: proc(s: string) -> (Color, bool) {
	if len(s) != 7 && len(s) != 9 || s[0] != '#' do return {}, false
	v, ok := strconv.parse_u64_of_base(s[1:], 16)
	if !ok do return {}, false
	if len(s) == 7 do return hex(u32(v)), true
	return hex(u32(v >> 8), u8(v)), true
}

col :: proc(key: string) -> Color {return theme[key]}

pj :: proc(parts: ..string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}

obj :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok do return o[key]
	return nil
}
str :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

// ---------------------------------------------------------------------------

zed_load :: proc() {
	home := os.get_env("HOME", context.allocator)
	flat := pj(home, ".var/app/dev.zed.Zed", allocator = context.allocator)
	native_data := pj(home, ".local/share/zed", allocator = context.allocator)
	zed.data = native_data
	zed.config = pj(home, ".config/zed", allocator = context.allocator)
	// prefer whichever install actually has extensions
	if !os.exists(pj(native_data, "extensions/installed")) &&
	   os.exists(pj(flat, "data/zed")) {
		zed.data = pj(flat, "data/zed", allocator = context.allocator)
		zed.config = pj(flat, "config/zed", allocator = context.allocator)
	}

	for kv in DEFAULT_THEME do theme[kv[0]], _ = parse_color(kv[1])
	for s, st in DEFAULT_SYNTAX do syntax[st], _ = parse_color(s)
	zed.font_family, zed.font_size, zed.ui_font_size = "monospace", 15, 14
	zed.autosave, zed.format_save, zed.inline_diag = false, true, true

	if data, err := os.read_entire_file(pj(zed.config, "settings.json"), context.allocator); err == nil {
		// JSON5 accepts Zed's // comments and trailing commas
		v, perr := json.parse(data, .JSON5, parse_integers = false)
		if perr == .None do zed.settings = v
	}
	s := zed.settings
	if f := str(obj(s, "buffer_font_family")); f != "" do zed.font_family = f
	if f, ok := obj(s, "buffer_font_size").(json.Float); ok do zed.font_size = i32(f)
	if f, ok := obj(s, "ui_font_size").(json.Float); ok do zed.ui_font_size = i32(f)
	if a := obj(s, "autosave"); a != nil do zed.autosave = str(a) != "off"
	if f := str(obj(s, "format_on_save")); f != "" do zed.format_save = f != "off"
	if b, ok := obj(obj(obj(s, "diagnostics"), "inline"), "enabled").(json.Boolean); ok do zed.inline_diag = b
	if b, ok := obj(obj(s, "inlay_hints"), "enabled").(json.Boolean); ok do zed.inlay_hints = b

	if ov, ok := obj(s, "experimental.theme_overrides").(json.Object); ok {
		for k, v in ov {
			if c, ok := parse_color(str(v)); ok do theme[k] = c
		}
		if ps, ok := ov["players"].(json.Array); ok && len(ps) > 0 {
			if c, ok := parse_color(str(obj(ps[0], "cursor"))); ok do theme["cursor"] = c
			if c, ok := parse_color(str(obj(ps[0], "selection"))); ok do theme["selection"] = c
		}
		if sy, ok := ov["syntax"].(json.Object); ok {
			for k, v in sy {
				st, known := capture_style(k)
				if !known || strings.contains(k, ".") do continue // "comment.doc" must not repaint all comments
				if c, ok := parse_color(str(obj(v, "color"))); ok do syntax[st] = c
			}
		}
	}

	load_extensions()
	add_builtin_languages()
}

@(private = "file")
load_extensions :: proc() {
	root := pj(zed.data, "extensions/installed")
	exts, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return
	for e in exts {
		toml_text, rerr := os.read_entire_file(pj(e.fullpath, "extension.toml"), context.temp_allocator)
		if rerr != nil do continue
		ext_id := strings.clone(e.name)
		// [language_servers.NAME] blocks: language = "X" / languages = ["X", "Y"]
		server_langs := make(map[string][dynamic]string, context.temp_allocator)
		section := ""
		for line in strings.split_lines(string(toml_text), context.temp_allocator) {
			l := strings.trim_space(line)
			if strings.has_prefix(l, "[") {
				section = strings.trim(l, "[]")
				continue
			}
			if !strings.has_prefix(section, "language_servers.") || strings.count(section, ".") != 1 do continue
			name := section[len("language_servers."):]
			key, val := toml_kv(l)
			if key == "language" || key == "languages" {
				for q in toml_strings(val) {
					list := server_langs[name]
					append(&list, q)
					server_langs[name] = list
				}
			}
		}
		for name, list in server_langs {
			zed.server_ext[strings.clone(name)] = ext_id
		}

		lang_dirs, _ := os.read_all_directory_by_path(pj(e.fullpath, "languages"), context.temp_allocator)
		for ld in lang_dirs {
			cfg, cerr := os.read_entire_file(pj(ld.fullpath, "config.toml"), context.temp_allocator)
			if cerr != nil do continue
			lang := Language{tab_size = 4, block_comment = {"/*", "*/"}}
			for line in strings.split_lines(string(cfg), context.temp_allocator) {
				key, val := toml_kv(strings.trim_space(line))
				switch key {
				case "name":
					lang.name = strings.clone(str_value(val))
				case "grammar":
					lang.grammar = strings.clone(str_value(val))
				case "path_suffixes":
					for q in toml_strings(val) do append(&lang.suffixes, strings.clone(q))
				case "line_comments":
					if qs := toml_strings(val); len(qs) > 0 do lang.line_comment = strings.clone(strings.trim_space(qs[0]))
				case "block_comment":
					if qs := toml_strings(val); len(qs) == 2 do lang.block_comment = {strings.clone(strings.trim_space(qs[0])), strings.clone(strings.trim_space(qs[1]))}
				case "hard_tabs":
					lang.hard_tabs = val == "true"
				case "tab_size":
					if n, ok := strconv.parse_int(val); ok do lang.tab_size = n
				}
			}
			if lang.name == "" do continue
			for name, list in server_langs {
				if slice.contains(list[:], lang.name) do append(&lang.servers, strings.clone(name))
			}
			if hl, herr := os.read_entire_file(pj(ld.fullpath, "highlights.scm"), context.temp_allocator); herr == nil {
				scm_words(string(hl), &lang.words)
				if lang.grammar != "" {
					w := pj(e.fullpath, "grammars", strings.concatenate({lang.grammar, ".wasm"}, context.temp_allocator), allocator = context.allocator)
					if os.exists(w) do lang.wasm_path, lang.hl_path = w, pj(ld.fullpath, "highlights.scm", allocator = context.allocator)
				}
			}
			append(&zed.langs, lang)
		}
	}
}

// Languages Zed ships built in (not extensions) and their bundled servers.
@(private = "file")
add_builtin_languages :: proc() {
	Builtin :: struct {
		name, server, comment: string,
		suffixes:              []string,
		words:                 string,
	}
	C_WORDS :: "if else for while do switch case default break continue return goto struct union enum typedef static const extern inline sizeof void int char long short unsigned signed float double bool true false NULL nullptr auto class public private protected virtual template typename namespace using new delete this #include #define #ifdef #ifndef #endif #if #else #pragma"
	list := []Builtin {
		{"Rust", "rust-analyzer", "//", {"rs"}, "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"},
		{"C", "clangd", "//", {"c", "h"}, C_WORDS},
		{"C++", "clangd", "//", {"cpp", "cc", "cxx", "hpp", "hh", "hxx"}, C_WORDS},
		{"Go", "gopls", "//", {"go"}, "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil"},
		{"Python", "", "#", {"py"}, "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"},
		{"JavaScript", "", "//", {"js", "mjs", "cjs", "jsx", "ts", "tsx"}, "async await break case catch class const continue default delete do else export extends false finally for from function if import in instanceof let new null of return super switch this throw true try typeof undefined var void while yield interface type"},
		{"JSON", "", "", {"json", "jsonc"}, "true false null"},
		{"Shell", "", "#", {"sh", "bash", "zsh"}, "if then else elif fi for while do done case esac in function return local export"},
		{"Markdown", "", "", {"md"}, ""},
	}
	outer: for b in list {
		for l in zed.langs do if l.name == b.name do continue outer
		lang := Language{name = b.name, line_comment = b.comment, block_comment = {"/*", "*/"}, tab_size = 4}
		if b.comment == "#" do lang.block_comment = {}
		for s in b.suffixes do append(&lang.suffixes, s)
		if b.server != "" do append(&lang.servers, b.server)
		for w in strings.fields(b.words, context.temp_allocator) do lang.words[strings.clone(w)] = .Keyword
		for w in ([]string{"true", "false", "null", "nil", "None", "True", "False", "NULL", "nullptr", "undefined"}) {
			if w in lang.words do lang.words[w] = .Constant
		}
		append(&zed.langs, lang)
	}
}

language_for :: proc(path: string) -> ^Language {
	base := filepath.base(path)
	ext := filepath.ext(base)
	for &l in zed.langs {
		for s in l.suffixes {
			if s == base || (len(ext) > 1 && s == ext[1:]) do return &l
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Tiny TOML / tree-sitter-query readers (only what config files above need)

@(private = "file")
toml_kv :: proc(l: string) -> (key, val: string) {
	i := strings.index_byte(l, '=')
	if i < 0 || strings.has_prefix(l, "#") do return
	return strings.trim_space(l[:i]), strings.trim_space(l[i + 1:])
}

@(private = "file")
str_value :: proc(v: string) -> string {
	return strings.trim(v, "\"'")
}

// All "quoted" strings in a value (handles ["a", "b"] and "a").
@(private = "file")
toml_strings :: proc(v: string) -> []string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	i := 0
	for i < len(v) {
		if v[i] != '"' {
			i += 1
			continue
		}
		j := i + 1
		for j < len(v) && v[j] != '"' {
			if v[j] == '\\' do j += 1
			j += 1
		}
		if j > len(v) do break
		append(&out, v[i + 1:min(j, len(v))])
		i = j + 1
	}
	return out[:]
}

// Collects literal words from a highlights.scm: `[ "fn" "pub" ] @keyword`,
// `"return" @keyword.return` and `(#any-of? @type.builtin "u8" "i32")`.
scm_words :: proc(src: string, words: ^map[string]Style) {
	group: [dynamic]string
	group.allocator = context.temp_allocator
	any_of_style: Style
	in_any_of := false
	depth := 0
	i := 0
	is_word :: proc(s: string) -> bool {
		if len(s) == 0 do return false
		for c in s do if !(c == '_' || c == '@' || c == '#' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) do return false
		return true
	}
	for i < len(src) {
		c := src[i]
		switch c {
		case ';':
			for i < len(src) && src[i] != '\n' do i += 1
		case '"':
			j := i + 1
			for j < len(src) && src[j] != '"' {
				if src[j] == '\\' do j += 1
				j += 1
			}
			w := src[i + 1:min(j, len(src))]
			if in_any_of {
				if is_word(w) && !(w in words) do words[strings.clone(w)] = any_of_style
			} else {
				append(&group, w)
			}
			i = j + 1
			continue
		case '[':
			clear(&group)
		case '(':
			depth += 1
			if !in_any_of do clear(&group)
		case ')':
			depth -= 1
			in_any_of = false
		case '@':
			j := i + 1
			for j < len(src) && (src[j] == '.' || src[j] == '_' || src[j] == '-' || (src[j] >= 'a' && src[j] <= 'z')) do j += 1
			cap := src[i + 1:j]
			st, ok := capture_style(cap)
			if strings.has_suffix(src[:i], "#any-of? ") {
				in_any_of, any_of_style = ok, st
			} else if ok && st != .Operator && st != .Punct {
				for w in group do if is_word(w) && !(w in words) do words[strings.clone(w)] = st
			}
			clear(&group)
			i = j
			continue
		}
		i += 1
	}
}

// ---------------------------------------------------------------------------
// Finding a server binary the way Zed's extensions would

Server_Cmd :: struct {
	argv:       []string,
	init_opts:  json.Value,
	settings:   json.Value,
}

resolve_server :: proc(name: string) -> (cmd: Server_Cmd, ok: bool) {
	cfg := obj(obj(zed.settings, "lsp"), name)
	cmd.init_opts = obj(cfg, "initialization_options")
	cmd.settings = obj(cfg, "settings")
	bin := obj(cfg, "binary")
	args: [dynamic]string
	if a, aok := obj(bin, "arguments").(json.Array); aok {
		for v in a do append(&args, str(v))
	}
	path := str(obj(bin, "path"))
	if path == "" do path = find_in_path(name)
	if path == "" {
		dirs := []string {
			pj(zed.data, "extensions/work", zed.server_ext[name]) if name in zed.server_ext else "",
			pj(zed.data, "languages", name),
		}
		for d in dirs do if d != "" && path == "" do path = find_exe(d, name, 0)
	}
	if path == "" do return
	argv := make([dynamic]string)
	append(&argv, path)
	append(&argv, ..args[:])
	cmd.argv = argv[:]
	return cmd, true
}

// ~/.local/state/seoritsu (or $XDG_STATE_HOME/seoritsu), created on demand.
state_dir :: proc() -> string {
	dir := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if dir == "" do dir = pj(os.get_env("HOME", context.temp_allocator), ".local/state")
	dir = pj(dir, "seoritsu")
	os.make_directory_all(dir)
	return dir
}

// p is dir itself or something inside it.
is_under :: proc(p, dir: string) -> bool {
	return p == dir || strings.has_prefix(p, strings.concatenate({strings.trim_suffix(dir, "/"), "/"}, context.temp_allocator))
}

find_in_path :: proc(name: string) -> string {
	for d in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		// relative entries ("", ".") would run a same-named program from the opened project
		if !strings.has_prefix(d, "/") do continue
		p := pj(d, name)
		if is_exe(p) do return strings.clone(p)
	}
	return ""
}

@(private = "file")
is_exe :: proc(p: string) -> bool {
	fi, err := os.stat(p, context.temp_allocator)
	return err == nil && fi.type == .Regular && (fi.mode & {.Execute_User}) != {}
}

// Newest (last in name order) executable under dir whose name starts with `name`.
@(private = "file")
find_exe :: proc(dir, name: string, depth: int) -> string {
	if depth > 3 do return ""
	ents, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return ""
	slice.sort_by(ents, proc(a, b: os.File_Info) -> bool {return a.name > b.name})
	for e in ents {
		if e.type == .Regular && strings.has_prefix(e.name, name) && filepath.ext(e.name) != ".metadata" && is_exe(e.fullpath) {
			return strings.clone(e.fullpath)
		}
	}
	for e in ents {
		if e.type == .Directory && e.name != "node_modules" {
			if p := find_exe(e.fullpath, name, depth + 1); p != "" do return p
		}
	}
	return ""
}
