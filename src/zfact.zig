//! zfact — current Zig std API fact-checker (the lookup half, in Zig).
//!
//! Resolves a std symbol to its CURRENT signature + doc comment from THIS
//! install's std source, to override an AI's stale knowledge of a fast-churning
//! language. Reads the installed std live (never a snapshot) so it is never stale.
//!
//!   zfact Io.Reader.stream        signature of stream() under Io/Reader
//!   zfact ArrayList.append        both managed + unmanaged variants
//!   zfact crypto.ChaCha20         type/const definitions
//!   zfact stream                  bare symbol, searched std-wide (noisier)
//!   zfact ArrayList.append --sig  signatures only, suppress the cluster (hook mode)
//!
//! Beyond the signature it prints a Layer-A "neighborhood" cluster so the caller
//! builds GROUPED knowledge, not just one fact: name family, doc cross-refs, and
//! efficiency notes (AssumeCapacity/Unmanaged variants, "use X instead").
//!
//! Semantic search ("find by concept") lives in the Nushell tool `zfind` — it
//! needs ollama + postgres, which are glue, not Zig-source analysis.
const std = @import("std");
const Io = std.Io;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn isIdentChar(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}
fn stripLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}
fn startsWord(s: []const u8, w: []const u8) bool {
    if (!std.mem.startsWith(u8, s, w)) return false;
    return s.len == w.len or !isIdentChar(s[w.len]);
}
fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// camelCase/PascalCase -> snake_case (ArrayList -> array_list).
fn camelToSnake(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (i != 0 and std.ascii.isUpper(c)) try out.append(a, '_');
        try out.append(a, std.ascii.toLower(c));
    }
    return out.items;
}

/// Leading camelCase token, lowercased — append/appendSlice -> "append".
fn camelBase(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var i: usize = 0;
    if (name.len > 0 and std.ascii.isAlphabetic(name[0])) {
        i = 1;
        while (i < name.len and std.ascii.isLower(name[i])) : (i += 1) {}
    }
    const tok = if (i == 0) name else name[0..i];
    const buf = try a.alloc(u8, tok.len);
    for (tok, 0..) |c, k| buf[k] = std.ascii.toLower(c);
    return buf;
}

/// If `line` declares a `pub fn|const|var NAME`, return {kind, name}, else null.
fn declParse(line: []const u8) ?struct { kind: []const u8, name: []const u8 } {
    var s = stripLeft(line);
    if (!startsWord(s, "pub")) return null;
    s = stripLeft(s[3..]);
    const kw = blk: {
        if (startsWord(s, "fn")) break :blk "fn";
        if (startsWord(s, "const")) break :blk "const";
        if (startsWord(s, "var")) break :blk "var";
        return null;
    };
    s = stripLeft(s[kw.len..]);
    var i: usize = 0;
    while (i < s.len and isIdentChar(s[i])) : (i += 1) {}
    if (i == 0) return null;
    return .{ .kind = kw, .name = s[0..i] };
}

/// If `line` declares a `pub fn|const|var NAME`, return NAME, else null.
fn declName(line: []const u8) ?[]const u8 {
    const d = declParse(line) orelse return null;
    return d.name;
}

const Hit = struct {
    rel: []const u8,
    line: usize,
    sig: []const u8,
    docs: [][]const u8,
};

const Ctx = struct {
    a: std.mem.Allocator,
    io: Io,
    std_dir: []const u8,

    fn readFile(c: Ctx, rel: []const u8) ?[]const u8 {
        const full = std.fs.path.join(c.a, &.{ c.std_dir, rel }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(c.io, full, c.a, .unlimited) catch null;
    }
};

fn splitLines(a: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |ln| try list.append(a, ln);
    return list.items;
}

/// /// doc-comment lines immediately above line index `idx`.
fn docAbove(a: std.mem.Allocator, lines: [][]const u8, idx: usize) ![][]const u8 {
    var docs: std.ArrayList([]const u8) = .empty;
    var j: isize = @as(isize, @intCast(idx)) - 1;
    while (j >= 0) : (j -= 1) {
        const ln = lines[@intCast(j)];
        if (std.mem.startsWith(u8, stripLeft(ln), "///")) {
            try docs.insert(a, 0, std.mem.trim(u8, ln, " \t\r"));
        } else break;
    }
    return docs.items;
}

/// Walk the std dir once, returning every .zig path relative to it.
fn allZig(c: Ctx) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(c.io, c.std_dir, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(c.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".zig"))
            try list.append(c.a, try c.a.dupe(u8, entry.path));
    }
    return list.items;
}

