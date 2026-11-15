package main

// FreeType glyph cache (adapted from the file manager's font.odin): two font
// chains, the code font (Zed's buffer_font_family) and the UI font, each with
// a CJK and a Nerd-symbols fallback.

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"

foreign import ft "system:freetype"

FT_Library :: distinct rawptr
FT_Generic :: struct {
	data:      rawptr,
	finalizer: rawptr,
}
FT_Bitmap :: struct {
	rows, width:  c.uint,
	pitch:        c.int,
	buffer:       [^]u8,
	num_grays:    u16,
	pixel_mode:   u8,
	palette_mode: u8,
	palette:      rawptr,
}
FT_GlyphSlotRec :: struct {
	library:             FT_Library,
	face:                rawptr,
	next:                rawptr,
	glyph_index:         c.uint,
	generic:             FT_Generic,
	metrics:             [8]c.long,
	linear_hori_advance: c.long,
	linear_vert_advance: c.long,
	advance:             [2]c.long,
	format:              c.uint,
	bitmap:              FT_Bitmap,
	bitmap_left:         c.int,
	bitmap_top:          c.int,
}
FT_Size_Metrics :: struct {
	x_ppem, y_ppem:                           u16,
	x_scale, y_scale:                         c.long,
	ascender, descender, height, max_advance: c.long,
}
FT_SizeRec :: struct {
	face:    rawptr,
	generic: FT_Generic,
	metrics: FT_Size_Metrics,
}
FT_FaceRec :: struct {
	num_faces, face_index, face_flags, style_flags, num_glyphs:                                                    c.long,
	family_name, style_name:                                                                                       cstring,
	num_fixed_sizes:                                                                                               c.int,
	available_sizes:                                                                                               rawptr,
	num_charmaps:                                                                                                  c.int,
	charmaps:                                                                                                      rawptr,
	generic:                                                                                                       FT_Generic,
	bbox:                                                                                                          [4]c.long,
	units_per_EM:                                                                                                  u16,
	ascender, descender, height, max_advance_width, max_advance_height, underline_position, underline_thickness: i16,
	glyph:                                                                                                         ^FT_GlyphSlotRec,
	size:                                                                                                          ^FT_SizeRec,
	charmap:                                                                                                       rawptr,
}
FT_Face :: ^FT_FaceRec

FT_LOAD_RENDER :: 1 << 2
FT_LOAD_TARGET_LIGHT :: 1 << 16

@(default_calling_convention = "c")
foreign ft {
	FT_Init_FreeType :: proc(lib: ^FT_Library) -> c.int ---
	FT_New_Face :: proc(lib: FT_Library, path: cstring, index: c.long, face: ^FT_Face) -> c.int ---
	FT_Set_Pixel_Sizes :: proc(face: FT_Face, w, h: c.uint) -> c.int ---
	FT_Get_Char_Index :: proc(face: FT_Face, code: c.ulong) -> c.uint ---
	FT_Load_Glyph :: proc(face: FT_Face, index: c.uint, flags: i32) -> c.int ---
}

Glyph :: struct {
	w, h, left, top, adv: i32,
	px:                   []u8,
}

// chain[0] = code font, chain[1] = UI font; each: main, CJK fallback, icon font
@(private = "file") lib: FT_Library
@(private = "file") chain: [2][3]FT_Face
@(private = "file") face_size: map[FT_Face]i32
@(private = "file") cache: map[u64]Glyph

UI_FONTS :: []string {
	"/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf",
	"/usr/share/fonts/adwaita-sans-fonts/AdwaitaSans-Regular.ttf",
	"/usr/share/fonts/cantarell/Cantarell-VF.otf",
	"/usr/share/fonts/noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu/DejaVuSans.ttf",
}
CJK_FONTS :: []string {
	"/usr/share/fonts/noto/NotoSansCJKjp-Regular.otf",
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
}
ICON_FONTS :: []string {
	"/usr/share/fonts/nerd-symbols-only/SymbolsNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf",
	"/usr/share/fonts/nerd-fonts/SymbolsNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/SymbolsNerdFontMono-Regular.ttf",
}

@(private = "file")
open_first :: proc(paths: []string) -> FT_Face {
	for p in paths {
		if !os.exists(p) do continue
		face: FT_Face
		if FT_New_Face(lib, strings.clone_to_cstring(p, context.temp_allocator), 0, &face) == 0 do return face
	}
	return nil
}

@(private = "file")
fc_match :: proc(pattern: string) -> FT_Face {
	_, out, _, err := os.process_exec({command = {"fc-match", "-f", "%{file}", pattern}}, context.temp_allocator)
	if err != nil || len(out) == 0 do return nil
	return open_first({string(out)})
}

font_init :: proc(code_family: string) -> bool {
	if FT_Init_FreeType(&lib) != 0 do return false
	cjk := open_first(CJK_FONTS)
	if cjk == nil do cjk = fc_match("sans-serif:lang=ja")
	icons := open_first(ICON_FONTS)
	if icons == nil do icons = fc_match("Symbols Nerd Font")
	code := fc_match(strings.concatenate({code_family, ":spacing=mono"}, context.temp_allocator))
	if code == nil do code = fc_match("monospace")
	ui := open_first(UI_FONTS)
	if ui == nil do ui = fc_match("sans-serif")
	chain[0] = {code, cjk, icons}
	chain[1] = {ui if ui != nil else code, cjk, icons}
	return code != nil || cjk != nil
}

@(private = "file")
set_size :: proc(face: FT_Face, size: i32) {
	if face_size[face] != size {
		FT_Set_Pixel_Sizes(face, 0, c.uint(size))
		face_size[face] = size
	}
}

get_glyph :: proc(r: rune, size: i32, ui := false) -> Glyph {
	key := u64(r) | u64(size) << 32 | (u64(1) << 63 if ui else 0)
	if g, ok := cache[key]; ok do return g
	// the cache lives for the whole process, whatever allocator the caller runs under
	context.allocator = runtime.heap_allocator()
	g: Glyph
	faces := &chain[1 if ui else 0]
	pick: FT_Face
	idx: c.uint
	for f in faces {
		if f == nil do continue
		if i := FT_Get_Char_Index(f, c.ulong(r)); i != 0 {
			pick, idx = f, i
			break
		}
	}
	if pick == nil do pick = faces[0] if faces[0] != nil else faces[1] // .notdef box
	if pick != nil {
		set_size(pick, size)
		if FT_Load_Glyph(pick, idx, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT) == 0 {
			slot := pick.glyph
			bm := slot.bitmap
			g.w, g.h = i32(bm.width), i32(bm.rows)
			g.left, g.top = i32(slot.bitmap_left), i32(slot.bitmap_top)
			g.adv = i32((slot.advance[0] + 32) >> 6)
			if g.w > 0 && g.h > 0 && bm.buffer != nil {
				g.px = make([]u8, int(g.w * g.h))
				for y in 0 ..< int(g.h) do copy(g.px[y * int(g.w):][:g.w], bm.buffer[y * int(bm.pitch):][:g.w])
			}
		}
	}
	cache[key] = g
	return g
}

font_metrics :: proc(size: i32, ui := false) -> (asc, desc: i32) {
	f := chain[1 if ui else 0][0]
	if f == nil do return size, size / 4
	set_size(f, size)
	return i32(f.size.metrics.ascender >> 6), i32(-f.size.metrics.descender >> 6)
}

text_width :: proc(s: string, size: i32, ui := false) -> i32 {
	w: i32
	for r in s do w += get_glyph(r, size, ui).adv
	return w
}
