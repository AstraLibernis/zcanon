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
    /// Self-contained rules; run whenever zsnag runs.
    core,
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
        .msg = "stream() returning 0 means 'switched modes', not end-of-stream; use continue, not break/return. (heuristic)",
    },
    .r007_cast = .{
        .code = "R007",
        .sev = .info,
        .msg = "this cast can panic/corrupt if out of range; verify first.",
    },
    .r008_acquire = .{
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

const NEEDS_DEINIT = [_][]const u8{
    "ArrayList",     "HashMap", "ArrayHashMap", "MultiArrayList",
    "ArenaAllocator", "BufSet", "BufMap",       "PriorityQueue",
    "SegmentedList",
};

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

    fn text(s: Scanner, t: Tk) []const u8 {
        return s.src[t.start..t.end];
    }

    fn emit(s: Scanner, off: usize, id: Id) !void {
        return s.emitMsg(off, id, ruleOf(id).msg);
    }

    /// `msg` may differ from the rule's default when the advice is derived from the map.
    fn emitMsg(s: Scanner, off: usize, id: Id, msg: []const u8) !void {
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
    var allow: std.ArrayList([]const u8) = .empty;
    defer allow.deinit(gpa);
    try collectAllow(gpa, src, &allow);

    const st: Scanner = .{ .gpa = gpa, .path = path, .src = src, .allow = allow.items, .out = out };
    const t = try lex(gpa, src);
    defer gpa.free(t);

    try scanTokens(st, t);
    try scanAcquire(gpa, st, t);
    try scanStreamZero(st, t);
    if (map) |m| try scanStdPaths(gpa, st, t, m);

    std.mem.sort(Finding, out.items, {}, struct {
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
                if (eq(w, "@intCast") or eq(w, "@ptrCast") or eq(w, "@alignCast")) {
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

const Acq = struct { name: []const u8, close: bool, off: usize };

/// R008: acquire (init of a deinit-having type, or openFile/createFile) without release.
///
/// Grows dynamically — the old fixed 128-entry cap dropped acquisitions silently (ledger B4).
/// Still heuristic; the declaration scan is the source of ledger B1 and B10 and wants an AST.
fn scanAcquire(gpa: std.mem.Allocator, st: Scanner, t: []const Tk) !void {
    var acq: std.ArrayList(Acq) = .empty;
    defer acq.deinit(gpa);

    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i].tag != .keyword_var and t[i].tag != .keyword_const) continue;
        if (i + 1 >= t.len or t[i + 1].tag != .identifier) continue;
        const vname = st.text(t[i + 1]);
        const voff = t[i + 1].start;
        var saw_init = false;
        var saw_type = false;
        var close = false;
        var j = i + 2;
        while (j < t.len and t[j].tag != .semicolon) : (j += 1) {
            if (t[j].tag != .identifier) continue;
            const wj = st.text(t[j]);
            if (wj.len >= 4 and std.mem.startsWith(u8, wj, "init") and
                j > 0 and t[j - 1].tag == .period) saw_init = true;
            if (eq(wj, "openFile") or eq(wj, "createFile")) {
                saw_init = true;
                close = true;
            }
            for (NEEDS_DEINIT) |ty| if (eq(wj, ty)) {
                saw_type = true;
            };
        }
        if (saw_init and (saw_type or close))
            try acq.append(gpa, .{ .name = vname, .close = close, .off = voff });
    }

    for (acq.items) |a| {
        var released = false;
        var k: usize = 0;
        while (k + 2 < t.len) : (k += 1) {
            if (t[k].tag != .identifier or !eq(st.text(t[k]), a.name)) continue;
            if (t[k + 1].tag != .period or t[k + 2].tag != .identifier) continue;
            const m = st.text(t[k + 2]);
            if ((!a.close and eq(m, "deinit")) or (a.close and eq(m, "close"))) {
                released = true;
                break;
            }
        }
        if (!released) try st.emit(a.off, .r008_acquire);
    }
}

/// R006: a `stream()` result compared `== 0` and then broken out of (heuristic).
fn scanStreamZero(st: Scanner, t: []const Tk) !void {
    var i: usize = 0;
    while (i + 5 < t.len) : (i += 1) {
        if (!(t[i].tag == .keyword_if and t[i + 1].tag == .l_paren and t[i + 2].tag == .identifier and
            t[i + 3].tag == .equal_equal and t[i + 4].tag == .number_literal and eq(st.text(t[i + 4]), "0")))
            continue;

        const vn = st.text(t[i + 2]);
        var from_stream = false;
        var k: usize = 0;
        while (k + 2 < i) : (k += 1) {
            if (t[k].tag != .identifier or !eq(st.text(t[k]), vn)) continue;
            var m = k;
            while (m < i and t[m].tag != .semicolon) : (m += 1) {
                if (t[m].tag == .identifier and std.mem.startsWith(u8, st.text(t[m]), "stream")) from_stream = true;
            }
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

/// R011/R012/R013 — the map-backed rules.
///
/// Resolves only a plain dotted chain (`std` `.` ident `.` ident …) and stops at the first
/// call. It deliberately does NOT follow a chain across a call: in
/// `std.Io.Dir.cwd().readFileAlloc(io, …)` the path checked is `std.Io.Dir.cwd`, and the
/// `.readFileAlloc` continuation is skipped — its receiver is a *value*, so its first
/// parameter is implicit and its arity cannot be compared against the map's signature.
/// Guessing there would produce false positives on ordinary method-call style.
fn scanStdPaths(gpa: std.mem.Allocator, st: Scanner, t: []const Tk, map: *const zephem.Map) !void {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i].tag != .identifier or !eq(st.text(t[i]), "std")) continue;
        // Must be a root reference, not the tail of some other selector chain.
        if (i > 0 and t[i - 1].tag == .period) continue;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, "std");

        var j = i + 1;
        while (j + 1 < t.len and t[j].tag == .period and t[j + 1].tag == .identifier) : (j += 2) {
            try buf.append(gpa, '.');
            try buf.appendSlice(gpa, st.text(t[j + 1]));
        }
        // `std` alone carries no claim to check.
        if (buf.items.len == 3) {
            i = j;
            continue;
        }

        const entry = map.get(buf.items);
        if (entry == null) {
            const msg = try std.fmt.allocPrint(
                gpa,
                "`{s}` is not in the zephem map — cannot verify it exists (check with `zephem look`).",
                .{buf.items},
            );
            try st.emitMsg(t[i].start, .r013_unknown_std, msg);
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
            if (zephem.arityOf(e.sig)) |want| {
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
    if (map.get("std.mem.copy") != null or map.get("std.mem.set") != null)
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