/// Does relpath name this namespace part? (segment or basename stem, snake too)
fn relMatchesPart(c: Ctx, rel: []const u8, part: []const u8) bool {
    const snake = camelToSnake(c.a, part) catch part;
    var it = std.mem.splitScalar(u8, rel, std.fs.path.sep);
    while (it.next()) |seg| {
        const stem = if (std.mem.endsWith(u8, seg, ".zig")) seg[0 .. seg.len - 4] else seg;
        if (eqIgnoreCase(stem, part) or eqIgnoreCase(stem, snake)) return true;
    }
    return false;
}

fn candidateFiles(c: Ctx, all: [][]const u8, ns: [][]const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (all) |rel| {
        for (ns) |part| {
            if (relMatchesPart(c, rel, part)) {
                try list.append(c.a, rel);
                break;
            }
        }
    }
    return list.items;
}

fn search(c: Ctx, files: []const []const u8, sym: []const u8, fuzzy: bool) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    for (files) |rel| {
        const src = c.readFile(rel) orelse continue;
        const lines = try splitLines(c.a, src);
        for (lines, 0..) |line, i| {
            const name = declName(line) orelse continue;
            const match = if (fuzzy) contains(name, sym) else eq(name, sym);
            if (match) try hits.append(c.a, .{
                .rel = rel,
                .line = i + 1,
                .sig = std.mem.trim(u8, line, " \t\r"),
                .docs = try docAbove(c.a, lines, i),
            });
        }
    }
    return hits.items;
}

const FindResult = struct { hits: []Hit, fuzzy: bool };

fn findIn(c: Ctx, files: []const []const u8, sym: []const u8) !FindResult {
    var h = try search(c, files, sym, false);
    if (h.len > 0) return .{ .hits = h, .fuzzy = false };
    h = try search(c, files, sym, true);
    return .{ .hits = h, .fuzzy = h.len > 0 };
}

// --- one-hop re-export / alias resolution ---------------------------------

const ALIAS_SKIP = [_][]const u8{ "error", "struct", "enum", "union", "opaque", "extern", "packed" };

const Reexport = struct { kind: []const u8, hit: Hit };

/// Extract @import("X").Member from a signature, if present.
fn parseImport(sig: []const u8) ?struct { path: []const u8, member: ?[]const u8 } {
    const at = std.mem.indexOf(u8, sig, "@import(") orelse return null;
    var s = sig[at + "@import(".len ..];
    s = stripLeft(s);
    if (s.len == 0 or s[0] != '"') return null;
    s = s[1..];
    const end = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const path = s[0..end];
    s = s[end + 1 ..];
    // optional ) . Member
    const rp = std.mem.indexOfScalar(u8, s, ')') orelse return .{ .path = path, .member = null };
    s = stripLeft(s[rp + 1 ..]);
    if (s.len == 0 or s[0] != '.') return .{ .path = path, .member = null };
    s = stripLeft(s[1..]);
    var i: usize = 0;
    while (i < s.len and isIdentChar(s[i])) : (i += 1) {}
    if (i == 0) return .{ .path = path, .member = null };
    return .{ .path = path, .member = s[0..i] };
}

/// `pub const X = Base;` alias target (Base), skipping type keywords.
fn parseAlias(sig: []const u8) ?[]const u8 {
    const name = declName(sig) orelse return null;
    // find '=' then the first identifier after it
    const eqi = std.mem.indexOfScalar(u8, sig, '=') orelse return null;
    _ = name;
    var s = stripLeft(sig[eqi + 1 ..]);
    var i: usize = 0;
    while (i < s.len and isIdentChar(s[i])) : (i += 1) {}
    if (i == 0) return null;
    const base = s[0..i];
    for (ALIAS_SKIP) |k| if (eq(base, k)) return null;
    return base;
}

