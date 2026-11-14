package main

// Software renderer into a premultiplied ARGB8888 buffer (copied from the file manager's draw.odin).

import "core:math"

Color :: [4]u8 // r, g, b, a (straight alpha)

Rect :: struct {
	x, y, w, h: f32,
}

Canvas :: struct {
	px:     [^]u32,
	w, h:   i32,
	stride: i32, // in pixels
	clip:   [4]i32, // x0, y0, x1, y1
}

cv: Canvas
draw_alpha: u32 = 255 // global opacity for fade animations

hex :: proc(v: u32, a: u8 = 255) -> Color {
	return {u8(v >> 16), u8(v >> 8), u8(v), a}
}

with_alpha :: proc(c: Color, a: u8) -> Color {
	return {c.r, c.g, c.b, a}
}

contains :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

shrink :: proc(r: Rect, d: f32) -> Rect {
	return {r.x + d, r.y + d, r.w - 2 * d, r.h - 2 * d}
}

set_clip :: proc(r: Rect) {
	cv.clip = {
		max(i32(math.floor(r.x)), 0),
		max(i32(math.floor(r.y)), 0),
		min(i32(math.ceil(r.x + r.w)), cv.w),
		min(i32(math.ceil(r.y + r.h)), cv.h),
	}
}

reset_clip :: proc() {
	cv.clip = {0, 0, cv.w, cv.h}
}

clear_canvas :: proc(c: Color) {
	a := u32(c.a)
	p := a << 24 | (u32(c.r) * a / 255) << 16 | (u32(c.g) * a / 255) << 8 | u32(c.b) * a / 255
	for y in 0 ..< cv.h {
		row := cv.px[y * cv.stride:][:cv.w]
		for &v in row do v = p
	}
}

blend :: #force_inline proc(p: ^u32, c: Color, cov: u32) {
	a := (u32(c.a) * cov * draw_alpha + 32512) / 65025
	if a == 0 do return
	inv := 255 - a
	d := p^
	r := (u32(c.r) * a + ((d >> 16) & 0xff) * inv + 127) / 255
	g := (u32(c.g) * a + ((d >> 8) & 0xff) * inv + 127) / 255
	b := (u32(c.b) * a + (d & 0xff) * inv + 127) / 255
	oa := a + ((d >> 24) * inv + 127) / 255
	p^ = oa << 24 | r << 16 | g << 8 | b
}

fill :: proc(r: Rect, c: Color) {
	x0 := max(i32(math.round(r.x)), cv.clip[0])
	y0 := max(i32(math.round(r.y)), cv.clip[1])
	x1 := min(i32(math.round(r.x + r.w)), cv.clip[2])
	y1 := min(i32(math.round(r.y + r.h)), cv.clip[3])
	for y in y0 ..< y1 {
		for x in x0 ..< x1 do blend(&cv.px[y * cv.stride + x], c, 255)
	}
}

// Anti-aliased rounded rectangle; ring > 0 draws only a border of that width.
rrect :: proc(r: Rect, rad: f32, c: Color, ring: f32 = 0) {
	if r.w <= 0 || r.h <= 0 do return
	rad := min(rad, r.w / 2, r.h / 2)
	x0 := max(i32(math.floor(r.x)), cv.clip[0])
	y0 := max(i32(math.floor(r.y)), cv.clip[1])
	x1 := min(i32(math.ceil(r.x + r.w)), cv.clip[2])
	y1 := min(i32(math.ceil(r.y + r.h)), cv.clip[3])
	cx, cy := r.x + r.w / 2, r.y + r.h / 2
	hx, hy := r.w / 2 - rad, r.h / 2 - rad
	edge_px :: #force_inline proc(x, y: i32, cx, hx, qy, rad, ring: f32, c: Color) {
		qx := abs(f32(x) + 0.5 - cx) - hx
		d: f32
		if qx > 0 && qy > 0 {
			d = math.sqrt(qx * qx + qy * qy) - rad
		} else {
			d = max(qx, qy) - rad
		}
		cov := clamp(0.5 - d, 0, 1)
		if ring > 0 do cov -= clamp(0.5 - d - ring, 0, 1)
		if cov > 0 do blend(&cv.px[y * cv.stride + x], c, u32(cov * 255))
	}
	for y in y0 ..< y1 {
		qy := abs(f32(y) + 0.5 - cy) - hy
		// rows away from the corners: only the left/right edges need anti-aliasing,
		// the middle is solid (filled) or, for a ring, empty (skipped)
		if qy < -0.5 && qy - rad < -(ring + 1) {
			m := min(0, rad - ring - 1)
			ix0 := max(i32(math.ceil(cx - (hx + m) - 0.5)), x0)
			ix1 := min(i32(math.floor(cx + (hx + m) - 0.5)) + 1, x1)
			if ix1 > ix0 {
				for x in x0 ..< ix0 do edge_px(x, y, cx, hx, qy, rad, ring, c)
				if ring <= 0 {
					row := cv.px[y * cv.stride:]
					for x in ix0 ..< ix1 do blend(&row[x], c, 255)
				}
				for x in ix1 ..< x1 do edge_px(x, y, cx, hx, qy, rad, ring, c)
				continue
			}
		}
		for x in x0 ..< x1 do edge_px(x, y, cx, hx, qy, rad, ring, c)
	}
}

// Draws text with its baseline at y; returns the advance width.
text :: proc(x, y: f32, s: string, size: i32, c: Color, ui := true) -> f32 {
	pen := i32(math.round(x))
	for r in s {
		glyph(pen, i32(math.round(y)), r, size, c, ui)
		pen += get_glyph(r, size, ui).adv
	}
	return f32(pen) - x
}

glyph :: proc(pen, by: i32, r: rune, size: i32, c: Color, ui := false) {
	g := get_glyph(r, size, ui)
	gx, gy := pen + g.left, by - g.top
	for j in 0 ..< g.h {
		py := gy + j
		if py < cv.clip[1] || py >= cv.clip[3] do continue
		for i in 0 ..< g.w {
			px := gx + i
			if px < cv.clip[0] || px >= cv.clip[2] do continue
			if m := g.px[j * g.w + i]; m != 0 do blend(&cv.px[py * cv.stride + px], c, u32(m))
		}
	}
}

// Baseline that vertically centers a line of `size` px text inside r.
baseline :: proc(r: Rect, size: i32, ui := true) -> f32 {
	asc, desc := font_metrics(size, ui)
	return math.round(r.y + (r.h + f32(asc - desc)) / 2)
}
