package main

// Split panes side by side (Ctrl+\). app.bufs / app.active are the focused pane's tabs;
// the other panes wait in `panes`. A file open in two panes is one Buffer (same text);
// each pane remembers its own caret and scroll for it.

import "core:slice"

View :: struct {
	cur, anchor:        Pos,
	scroll_y, scroll_x: f32,
	want_x:             f32,
}

Pane :: struct {
	bufs:   [dynamic]^Buffer,
	active: int,
	views:  map[^Buffer]View,
}

panes: [dynamic]Pane // empty: one pane, app.bufs is all there is
pane_i: int
MAX_PANES :: 4

pane_count :: proc() -> int {return max(len(panes), 1)}

@(private = "file")
pane_save :: proc(i: int) {
	p := &panes[i]
	p.bufs, p.active = app.bufs, app.active
	if b := cur_buf(); b != nil do p.views[b] = View{b.cur, b.anchor, b.scroll_y, b.scroll_x, b.want_x}
}

@(private = "file")
pane_load :: proc(i: int) {
	p := &panes[i]
	app.bufs, app.active = p.bufs, p.active
	if b := cur_buf(); b != nil {
		if v, ok := p.views[b]; ok {
			b.cur, b.anchor = clamp_pos(b, v.cur), clamp_pos(b, v.anchor)
			b.scroll_y, b.scroll_x, b.want_x = v.scroll_y, v.scroll_x, v.want_x
			clear(&b.extra)
			clamp_scroll(b)
		}
	}
}

focus_pane :: proc(i: int) {
	if len(panes) == 0 || i == pane_i || i < 0 || i >= len(panes) do return
	pane_save(pane_i)
	pane_load(i)
	pane_i = i
	app.comp_on, app.hover, app.sig = false, "", ""
}

split_right :: proc() {
	if pane_count() >= MAX_PANES {
		toast("これ以上分割できません")
		return
	}
	if len(panes) == 0 do append(&panes, Pane{})
	pane_save(pane_i)
	np := Pane{}
	if b := cur_buf(); b != nil {
		append(&np.bufs, b) // Zed: the new pane starts with the same file
		np.views[b] = View{b.cur, b.anchor, b.scroll_y, b.scroll_x, b.want_x}
	}
	inject_at(&panes, pane_i + 1, np)
	focus_pane(pane_i + 1)
}

// Called when the focused pane lost its last tab: the pane goes away.
close_pane_if_empty :: proc() {
	if len(panes) <= 1 || len(app.bufs) > 0 do return
	delete(panes[pane_i].views)
	ordered_remove(&panes, pane_i)
	pane_i = min(pane_i, len(panes) - 1)
	pane_load(pane_i)
	if len(panes) == 1 { // back to a single pane
		delete(panes[0].views)
		clear(&panes)
		pane_i = 0
	}
}

close_pane :: proc() {
	if len(panes) <= 1 do return
	close_tabs(proc(i: int) -> bool {return true})
	if len(app.bufs) > 0 do return // unsaved tabs kept it open
	close_pane_if_empty()
}

// Every open buffer, each once (all panes).
all_bufs :: proc() -> []^Buffer {
	out := make([dynamic]^Buffer, context.temp_allocator)
	append(&out, ..app.bufs[:])
	for p, i in panes do if i != pane_i {
		for b in p.bufs do if !slice.contains(out[:], b) do append(&out, b)
	}
	return out[:]
}

// Open in another pane too? (Then closing a tab must not close the document.)
open_elsewhere :: proc(b: ^Buffer) -> bool {
	for p, i in panes do if i != pane_i && slice.contains(p.bufs[:], b) do return true
	return false
}

// Drops b from every pane but the focused one (a deleted file).
remove_from_other_panes :: proc(b: ^Buffer) {
	for &p, i in panes do if i != pane_i {
		if k, found := slice.linear_search(p.bufs[:], b); found {
			ordered_remove(&p.bufs, k)
			p.active = clamp(p.active, 0, max(len(p.bufs) - 1, 0))
			delete_key(&p.views, b)
		}
	}
	// a pane left empty goes away (unless it's the focused one)
	for i := len(panes) - 1; i >= 0; i -= 1 do if i != pane_i && len(panes[i].bufs) == 0 && len(panes) > 1 {
		delete(panes[i].views)
		ordered_remove(&panes, i)
		if i < pane_i do pane_i -= 1
	}
	if len(panes) == 1 {
		pane_save(0)
		delete(panes[0].views)
		clear(&panes)
		pane_i = 0
	}
}

// Column i of the editor area (right of the project panel).
pane_rect :: proc(i: int) -> Rect {
	n := f32(pane_count())
	x0 := app.panel.w if app.panel_on else 0
	w := (app.W - x0) / n
	return {x0 + w * f32(i), app.titlebar.h, w, app.H - app.titlebar.h - app.status.h - term_h()}
}

pane_at :: proc(x: f32) -> int {
	for i in 0 ..< pane_count() {
		r := pane_rect(i)
		if x >= r.x && x < r.x + r.w do return i
	}
	return pane_i
}

// Draws every pane; the focused one is laid out last so input uses its rects.
draw_panes :: proc() {
	if len(panes) == 0 {
		app.text_focus = !term.focus
		draw_editor()
		draw_tabbar()
		draw_breadcrumbs()
		return
	}
	focused := pane_i
	pane_save(focused)
	for i in 0 ..< len(panes) {
		pane_load(i)
		layout_pane(pane_rect(i))
		app.text_focus = i == focused && !term.focus
		draw_editor()
		draw_tabbar()
		draw_breadcrumbs()
		if i > 0 do fill({pane_rect(i).x, pane_rect(i).y, max(app.S, 1), pane_rect(i).h}, col("border"))
		pane_save(i)
	}
	pane_load(focused)
	layout_pane(pane_rect(focused))
}

// Wheel over a pane scrolls that pane without moving the keyboard focus.
scroll_pane :: proc(i: int, ev: Ev) {
	if i == pane_i || len(panes) == 0 {
		wheel_scroll(ev)
		return
	}
	focused := pane_i
	focus_pane(i)
	layout_pane(pane_rect(i))
	wheel_scroll(ev)
	focus_pane(focused)
	layout_pane(pane_rect(focused))
}