fn resolveReexport(c: Ctx, sig: []const u8, rel_file: []const u8) !?Reexport {
    if (parseImport(sig)) |imp| {
        // resolve import path relative to the importing file's dir, then std root
        const dir = std.fs.path.dirname(rel_file) orelse "";
        const cand1 = try std.fs.path.join(c.a, &.{ dir, imp.path });
        const target = if (c.readFile(cand1) != null) cand1 else imp.path;
        if (imp.member) |m| {
            const h = try search(c, &.{target}, m, false);
            if (h.len > 0) return .{ .kind = "via @import", .hit = h[0] };
            return null;
        }
        return .{ .kind = "namespace file", .hit = .{
            .rel = target,
            .line = 1,
            .sig = try std.fmt.allocPrint(c.a, "(whole-file namespace -> {s})", .{target}),
            .docs = &.{},
        } };
    }
    if (parseAlias(sig)) |base| {
        const h = try search(c, &.{rel_file}, base, false);
        if (h.len > 0) return .{ .kind = try std.fmt.allocPrint(c.a, "alias of {s}", .{base}), .hit = h[0] };
    }
    return null;
}

// --- Layer A neighborhood --------------------------------------------------

fn filePubNames(c: Ctx, rel: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const src = c.readFile(rel) orelse return names.items;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (declName(line)) |n| try names.append(c.a, n);
    }
    return names.items;
}

const Neighborhood = struct { family: [][]const u8, see: [][]const u8, eff: [][]const u8 };

fn already(list: std.ArrayList([]const u8), s: []const u8) bool {
    for (list.items) |x| if (eq(x, s)) return true;
    return false;
}

fn neighborhood(c: Ctx, hits: []Hit, sym: []const u8) !Neighborhood {
    const base = try camelBase(c.a, sym);

    // unique hit files
    var files: std.ArrayList([]const u8) = .empty;
    for (hits) |h| if (!already(files, h.rel)) try files.append(c.a, h.rel);

    // family: pub names in those files sharing the camel base
    var fam: std.ArrayList([]const u8) = .empty;
    if (base.len >= 3) {
        for (files.items) |rel| {
            for (try filePubNames(c, rel)) |n| {
                if (!eq(n, sym) and eq(try camelBase(c.a, n), base) and !already(fam, n))
                    try fam.append(c.a, n);
            }
        }
    }
    std.mem.sort([]const u8, fam.items, {}, lessStr);

    // see-also: backtick idents in doc comments
    var see: std.ArrayList([]const u8) = .empty;
    for (hits) |h| {
        for (h.docs) |d| {
            var rest = d;
            while (std.mem.indexOfScalar(u8, rest, '`')) |o| {
                rest = rest[o + 1 ..];
                const close = std.mem.indexOfScalar(u8, rest, '`') orelse break;
                const ident = rest[0..close];
                rest = rest[close + 1 ..];
                if (ident.len > 0 and (std.ascii.isAlphabetic(ident[0]) or ident[0] == '_') and
                    isAllIdent(ident) and !eq(ident, sym) and !already(see, ident))
                    try see.append(c.a, ident);
            }
        }
    }

    // efficiency notes
    var eff: std.ArrayList([]const u8) = .empty;
    for (fam.items) |n| {
        if (contains(n, "AssumeCapacity"))
            try addEff(c, &eff, try std.fmt.allocPrint(c.a, "{s} — skips the capacity/alloc check (faster, you guarantee room)", .{n}))
        else if (contains(n, "Unmanaged"))
            try addEff(c, &eff, try std.fmt.allocPrint(c.a, "{s} — caller passes the allocator (no stored allocator)", .{n}))
        else if (contains(n, "Comptime"))
            try addEff(c, &eff, try std.fmt.allocPrint(c.a, "{s} — comptime-evaluated variant", .{n}));
    }
    for (hits) |h| {
        for (h.docs) |d| {
            const low = try std.ascii.allocLowerString(c.a, d);
            if (contains(low, "instead") or contains(low, "asserts"))
                try addEff(c, &eff, std.mem.trim(u8, std.mem.trimStart(u8, d, "/ "), " \t\r"));
        }
    }
    const eff_capped = if (eff.items.len > 6) eff.items[0..6] else eff.items;
    return .{ .family = fam.items, .see = see.items, .eff = eff_capped };
}

fn addEff(c: Ctx, eff: *std.ArrayList([]const u8), s: []const u8) !void {
    for (eff.items) |x| if (eq(x, s)) return;
    try eff.append(c.a, s);
}
fn isAllIdent(s: []const u8) bool {
    for (s) |ch| if (!isIdentChar(ch)) return false;
    return true;
}
fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// --- std dir discovery -----------------------------------------------------

