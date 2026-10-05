// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The linter core: the rule registry and the scan that produces findings.
//!
//! Token-based (the real Zig tokenizer, so comments/strings and identifier boundaries are
//! handled correctly — unlike a regex). Not a general linter; the compiler already does that.
//! Targets stale-knowledge and footgun mistakes.
//!
//! Split out of `zsnag.zig` so the rules are a table rather than inline `emit` calls, and so
//! callers can scan in-process instead of shelling out and re-parsing JSON.
const std = @import("std");
const zephem = @import("zephem.zig");
const Token = std.zig.Token;
const Tokenizer = std.zig.Tokenizer;

pub const Sev = enum {
    err,
    warn,
    info,

    pub fn mark(s: Sev) []const u8 {
        return switch (s) {
            .err => "x",
            .warn => "!",
            .info => ".",
        };
    }
    pub fn name(s: Sev) []const u8 {
        return switch (s) {
            .err => "error",
            .warn => "warn",
            .info => "info",
        };
    }
};

/// Which checker a rule belongs to. The hook prunes the book per group, so a group that did
/// not run cannot erase its own history — see `book.pruneFile`.
pub const Group = enum {
    /// Token-based rules; run whenever zsnag runs.
    core,
    /// Rules that need a parse tree. A file with a SYNTAX ERROR does not parse, so these are
    /// skipped — and that is exactly when an LLM's stale-syntax mistakes appear, so their
    /// silence must be reported rather than read as "nothing found".
    structural,
    /// Rules that need the zephem map; absent map means they did not run at all.
    map,

    pub fn name(g: Group) []const u8 {
        return @tagName(g);
    }
};

pub const Rule = struct {
    code: []const u8,
    sev: Sev,
    msg: []const u8,
    group: Group = .core,
    /// Short statement of what makes the rule true, for `--list-rules`.
    premise: []const u8 = "",
};

pub const Id = enum {
    r001_async,
    r002_usingnamespace,
    r003_mem_copy,
    r004_catch_unreachable,
    r005_empty_catch,
    r006_stream_zero,
    r007_cast,
    r008_acquire,
    r009_page_allocator,
    r010_debug_print,
    // Map-backed rules: their advice is derived from zephem, not from a literal here.
    r011_deprecated,
    r012_arity,
    r013_unknown_std,
    r014_positional_stdio,
    r015_big_undefined,
};

/// Every rule lives here. Adding one means adding a table entry and a `find` site — nothing
/// is a bare string literal at the call site any more, so `--list-rules`, the group-scoped
/// prune, and the zephem self-check can all enumerate them.
pub const rules = std.enums.directEnumArray(Id, Rule, 0, .{
    .r001_async = .{
        .code = "R001",
        .sev = .err,
        .msg = "async/await is no longer a keyword (old Zig). As a .method() call it's fine.",
        .premise = "async/await were removed from the language",
    },
    .r002_usingnamespace = .{
        .code = "R002",
        .sev = .err,
        .msg = "usingnamespace was removed; import/redeclare explicitly.",
        .premise = "usingnamespace was removed from the language",
    },
    .r003_mem_copy = .{
        .code = "R003",
        .sev = .err,
        .msg = "mem.copy/mem.set were removed; use @memcpy/@memset.",
        .premise = "std.mem.copy and std.mem.set are absent from std",
    },
    .r004_catch_unreachable = .{
        .code = "R004",
        .sev = .warn,
        .msg = "catch unreachable crashes in release if it ever fails; handle the error.",
    },
    .r005_empty_catch = .{
        .code = "R005",
        .sev = .warn,
        .msg = "empty catch {} silently swallows an error.",
    },
    .r006_stream_zero = .{
        .code = "R006",
        .sev = .warn,
        .msg = "Reader.stream() returning 0 is not end of stream (that is error.EndOfStream); keep looping instead of break/return. (heuristic)",
        .premise = "std documents that stream()'s count, including zero, does not indicate end of stream",
    },
    .r007_cast = .{
        .code = "R007",
        .sev = .info,
        .msg = "this cast can panic/corrupt if out of range; verify first.",
    },
    .r008_acquire = .{
        .group = .structural,
        .code = "R008",
        .sev = .warn,
        .msg = "acquired but never released (no matching deinit/close); add a defer. (heuristic)",
    },
    .r009_page_allocator = .{
        .code = "R009",
        .sev = .info,
        .msg = "page_allocator as a general allocator is slow; pass an allocator in.",
    },
    .r010_debug_print = .{
        .code = "R010",
        .sev = .info,
        .msg = "debug.print left in code? remove or use std.log.",
    },
    .r011_deprecated = .{
        .group = .map,
        .code = "R011",
        .sev = .warn,
        .msg = "this std API is deprecated.",
        .premise = "the zephem map records a deprecation on this decl (message comes from the map)",
    },
    .r012_arity = .{
        .group = .map,
        .code = "R012",
        .sev = .warn,
        .msg = "wrong number of arguments for this std call.",
        .premise = "argument count at the call site disagrees with the map's signature",
    },
    .r013_unknown_std = .{
        .group = .map,
        .code = "R013",
        .sev = .info,
        .msg = "this std path is not in the zephem map — cannot verify it exists.",
        .premise = "a fully-qualified std.* path with no entry in the map",
    },
    .r014_positional_stdio = .{
        .code = "R014",
        .sev = .warn,
        .msg = "stdout()/stderr().writer() writes at file offsets: redirected to a file, each run starts at byte 0 and `{ a; b; } > out` loses a's output. Use .writerStreaming().",
        .premise = "File.writer defaults to positional writes; writerStreaming appends",
    },
    .r015_big_undefined = .{
        .group = .structural,
        .code = "R015",
        .sev = .info,
        .msg = "large `= undefined` array on the stack (>= 64 KiB): Debug and ReleaseSafe write 0xAA over all of it on every call, and the frame costs a stack probe in every mode. Harmless in a function called once; in one called per row, node or round, size it to need or allocate it once outside the loop.",
        .premise = "safe modes fill undefined memory with 0xAA; a large frame is probed page by page",
    },
});

