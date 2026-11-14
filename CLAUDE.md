# Seoritsu — notes for Claude

Translucent code editor, pure Odin on raw Wayland. Reads Zed's settings.json, installed
extensions and Zed-downloaded language servers (see README.md). Build: `./build.sh`, tests: `./build.sh test`.

## Rules
- Never run the editor on real project files in tests: autosave writes on exit/focus loss.
  Use copies in a scratch dir; `SEORITSU_DUMP=out.raw ./seoritsu file` dumps frames for 6 s
  (autosave off) → `python3 tools/dump2png.py out.raw out.png`.
- Odin toolchain: ~/.cache/ame-shell/toolchain/odin-dev-2026-08/odin. sed is BSD (use python for in-place edits).
- `src/wl.odin`, `src/draw.odin`, `src/font.odin` were copied from ~/AmeFileManger/src/gui (now independent).

## Debugging
`SEORITSU_DUMP_CMD="<palette name>"` runs that command 2.5 s after start (screenshots of pickers etc.);
`menu:panel` / `menu:tab` / `menu:editor` open a right-click menu instead.
Tests: `./build.sh test` (single-threaded: tests share `app`; reset globals that hold a previous test's allocator).

## Status (batch 2 done)
Multi-cursor, picker (files / palette / rg search / refs / symbols / diagnostics / code actions), find & replace,
go to line, LSP rename / references / code actions / signature help / inlay hints / symbols / incremental sync /
applyEdit, git gutter, minimap, bracket match, word highlight, session restore, reload on focus, back/forward.
Measured: 16 MB RSS, ~0% idle CPU (fixed a redraw loop: only real events set `dirty`), 200k lines: 43 MB.

## Tree-sitter
`src/ts.odin`: Zed's grammars/<name>.wasm run on our own wasm interpreter (`wasm/wasm.zig`, test: `wasm/test/run.sh`),
highlights.scm query colors visible lines over the lexer, LSP semantic tokens still win. Parse is time-sliced (8 ms/loop).
Rebuild C/Zig libs after changing wasm/ or third_party/: `./wasm/build.sh`.

## Workspace (src/workspace.odin)
Title bar, breadcrumbs, git status colors, project panel keys (`panel_focus`), file ops (trash = freedesktop
~/.local/share/Trash, never rm), external terminal (choice saved in ~/.local/state/seoritsu/terminal).

## Extras (src/extras.odin)
Drag & drop via plat_start_drag / Dnd_* events (panel: press = click on release, drag on motion), file clipboard,
recent projects (~/.local/state/seoritsu/recent; switching re-execs /proc/self/exe after the normal quit path),
git branch/commit/push/pull (synchronous), generic `.Prompt` input mode, extra edit commands.
Dump runs: set XDG_STATE_HOME to a scratch dir so they don't touch the user's recent list / terminal choice.

## Ideas not done yet
Embedded terminal pane, split panes, code folding, vim mode, completion with several carets, codeAction/resolve,
damage-tracked partial redraw.
