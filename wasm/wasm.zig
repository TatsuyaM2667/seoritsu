//! A small WebAssembly interpreter, just enough to run tree-sitter grammars
//! (the `grammars/*.wasm` side modules shipped in Zed extensions).
//!
//! Bytecode is compiled once into a flat instruction array with resolved branch
//! targets and stack heights, so the hot loop never searches for `end`.
//! The C side (ts_wasm_store.c) plugs this into tree-sitter's wasm store API.

const std = @import("std");
const A = std.heap.c_allocator;

const Err = error{ Trap, OutOfMemory, Invalid, Unsupported };

// ---------------------------------------------------------------------------
// Module

const FuncType = struct {
    params: []const u8,
    results: []const u8,
};

const Ins = struct {
    op: u16,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    v: u64 = 0,
};

const BrTarget = struct { pc: u32, keep: u32, h: u32 };

const HostFn = *const fn (inst: *Inst, args: []u64) Err!u64;

const Func = struct {
    type_idx: u32,
    host: ?HostFn = null,
    code: []Ins = &.{},
    nlocals: u32 = 0, // params + declared locals
    body: []const u8 = &.{}, // raw, until compiled
    local_types: []const u8 = &.{},
};

const Global = struct { v: u64, mutable: bool };

pub const Inst = struct {
    types: []FuncType,
    funcs: std.ArrayList(Func) = .empty,
    globals: std.ArrayList(Global) = .empty,
    table: std.ArrayList(u32) = .empty, // function index + 1 (0 = null)
    brtables: std.ArrayList(BrTarget) = .empty,
    mem: []u8 = &.{},
    max_pages: u32 = 2048, // 128 MiB
    stack: []u64,
    sp: u32 = 0,
    depth: u32 = 0,
    // tree-sitter glue
    lexer: ?*TSLexer = null,
    heap_start: u32 = 0,
    heap_ptr: u32 = 0,
    lexer_addr: u32 = 0,
    ser_addr: u32 = 0,
    host_slots: u32 = 0, // table index of the first lexer callback
    exports: std.StringHashMapUnmanaged(u32) = .empty, // name -> func index
};

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn byte(r: *Reader) Err!u8 {
        if (r.i >= r.b.len) return error.Invalid;
        r.i += 1;
        return r.b[r.i - 1];
    }
    fn uleb(r: *Reader) Err!u64 {
        var res: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const x = try r.byte();
            res |= @as(u64, x & 0x7f) << shift;
            if (x < 0x80) return res;
            if (shift >= 63) return error.Invalid;
            shift += 7;
        }
    }
    fn u32_(r: *Reader) Err!u32 {
        return @truncate(try r.uleb());
    }
    fn sleb(r: *Reader, comptime bits: u7) Err!i64 {
        var res: i64 = 0;
        var shift: u7 = 0;
        var x: u8 = 0;
        while (true) {
            x = try r.byte();
            if (shift < 64) res |= @as(i64, x & 0x7f) << @intCast(shift);
            shift += 7;
            if (x < 0x80) break;
            if (shift > bits + 7) return error.Invalid;
        }
        if (shift < 64 and (x & 0x40) != 0) res |= @as(i64, -1) << @intCast(shift);
        return res;
    }
    fn bytes(r: *Reader, n: usize) Err![]const u8 {
        if (r.i + n > r.b.len) return error.Invalid;
        r.i += n;
        return r.b[r.i - n .. r.i];
    }
    fn name(r: *Reader) Err![]const u8 {
        return r.bytes(try r.u32_());
    }
};

// ---------------------------------------------------------------------------
// Loading a tree-sitter side module

pub const Dylink = extern struct { memory_size: u32, memory_align: u32, table_size: u32, table_align: u32 };

const STACK_SIZE: u32 = 256 * 1024;
const PAGE: u32 = 65536;

fn alignUp(x: u32, a: u32) u32 {
    return (x + a - 1) / a * a;
}

/// Loads `bytes`, lays out memory as [stack | lexer | serialization buffer | module data | heap],
/// runs the relocation / init functions and returns the instance plus the address of
/// `tree_sitter_<name>()`'s language object.
export fn tsw_load(bytes: [*]const u8, len: usize, lang_name: [*:0]const u8, out_lang: *u32, out_dylink: *Dylink) ?*Inst {
    return load(bytes[0..len], std.mem.span(lang_name), out_lang, out_dylink) catch null;
}