fn stdDir(c_a: std.mem.Allocator, io: Io, env: *std.process.Environ.Map) ![]const u8 {
    if (env.get("ZFACT_STD")) |d| return d;
    const r = std.process.run(c_a, io, .{ .argv = &.{ "zig", "env" } }) catch
        return "/usr/lib/zig/std";
    // parse  .std_dir = "..."
    if (std.mem.indexOf(u8, r.stdout, ".std_dir")) |p| {
        var s = r.stdout[p..];
        const q1 = std.mem.indexOfScalar(u8, s, '"') orelse return "/usr/lib/zig/std";
        s = s[q1 + 1 ..];
        const q2 = std.mem.indexOfScalar(u8, s, '"') orelse return "/usr/lib/zig/std";
        return s[0..q2];
    }
    return "/usr/lib/zig/std";
}

// --- dump mode (feeds the Nushell indexer) ---------------------------------

fn jsonEscape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => try out.append(a, ch),
    };
    return out.items;
}

/// Multi-line signature: join lines from `i` until one has '{' or ends ';',
/// then cut at the first '{'. Multi-line decls become one signature string.
fn sigBlock(a: std.mem.Allocator, lines: [][]const u8, i: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var j = i;
    const end = @min(i + 8, lines.len);
    while (j < end) : (j += 1) {
        const t = std.mem.trim(u8, lines[j], " \t\r");
        if (j != i) try buf.append(a, ' ');
        try buf.appendSlice(a, t);
        if (contains(t, "{") or std.mem.endsWith(u8, t, ";")) break;
    }
    var s = buf.items;
    if (std.mem.indexOfScalar(u8, s, '{')) |b| s = s[0..b];
    return std.mem.trim(u8, s, " \t\r");
}

/// Emit one JSON object per documented pub decl (JSONL) for the indexer.
fn dumpIndex(c: Ctx, out: *Io.Writer, include_all: bool, module: ?[]const u8) !void {
    const all = try allZig(c);
    for (all) |rel| {
        if (module) |m| if (!contains(rel, m)) continue;
        const src = c.readFile(rel) orelse continue;
        const lines = try splitLines(c.a, src);
        const dir = std.fs.path.dirname(rel) orelse "";
        const ns = try c.a.dupe(u8, dir);
        for (ns) |*ch| if (ch.* == std.fs.path.sep) {
            ch.* = '.';
        };
        for (lines, 0..) |line, i| {
            const d = declParse(line) orelse continue;
            const docs = try docAbove(c.a, lines, i);
            var doc: std.ArrayList(u8) = .empty;
            for (docs, 0..) |dl, k| {
                if (k != 0) try doc.append(c.a, ' ');
                try doc.appendSlice(c.a, std.mem.trim(u8, std.mem.trimStart(u8, dl, "/ "), " \t\r"));
            }
            if (doc.items.len == 0 and !include_all) continue;
            const sig = try sigBlock(c.a, lines, i);
            try out.print(
                "{{\"symbol\":\"{s}\",\"namespace\":\"{s}\",\"kind\":\"{s}\",\"signature\":\"{s}\",\"doc\":\"{s}\",\"file\":\"{s}\",\"line\":{d}}}\n",
                .{
                    try jsonEscape(c.a, d.name),  try jsonEscape(c.a, ns),
                    d.kind,                       try jsonEscape(c.a, sig),
                    try jsonEscape(c.a, doc.items), try jsonEscape(c.a, rel),
                    i + 1,
                },
            );
        }
    }
}