pub fn ruleOf(id: Id) Rule {
    return rules[@intFromEnum(id)];
}

pub const Finding = struct {
    file: []const u8,
    id: Id,
    line: u32,
    col: u32,
    /// Normally the rule's own message; a rule that derives its advice from the zephem map
    /// overrides it here.
    msg: []const u8,

    pub fn rule(f: Finding) Rule {
        return ruleOf(f.id);
    }
};

const Tk = struct { tag: Token.Tag, start: usize, end: usize };

/// What a declaration acquired, and so what releases it.
const Owns = enum {
    /// A file or directory: `close`.
    handle,
    /// Owns threads or its own memory whatever allocator backs it: `deinit`, always.
    resource,
    /// A collection: its memory comes from an allocator, and an arena frees it wholesale.
    /// Flagged only when the allocator is visibly a real heap (see `heapAllocator`).
    collection,
};

/// Type names, matched as substrings of an identifier so `AutoHashMap`,
/// `StringHashMapUnmanaged` and `MultiArrayList` count.
const RESOURCE_TYPES = [_][]const u8{ "ArenaAllocator", "DebugAllocator", "Threaded" };
const COLLECTION_TYPES = [_][]const u8{
    "ArrayList", "HashMap", "BufSet", "BufMap", "PriorityQueue", "SegmentedList",
};

fn ownerKind(name: []const u8) ?Owns {
    for (RESOURCE_TYPES) |ty| if (std.mem.find(u8, name, ty) != null) return .resource;
    for (COLLECTION_TYPES) |ty| if (std.mem.find(u8, name, ty) != null) return .collection;
    return null;
}

/// An allocator expression that is certainly NOT an arena, so memory from it leaks unless
/// freed. Measured: flagging every collection without a `deinit` hit 94 declarations across
/// Zig's std and four real projects, nearly all arena-backed and correct.
fn heapAllocator(text: []const u8) bool {
    const heaps = [_][]const u8{ "testing.allocator", "smp_allocator", "c_allocator", "page_allocator" };
    for (heaps) |h| if (std.mem.find(u8, text, h) != null) return true;
    return false;
}

/// Source text of a node.
fn nodeText(st: Scanner, tree: *const std.zig.Ast, t: []const Tk, n: std.zig.Ast.Node.Index) []const u8 {
    const first = tree.firstToken(n);
    const last = tree.lastToken(n);
    if (last >= t.len) return "";
    return st.src[t[first].start..t[last].end];
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Rule codes named in `zsnag:allow R0NN ...` comments anywhere in the source. A file that
/// deliberately trips a rule can silence it file-wide with one comment.
///
/// Grows dynamically: the old fixed 32-code cap dropped anything past it silently (ledger B4).
pub fn collectAllow(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayList([]const u8)) !void {
    const marker = "zsnag:allow";
    var i: usize = 0;
    while (i + marker.len <= src.len) : (i += 1) {
        if (!eq(src[i .. i + marker.len], marker)) continue;
        var j = i + marker.len;
        while (j < src.len and src[j] != '\n') : (j += 1) {
            if (src[j] == 'R' and j + 4 <= src.len and
                std.ascii.isDigit(src[j + 1]) and std.ascii.isDigit(src[j + 2]) and std.ascii.isDigit(src[j + 3]))
            {
                try out.append(gpa, src[j .. j + 4]);
                j += 3;
            }
        }
        i = j;
    }
}

fn lex(gpa: std.mem.Allocator, src: [:0]const u8) ![]Tk {
    var n: usize = 0;
    var tz = Tokenizer.init(src);
    while (true) {
        const t = tz.next();
        n += 1;
        if (t.tag == .eof) break;
    }
    const toks = try gpa.alloc(Tk, n);
    var tz2 = Tokenizer.init(src);
    var i: usize = 0;
    while (true) : (i += 1) {
        const t = tz2.next();
        toks[i] = .{ .tag = t.tag, .start = t.loc.start, .end = t.loc.end };
        if (t.tag == .eof) break;
    }
    return toks;
}

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    src: [:0]const u8,
    allow: []const []const u8,
    out: *std.ArrayList(Finding),
    stale: []const Id = &.{},

    fn text(s: Scanner, t: Tk) []const u8 {
        return s.src[t.start..t.end];
    }

    fn emit(s: Scanner, off: usize, id: Id) !void {
        return s.emitMsg(off, id, ruleOf(id).msg);
    }

    /// `msg` may differ from the rule's default when the advice is derived from the map.
    fn emitMsg(s: Scanner, off: usize, id: Id, msg: []const u8) !void {
        // A rule the map has contradicted emits nothing at all.
        for (s.stale) |sid| if (sid == id) return;

        const code = ruleOf(id).code;
        for (s.allow) |r| if (eq(r, code)) return;

        var line: usize = 1;
        var col: usize = 1;
        var k: usize = 0;
        while (k < off and k < s.src.len) : (k += 1) {
            if (s.src[k] == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }

        // inline suppression: `zsnag:ok` anywhere on the finding's own source line.
        var ls = off;
        while (ls > 0 and s.src[ls - 1] != '\n') : (ls -= 1) {}
        var le = off;
        while (le < s.src.len and s.src[le] != '\n') : (le += 1) {}
        if (std.mem.find(u8, s.src[ls..le], "zsnag:ok") != null) return;

        // Saturate rather than panic: a pathological file should clamp its reported position,
        // not crash the linter that is meant to be checking it.
        try s.out.append(s.gpa, .{
            .file = s.path,
            .id = id,
            .line = std.math.cast(u32, line) orelse std.math.maxInt(u32),
            .col = std.math.cast(u32, col) orelse std.math.maxInt(u32),
            .msg = msg,
        });
    }
};

pub fn scan(
    gpa: std.mem.Allocator,
    path: []const u8,
    src: [:0]const u8,
    out: *std.ArrayList(Finding),
) !void {
    return scanWithMap(gpa, path, src, out, null);
}

/// `map` is the companion zephem std map. When supplied, the map-backed rules (R011–R013)
/// run and their advice is read out of the map rather than written here.
pub fn scanWithMap(
    gpa: std.mem.Allocator,
    path: []const u8,
    src: [:0]const u8,
    out: *std.ArrayList(Finding),
    map: ?*const zephem.Map,
) !void {
    return scanWithOpts(gpa, path, src, out, .{ .map = map });
}

pub const Opts = struct {
    map: ?*const zephem.Map = null,
    /// R013 (a std path with no map entry) is ON by default, at advisory severity: left off,
    /// removed APIs (`std.fs.cwd`, `std.io.getStdOut`) passed the hook silently. Measured 3
    /// findings across Zig's own std (550 files) after the container-kind guard; all 3 are
    /// real dangling references (PLAN D5). zsnag's `--no-check-existence` turns it off.
    check_existence: bool = true,
    /// Set to true when the structural rules actually ran — i.e. the file parsed. The caller
    /// needs this to know whether their silence is meaningful.
    ran_structural: ?*bool = null,
    /// Rules whose stated premise the map contradicts. They are SUPPRESSED, not merely warned
    /// about: a rule asserting "this API was removed" must not keep saying so once the map
    /// shows the API is back. Advice derived from a literal going stale is the failure this
    /// whole integration exists to prevent.
    stale: []const Id = &.{},
    /// Lets R015 follow an array length into an imported file (`[data.max_bins]T`). Without it,
    /// only lengths defined in the scanned file are resolved.
    io: ?std.Io = null,
};

pub fn scanWithOpts(
    gpa: std.mem.Allocator,
    path: []const u8,
    src: [:0]const u8,
    out: *std.ArrayList(Finding),
    opts: Opts,
) !void {
    const map = opts.map;
    const start = out.items.len; // findings already present belong to earlier files
    var allow: std.ArrayList([]const u8) = .empty;
    defer allow.deinit(gpa);
    try collectAllow(gpa, src, &allow);

    const st: Scanner = .{
        .gpa = gpa,
        .path = path,
        .src = src,
        .allow = allow.items,
        .out = out,
        .stale = opts.stale,
    };
    const t = try lex(gpa, src);
    defer gpa.free(t);

    try scanTokens(st, t);
    try scanStreamZero(st, t);
    if (map) |m| try scanStdPaths(gpa, st, t, m, opts.check_existence);

    // The structural rules need a parse tree. If the file does not parse, skip them: the
    // compiler's own ast-check will report the syntax error, and heuristics run over a broken
    // parse are noise stacked on top of a real problem.
    var tree = try std.zig.Ast.parse(gpa, src, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len == 0) {
        try scanAcquire(gpa, st, &tree, t);
        try scanBigUndefined(gpa, st, &tree, t, opts.io);
        if (opts.ran_structural) |flag| flag.* = true;
    }

    // Sort ONLY what this call appended. Sorting the caller's whole accumulator interleaved
    // findings from different files by line number, so `zsnag b.zig a.zig` printed a.zig's
    // line 2 before b.zig's line 3 — output order stopped matching argument order.
    std.mem.sort(Finding, out.items[start..], {}, struct {
        fn lt(_: void, a: Finding, b: Finding) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.col < b.col;
        }
    }.lt);
}