fn load(input: []const u8, lang_name: []const u8, out_lang: *u32, out_dylink: *Dylink) Err!*Inst {
    // types and names point into the module bytes: keep our own copy
    const b = try A.dupe(u8, input);
    if (b.len < 8 or !std.mem.eql(u8, b[0..4], "\x00asm")) return error.Invalid;
    var r = Reader{ .b = b, .i = 8 };
    var dl = Dylink{ .memory_size = 0, .memory_align = 0, .table_size = 0, .table_align = 0 };

    const inst = try A.create(Inst);
    inst.* = .{ .types = &.{}, .stack = try A.alloc(u64, 1 << 18) };
    var types: std.ArrayList(FuncType) = .empty;

    const Imp = struct { mod: []const u8, name: []const u8, kind: u8, idx: u32 };
    var imports: std.ArrayList(Imp) = .empty;
    defer imports.deinit(A);
    var global_inits: std.ArrayList([]const u8) = .empty; // const exprs of defined globals
    defer global_inits.deinit(A);
    var elem_secs: []const u8 = &.{};
    var data_secs: []const u8 = &.{};
    var exports_raw: []const u8 = &.{};
    var n_imported_funcs: u32 = 0;
    var mem_base: u32 = 0;

    while (r.i < b.len) {
        const id = try r.byte();
        const size = try r.u32_();
        const body = try r.bytes(size);
        var s = Reader{ .b = body };
        switch (id) {
            0 => {
                const nm = try s.name();
                if (std.mem.eql(u8, nm, "dylink.0")) {
                    while (s.i < body.len) {
                        const sub = try s.byte();
                        const l = try s.u32_();
                        const sb = try s.bytes(l);
                        if (sub == 1) {
                            var t = Reader{ .b = sb };
                            dl.memory_size = try t.u32_();
                            dl.memory_align = try t.u32_();
                            dl.table_size = try t.u32_();
                            dl.table_align = try t.u32_();
                        }
                    }
                }
            },
            1 => {
                const n = try s.u32_();
                for (0..n) |_| {
                    if (try s.byte() != 0x60) return error.Invalid;
                    const p = try s.bytes(try s.u32_());
                    const res = try s.bytes(try s.u32_());
                    try types.append(A, .{ .params = p, .results = res });
                }
                inst.types = types.items;
            },
            2 => {
                const n = try s.u32_();
                for (0..n) |_| {
                    const m = try s.name();
                    const f = try s.name();
                    const kind = try s.byte();
                    var idx: u32 = 0;
                    switch (kind) {
                        0 => idx = try s.u32_(),
                        1 => {
                            _ = try s.byte();
                            const fl = try s.byte();
                            _ = try s.u32_();
                            if (fl & 1 != 0) _ = try s.u32_();
                        },
                        2 => {
                            const fl = try s.byte();
                            _ = try s.u32_();
                            if (fl & 1 != 0) _ = try s.u32_();
                        },
                        3 => {
                            _ = try s.byte();
                            idx = try s.byte(); // mutability
                        },
                        else => return error.Invalid,
                    }
                    try imports.append(A, .{ .mod = m, .name = f, .kind = kind, .idx = idx });
                }
            },
            3 => {
                // memory layout is known once dylink + imports are read (both come first)
                if (mem_base == 0) mem_base = try setupMemory(inst, dl);
                // resolve imports now that we know where things go
                for (imports.items) |imp| {
                    switch (imp.kind) {
                        0 => {
                            try inst.funcs.append(A, .{ .type_idx = imp.idx, .host = hostFor(imp.name) });
                            n_imported_funcs += 1;
                        },
                        3 => {
                            var v: u64 = 0;
                            if (std.mem.eql(u8, imp.name, "__memory_base")) v = mem_base
                            else if (std.mem.eql(u8, imp.name, "__table_base")) v = 1
                            else if (std.mem.eql(u8, imp.name, "__stack_pointer")) v = STACK_SIZE;
                            try inst.globals.append(A, .{ .v = v, .mutable = imp.idx != 0 });
                        },
                        else => {}, // memory and table are ours
                    }
                }
                const n = try s.u32_();
                for (0..n) |_| try inst.funcs.append(A, .{ .type_idx = try s.u32_() });
            },
            6 => {
                const n = try s.u32_();
                for (0..n) |_| {
                    _ = try s.byte();
                    const mut = try s.byte();
                    const start = s.i;
                    try skipConstExpr(&s);
                    try global_inits.append(A, body[start..s.i]);
                    try inst.globals.append(A, .{ .v = 0, .mutable = mut != 0 });
                }
            },
            7 => exports_raw = body,
            9 => elem_secs = body,
            10 => {
                const n = try s.u32_();
                if (n + n_imported_funcs != inst.funcs.items.len) return error.Invalid;
                for (0..n) |k| {
                    const fb = try s.bytes(try s.u32_());
                    var fr = Reader{ .b = fb };
                    const f = &inst.funcs.items[n_imported_funcs + k];
                    const ty = inst.types[f.type_idx];
                    var lt: std.ArrayList(u8) = .empty;
                    try lt.appendSlice(A, ty.params);
                    const groups = try fr.u32_();
                    for (0..groups) |_| {
                        const cnt = try fr.u32_();
                        const t = try fr.byte();
                        if (cnt > 50000) return error.Invalid;
                        try lt.appendNTimes(A, t, cnt);
                    }
                    f.local_types = lt.items;
                    f.nlocals = @intCast(lt.items.len);
                    f.body = fb[fr.i..];
                }
            },
            11 => data_secs = body,
            else => {},
        }
    }
    out_dylink.* = dl;
    if (mem_base == 0) mem_base = try setupMemory(inst, dl);

    // defined globals: evaluate their init expressions (may read imported globals)
    const first_defined = inst.globals.items.len - global_inits.items.len;
    for (global_inits.items, 0..) |e, k| {
        inst.globals.items[first_defined + k].v = try evalConst(inst, e);
    }

    // function table: [null | module's slots | lexer callbacks]
    const tsize = 1 + dl.table_size;
    try inst.table.appendNTimes(A, 0, tsize);
    inst.host_slots = tsize;
    const cbs = [_]HostFn{ lexAdvance, lexMarkEnd, lexGetColumn, lexAtRangeStart, lexEof };
    for (cbs) |cb| {
        try inst.funcs.append(A, .{ .type_idx = 0, .host = cb });
        try inst.table.append(A, @intCast(inst.funcs.items.len)); // index + 1
    }

    // exports
    if (exports_raw.len > 0) {
        var s = Reader{ .b = exports_raw };
        const n = try s.u32_();
        for (0..n) |_| {
            const nm = try s.name();
            const kind = try s.byte();
            const idx = try s.u32_();
            if (kind == 0) try inst.exports.put(A, nm, idx);
        }
    }
    // element segments -> table
    if (elem_secs.len > 0) {
        var s = Reader{ .b = elem_secs };
        const n = try s.u32_();
        for (0..n) |_| {
            const flags = try s.u32_();
            var offset: u32 = 0;
            const active = flags & 1 == 0;
            if (flags & 2 != 0 and active) _ = try s.u32_(); // table index
            if (active) {
                const start = s.i;
                try skipConstExpr(&s);
                offset = @truncate(try evalConst(inst, s.b[start..s.i]));
            }
            if (flags & 3 != 0) _ = try s.byte(); // elemkind / reftype
            const cnt = try s.u32_();
            for (0..cnt) |k| {
                var fidx: u32 = 0;
                if (flags & 4 != 0) {
                    // expression: ref.func x / ref.null
                    const op = try s.byte();
                    if (op == 0xD2) fidx = try s.u32_() + 1 else if (op == 0xD0) _ = try s.byte() else return error.Unsupported;
                    if (try s.byte() != 0x0B) return error.Invalid;
                } else {
                    fidx = try s.u32_() + 1;
                }
                if (active) {
                    const slot = offset + @as(u32, @intCast(k));
                    if (slot >= inst.table.items.len) return error.Invalid;
                    inst.table.items[slot] = fidx;
                }
            }
        }
    }
    // data segments -> memory
    if (data_secs.len > 0) {
        var s = Reader{ .b = data_secs };
        const n = try s.u32_();
        for (0..n) |_| {
            const flags = try s.u32_();
            var offset: u32 = 0;
            if (flags != 1) {
                if (flags == 2) _ = try s.u32_();
                const start = s.i;
                try skipConstExpr(&s);
                offset = @truncate(try evalConst(inst, s.b[start..s.i]));
            }
            const d = try s.bytes(try s.u32_());
            if (flags == 1) continue; // passive: not used by these modules
            if (@as(usize, offset) + d.len > inst.mem.len) return error.Invalid;
            @memcpy(inst.mem[offset..][0..d.len], d);
        }
    }

    // compile every function body
    for (inst.funcs.items) |*f| {
        if (f.host == null and f.body.len > 0) try compile(inst, f);
    }

    // relocations, constructors, then the language object
    for ([_][]const u8{ "__wasm_apply_data_relocs", "_initialize", "__wasm_call_ctors" }) |nm| {
        if (inst.exports.get(nm)) |fi| _ = try call(inst, fi, &.{});
    }
    var fname_buf: [128]u8 = undefined;
    const fname = std.fmt.bufPrint(&fname_buf, "tree_sitter_{s}", .{lang_name}) catch return error.Invalid;
    const lf = inst.exports.get(fname) orelse return error.Invalid;
    out_lang.* = @truncate(try call(inst, lf, &.{}));
    return inst;
}

fn setupMemory(inst: *Inst, dl: Dylink) Err!u32 {
    inst.lexer_addr = STACK_SIZE;
    inst.ser_addr = STACK_SIZE + 64;
    const al: u32 = @max(16, @as(u32, 1) << @intCast(@min(dl.memory_align, 12)));
    const base = alignUp(inst.ser_addr + 1024, al);
    inst.heap_start = alignUp(base + dl.memory_size, 16);
    inst.heap_ptr = inst.heap_start;
    const pages = alignUp(inst.heap_start + 1024 * 1024, PAGE) / PAGE;
    inst.mem = try A.alloc(u8, pages * PAGE);
    @memset(inst.mem, 0);
    return base;
}

fn skipConstExpr(s: *Reader) Err!void {
    while (true) {
        const op = try s.byte();
        switch (op) {
            0x0B => return,
            0x41 => _ = try s.sleb(32),
            0x42 => _ = try s.sleb(64),
            0x43 => _ = try s.bytes(4),
            0x44 => _ = try s.bytes(8),
            0x23, 0xD2 => _ = try s.u32_(),
            0xD0 => _ = try s.byte(),
            0x6A, 0x6B, 0x6C, 0x7C, 0x7D, 0x7E => {},
            else => return error.Unsupported,
        }
    }
}

fn evalConst(inst: *Inst, e: []const u8) Err!u64 {
    var s = Reader{ .b = e };
    var st: [8]u64 = undefined;
    var n: usize = 0;
    while (true) {
        const op = try s.byte();
        if (op == 0x0B) break;
        if (n >= st.len) return error.Invalid;
        switch (op) {
            0x41 => {
                st[n] = @as(u32, @truncate(@as(u64, @bitCast(try s.sleb(32)))));
                n += 1;
            },
            0x42 => {
                st[n] = @bitCast(try s.sleb(64));
                n += 1;
            },
            0x43 => {
                st[n] = std.mem.readInt(u32, (try s.bytes(4))[0..4], .little);
                n += 1;
            },
            0x44 => {
                st[n] = std.mem.readInt(u64, (try s.bytes(8))[0..8], .little);
                n += 1;
            },
            0x23 => {
                const g = try s.u32_();
                if (g >= inst.globals.items.len) return error.Invalid;
                st[n] = inst.globals.items[g].v;
                n += 1;
            },
            0xD2 => {
                st[n] = try s.u32_() + 1;
                n += 1;
            },
            0xD0 => {
                _ = try s.byte();
                st[n] = 0;
                n += 1;
            },
            0x6A, 0x6B, 0x6C => {
                if (n < 2) return error.Invalid;
                const x: u32 = @truncate(st[n - 2]);
                const y: u32 = @truncate(st[n - 1]);
                st[n - 2] = switch (op) {
                    0x6A => x +% y,
                    0x6B => x -% y,
                    else => x *% y,
                };
                n -= 1;
            },
            0x7C, 0x7D, 0x7E => {
                if (n < 2) return error.Invalid;
                st[n - 2] = switch (op) {
                    0x7C => st[n - 2] +% st[n - 1],
                    0x7D => st[n - 2] -% st[n - 1],
                    else => st[n - 2] *% st[n - 1],
                };
                n -= 1;
            },
            else => return error.Unsupported,
        }
    }
    return if (n > 0) st[n - 1] else 0;
}

// ---------------------------------------------------------------------------
// Compiler: wasm bytecode -> Ins[] with branch targets and stack heights