// --- main ------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var sig_only = false;
    var dump = false;
    var dump_all = false;
    var module: ?[]const u8 = null;
    var query: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(a);
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];
        if (eq(arg, "--sig") or eq(arg, "-s")) {
            sig_only = true;
        } else if (eq(arg, "--dump")) {
            dump = true;
        } else if (eq(arg, "--all")) {
            dump_all = true;
        } else if (eq(arg, "--module")) {
            if (ai + 1 < args.len) {
                ai += 1;
                module = args[ai];
            }
        } else if (eq(arg, "find")) {
            try out.print("semantic search moved to the Nushell tool `zfind` (needs ollama + postgres).\n  zfind \"natural language description\" [--limit N]\n", .{});
            try out.flush();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-") and query == null) {
            query = arg;
        }
    }

    const sd = try stdDir(a, io, init.environ_map);
    const c = Ctx{ .a = a, .io = io, .std_dir = sd };

    if (dump) {
        dumpIndex(c, out, dump_all, module) catch {}; // ignore EPIPE (| head)
        out.flush() catch {};
        return;
    }

    const q = query orelse {
        try out.print("usage: zfact <Namespace.Symbol> [--sig]\n  e.g. zfact Io.Reader.stream | zfact ArrayList.append\n", .{});
        try out.flush();
        return;
    };

    // split query into namespace parts + symbol
    var parts: std.ArrayList([]const u8) = .empty;
    var pit = std.mem.splitScalar(u8, q, '.');
    while (pit.next()) |p| try parts.append(a, p);
    const sym = parts.items[parts.items.len - 1];
    const ns = parts.items[0 .. parts.items.len - 1];

    const all = try allZig(c);
    const scoped = if (ns.len > 0) try candidateFiles(c, all, ns) else &[_][]const u8{};

    var res = try findIn(c, if (scoped.len > 0) scoped else all, sym);
    var widened = false;
    if (res.hits.len == 0 and scoped.len > 0) {
        res = try findIn(c, all, sym);
        widened = res.hits.len > 0;
    }

    const hits = res.hits;
    // rank: files whose path mentions a namespace part first, then by path/line
    const Sorter = struct {
        ns: [][]const u8,
        fn score(self: @This(), h: Hit) usize {
            var n: usize = 0;
            for (self.ns) |p| if (contains(h.rel, p)) {
                n += 1;
            };
            return n;
        }
        fn lessThan(self: @This(), x: Hit, y: Hit) bool {
            const sx = self.score(x);
            const sy = self.score(y);
            if (sx != sy) return sx > sy;
            const c0 = std.mem.order(u8, x.rel, y.rel);
            if (c0 != .eq) return c0 == .lt;
            return x.line < y.line;
        }
    };
    std.mem.sort(Hit, hits, Sorter{ .ns = ns }, Sorter.lessThan);

    if (hits.len == 0) {
        if (ns.len > 0) {
            try out.print("no `pub` decl named '{s}' found (scoped to {s}) in {s}\n", .{ sym, q, sd });
        } else {
            try out.print("no `pub` decl named '{s}' found (std-wide) in {s}\n", .{ sym, sd });
        }
        try out.flush();
        std.process.exit(1);
    }

    // header + notes
    try out.print("# {s}  —  {d} match(es) in {s}", .{ q, hits.len, sd });
    if (widened or res.fuzzy) {
        try out.print("  [", .{});
        var first = true;
        if (widened) {
            try out.print("NOT in that namespace — found std-wide (your namespace may be stale)", .{});
            first = false;
        }
        if (res.fuzzy) {
            if (!first) try out.print("; ", .{});
            try out.print("fuzzy: declared name contains the query", .{});
        }
        try out.print("]", .{});
    }
    try out.print("\n\n", .{});

    for (hits) |h| {
        for (h.docs) |d| try out.print("  {s}\n", .{d});
        try out.print("  {s}\n", .{h.sig});
        try out.print("      └─ {s}:{d}\n", .{ h.rel, h.line });
        if (try resolveReexport(c, h.sig, h.rel)) |rx| {
            try out.print("      → {s}:\n", .{rx.kind});
            for (rx.hit.docs) |d| try out.print("          {s}\n", .{d});
            try out.print("          {s}\n", .{rx.hit.sig});
            try out.print("            └─ {s}:{d}\n", .{ rx.hit.rel, rx.hit.line });
        }
        try out.print("\n", .{});
    }

    if (!sig_only) {
        const nb = try neighborhood(c, hits, sym);
        if (nb.family.len > 0 or nb.see.len > 0 or nb.eff.len > 0)
            try out.print("  ── neighborhood ──\n", .{});
        if (nb.family.len > 0) {
            try out.print("  ◆ family:   ", .{});
            const shown = if (nb.family.len > 16) nb.family[0..16] else nb.family;
            for (shown, 0..) |n, i| {
                if (i != 0) try out.print(" · ", .{});
                try out.print("{s}", .{n});
            }
            if (nb.family.len > 16) try out.print("  (+{d} more)", .{nb.family.len - 16});
            try out.print("\n", .{});
        }
        if (nb.see.len > 0) {
            try out.print("  ◆ see also: ", .{});
            const shown = if (nb.see.len > 12) nb.see[0..12] else nb.see;
            for (shown, 0..) |n, i| {
                if (i != 0) try out.print(" · ", .{});
                try out.print("`{s}`", .{n});
            }
            try out.print("\n", .{});
        }
        if (nb.eff.len > 0) {
            try out.print("  ◆ notes:\n", .{});
            for (nb.eff) |e| try out.print("      - {s}\n", .{e});
        }
    }

    try out.flush();
}