/// True only for the STALE KEYWORD SYNTAX — `async foo()` / `await frame` — which is the sole
/// thing R001 exists to catch.
///
/// The old syntax puts an expression directly after the keyword, so the next token is an
/// identifier. Every other position is ordinary modern usage of an ordinary identifier, and
/// std is full of them: `async,` is an enum member, `.async = async` reads a field, and
/// `await(ev, future, …)` calls a function actually named `await`. Matching the bare name
/// flagged 13 error-severity findings across std — BLOCKING, on correct code, for the one
/// reason that is backwards: those declarations are only legal *because* it is no longer a
/// keyword.
fn isStaleAsyncSyntax(t: []const Tk, i: usize) bool {
    return i + 1 < t.len and t[i + 1].tag == .identifier;
}

/// Single-token and short-lookback rules: R001, R002, R003, R004, R005, R007, R009, R010.
fn scanTokens(st: Scanner, t: []const Tk) !void {
    for (t, 0..) |tok, i| {
        const prev: ?Tk = if (i > 0) t[i - 1] else null;
        const prev2: ?Tk = if (i > 1) t[i - 2] else null;
        const after_dot = prev != null and prev.?.tag == .period;
        switch (tok.tag) {
            .identifier => {
                const w = st.text(tok);
                if (!after_dot and (eq(w, "async") or eq(w, "await")) and isStaleAsyncSyntax(t, i))
                    try st.emit(tok.start, .r001_async);
                if (!after_dot and eq(w, "usingnamespace"))
                    try st.emit(tok.start, .r002_usingnamespace);
                if ((eq(w, "copy") or eq(w, "set")) and after_dot and
                    prev2 != null and prev2.?.tag == .identifier and eq(st.text(prev2.?), "mem"))
                    try st.emit(tok.start, .r003_mem_copy);
                if (eq(w, "page_allocator"))
                    try st.emit(tok.start, .r009_page_allocator);
                if (eq(w, "writer") and after_dot and i >= 4 and t[i - 2].tag == .r_paren and
                    t[i - 3].tag == .l_paren and t[i - 4].tag == .identifier and
                    (eq(st.text(t[i - 4]), "stdout") or eq(st.text(t[i - 4]), "stderr")))
                    try st.emit(tok.start, .r014_positional_stdio);
                if (eq(w, "print") and after_dot and
                    prev2 != null and prev2.?.tag == .identifier and eq(st.text(prev2.?), "debug"))
                    try st.emit(tok.start, .r010_debug_print);
            },
            .keyword_unreachable => {
                if (prev != null and prev.?.tag == .keyword_catch)
                    try st.emit(tok.start, .r004_catch_unreachable);
            },
            .r_brace => {
                if (prev != null and prev.?.tag == .l_brace and prev2 != null and prev2.?.tag == .keyword_catch)
                    try st.emit(tok.start, .r005_empty_catch);
            },
            .builtin => {
                const w = st.text(tok);
                if (eq(w, "@intCast") or eq(w, "@ptrCast") or eq(w, "@alignCast") or
                    eq(w, "@enumFromInt") or eq(w, "@intFromFloat"))
                {
                    // `x[@intCast(..)]` is already bounds-checked by the element access, so
                    // the warning would be redundant there. (Index casts dominate in ported C.)
                    const is_index = prev != null and prev.?.tag == .l_bracket;
                    if (!is_index) try st.emit(tok.start, .r007_cast);
                }
            },
            else => {},
        }
    }
}