// internal ops beyond the wasm byte range
const OP_JMP: u16 = 0x100; // unconditional jump without stack change (end of `then`)
const OP_FC: u16 = 0x200; // 0xFC sub-op n -> 0x200 + n
// Fused instructions (tree-sitter lexers are long "compare the char, branch" chains):
// OP_LK + (op - 0x46): `local.get L; i32.const K; <i32 cmp/binop>`  (v = K | L << 32)
// OP_BRLK + (op - 0x46): the same compare followed by br_if          (a/b/c = branch)
// OP_BRL / OP_BRLZ: `local.get L; br_if` / `local.get L; i32.eqz; br_if`
const OP_LK: u16 = 0x300;
const OP_BRLK: u16 = 0x340;
const OP_BRL: u16 = 0x350;
const OP_BRLZ: u16 = 0x351;
// OP_SK + (op - 0x46): `<value on stack>; i32.const K; <i32 op>`  (v = K)
// OP_BRSK + (op - 0x46): that compare followed by br_if
const OP_SK: u16 = 0x380;
const OP_BRSK: u16 = 0x3C0;

// first instruction index that may be a branch target; fusion never spans one
var label_pc: u32 = 0;

const Ctl = struct {
    loop: bool,
    is_if: bool,
    start_pc: u32,
    height: u32, // operand height below the block's params
    nparams: u32,
    nresults: u32,
    patches: std.ArrayList(u32), // instruction indexes whose `a` must become the end pc
    br_patches: std.ArrayList(u32), // brtable entries
    else_ins: ?u32,
    unreachable_: bool,
    born_dead: bool = false, // opened inside unreachable code: everything in it is skipped
};

const BrInfo = struct { keep: u32, h: u32 };

fn branchInfo(ctls: []Ctl, depth: u32) Err!BrInfo {
    if (depth >= ctls.len) return error.Invalid;
    const c = &ctls[ctls.len - 1 - depth];
    return .{ .keep = if (c.loop) c.nparams else c.nresults, .h = c.height };
}

fn blockType(inst: *Inst, s: *Reader) Err!struct { p: u32, r: u32 } {
    const peek = s.b[s.i];
    if (peek == 0x40) {
        s.i += 1;
        return .{ .p = 0, .r = 0 };
    }
    if (peek == 0x7F or peek == 0x7E or peek == 0x7D or peek == 0x7C or peek == 0x70 or peek == 0x6F) {
        s.i += 1;
        return .{ .p = 0, .r = 1 };
    }
    const idx: u32 = @intCast(try s.sleb(33));
    if (idx >= inst.types.len) return error.Invalid;
    const t = inst.types[idx];
    return .{ .p = @intCast(t.params.len), .r = @intCast(t.results.len) };
}

fn compile(inst: *Inst, f: *Func) Err!void {
    label_pc = 0;
    var code: std.ArrayList(Ins) = .empty;
    var ctl: std.ArrayList(Ctl) = .empty;
    defer ctl.deinit(A);
    var s = Reader{ .b = f.body };
    const ty = inst.types[f.type_idx];
    const nl = f.nlocals;
    var h: u32 = 0; // operand stack height

    try ctl.append(A, .{ .loop = false, .is_if = false, .start_pc = 0, .height = 0, .nparams = 0, .nresults = @intCast(ty.results.len), .patches = .empty, .br_patches = .empty, .else_ins = null, .unreachable_ = false });

    while (ctl.items.len > 0) {
        const pc_here: u32 = @intCast(code.items.len);
        const op = try s.byte();
        const top = &ctl.items[ctl.items.len - 1];
        const dead = top.unreachable_;
        if (op >= 0x02 and op <= 0x05 or op == 0x0B) label_pc = pc_here;

        switch (op) {
            0x02, 0x03, 0x04 => {
                const bt = try blockType(inst, &s);
                if (op == 0x04 and !dead) h -= 1; // condition
                var c = Ctl{ .loop = op == 0x03, .is_if = op == 0x04, .start_pc = pc_here, .height = if (dead) 0 else h - bt.p, .nparams = bt.p, .nresults = bt.r, .patches = .empty, .br_patches = .empty, .else_ins = null, .unreachable_ = dead, .born_dead = dead };
                if (op == 0x04 and !dead) {
                    c.else_ins = pc_here;
                    try code.append(A, .{ .op = 0x04 });
                }
                try ctl.append(A, c);
            },
            0x05 => { // else
                if (!top.is_if) return error.Invalid;
                if (!top.born_dead) {
                    if (!top.unreachable_) {
                        // end of the then-arm: jump over the else-arm
                        try top.patches.append(A, @intCast(code.items.len));
                        try code.append(A, .{ .op = OP_JMP });
                    }
                    if (top.else_ins) |ei| code.items[ei].a = @intCast(code.items.len);
                    label_pc = @intCast(code.items.len);
                    top.else_ins = null;
                    top.unreachable_ = false;
                    h = top.height + top.nparams;
                }
            },
            0x0B => { // end
                var c = ctl.pop().?;
                const end_pc: u32 = @intCast(code.items.len);
                if (c.else_ins) |ei| code.items[ei].a = end_pc; // `if` without else
                for (c.patches.items) |pi| code.items[pi].a = end_pc;
                for (c.br_patches.items) |bi| inst.brtables.items[bi].pc = end_pc;
                label_pc = end_pc;
                c.patches.deinit(A);
                c.br_patches.deinit(A);
                h = c.height + c.nresults;
                if (ctl.items.len == 0) {
                    try code.append(A, .{ .op = 0x0F, .b = c.nresults }); // implicit return
                }
            },
            else => {
                if (dead) {
                    try skipImmediates(op, &s);
                    continue;
                }
                try compileOp(inst, &code, &ctl, &s, op, &h, nl);
            },
        }
    }
    f.code = code.items;
}

fn skipImmediates(op: u8, s: *Reader) Err!void {
    switch (op) {
        0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0xD2 => _ = try s.u32_(),
        0x0E => {
            const n = try s.u32_();
            for (0..n + 1) |_| _ = try s.u32_();
        },
        0x11 => {
            _ = try s.u32_();
            _ = try s.u32_();
        },
        0x1C => {
            const n = try s.u32_();
            for (0..n) |_| _ = try s.byte();
        },
        0x28...0x3E => {
            _ = try s.u32_();
            _ = try s.u32_();
        },
        0x3F, 0x40, 0xD0 => _ = try s.byte(),
        0x41 => _ = try s.sleb(32),
        0x42 => _ = try s.sleb(64),
        0x43 => _ = try s.bytes(4),
        0x44 => _ = try s.bytes(8),
        0xFC => {
            const sub = try s.u32_();
            switch (sub) {
                0...7 => {},
                8, 12, 14 => {
                    _ = try s.u32_();
                    _ = try s.u32_();
                },
                9, 10, 11, 13, 15, 16, 17 => {
                    _ = try s.u32_();
                    if (sub == 10) _ = try s.u32_();
                },
                else => return error.Unsupported,
            }
        },
        else => {},
    }
}

