//! zsnag — catch the mistakes an LLM tends to make writing Zig 0.16.
//! Token-based (uses the real Zig tokenizer, so comments/strings and identifier
//! boundaries are handled correctly — unlike a regex). Not a general linter; the
//! compiler already does that. Targets stale-knowledge and footgun mistakes.
//!
//!   zsnag file.zig [more.zig ...]    check files
//!   zsnag --json file.zig           one JSON object per finding (JSONL)
//! Exit code is non-zero if any 'error'-severity finding is present.
const std = @import("std");
const Token = std.zig.Token;
const Tokenizer = std.zig.Tokenizer;

const Sev = enum { err, warn, info };
fn mark(s: Sev) []const u8 {
    return switch (s) { .err => "x", .warn => "!", .info => "." };
}
fn sevName(s: Sev) []const u8 {
    return switch (s) { .err => "error", .warn => "warn", .info => "info" };
}

const Tk = struct { tag: Token.Tag, start: usize, end: usize };

const NEEDS_DEINIT = [_][]const u8{
    "ArrayList", "HashMap", "ArrayHashMap", "MultiArrayList",
    "ArenaAllocator", "BufSet", "BufMap", "PriorityQueue", "SegmentedList",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
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

const State = struct {
    path: []const u8,
    src: [:0]const u8,
    json: bool,
    any_err: *bool,

    fn text(s: State, t: Tk) []const u8 {
        return s.src[t.start..t.end];
    }

    fn emit(s: State, off: usize, rule: []const u8, sev: Sev, msg: []const u8) void {
        if (sev == .err) s.any_err.* = true;
        var line: usize = 1;
        var col: usize = 1;
        var k: usize = 0;
        while (k < off and k < s.src.len) : (k += 1) {
            if (s.src[k] == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        if (s.json) {
            std.debug.print(
                "{{\"file\":\"{s}\",\"line\":{d},\"col\":{d},\"rule\":\"{s}\",\"severity\":\"{s}\",\"message\":\"{s}\"}}\n",
                .{ s.path, line, col, rule, sevName(sev), msg },
            );
        } else {
            std.debug.print("{s} {s}:{d}:{d}  [{s} {s}]  {s}\n", .{ mark(sev), s.path, line, col, rule, sevName(sev), msg });
        }
    }
};

fn scan(gpa: std.mem.Allocator, st: State) !void {
    const t = try lex(gpa, st.src);
    const tag = struct {
        fn at(ts: []Tk, i: usize) Token.Tag {
            return ts[i].tag;
        }
    };
    _ = tag;

    // single-token + lookback rules
    for (t, 0..) |tok, i| {
        const prev: ?Tk = if (i > 0) t[i - 1] else null;
        const prev2: ?Tk = if (i > 1) t[i - 2] else null;
        const after_dot = prev != null and prev.?.tag == .period;
        switch (tok.tag) {
            .identifier => {
                const w = st.text(tok);
                if (!after_dot and (eq(w, "async") or eq(w, "await")))
                    st.emit(tok.start, "R001", .err, "async/await is no longer a keyword (old Zig). As a .method() call it's fine.");
                if (!after_dot and eq(w, "usingnamespace"))
                    st.emit(tok.start, "R002", .err, "usingnamespace was removed; import/redeclare explicitly.");
                if ((eq(w, "copy") or eq(w, "set")) and prev != null and prev.?.tag == .period and
                    prev2 != null and prev2.?.tag == .identifier and eq(st.text(prev2.?), "mem"))
                    st.emit(tok.start, "R003", .err, "mem.copy/mem.set were removed; use @memcpy/@memset.");
                if (eq(w, "page_allocator"))
                    st.emit(tok.start, "R009", .info, "page_allocator as a general allocator is slow; pass an allocator in.");
                if (eq(w, "print") and prev != null and prev.?.tag == .period and
                    prev2 != null and prev2.?.tag == .identifier and eq(st.text(prev2.?), "debug"))
                    st.emit(tok.start, "R010", .info, "debug.print left in code? remove or use std.log.");
            },
            .keyword_unreachable => {
                if (prev != null and prev.?.tag == .keyword_catch)
                    st.emit(tok.start, "R004", .warn, "catch unreachable crashes in release if it ever fails; handle the error.");
            },
            .r_brace => {
                if (prev != null and prev.?.tag == .l_brace and prev2 != null and prev2.?.tag == .keyword_catch)
                    st.emit(tok.start, "R005", .warn, "empty catch {} silently swallows an error.");
            },
            .builtin => {
                const w = st.text(tok);
                if (eq(w, "@intCast") or eq(w, "@ptrCast") or eq(w, "@alignCast"))
                    st.emit(tok.start, "R007", .info, "this cast can panic/corrupt if out of range; verify first.");
            },
            else => {},
        }
    }

    // R008: acquire (init of a deinit-having type, or openFile/createFile) without release.
    var names: [128][]const u8 = undefined;
    var kinds: [128]u8 = undefined; // 'd'=deinit 'c'=close
    var offs: [128]usize = undefined;
    var nacq: usize = 0;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i].tag == .keyword_var or t[i].tag == .keyword_const) {
            if (i + 1 >= t.len or t[i + 1].tag != .identifier) continue;
            const vname = st.text(t[i + 1]);
            const voff = t[i + 1].start;
            var saw_init = false;
            var saw_type = false;
            var kind: u8 = 'd';
            var j = i + 2;
            while (j < t.len and t[j].tag != .semicolon) : (j += 1) {
                const wj = if (t[j].tag == .identifier) st.text(t[j]) else "";
                if (t[j].tag == .identifier and wj.len >= 4 and std.mem.startsWith(u8, wj, "init") and
                    j > 0 and t[j - 1].tag == .period) saw_init = true;
                if (t[j].tag == .identifier and (eq(wj, "openFile") or eq(wj, "createFile"))) {
                    saw_init = true;
                    kind = 'c';
                }
                if (t[j].tag == .identifier) {
                    for (NEEDS_DEINIT) |ty| if (eq(wj, ty)) {
                        saw_type = true;
                    };
                }
            }
            if (saw_init and (saw_type or kind == 'c') and nacq < names.len) {
                names[nacq] = vname;
                kinds[nacq] = kind;
                offs[nacq] = voff;
                nacq += 1;
            }
        }
    }
    // release check: look for vname . (deinit|close)
    for (0..nacq) |a| {
        var released = false;
        var k: usize = 0;
        while (k + 2 < t.len) : (k += 1) {
            if (t[k].tag == .identifier and eq(st.text(t[k]), names[a]) and
                t[k + 1].tag == .period and t[k + 2].tag == .identifier)
            {
                const m = st.text(t[k + 2]);
                if ((kinds[a] == 'd' and eq(m, "deinit")) or (kinds[a] == 'c' and eq(m, "close"))) {
                    released = true;
                    break;
                }
            }
        }
        if (!released) {
            const rel = if (kinds[a] == 'c') "close" else "deinit";
            _ = rel;
            st.emit(offs[a], "R008", .warn, "acquired but never released (no matching deinit/close); add a defer. (heuristic)");
        }
    }

    // R006: stream() result compared == 0 then break/return (heuristic).
    i = 0;
    while (i + 5 < t.len) : (i += 1) {
        // if ( IDENT == 0 ) ... break|return  on the same statement, where IDENT came from a .stream call
        if (t[i].tag == .keyword_if and t[i + 1].tag == .l_paren and t[i + 2].tag == .identifier and
            t[i + 3].tag == .equal_equal and t[i + 4].tag == .number_literal and eq(st.text(t[i + 4]), "0"))
        {
            const vn = st.text(t[i + 2]);
            // assigned from a stream call earlier?
            var fromStream = false;
            var k: usize = 0;
            while (k + 2 < i) : (k += 1) {
                if (t[k].tag == .identifier and eq(st.text(t[k]), vn)) {
                    var m = k;
                    while (m < i and t[m].tag != .semicolon) : (m += 1) {
                        if (t[m].tag == .identifier and std.mem.startsWith(u8, st.text(t[m]), "stream")) fromStream = true;
                    }
                }
            }
            if (!fromStream) continue;
            // look for break/return before the statement ends (next ~6 tokens / until semicolon)
            var j = i + 5;
            while (j < t.len and j < i + 12 and t[j].tag != .semicolon) : (j += 1) {
                if (t[j].tag == .keyword_break or t[j].tag == .keyword_return) {
                    st.emit(t[i].start, "R006", .warn, "stream() returning 0 means 'switched modes', not end-of-stream; use continue, not break/return. (heuristic)");
                    break;
                }
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var json = false;
    var any_err = false;
    var nfiles: usize = 0;
    var it = init.minimal.args.iterate();
    _ = it.next(); // skip argv[0]
    while (it.next()) |a| {
        if (eq(a, "--json")) {
            json = true;
            continue;
        }
        nfiles += 1;
        const src = std.Io.Dir.cwd().readFileAllocOptions(io, a, gpa, .unlimited, .of(u8), 0) catch |e| {
            std.debug.print("cannot read {s}: {s}\n", .{ a, @errorName(e) });
            continue;
        };
        try scan(gpa, .{ .path = a, .src = src, .json = json, .any_err = &any_err });
    }
    if (nfiles == 0) std.debug.print("usage: zsnag [--json] file.zig ...\n", .{});
    if (any_err) std.process.exit(1);
}