const Acq = struct { name: []const u8, owns: Owns, off: usize, tok: u32, heap: bool };

const Span = struct { first: u32, last: u32 };

/// True for an initializer that DEFINES A TYPE rather than acquiring a resource.
/// `const Book = struct { arena: ArenaAllocator, ... }` is a declaration, not an acquisition —
/// treating it as one is what made R008 fire on most files that declare an allocator-owning
/// type, then hunt for a `Book.deinit` that will never exist.
fn isTypeDefinition(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .error_set_decl,
        => true,
        else => false,
    };
}

/// Token span of every function (and test) body, so a release can be matched within the declaration's own
/// function instead of anywhere in the file. Matching file-wide meant two functions each
/// declaring `var l = ...init(gpa)`, with only one `defer l.deinit()`, reported NOTHING —
/// a rule claiming clean code over a real leak. The names that repeat (`l`, `list`, `arena`,
/// `buf`) are exactly the common ones.
fn fnSpans(gpa: std.mem.Allocator, tree: *const std.zig.Ast) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        // Test bodies are function bodies too: a leak in a test is still a leak.
        if (tree.nodeTag(node) != .fn_decl and tree.nodeTag(node) != .test_decl) continue;
        try spans.append(gpa, .{ .first = tree.firstToken(node), .last = tree.lastToken(node) });
    }
    return spans.toOwnedSlice(gpa);
}