fn compileOp(inst: *Inst, code: *std.ArrayList(Ins), ctl: *std.ArrayList(Ctl), s: *Reader, op: u8, hp: *u32, nl: u32) Err!void {
    var h = hp.*;
    defer hp.* = h;
    const top = &ctl.items[ctl.items.len - 1];
    switch (op) {
        0x00 => {
            try code.append(A, .{ .op = 0x00 });
            top.unreachable_ = true;
        },
        0x01 => {},
        0x0C, 0x0D => {
            const d = try s.u32_();
            if (op == 0x0D) h -= 1;
            const t = try branchInfo(ctl.items, d);
            const target = &ctl.items[ctl.items.len - 1 - d];
            var fop: u16 = op;
            var fv: u64 = 0;
            const n: u32 = @intCast(code.items.len);
            if (op == 0x0D and n >= 1 and label_pc < n) {
                const last = code.items[n - 1];
                if (last.op >= OP_LK and last.op <= OP_LK + (0x4F - 0x46)) {
                    fop = OP_BRLK + (last.op - OP_LK);
                    fv = last.v;
                    _ = code.pop();
                } else if (last.op >= OP_SK and last.op <= OP_SK + (0x4F - 0x46)) {
                    fop = OP_BRSK + (last.op - OP_SK);
                    fv = last.v;
                    _ = code.pop();
                } else if (last.op == 0x20) {
                    fop = OP_BRL;
                    fv = @as(u64, last.a) << 32;
                    _ = code.pop();
                } else if (last.op == 0x45 and n >= 2 and label_pc < n - 1 and code.items[n - 2].op == 0x20) {
                    fop = OP_BRLZ;
                    fv = @as(u64, code.items[n - 2].a) << 32;
                    _ = code.pop();
                    _ = code.pop();
                }
            }
            const idx: u32 = @intCast(code.items.len);
            try code.append(A, .{ .op = fop, .a = if (target.loop) target.start_pc else 0, .b = t.keep, .c = nl + t.h, .v = fv });
            if (!target.loop) try target.patches.append(A, idx);
            if (op == 0x0C) top.unreachable_ = true;
        },
        0x0E => {
            const n = try s.u32_();
            h -= 1;
            const first: u32 = @intCast(inst.brtables.items.len);
            for (0..n + 1) |_| {
                const d = try s.u32_();
                const t = try branchInfo(ctl.items, d);
                const target = &ctl.items[ctl.items.len - 1 - d];
                const bi: u32 = @intCast(inst.brtables.items.len);
                try inst.brtables.append(A, .{ .pc = if (target.loop) target.start_pc else 0, .keep = t.keep, .h = nl + t.h });
                if (!target.loop) try target.br_patches.append(A, bi);
            }
            try code.append(A, .{ .op = 0x0E, .a = first, .b = n });
            top.unreachable_ = true;
        },
        0x0F => {
            try code.append(A, .{ .op = 0x0F, .b = ctl.items[0].nresults });
            top.unreachable_ = true;
        },
        0x10 => {
            const fi = try s.u32_();
            if (fi >= inst.funcs.items.len) return error.Invalid;
            const t = inst.types[inst.funcs.items[fi].type_idx];
            h = h - @as(u32, @intCast(t.params.len)) + @as(u32, @intCast(t.results.len));
            try code.append(A, .{ .op = 0x10, .a = fi });
        },
        0x11 => {
            const ti = try s.u32_();
            _ = try s.u32_(); // table (only one)
            if (ti >= inst.types.len) return error.Invalid;
            const t = inst.types[ti];
            h = h - 1 - @as(u32, @intCast(t.params.len)) + @as(u32, @intCast(t.results.len));
            try code.append(A, .{ .op = 0x11, .a = ti });
        },
        0x1A => {
            h -= 1;
            try code.append(A, .{ .op = 0x1A });
        },
        0x1B, 0x1C => {
            if (op == 0x1C) {
                const n = try s.u32_();
                for (0..n) |_| _ = try s.byte();
            }
            h -= 2;
            try code.append(A, .{ .op = 0x1B });
        },
        0x20, 0x21, 0x22 => {
            const li = try s.u32_();
            if (li >= nl) return error.Invalid;
            if (op == 0x20) h += 1;
            if (op == 0x21) h -= 1;
            try code.append(A, .{ .op = op, .a = li });
        },
        0x23, 0x24 => {
            const gi = try s.u32_();
            if (gi >= inst.globals.items.len) return error.Invalid;
            if (op == 0x23) h += 1 else h -= 1;
            try code.append(A, .{ .op = op, .a = gi });
        },
        0x25 => {
            _ = try s.u32_();
            try code.append(A, .{ .op = 0x25 });
        },
        0x26 => {
            _ = try s.u32_();
            h -= 2;
            try code.append(A, .{ .op = 0x26 });
        },
        0x28...0x35 => {
            _ = try s.u32_();
            const off = try s.u32_();
            try code.append(A, .{ .op = op, .a = off });
        },
        0x36...0x3E => {
            _ = try s.u32_();
            const off = try s.u32_();
            h -= 2;
            try code.append(A, .{ .op = op, .a = off });
        },
        0x3F => {
            _ = try s.byte();
            h += 1;
            try code.append(A, .{ .op = 0x3F });
        },
        0x40 => {
            _ = try s.byte();
            try code.append(A, .{ .op = 0x40 });
        },
        0x41 => {
            h += 1;
            try code.append(A, .{ .op = 0x41, .v = @as(u32, @truncate(@as(u64, @bitCast(try s.sleb(32))))) });
        },
        0x42 => {
            h += 1;
            try code.append(A, .{ .op = 0x42, .v = @bitCast(try s.sleb(64)) });
        },
        0x43 => {
            h += 1;
            try code.append(A, .{ .op = 0x41, .v = std.mem.readInt(u32, (try s.bytes(4))[0..4], .little) });
        },
        0x44 => {
            h += 1;
            try code.append(A, .{ .op = 0x42, .v = std.mem.readInt(u64, (try s.bytes(8))[0..8], .little) });
        },
        // comparisons and binary ops pop two, push one
        0x46...0x4F, 0x51...0x66, 0x6A...0x78, 0x7C...0x8A, 0x92...0x98, 0xA0...0xA6 => {
            h -= 1;
            const n: u32 = @intCast(code.items.len);
            const i32op = (op >= 0x46 and op <= 0x4F) or (op >= 0x6A and op <= 0x78);
            if (i32op and n >= 2 and label_pc < n - 1 and code.items[n - 2].op == 0x20 and code.items[n - 1].op == 0x41) {
                const v = (code.items[n - 1].v & 0xffffffff) | (@as(u64, code.items[n - 2].a) << 32);
                _ = code.pop();
                _ = code.pop();
                try code.append(A, .{ .op = OP_LK + (op - 0x46), .v = v });
            } else if (i32op and n >= 1 and label_pc < n and code.items[n - 1].op == 0x41) {
                const v = code.items[n - 1].v & 0xffffffff;
                _ = code.pop();
                try code.append(A, .{ .op = OP_SK + (op - 0x46), .v = v });
            } else {
                try code.append(A, .{ .op = op });
            }
        },
        // tests, unary ops and conversions keep the height
        0x45, 0x50, 0x67...0x69, 0x79...0x7B, 0x8B...0x91, 0x99...0x9F, 0xA7...0xC4 => try code.append(A, .{ .op = op }),
        0xD0 => {
            _ = try s.byte();
            h += 1;
            try code.append(A, .{ .op = 0x42, .v = 0 });
        },
        0xD1 => try code.append(A, .{ .op = 0x45 }), // ref.is_null == eqz on our encoding
        0xD2 => {
            const fi = try s.u32_();
            h += 1;
            try code.append(A, .{ .op = 0x42, .v = fi + 1 });
        },
        0xFC => {
            const sub = try s.u32_();
            switch (sub) {
                0...7 => try code.append(A, .{ .op = OP_FC + @as(u16, @intCast(sub)) }),
                10 => {
                    _ = try s.u32_();
                    _ = try s.u32_();
                    h -= 3;
                    try code.append(A, .{ .op = OP_FC + 10 });
                },
                11 => {
                    _ = try s.u32_();
                    h -= 3;
                    try code.append(A, .{ .op = OP_FC + 11 });
                },
                else => return error.Unsupported,
            }
        },
        else => return error.Unsupported,
    }
}

// ---------------------------------------------------------------------------
// Execution

fn call(inst: *Inst, fi: u32, args: []const u64) Err!u64 {
    const base = inst.sp;
    for (args, 0..) |a, k| inst.stack[base + k] = a;
    inst.sp = base + @as(u32, @intCast(args.len));
    try exec(inst, fi);
    const t = inst.types[inst.funcs.items[fi].type_idx];
    const r = if (t.results.len > 0) inst.stack[base] else 0;
    inst.sp = base;
    return r;
}

inline fn f32v(x: u64) f32 {
    return @bitCast(@as(u32, @truncate(x)));
}
inline fn f64v(x: u64) f64 {
    return @bitCast(x);
}
inline fn uf32(x: f32) u64 {
    return @as(u32, @bitCast(x));
}
inline fn uf64(x: f64) u64 {
    return @bitCast(x);
}
inline fn u32v(x: u64) u32 {
    return @truncate(x);
}
inline fn i32v(x: u64) i32 {
    return @bitCast(@as(u32, @truncate(x)));
}
inline fn ui32(x: i32) u64 {
    return @as(u32, @bitCast(x));
}
inline fn b2u(x: bool) u64 {
    return @intFromBool(x);
}

fn fmin(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0 and b == 0) return if (std.math.signbit(a)) a else b;
    return @min(a, b);
}
fn fmax(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0 and b == 0) return if (std.math.signbit(a)) b else a;
    return @max(a, b);
}
fn nearest(comptime T: type, x: T) T {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) return 2.0 * @round(x / 2.0); // ties to even
    return r;
}
fn trunc(comptime I: type, comptime F: type, x: F) Err!I {
    if (std.math.isNan(x)) return error.Trap;
    const t = @trunc(x);
    const info = @typeInfo(I).int;
    const hi: F = std.math.ldexp(@as(F, 1.0), if (info.signedness == .signed) info.bits - 1 else info.bits);
    const lo: F = if (info.signedness == .signed) -hi else 0;
    if (t < lo or t >= hi) return error.Trap;
    return @intFromFloat(t);
}
fn truncSat(comptime I: type, comptime F: type, x: F) I {
    if (std.math.isNan(x)) return 0;
    if (x <= @as(F, @floatFromInt(std.math.minInt(I)))) return std.math.minInt(I);
    if (x >= @as(F, @floatFromInt(std.math.maxInt(I)))) return std.math.maxInt(I);
    return @intFromFloat(@trunc(x));
}

const PROFILE = false; // instruction histogram for tuning (tsw_profile_dump)
var prof_ops: [0x300]u64 = @splat(0);
var prof_calls: u64 = 0;
var prof_fn: [4096]u64 = @splat(0);

export fn tsw_profile_dump() void {
    if (!PROFILE) return;
    var total: u64 = 0;
    for (prof_ops) |c| total += c;
    std.debug.print("calls {d}, instructions {d}\n", .{ prof_calls, total });
    for (0..6) |_| {
        var best: usize = 0;
        for (prof_fn, 0..) |c, i| if (c > prof_fn[best]) {
            best = i;
        };
        if (prof_fn[best] == 0) break;
        std.debug.print("  func {d}: {d}\n", .{ best, prof_fn[best] });
        prof_fn[best] = 0;
    }
    for (0..12) |_| {
        var best: usize = 0;
        for (prof_ops, 0..) |c, i| if (c > prof_ops[best]) {
            best = i;
        };
        if (prof_ops[best] == 0) break;
        std.debug.print("  op 0x{x}: {d}\n", .{ best, prof_ops[best] });
        prof_ops[best] = 0;
    }
}

inline fn bin32(op: u16, x: u32, y: u32) Err!u64 {
    const xs: i32 = @bitCast(x);
    const ys: i32 = @bitCast(y);
    const sh: u5 = @truncate(y);
    return switch (op) {
        0x46 => b2u(x == y),
        0x47 => b2u(x != y),
        0x48 => b2u(xs < ys),
        0x49 => b2u(x < y),
        0x4A => b2u(xs > ys),
        0x4B => b2u(x > y),
        0x4C => b2u(xs <= ys),
        0x4D => b2u(x <= y),
        0x4E => b2u(xs >= ys),
        0x4F => b2u(x >= y),
        0x6A => x +% y,
        0x6B => x -% y,
        0x6C => x *% y,
        0x6D => blk: {
            if (y == 0 or (xs == std.math.minInt(i32) and ys == -1)) return error.Trap;
            break :blk ui32(@divTrunc(xs, ys));
        },
        0x6E => if (y == 0) error.Trap else x / y,
        0x6F => blk: {
            if (y == 0) return error.Trap;
            if (ys == -1) break :blk 0;
            break :blk ui32(@rem(xs, ys));
        },
        0x70 => if (y == 0) error.Trap else x % y,
        0x71 => x & y,
        0x72 => x | y,
        0x73 => x ^ y,
        0x74 => x << sh,
        0x75 => ui32(xs >> sh),
        0x76 => x >> sh,
        0x77 => std.math.rotl(u32, x, sh),
        0x78 => std.math.rotr(u32, x, sh),
        else => error.Unsupported, // 0x50..0x69 never get fused
    };
}