/// True when the identifier at `k` is part of a `return` expression — the value is handed to
/// the caller, so this function is not the one responsible for releasing it.
///
/// Scans back over the expression to the statement start: `return f;`, `return .{ .x = f };`
/// and `return try wrap(f);` all count. Stops at a statement boundary so an unrelated earlier
/// `return` cannot match.
fn isReturned(t: []const Tk, span: Span, k: usize) bool {
    var i = k;
    while (i > span.first) : (i -= 1) {
        switch (t[i - 1].tag) {
            .keyword_return => return true,
            // `.{` opens an anonymous struct literal, so `return .{ .list = l }` is still one
            // return expression. Only a bare `{` is a real statement boundary.
            .l_brace => if (i >= 2 and t[i - 2].tag == .period) continue else return false,
            .semicolon, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

/// The tightest function span containing `tok`, or null for file-level declarations.
fn enclosing(spans: []const Span, tok: u32) ?Span {
    var best: ?Span = null;
    for (spans) |s| {
        if (tok < s.first or tok > s.last) continue;
        if (best == null or (s.last - s.first) < (best.?.last - best.?.first)) best = s;
    }
    return best;
}

const Acquired = struct { owns: Owns, heap: bool };

/// Is this declaration an acquisition, and of what? Null if not. `heap` is set when the
/// initializer itself passes a known heap allocator (`.init(std.testing.allocator)`).
///
/// Only when the acquiring expression IS the initializer (under an optional `try`). A value
/// computed by a labelled block or an `if` that opens and closes a file inside it is not
/// itself a file; scanning the initializer's tokens for `openFile` made that fire 9 times on
/// Zig's own std. Zig 0.16's decl literals count: `var l: std.ArrayList(u8) = .empty;` and
/// `var a: std.heap.ArenaAllocator = .init(gpa);` take the type from the annotation.
fn acquisition(
    st: Scanner,
    tree: *const std.zig.Ast,
    t: []const Tk,
    type_node: ?std.zig.Ast.Node.Index,
    init_node: std.zig.Ast.Node.Index,
) ?Acquired {
    var n = init_node;
    if (tree.nodeTag(n) == .@"try") n = tree.nodeData(n).node;

    const annotated: ?Owns = if (type_node) |tn| blk: {
        var j = tree.firstToken(tn);
        while (j <= tree.lastToken(tn) and j < t.len) : (j += 1) {
            if (t[j].tag == .identifier) if (ownerKind(st.text(t[j]))) |k| break :blk k;
        }
        break :blk null;
    } else null;

    // `.empty`
    if (tree.nodeTag(n) == .enum_literal) {
        if (!eq(tree.tokenSlice(tree.nodeMainToken(n)), "empty")) return null;
        return .{ .owns = annotated orelse return null, .heap = false };
    }

    var buf: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buf, n) orelse return null;
    const callee = call.ast.fn_expr;
    const last = tree.lastToken(callee);
    if (last >= t.len or t[last].tag != .identifier) return null;
    const m = st.text(t[last]);

    if (eq(m, "openFile") or eq(m, "createFile") or eq(m, "openDir")) return .{ .owns = .handle, .heap = false };
    // `initBuffer` borrows a caller's buffer; there is nothing to free.
    if (!std.mem.startsWith(u8, m, "init") or eq(m, "initBuffer")) return null;
    const heap = call.ast.params.len > 0 and heapAllocator(nodeText(st, tree, t, call.ast.params[0]));

    // `.init(…)`: a decl literal, typed by the annotation.
    if (tree.nodeTag(callee) == .enum_literal) return .{ .owns = annotated orelse return null, .heap = heap };
    // `std.ArrayList(u8).init(gpa)`, `std.heap.ArenaAllocator.init(gpa)`: typed by the callee.
    var j = tree.firstToken(callee);
    while (j < last) : (j += 1) {
        if (t[j].tag == .identifier) if (ownerKind(st.text(t[j]))) |k| return .{ .owns = k, .heap = heap };
    }
    return null;
}

/// True when some `name.method(A, …)` in the span passes a known heap allocator as `A` —
/// how an unmanaged collection (`= .empty`) shows where its memory comes from.
fn usedWithHeap(st: Scanner, t: []const Tk, span: Span, name: []const u8) bool {
    var k: usize = span.first;
    while (k + 3 <= span.last and k + 3 < t.len) : (k += 1) {
        if (t[k].tag != .identifier or !eq(st.text(t[k]), name)) continue;
        if (t[k + 1].tag != .period or t[k + 2].tag != .identifier or t[k + 3].tag != .l_paren) continue;
        // The first argument runs to the first `,` or `)` at depth 0.
        var depth: usize = 0;
        var e = k + 4;
        while (e <= span.last and e < t.len) : (e += 1) {
            switch (t[e].tag) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                .comma => if (depth == 0) break,
                else => {},
            }
        }
        if (e > k + 4 and heapAllocator(st.src[t[k + 4].start..t[e - 1].end])) return true;
    }
    return false;
}

/// R008: acquire (init of a deinit-having type, or openFile/createFile) without release.
///
/// Grows dynamically — the old fixed 128-entry cap dropped acquisitions silently (ledger B4).
/// Still heuristic; the declaration scan is the source of ledger B1 and B10 and wants an AST.
fn scanAcquire(gpa: std.mem.Allocator, st: Scanner, tree: *const std.zig.Ast, t: []const Tk) !void {
    var acq: std.ArrayList(Acq) = .empty;
    defer acq.deinit(gpa);

    const spans = try fnSpans(gpa, tree);
    defer gpa.free(spans);

    // Declarations come from the AST, not from scanning for the `const`/`var` KEYWORD and
    // reading to the next `;`. That scan had two failure modes, both systemic: for
    // `const T = struct { … }` the span was the whole struct body, and in `fn f(s: []const u8)`
    // the `const` inside the type bound to `u8` and swallowed the function body.
    for (0..tree.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        const decl = tree.fullVarDecl(node) orelse continue;
        const init_node = decl.ast.init_node.unwrap() orelse continue;
        if (isTypeDefinition(tree, init_node)) continue;

        const name_tok = decl.ast.mut_token + 1;
        if (name_tok >= t.len) continue;
        // A container-level value lives for the whole program; nothing is expected to free it.
        if (enclosing(spans, name_tok) == null) continue;

        const got = acquisition(st, tree, t, decl.ast.type_node.unwrap(), init_node) orelse continue;
        try acq.append(gpa, .{
            .name = st.text(t[name_tok]),
            .owns = got.owns,
            .off = t[name_tok].start,
            .tok = name_tok,
            .heap = got.heap,
        });
    }
    if (acq.items.len == 0) return;

    // One pass per function that actually holds an acquisition, building the set of names
    // released in it — rather than rescanning the whole token stream per acquisition, which
    // was the O(n²) half of the old implementation.
    for (acq.items) |a| {
        const span = enclosing(spans, a.tok) orelse continue;
        // A collection is only a leak when its memory visibly comes from a real heap.
        if (a.owns == .collection and !a.heap and !usedWithHeap(st, t, span, a.name)) continue;
        var released = false;
        var k: usize = span.first;
        while (k <= span.last and k < t.len) : (k += 1) {
            if (t[k].tag != .identifier or !eq(st.text(t[k]), a.name)) continue;

            // Returned to the caller: ownership transfers, and releasing it here would be the
            // bug. `fn createDirAndFile(...) !File { const f = try dir.createFile(...); return f; }`
            // is correct code, and treating it as a leak is a false positive.
            if (isReturned(t, span, k)) {
                released = true;
                break;
            }
            // Moved into something else (`self.list = l;`, `.{ .list = l }`): the new owner
            // releases it. `_ = l` discards, which moves nothing.
            const discard = k >= 2 and t[k - 2].tag == .identifier and eq(st.text(t[k - 2]), "_");
            if (k > 0 and t[k - 1].tag == .equal and !discard) {
                released = true;
                break;
            }
            if (k + 2 > span.last or k + 2 >= t.len) continue;
            if (t[k + 1].tag != .period or t[k + 2].tag != .identifier) continue;
            const m = st.text(t[k + 2]);
            const releases = if (a.owns == .handle)
                eq(m, "close")
            else
                eq(m, "deinit") or std.mem.startsWith(u8, m, "toOwnedSlice");
            if (releases) {
                released = true;
                break;
            }
        }
        if (!released) try st.emit(a.off, .r008_acquire);
    }
}

/// R015 fires at this many bytes. Below it the fill and the probe are noise next to a call.
const big_undefined_bytes: u64 = 64 << 10;
/// For an element type whose size cannot be read here (a struct), fire at this many elements:
/// a struct of 16+ bytes makes it 64 KiB, and few hot-path structs are smaller.
const big_undefined_elems: u64 = 4096;

/// R015 (advisory): `var x: [N]T = undefined` inside a function, where N * @sizeOf(T) is large.
/// Advisory because the cost depends on how often the function runs, which syntax cannot show:
/// on its first run it flagged 22 such arrays across these projects, nearly all 64 KiB I/O
/// buffers in once-per-command functions, and 10 in Zig's std. Debug and
/// ReleaseSafe fill undefined memory with 0xAA on every call, and a big frame is probed a page at
/// a time in every mode. Found in zarbor (2026-10-05): a 1 MB `[data.max_bins]CatKey` scratch in
/// `bestSplit`, filled per node though its search was off by default, made ReleaseSafe 12x
/// slower. N is evaluated from literals, `*`/`+`, constants in this file or (with `io`) one
/// imported file, and `std.math.maxInt(uN)`; T from integer/float primitives and aliases of
/// them. Anything else is left unjudged rather than guessed.
fn scanBigUndefined(gpa: std.mem.Allocator, st: Scanner, tree: *const std.zig.Ast, t: []const Tk, io: ?std.Io) !void {
    const spans = try fnSpans(gpa, tree);
    defer gpa.free(spans);
    var ev: SizeEval = .{ .gpa = gpa, .io = io, .dir = std.fs.path.dirname(st.path) orelse "." };
    for (0..tree.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        const decl = tree.fullVarDecl(node) orelse continue;
        const init_node = decl.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(init_node) != .identifier or !eq(tree.tokenSlice(tree.nodeMainToken(init_node)), "undefined")) continue;
        const type_node = decl.ast.type_node.unwrap() orelse continue;
        const arr = tree.fullArrayType(type_node) orelse continue;
        const name_tok = decl.ast.mut_token + 1;
        if (name_tok >= t.len) continue;
        // A container-level array is not on the stack and is not refilled per call.
        if (enclosing(spans, name_tok) == null) continue;

        const n = ev.int(tree, arr.ast.elem_count, 0) orelse continue;
        const big = if (ev.size(tree, arr.ast.elem_type, 0)) |sz|
            n *| sz >= big_undefined_bytes
        else
            n >= big_undefined_elems;
        if (big) try st.emit(t[name_tok].start, .r015_big_undefined);
    }
}