fn exec(inst: *Inst, fi: u32) Err!void {
    if (PROFILE) prof_calls += 1;
    const f = &inst.funcs.items[fi];
    const t = inst.types[f.type_idx];
    const np: u32 = @intCast(t.params.len);
    if (f.host) |h| {
        const fp = inst.sp - np;
        const r = try h(inst, inst.stack[fp..inst.sp]);
        inst.sp = fp;
        if (t.results.len > 0) {
            inst.stack[fp] = r;
            inst.sp = fp + 1;
        }
        return;
    }
    if (inst.depth > 2000) return error.Trap;
    inst.depth += 1;
    defer inst.depth -= 1;

    const st = inst.stack;
    const fp: u32 = inst.sp - np;
    if (fp + f.nlocals + 4096 >= st.len) return error.Trap;
    @memset(st[fp + np .. fp + f.nlocals], 0);
    var sp: u32 = fp + f.nlocals;
    const code = f.code;
    var pc: u32 = 0;
    var mem = inst.mem;

    while (true) {
        const in = &code[pc];
        pc += 1;
        if (PROFILE) {
            prof_ops[in.op] += 1;
            prof_fn[@min(fi, 4095)] += 1;
        }
        switch (in.op) {
            0x00 => return error.Trap,
            0x04 => {
                sp -= 1;
                if (u32v(st[sp]) == 0) pc = in.a;
            },
            OP_JMP => pc = in.a,
            0x0C => {
                const dst = fp + in.c;
                if (in.b > 0 and dst != sp - in.b) std.mem.copyForwards(u64, st[dst .. dst + in.b], st[sp - in.b .. sp]);
                sp = dst + in.b;
                pc = in.a;
            },
            0x0D => {
                sp -= 1;
                if (u32v(st[sp]) != 0) {
                    const dst = fp + in.c;
                    if (in.b > 0 and dst != sp - in.b) std.mem.copyForwards(u64, st[dst .. dst + in.b], st[sp - in.b .. sp]);
                    sp = dst + in.b;
                    pc = in.a;
                }
            },
            0x0E => {
                sp -= 1;
                const k = @min(u32v(st[sp]), in.b);
                const e = inst.brtables.items[in.a + k];
                const dst = fp + e.h;
                if (e.keep > 0 and dst != sp - e.keep) std.mem.copyForwards(u64, st[dst .. dst + e.keep], st[sp - e.keep .. sp]);
                sp = dst + e.keep;
                pc = e.pc;
            },
            0x0F => {
                if (in.b > 0) std.mem.copyForwards(u64, st[fp .. fp + in.b], st[sp - in.b .. sp]);
                inst.sp = fp + in.b;
                return;
            },
            0x10, 0x11 => {
                var callee = in.a;
                var nres: u32 = 0;
                if (in.op == 0x11) {
                    sp -= 1;
                    const slot = u32v(st[sp]);
                    if (slot >= inst.table.items.len or inst.table.items[slot] == 0) return error.Trap;
                    callee = inst.table.items[slot] - 1;
                    const want = inst.types[in.a];
                    const got = &inst.funcs.items[callee];
                    if (got.host == null) {
                        const gt = inst.types[got.type_idx];
                        if (!std.mem.eql(u8, gt.params, want.params) or !std.mem.eql(u8, gt.results, want.results)) return error.Trap;
                    }
                    nres = @intCast(want.results.len);
                    // host callbacks take their arity from the caller's type
                    if (got.host) |h| {
                        const n: u32 = @intCast(want.params.len);
                        const r = try h(inst, st[sp - n .. sp]);
                        sp -= n;
                        if (nres > 0) {
                            st[sp] = r;
                            sp += 1;
                        }
                        mem = inst.mem;
                        continue;
                    }
                }
                inst.sp = sp;
                try exec(inst, callee);
                sp = inst.sp;
                mem = inst.mem;
            },
            0x1A => sp -= 1,
            0x1B => {
                sp -= 2;
                if (u32v(st[sp + 1]) == 0) st[sp - 1] = st[sp];
            },
            0x20 => {
                st[sp] = st[fp + in.a];
                sp += 1;
            },
            0x21 => {
                sp -= 1;
                st[fp + in.a] = st[sp];
            },
            0x22 => st[fp + in.a] = st[sp - 1],
            0x23 => {
                st[sp] = inst.globals.items[in.a].v;
                sp += 1;
            },
            0x24 => {
                sp -= 1;
                inst.globals.items[in.a].v = st[sp];
            },
            0x25 => {
                const k = u32v(st[sp - 1]);
                if (k >= inst.table.items.len) return error.Trap;
                st[sp - 1] = inst.table.items[k];
            },
            0x26 => {
                sp -= 2;
                const k = u32v(st[sp]);
                if (k >= inst.table.items.len) return error.Trap;
                inst.table.items[k] = u32v(st[sp + 1]);
            },
            0x28...0x35 => {
                const addr = @as(u64, u32v(st[sp - 1])) + in.a;
                const n: u64 = switch (in.op) {
                    0x28, 0x2A, 0x34, 0x35 => 4,
                    0x29, 0x2B => 8,
                    0x2C, 0x2D, 0x30, 0x31 => 1,
                    0x2E, 0x2F, 0x32, 0x33 => 2,
                    else => unreachable,
                };
                if (addr + n > mem.len) return error.Trap;
                const p = mem[@intCast(addr)..];
                st[sp - 1] = switch (in.op) {
                    0x28, 0x2A => std.mem.readInt(u32, p[0..4], .little),
                    0x29, 0x2B => std.mem.readInt(u64, p[0..8], .little),
                    0x2C => ui32(@as(i8, @bitCast(p[0]))),
                    0x2D => p[0],
                    0x2E => ui32(@as(i16, @bitCast(std.mem.readInt(u16, p[0..2], .little)))),
                    0x2F => std.mem.readInt(u16, p[0..2], .little),
                    0x30 => @bitCast(@as(i64, @as(i8, @bitCast(p[0])))),
                    0x31 => p[0],
                    0x32 => @bitCast(@as(i64, @as(i16, @bitCast(std.mem.readInt(u16, p[0..2], .little))))),
                    0x33 => std.mem.readInt(u16, p[0..2], .little),
                    0x34 => @bitCast(@as(i64, @as(i32, @bitCast(std.mem.readInt(u32, p[0..4], .little))))),
                    0x35 => std.mem.readInt(u32, p[0..4], .little),
                    else => unreachable,
                };
            },
            0x36...0x3E => {
                sp -= 2;
                const addr = @as(u64, u32v(st[sp])) + in.a;
                const v = st[sp + 1];
                const n: u64 = switch (in.op) {
                    0x36, 0x38, 0x3E => 4,
                    0x37, 0x39 => 8,
                    0x3A, 0x3C => 1,
                    0x3B, 0x3D => 2,
                    else => unreachable,
                };
                if (addr + n > mem.len) return error.Trap;
                const p = mem[@intCast(addr)..];
                switch (n) {
                    1 => p[0] = @truncate(v),
                    2 => std.mem.writeInt(u16, p[0..2], @truncate(v), .little),
                    4 => std.mem.writeInt(u32, p[0..4], @truncate(v), .little),
                    else => std.mem.writeInt(u64, p[0..8], v, .little),
                }
            },
            0x3F => {
                st[sp] = mem.len / PAGE;
                sp += 1;
            },
            0x40 => {
                const n = u32v(st[sp - 1]);
                const old: u32 = @intCast(inst.mem.len / PAGE);
                st[sp - 1] = if (growPages(inst, n)) old else 0xffffffff;
                mem = inst.mem;
            },
            0x41, 0x42 => {
                st[sp] = in.v;
                sp += 1;
            },

            // i32
            0x45 => st[sp - 1] = b2u(u32v(st[sp - 1]) == 0),
            0x46...0x4F => {
                sp -= 1;
                const x = u32v(st[sp - 1]);
                const y = u32v(st[sp]);
                const xs: i32 = @bitCast(x);
                const ys: i32 = @bitCast(y);
                st[sp - 1] = b2u(switch (in.op) {
                    0x46 => x == y,
                    0x47 => x != y,
                    0x48 => xs < ys,
                    0x49 => x < y,
                    0x4A => xs > ys,
                    0x4B => x > y,
                    0x4C => xs <= ys,
                    0x4D => x <= y,
                    0x4E => xs >= ys,
                    else => x >= y,
                });
            },
            0x50 => st[sp - 1] = b2u(st[sp - 1] == 0),
            0x51...0x5A => {
                sp -= 1;
                const x = st[sp - 1];
                const y = st[sp];
                const xs: i64 = @bitCast(x);
                const ys: i64 = @bitCast(y);
                st[sp - 1] = b2u(switch (in.op) {
                    0x51 => x == y,
                    0x52 => x != y,
                    0x53 => xs < ys,
                    0x54 => x < y,
                    0x55 => xs > ys,
                    0x56 => x > y,
                    0x57 => xs <= ys,
                    0x58 => x <= y,
                    0x59 => xs >= ys,
                    else => x >= y,
                });
            },
            0x5B...0x60 => {
                sp -= 1;
                const x = f32v(st[sp - 1]);
                const y = f32v(st[sp]);
                st[sp - 1] = b2u(switch (in.op) {
                    0x5B => x == y,
                    0x5C => x != y,
                    0x5D => x < y,
                    0x5E => x > y,
                    0x5F => x <= y,
                    else => x >= y,
                });
            },
            0x61...0x66 => {
                sp -= 1;
                const x = f64v(st[sp - 1]);
                const y = f64v(st[sp]);
                st[sp - 1] = b2u(switch (in.op) {
                    0x61 => x == y,
                    0x62 => x != y,
                    0x63 => x < y,
                    0x64 => x > y,
                    0x65 => x <= y,
                    else => x >= y,
                });
            },
            0x67 => st[sp - 1] = @clz(u32v(st[sp - 1])),
            0x68 => st[sp - 1] = @ctz(u32v(st[sp - 1])),
            0x69 => st[sp - 1] = @popCount(u32v(st[sp - 1])),
            0x6A...0x78 => {
                sp -= 1;
                const x = u32v(st[sp - 1]);
                const y = u32v(st[sp]);
                const xs: i32 = @bitCast(x);
                const ys: i32 = @bitCast(y);
                const sh: u5 = @truncate(y);
                st[sp - 1] = switch (in.op) {
                    0x6A => x +% y,
                    0x6B => x -% y,
                    0x6C => x *% y,
                    0x6D => blk: {
                        if (y == 0 or (xs == std.math.minInt(i32) and ys == -1)) return error.Trap;
                        break :blk ui32(@divTrunc(xs, ys));
                    },
                    0x6E => blk: {
                        if (y == 0) return error.Trap;
                        break :blk x / y;
                    },
                    0x6F => blk: {
                        if (y == 0) return error.Trap;
                        if (ys == -1) break :blk 0;
                        break :blk ui32(@rem(xs, ys));
                    },
                    0x70 => blk: {
                        if (y == 0) return error.Trap;
                        break :blk x % y;
                    },
                    0x71 => x & y,
                    0x72 => x | y,
                    0x73 => x ^ y,
                    0x74 => x << sh,
                    0x75 => ui32(xs >> sh),
                    0x76 => x >> sh,
                    0x77 => std.math.rotl(u32, x, sh),
                    else => std.math.rotr(u32, x, sh),
                };
            },
            0x79 => st[sp - 1] = @clz(st[sp - 1]),
            0x7A => st[sp - 1] = @ctz(st[sp - 1]),
            0x7B => st[sp - 1] = @popCount(st[sp - 1]),
            0x7C...0x8A => {
                sp -= 1;
                const x = st[sp - 1];
                const y = st[sp];
                const xs: i64 = @bitCast(x);
                const ys: i64 = @bitCast(y);
                const sh: u6 = @truncate(y);
                st[sp - 1] = switch (in.op) {
                    0x7C => x +% y,
                    0x7D => x -% y,
                    0x7E => x *% y,
                    0x7F => blk: {
                        if (y == 0 or (xs == std.math.minInt(i64) and ys == -1)) return error.Trap;
                        break :blk @bitCast(@divTrunc(xs, ys));
                    },
                    0x80 => blk: {
                        if (y == 0) return error.Trap;
                        break :blk x / y;
                    },
                    0x81 => blk: {
                        if (y == 0) return error.Trap;
                        if (ys == -1) break :blk 0;
                        break :blk @bitCast(@rem(xs, ys));
                    },
                    0x82 => blk: {
                        if (y == 0) return error.Trap;
                        break :blk x % y;
                    },
                    0x83 => x & y,
                    0x84 => x | y,
                    0x85 => x ^ y,
                    0x86 => x << sh,
                    0x87 => @bitCast(xs >> sh),
                    0x88 => x >> sh,
                    0x89 => std.math.rotl(u64, x, sh),
                    else => std.math.rotr(u64, x, sh),
                };
            },
            0x8B...0x91 => {
                const x = f32v(st[sp - 1]);
                st[sp - 1] = uf32(switch (in.op) {
                    0x8B => @abs(x),
                    0x8C => -x,
                    0x8D => @ceil(x),
                    0x8E => @floor(x),
                    0x8F => @trunc(x),
                    0x90 => nearest(f32, x),
                    else => @sqrt(x),
                });
            },
            0x92...0x98 => {
                sp -= 1;
                const x = f32v(st[sp - 1]);
                const y = f32v(st[sp]);
                st[sp - 1] = uf32(switch (in.op) {
                    0x92 => x + y,
                    0x93 => x - y,
                    0x94 => x * y,
                    0x95 => x / y,
                    0x96 => fmin(f32, x, y),
                    0x97 => fmax(f32, x, y),
                    else => std.math.copysign(x, y),
                });
            },
            0x99...0x9F => {
                const x = f64v(st[sp - 1]);
                st[sp - 1] = uf64(switch (in.op) {
                    0x99 => @abs(x),
                    0x9A => -x,
                    0x9B => @ceil(x),
                    0x9C => @floor(x),
                    0x9D => @trunc(x),
                    0x9E => nearest(f64, x),
                    else => @sqrt(x),
                });
            },
            0xA0...0xA6 => {
                sp -= 1;
                const x = f64v(st[sp - 1]);
                const y = f64v(st[sp]);
                st[sp - 1] = uf64(switch (in.op) {
                    0xA0 => x + y,
                    0xA1 => x - y,
                    0xA2 => x * y,
                    0xA3 => x / y,
                    0xA4 => fmin(f64, x, y),
                    0xA5 => fmax(f64, x, y),
                    else => std.math.copysign(x, y),
                });
            },
            0xA7 => st[sp - 1] = u32v(st[sp - 1]), // i32.wrap_i64
            0xA8 => st[sp - 1] = ui32(try trunc(i32, f32, f32v(st[sp - 1]))),
            0xA9 => st[sp - 1] = try trunc(u32, f32, f32v(st[sp - 1])),
            0xAA => st[sp - 1] = ui32(try trunc(i32, f64, f64v(st[sp - 1]))),
            0xAB => st[sp - 1] = try trunc(u32, f64, f64v(st[sp - 1])),
            0xAC => st[sp - 1] = @bitCast(@as(i64, i32v(st[sp - 1]))),
            0xAD => st[sp - 1] = u32v(st[sp - 1]),
            0xAE => st[sp - 1] = @bitCast(try trunc(i64, f32, f32v(st[sp - 1]))),
            0xAF => st[sp - 1] = try trunc(u64, f32, f32v(st[sp - 1])),
            0xB0 => st[sp - 1] = @bitCast(try trunc(i64, f64, f64v(st[sp - 1]))),
            0xB1 => st[sp - 1] = try trunc(u64, f64, f64v(st[sp - 1])),
            0xB2 => st[sp - 1] = uf32(@floatFromInt(i32v(st[sp - 1]))),
            0xB3 => st[sp - 1] = uf32(@floatFromInt(u32v(st[sp - 1]))),
            0xB4 => st[sp - 1] = uf32(@floatFromInt(@as(i64, @bitCast(st[sp - 1])))),
            0xB5 => st[sp - 1] = uf32(@floatFromInt(st[sp - 1])),
            0xB6 => st[sp - 1] = uf32(@floatCast(f64v(st[sp - 1]))),
            0xB7 => st[sp - 1] = uf64(@floatFromInt(i32v(st[sp - 1]))),
            0xB8 => st[sp - 1] = uf64(@floatFromInt(u32v(st[sp - 1]))),
            0xB9 => st[sp - 1] = uf64(@floatFromInt(@as(i64, @bitCast(st[sp - 1])))),
            0xBA => st[sp - 1] = uf64(@floatFromInt(st[sp - 1])),
            0xBB => st[sp - 1] = uf64(@floatCast(f32v(st[sp - 1]))),
            0xBC, 0xBE => st[sp - 1] = u32v(st[sp - 1]), // reinterpret (bits already stored)
            0xBD, 0xBF => {},
            0xC0 => st[sp - 1] = ui32(@as(i8, @truncate(i32v(st[sp - 1])))),
            0xC1 => st[sp - 1] = ui32(@as(i16, @truncate(i32v(st[sp - 1])))),
            0xC2 => st[sp - 1] = @bitCast(@as(i64, @as(i8, @truncate(@as(i64, @bitCast(st[sp - 1])))))),
            0xC3 => st[sp - 1] = @bitCast(@as(i64, @as(i16, @truncate(@as(i64, @bitCast(st[sp - 1])))))),
            0xC4 => st[sp - 1] = @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(st[sp - 1])))))),
            OP_FC + 0 => st[sp - 1] = ui32(truncSat(i32, f32, f32v(st[sp - 1]))),
            OP_FC + 1 => st[sp - 1] = truncSat(u32, f32, f32v(st[sp - 1])),
            OP_FC + 2 => st[sp - 1] = ui32(truncSat(i32, f64, f64v(st[sp - 1]))),
            OP_FC + 3 => st[sp - 1] = truncSat(u32, f64, f64v(st[sp - 1])),
            OP_FC + 4 => st[sp - 1] = @bitCast(truncSat(i64, f32, f32v(st[sp - 1]))),
            OP_FC + 5 => st[sp - 1] = truncSat(u64, f32, f32v(st[sp - 1])),
            OP_FC + 6 => st[sp - 1] = @bitCast(truncSat(i64, f64, f64v(st[sp - 1]))),
            OP_FC + 7 => st[sp - 1] = truncSat(u64, f64, f64v(st[sp - 1])),
            OP_FC + 10 => { // memory.copy dst src n
                sp -= 3;
                const d = u32v(st[sp]);
                const sr = u32v(st[sp + 1]);
                const n = u32v(st[sp + 2]);
                if (@as(u64, d) + n > mem.len or @as(u64, sr) + n > mem.len) return error.Trap;
                std.mem.copyForwards(u8, mem[d .. d + n], mem[sr .. sr + n]); // overlapping-safe below
                if (d > sr and d < sr + n) std.mem.copyBackwards(u8, mem[d .. d + n], mem[sr .. sr + n]);
            },
            OP_FC + 11 => { // memory.fill dst val n
                sp -= 3;
                const d = u32v(st[sp]);
                const n = u32v(st[sp + 2]);
                if (@as(u64, d) + n > mem.len) return error.Trap;
                @memset(mem[d .. d + n], @truncate(st[sp + 1]));
            },
            OP_LK...OP_LK + (0x78 - 0x46) => {
                const x = u32v(st[fp + @as(u32, @truncate(in.v >> 32))]);
                st[sp] = try bin32(in.op - OP_LK + 0x46, x, @truncate(in.v));
                sp += 1;
            },
            OP_SK...OP_SK + (0x78 - 0x46) => st[sp - 1] = try bin32(in.op - OP_SK + 0x46, u32v(st[sp - 1]), @truncate(in.v)),
            OP_BRSK...OP_BRSK + (0x4F - 0x46) => {
                sp -= 1;
                if ((try bin32(in.op - OP_BRSK + 0x46, u32v(st[sp]), @truncate(in.v))) != 0) {
                    const dst = fp + in.c;
                    if (in.b > 0 and dst != sp - in.b) std.mem.copyForwards(u64, st[dst .. dst + in.b], st[sp - in.b .. sp]);
                    sp = dst + in.b;
                    pc = in.a;
                }
            },
            OP_BRLK...OP_BRLK + (0x4F - 0x46), OP_BRL, OP_BRLZ => {
                const x = u32v(st[fp + @as(u32, @truncate(in.v >> 32))]);
                const take = switch (in.op) {
                    OP_BRL => x != 0,
                    OP_BRLZ => x == 0,
                    else => (try bin32(in.op - OP_BRLK + 0x46, x, @truncate(in.v))) != 0,
                };
                if (take) {
                    const dst = fp + in.c;
                    if (in.b > 0 and dst != sp - in.b) std.mem.copyForwards(u64, st[dst .. dst + in.b], st[sp - in.b .. sp]);
                    sp = dst + in.b;
                    pc = in.a;
                }
            },
            else => return error.Unsupported,
        }
    }
}

fn growPages(inst: *Inst, n: u32) bool {
    const old = inst.mem.len / PAGE;
    if (old + n > inst.max_pages) return false;
    const nm = A.realloc(inst.mem, (old + n) * PAGE) catch return false;
    @memset(nm[old * PAGE ..], 0);
    inst.mem = nm;
    return true;
}

// ---------------------------------------------------------------------------
// Host functions: a tiny libc on top of linear memory

fn need(inst: *Inst, addr: u64, n: u64) Err!void {
    if (addr + n > inst.mem.len) return error.Trap;
}

fn hMalloc(inst: *Inst, args: []u64) Err!u64 {
    return alloc(inst, u32v(args[0]));
}

fn alloc(inst: *Inst, n: u32) Err!u64 {
    // bump allocator with a size header; the heap is reset before every parse
    const p = alignUp(inst.heap_ptr + 8, 16);
    const end = @as(u64, p) + n;
    while (end > inst.mem.len) {
        if (!growPages(inst, @intCast(@max(16, (end - inst.mem.len + PAGE - 1) / PAGE)))) return 0;
    }
    std.mem.writeInt(u32, inst.mem[p - 4 ..][0..4], n, .little);
    inst.heap_ptr = @intCast(end);
    return p;
}

fn hCalloc(inst: *Inst, args: []u64) Err!u64 {
    const n = @as(u64, u32v(args[0])) * u32v(args[1]);
    if (n > 0xffffffff) return 0;
    const p = try alloc(inst, @intCast(n));
    if (p != 0) @memset(inst.mem[@intCast(p)..][0..@intCast(n)], 0);
    return p;
}

fn hRealloc(inst: *Inst, args: []u64) Err!u64 {
    const old = u32v(args[0]);
    const n = u32v(args[1]);
    const p = try alloc(inst, n);
    if (old != 0 and p != 0) {
        try need(inst, old - 4, 4);
        const osz = std.mem.readInt(u32, inst.mem[old - 4 ..][0..4], .little);
        const c = @min(osz, n);
        try need(inst, old, c);
        std.mem.copyForwards(u8, inst.mem[@intCast(p)..][0..c], inst.mem[old..][0..c]);
    }
    return p;
}

fn hFree(_: *Inst, _: []u64) Err!u64 {
    return 0;
}

fn hMemcpy(inst: *Inst, args: []u64) Err!u64 {
    const d = u32v(args[0]);
    const s = u32v(args[1]);
    const n = u32v(args[2]);
    try need(inst, d, n);
    try need(inst, s, n);
    if (d < s) std.mem.copyForwards(u8, inst.mem[d..][0..n], inst.mem[s..][0..n]) else std.mem.copyBackwards(u8, inst.mem[d..][0..n], inst.mem[s..][0..n]);
    return d;
}

fn hMemset(inst: *Inst, args: []u64) Err!u64 {
    const d = u32v(args[0]);
    const n = u32v(args[2]);
    try need(inst, d, n);
    @memset(inst.mem[d..][0..n], @truncate(args[1]));
    return d;
}