/// Integer constants and type sizes, as far as the syntax shows them (see R015).
const SizeEval = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io,
    /// Directory of the scanned file: imports are relative to it.
    dir: []const u8,

    const Ast = std.zig.Ast;
    const max_depth = 8;

    fn int(e: *SizeEval, tree: *const Ast, node: Ast.Node.Index, depth: u8) ?u64 {
        if (depth > max_depth) return null;
        switch (tree.nodeTag(node)) {
            .number_literal => return std.fmt.parseInt(u64, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch null,
            .identifier => {
                const init = rootConst(tree, tree.tokenSlice(tree.nodeMainToken(node))) orelse return null;
                return e.int(tree, init, depth + 1);
            },
            .mul, .add => {
                const lr = tree.nodeData(node).node_and_node;
                const a = e.int(tree, lr[0], depth + 1) orelse return null;
                const b = e.int(tree, lr[1], depth + 1) orelse return null;
                return if (tree.nodeTag(node) == .mul) a *| b else a +| b;
            },
            .field_access => {
                const lt = tree.nodeData(node).node_and_token;
                const field = tree.tokenSlice(lt[1]);
                return e.inImport(tree, lt[0], field, depth);
            },
            .call_one, .call_one_comma, .call, .call_comma => {
                var buf: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buf, node) orelse return null;
                if (call.ast.params.len != 1) return null;
                const callee = tree.tokenSlice(tree.lastToken(call.ast.fn_expr));
                if (!eq(callee, "maxInt")) return null;
                const it = intType(tree, call.ast.params[0], depth + 1) orelse return null;
                const bits = if (it.signed) it.bits - 1 else it.bits;
                if (bits >= 64) return std.math.maxInt(u64);
                return (@as(u64, 1) << @intCast(bits)) - 1; // zsnag:ok — bits < 64, checked above
            },
            else => return null,
        }
    }

    /// `X.field` where `X` is `@import("file.zig")` in `tree`: the value of that file's `field`.
    fn inImport(e: *SizeEval, tree: *const Ast, lhs: Ast.Node.Index, field: []const u8, depth: u8) ?u64 {
        const io = e.io orelse return null;
        if (tree.nodeTag(lhs) != .identifier) return null;
        const init = rootConst(tree, tree.tokenSlice(tree.nodeMainToken(lhs))) orelse return null;
        const rel = importPath(tree, init) orelse return null;
        if (!std.mem.endsWith(u8, rel, ".zig")) return null; // a package, not a file beside us
        const path = std.fs.path.join(e.gpa, &.{ e.dir, rel }) catch return null;
        defer e.gpa.free(path);
        const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, e.gpa, .limited(16 << 20), .of(u8), 0) catch return null;
        defer e.gpa.free(src);
        var other = Ast.parse(e.gpa, src, .zig) catch return null;
        defer other.deinit(e.gpa);
        const value = rootConst(&other, field) orelse return null;
        // Its own constants resolve within it; its imports are relative to it, but one hop is
        // enough for the shapes this rule targets, so `io` stops here.
        var inner: SizeEval = .{ .gpa = e.gpa, .io = null, .dir = e.dir };
        return inner.int(&other, value, depth + 1);
    }

    /// Bytes of one element, for integer/float/bool primitives and aliases of them.
    fn size(e: *SizeEval, tree: *const Ast, node: Ast.Node.Index, depth: u8) ?u64 {
        _ = e;
        if (intType(tree, node, depth)) |it| return (it.bits + 7) / 8;
        return null;
    }

    const IntType = struct { bits: u16, signed: bool };

    fn intType(tree: *const Ast, node: Ast.Node.Index, depth: u8) ?IntType {
        if (depth > max_depth or tree.nodeTag(node) != .identifier) return null;
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        if (eq(name, "bool")) return .{ .bits = 8, .signed = false };
        if (eq(name, "usize") or eq(name, "isize")) return .{ .bits = 64, .signed = name[0] == 'i' };
        if (name.len >= 2 and (name[0] == 'u' or name[0] == 'i' or name[0] == 'f')) {
            if (std.fmt.parseInt(u16, name[1..], 10)) |bits| {
                return .{ .bits = bits, .signed = name[0] != 'u' };
            } else |_| {}
        }
        const init = rootConst(tree, name) orelse return null;
        return intType(tree, init, depth + 1);
    }

    /// The initializer of the container-level `const name = …` in `tree`, if any.
    fn rootConst(tree: *const Ast, name: []const u8) ?Ast.Node.Index {
        for (tree.rootDecls()) |d| {
            const decl = tree.fullVarDecl(d) orelse continue;
            if (!eq(tree.tokenSlice(decl.ast.mut_token), "const")) continue;
            if (!eq(tree.tokenSlice(decl.ast.mut_token + 1), name)) continue;
            return decl.ast.init_node.unwrap();
        }
        return null;
    }

    /// The path in `@import("path")`, without quotes.
    fn importPath(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
        var buf: [2]Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buf, node) orelse return null;
        if (!eq(tree.tokenSlice(tree.nodeMainToken(node)), "@import") or params.len != 1) return null;
        if (tree.nodeTag(params[0]) != .string_literal) return null;
        const lit = tree.tokenSlice(tree.nodeMainToken(params[0]));
        if (lit.len < 2) return null;
        return lit[1 .. lit.len - 1];
    }
};