fn hMemcmp(inst: *Inst, args: []u64) Err!u64 {
    const a = u32v(args[0]);
    const b = u32v(args[1]);
    const n = u32v(args[2]);
    try need(inst, a, n);
    try need(inst, b, n);
    return switch (std.mem.order(u8, inst.mem[a..][0..n], inst.mem[b..][0..n])) {
        .lt => ui32(-1),
        .eq => 0,
        .gt => 1,
    };
}

fn hMemchr(inst: *Inst, args: []u64) Err!u64 {
    const a = u32v(args[0]);
    const n = u32v(args[2]);
    try need(inst, a, n);
    const i = std.mem.indexOfScalar(u8, inst.mem[a..][0..n], @truncate(args[1])) orelse return 0;
    return a + @as(u32, @intCast(i));
}

fn cstrLen(inst: *Inst, a: u32) Err!u32 {
    if (a >= inst.mem.len) return error.Trap;
    const i = std.mem.indexOfScalar(u8, inst.mem[a..], 0) orelse return error.Trap;
    return @intCast(i);
}

fn hStrlen(inst: *Inst, args: []u64) Err!u64 {
    return @as(u64, try cstrLen(inst, u32v(args[0])));
}

fn hStrcmp(inst: *Inst, args: []u64) Err!u64 {
    const a = u32v(args[0]);
    const b = u32v(args[1]);
    const la = try cstrLen(inst, a);
    const lb = try cstrLen(inst, b);
    return switch (std.mem.order(u8, inst.mem[a..][0..la], inst.mem[b..][0..lb])) {
        .lt => ui32(-1),
        .eq => 0,
        .gt => 1,
    };
}

fn hStrncmp(inst: *Inst, args: []u64) Err!u64 {
    const a = u32v(args[0]);
    const b = u32v(args[1]);
    const n = u32v(args[2]);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try need(inst, a + i, 1);
        try need(inst, b + i, 1);
        const x = inst.mem[a + i];
        const y = inst.mem[b + i];
        if (x != y) return if (x < y) ui32(-1) else 1;
        if (x == 0) break;
    }
    return 0;
}

fn hStrncpy(inst: *Inst, args: []u64) Err!u64 {
    const d = u32v(args[0]);
    const s = u32v(args[1]);
    const n = u32v(args[2]);
    try need(inst, d, n);
    var i: u32 = 0;
    var ended = false;
    while (i < n) : (i += 1) {
        var c: u8 = 0;
        if (!ended) {
            try need(inst, s + i, 1);
            c = inst.mem[s + i];
            if (c == 0) ended = true;
        }
        inst.mem[d + i] = c;
    }
    return d;
}

fn isSpaceCp(c: u32) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0B, 0x0C, '\r', 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}
fn isAlphaCp(c: u32) bool {
    if (c < 0x80) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    // shortcut: every non-ASCII code point that is not a space or punctuation block counts as a letter
    return !isSpaceCp(c) and !(c >= 0x2000 and c <= 0x206F) and !(c >= 0x3000 and c <= 0x303F) and c != 0xD7 and c != 0xF7;
}
fn hIswspace(_: *Inst, args: []u64) Err!u64 {
    return b2u(isSpaceCp(u32v(args[0])));
}
fn hIswalpha(_: *Inst, args: []u64) Err!u64 {
    return b2u(isAlphaCp(u32v(args[0])));
}
fn hIswalnum(_: *Inst, args: []u64) Err!u64 {
    const c = u32v(args[0]);
    return b2u(isAlphaCp(c) or (c >= '0' and c <= '9'));
}
fn hIswdigit(_: *Inst, args: []u64) Err!u64 {
    const c = u32v(args[0]);
    return b2u(c >= '0' and c <= '9');
}
fn hIswxdigit(_: *Inst, args: []u64) Err!u64 {
    const c = u32v(args[0]);
    return b2u((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'));
}
fn hIswupper(_: *Inst, args: []u64) Err!u64 {
    const c = u32v(args[0]);
    return b2u((c >= 'A' and c <= 'Z') or (c >= 0xC0 and c <= 0xDE and c != 0xD7));
}
fn hIswlower(_: *Inst, args: []u64) Err!u64 {
    const c = u32v(args[0]);
    return b2u((c >= 'a' and c <= 'z') or (c >= 0xDF and c <= 0xFF and c != 0xF7));
}
fn hTowupper(_: *Inst, args: []u64) Err!u64 {
    const c = u32v(args[0]);
    return if ((c >= 'a' and c <= 'z') or (c >= 0xE0 and c <= 0xFE and c != 0xF7)) c - 32 else c;
}
fn hTowlower(_: *Inst, args: []u64) Err!u64 {
    const c = u32v(args[0]);
    return if ((c >= 'A' and c <= 'Z') or (c >= 0xC0 and c <= 0xDE and c != 0xD7)) c + 32 else c;
}
fn hTrap(_: *Inst, _: []u64) Err!u64 {
    return error.Trap;
}

fn hostFor(name: []const u8) HostFn {
    const table = .{
        .{ "malloc", hMalloc },       .{ "calloc", hCalloc },       .{ "realloc", hRealloc },
        .{ "free", hFree },           .{ "memcpy", hMemcpy },       .{ "memmove", hMemcpy },
        .{ "memset", hMemset },       .{ "memcmp", hMemcmp },       .{ "memchr", hMemchr },
        .{ "strlen", hStrlen },       .{ "strcmp", hStrcmp },       .{ "strncmp", hStrncmp },
        .{ "strncpy", hStrncpy },     .{ "iswspace", hIswspace },   .{ "iswalpha", hIswalpha },
        .{ "iswalnum", hIswalnum },   .{ "iswdigit", hIswdigit },   .{ "iswxdigit", hIswxdigit },
        .{ "iswupper", hIswupper },   .{ "iswlower", hIswlower },   .{ "towupper", hTowupper },
        .{ "towlower", hTowlower },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return hTrap; // abort, __assert_fail and anything unknown trap when called
}

// ---------------------------------------------------------------------------
// tree-sitter lexer bridge

pub const TSLexer = extern struct {
    lookahead: i32,
    result_symbol: u16,
    advance: *const fn (*TSLexer, bool) callconv(.c) void,
    mark_end: *const fn (*TSLexer) callconv(.c) void,
    get_column: *const fn (*TSLexer) callconv(.c) u32,
    is_at_included_range_start: *const fn (*const TSLexer) callconv(.c) bool,
    eof: *const fn (*const TSLexer) callconv(.c) bool,
};

fn lexAdvance(inst: *Inst, args: []u64) Err!u64 {
    const l = inst.lexer orelse return error.Trap;
    l.advance(l, u32v(args[1]) != 0);
    std.mem.writeInt(i32, inst.mem[inst.lexer_addr..][0..4], l.lookahead, .little);
    return 0;
}
fn lexMarkEnd(inst: *Inst, _: []u64) Err!u64 {
    const l = inst.lexer orelse return error.Trap;
    l.mark_end(l);
    return 0;
}
fn lexGetColumn(inst: *Inst, _: []u64) Err!u64 {
    const l = inst.lexer orelse return error.Trap;
    return l.get_column(l);
}
fn lexAtRangeStart(inst: *Inst, _: []u64) Err!u64 {
    const l = inst.lexer orelse return error.Trap;
    return b2u(l.is_at_included_range_start(l));
}
fn lexEof(inst: *Inst, _: []u64) Err!u64 {
    const l = inst.lexer orelse return error.Trap;
    return b2u(l.eof(l));
}

// ---------------------------------------------------------------------------
// C API used by ts_wasm_store.c

export fn tsw_memory(inst: *Inst) [*]u8 {
    return inst.mem.ptr;
}
export fn tsw_lexer_address(inst: *Inst) u32 {
    return inst.lexer_addr;
}
export fn tsw_serialization_address(inst: *Inst) u32 {
    return inst.ser_addr;
}
export fn tsw_start(inst: *Inst, lexer: ?*TSLexer) void {
    inst.lexer = lexer;
    inst.heap_ptr = inst.heap_start;
    inst.sp = 0;
    inst.depth = 0;
    if (lexer != null) {
        // the wasm-side TSLexer: data prefix + table slots of our callbacks
        const m = inst.mem[inst.lexer_addr..];
        for (0..5) |k| std.mem.writeInt(u32, m[8 + 4 * k ..][0..4], inst.host_slots + @as(u32, @intCast(k)), .little);
    }
}

/// Calls the function in table slot `slot`; args/result are i32. Returns false on a trap.
export fn tsw_call(inst: *Inst, slot: u32, args: [*]const u32, nargs: u32, result: *u32) bool {
    if (slot >= inst.table.items.len or inst.table.items[slot] == 0) return false;
    var a: [4]u64 = undefined;
    for (0..nargs) |k| a[k] = args[k];
    const r = call(inst, inst.table.items[slot] - 1, a[0..nargs]) catch {
        inst.sp = 0;
        inst.depth = 0;
        return false;
    };
    result.* = @truncate(r);
    return true;
}