/// R006: a `stream()` result compared `== 0` and then broken out of (heuristic).
fn scanStreamZero(st: Scanner, t: []const Tk) !void {
    var i: usize = 0;
    while (i + 5 < t.len) : (i += 1) {
        if (!(t[i].tag == .keyword_if and t[i + 1].tag == .l_paren and t[i + 2].tag == .identifier and
            t[i + 3].tag == .equal_equal and t[i + 4].tag == .number_literal and eq(st.text(t[i + 4]), "0")))
            continue;

        // The variable's nearest declaration before the test must be initialised by a
        // `.stream(` call. Matching any `stream`-prefixed identifier anywhere earlier in the
        // file fired 7 times on Zig's own std, all wrong (a field named `stream`, an
        // unrelated `n`).
        const vn = st.text(t[i + 2]);
        var from_stream = false;
        var k = i;
        while (k > 1) : (k -= 1) {
            const is_decl = t[k].tag == .identifier and eq(st.text(t[k]), vn) and
                (t[k - 1].tag == .keyword_const or t[k - 1].tag == .keyword_var);
            if (!is_decl) continue;
            var m = k;
            while (m + 2 < i and t[m].tag != .semicolon) : (m += 1) {
                if (t[m].tag == .period and t[m + 1].tag == .identifier and
                    eq(st.text(t[m + 1]), "stream") and t[m + 2].tag == .l_paren) from_stream = true;
            }
            break;
        }
        if (!from_stream) continue;

        var j = i + 5;
        while (j < t.len and j < i + 12 and t[j].tag != .semicolon) : (j += 1) {
            if (t[j].tag == .keyword_break or t[j].tag == .keyword_return) {
                try st.emit(t[i].start, .r006_stream_zero);
                break;
            }
        }
    }
}

/// The dotted chain rooted at a bare `std` token at `i` (`std.a.b`, up to the first thing that
/// is not `.ident`), written into `buf`. Returns the token index just past it, or null when
/// `t[i]` is not such a root. Shared by the scan and by `mapKeys`, so the map is loaded with
/// exactly the paths the scan will ask for.
fn stdChain(gpa: std.mem.Allocator, src: []const u8, t: []const Tk, i: usize, buf: *std.ArrayList(u8)) !?usize {
    if (t[i].tag != .identifier or !eq(src[t[i].start..t[i].end], "std")) return null;
    // Must be a root reference, not the tail of some other selector chain.
    if (i > 0 and t[i - 1].tag == .period) return null;

    buf.clearRetainingCapacity();
    try buf.appendSlice(gpa, "std");
    var j = i + 1;
    while (j + 1 < t.len and t[j].tag == .period and t[j + 1].tag == .identifier) : (j += 2) {
        try buf.append(gpa, '.');
        try buf.appendSlice(gpa, src[t[j + 1].start..t[j + 1].end]);
    }
    return j;
}

/// Paths `stalePremises` looks up.
const premise_keys = [_][]const u8{ "std.mem.copy", "std.mem.set" };

/// Every map path a scan of `src` can query: each std chain, all its proper prefixes (for
/// `longestPrefixKind`), and the premise self-check paths. Pass the set to `zephem.load`.
pub fn mapKeys(gpa: std.mem.Allocator, src: [:0]const u8, keys: *zephem.Keys) !void {
    for (premise_keys) |k| try zephem.addKey(gpa, keys, k);
    const t = try lex(gpa, src);
    defer gpa.free(t);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const j = (try stdChain(gpa, src, t, i, &buf)) orelse continue;
        // Down to `std` itself: `longestPrefixKind` can stop there too.
        var end = buf.items.len;
        while (true) {
            try zephem.addKey(gpa, keys, buf.items[0..end]);
            end = std.mem.findScalarLast(u8, buf.items[0..end], '.') orelse break;
        }
        i = j;
    }
}

/// R011/R012/R013 — the map-backed rules.
///
/// Resolves only a plain dotted chain (`std` `.` ident `.` ident …) and stops at the first
/// call. It deliberately does NOT follow a chain across a call: in
/// `std.Io.Dir.cwd().readFileAlloc(io, …)` the path checked is `std.Io.Dir.cwd`, and the
/// `.readFileAlloc` continuation is skipped — its receiver is a *value*, so its first
/// parameter is implicit and its arity cannot be compared against the map's signature.
/// Guessing there would produce false positives on ordinary method-call style.
fn scanStdPaths(gpa: std.mem.Allocator, st: Scanner, t: []const Tk, map: *const zephem.Map, check_existence: bool) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const j = (try stdChain(gpa, st.src, t, i, &buf)) orelse continue;
        // `std` alone carries no claim to check.
        if (buf.items.len == 3) {
            i = j;
            continue;
        }

        const entry = map.get(buf.items);
        if (entry == null) {
            // Only a MISSING MEMBER OF A CONTAINER is suspicious. If the longest resolving
            // prefix is a value (`const`, `alias`, `tag`, `field`, `fn`), the rest of the path
            // is member access through that value's type, which the map cannot follow —
            // `std.Io.Clock.real.now`, `std.testing.allocator.free`. Reporting those is what
            // made R013 fire 219 times on Zig's own std.
            const prefix_kind = zephem.longestPrefixKind(map.*, buf.items);
            if (check_existence and prefix_kind != null and zephem.isContainerKind(prefix_kind.?)) {
                const msg = try std.fmt.allocPrint(
                    gpa,
                    "`{s}` is not in the zephem map — cannot verify it exists (check with `zephem look`).",
                    .{buf.items},
                );
                try st.emitMsg(t[i].start, .r013_unknown_std, msg);
            }
            i = j;
            continue;
        }
        const e = entry.?;

        // R011 — deprecation, with the replacement read out of the map.
        if (zephem.isDeprecated(e.doc)) {
            const msg = if (zephem.deprecationOf(e.doc)) |repl|
                try std.fmt.allocPrint(gpa, "`{s}` is deprecated — the map says: use `{s}`.", .{ buf.items, repl })
            else
                try std.fmt.allocPrint(gpa, "`{s}` is deprecated — the map says: {s}", .{ buf.items, e.doc });
            try st.emitMsg(t[i].start, .r011_deprecated, msg);
        }

        // R012 — arity, only for a direct call on the resolved path.
        if (j < t.len and t[j].tag == .l_paren) {
            if (zephem.arityOf(gpa, e.sig)) |want| {
                const got = countArgs(t, j);
                if (got != null and got.? != want) {
                    const msg = try std.fmt.allocPrint(
                        gpa,
                        "`{s}` takes {d} argument{s}, called with {d}. Signature: {s}",
                        .{ buf.items, want, if (want == 1) "" else "s", got.?, e.sig },
                    );
                    try st.emitMsg(t[i].start, .r012_arity, msg);
                }
            }
        }
        i = j;
    }
}

/// Arguments at the call site — the number of non-empty comma-separated segments starting
/// from the `(` at `open`. Returns null on an unbalanced tail.
///
/// Counts segments, not commas: a multi-line call normally ends `.{x},\n)` with a TRAILING
/// comma, which would otherwise read as one argument too many.
fn countArgs(t: []const Tk, open: usize) ?usize {
    std.debug.assert(t[open].tag == .l_paren);
    var depth: usize = 0;
    var args: usize = 0;
    var seen = false;
    var k = open;
    while (k < t.len) : (k += 1) {
        switch (t[k].tag) {
            .l_paren, .l_bracket, .l_brace => {
                depth += 1;
                if (depth > 1) seen = true;
            },
            .r_paren, .r_bracket, .r_brace => {
                depth -= 1;
                if (depth == 0) return args + @intFromBool(seen);
                seen = true;
            },
            .comma => if (depth == 1) {
                args += @intFromBool(seen);
                seen = false;
            } else {
                seen = true;
            },
            else => if (depth >= 1) {
                seen = true;
            },
        }
    }
    return null;
}

/// Self-check the rules whose premise is "this API was removed". If the map says otherwise,
/// the rule is stale and must not fire — advice derived from a literal is exactly what this
/// integration exists to stop.
pub fn stalePremises(gpa: std.mem.Allocator, map: *const zephem.Map) ![]const Id {
    var stale: std.ArrayList(Id) = .empty;
    if (map.get(premise_keys[0]) != null or map.get(premise_keys[1]) != null)
        try stale.append(gpa, .r003_mem_copy);
    return stale.items;
}

// ---- rendering ------------------------------------------------------------

pub fn renderText(w: *std.Io.Writer, findings: []const Finding) !void {
    for (findings) |f| {
        const r = f.rule();
        try w.print("{s} {s}:{d}:{d}  [{s} {s}]  {s}\n", .{
            r.sev.mark(), f.file, f.line, f.col, r.code, r.sev.name(), f.msg,
        });
    }
}

/// JSONL — one object per finding. Strings go through the real escaper (ledger B2: the old
/// hand-built format emitted invalid JSON for any path containing a quote or backslash).
pub fn renderJson(w: *std.Io.Writer, findings: []const Finding) !void {
    for (findings) |f| {
        const r = f.rule();
        try w.writeAll("{\"file\":");
        try std.json.Stringify.value(f.file, .{}, w);
        try w.print(",\"line\":{d},\"col\":{d},\"rule\":\"{s}\",\"severity\":\"{s}\",\"message\":", .{
            f.line, f.col, r.code, r.sev.name(),
        });
        try std.json.Stringify.value(f.msg, .{}, w);
        try w.writeAll("}\n");
    }
}

/// A machine-readable status record, emitted as the FIRST JSONL line. It states which rule
/// groups actually ran, so the consumer never has to infer that from an exit code — inferring
/// it is what let a failed map load masquerade as "the map rules found nothing", which then
/// deleted their history from the book.
pub fn renderStatus(w: *std.Io.Writer, groups: []const Group) !void {
    try w.writeAll("{\"zsnag\":\"status\",\"ran\":[");
    for (groups, 0..) |g, i| {
        if (i > 0) try w.writeAll(",");
        try std.json.Stringify.value(g.name(), .{}, w);
    }
    try w.writeAll("]}\n");
}

pub fn listRules(w: *std.Io.Writer) !void {
    for (rules) |r| {
        try w.print("{s}  {s:<5}  {s}\n", .{ r.code, r.sev.name(), r.msg });
        if (r.premise.len > 0) try w.print("        premise: {s}\n", .{r.premise});
    }
}

pub fn anyError(findings: []const Finding) bool {
    for (findings) |f| if (f.rule().sev == .err) return true;
    return false;
}
