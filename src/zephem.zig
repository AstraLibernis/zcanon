//! Reader over the companion zephem std map, so zsnag's advice is *derived from the
//! installed std* rather than recalled from a string literal.
//!
//! It reads zephem's TSVs directly instead of shelling out to the binary, deliberately.
//! The original reasons were: no JSON mode, every query exited 0, and lossy byte-slice
//! truncation. The exit codes and truncation were FIXED upstream on 2026-08-10 (0 hit /
//! 1 miss / 2 usage / 3 unavailable; error sets emitted whole) — but the TSVs remain the
//! actual source of truth with a stated schema contract, there is still no JSON mode, and
//! an in-process read costs nothing per query, so direct reads remain the right choice.
//!
//! NEVER shell out to `zephem <sub>` with pass-through flags: unknown flags fall through to
//! the subcommand's action, so `zephem std --help` performs a full map regeneration and
//! `zephem depth --help` starts a multi-minute sweep (ledger B9).
const std = @import("std");
const vars = @import("vars.zig");

/// Column indices in `lookup.tsv`. Documented contract, mirrored from zephem's src/lookup.zig.
const Col = struct {
    const path = 0;
    const kind = 2;
    const sig = 6;
    const doc = 7;
    const rdetail = 9;
    const canon = 10;
    const vis = 14;
    const count = 16;
};

pub const Entry = struct {
    path: []const u8,
    kind: []const u8,
    sig: []const u8,
    doc: []const u8,
    rdetail: []const u8,
    canon: []const u8,
    vis: []const u8,

    /// `[priv]` decls exist in the map but are not callable at the shown path.
    pub fn isPublic(e: Entry) bool {
        return !std.mem.eql(u8, e.vis, "priv");
    }
};

pub const LoadError = error{
    NoLookupTable,
    HomeNotSet,
} || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError;

/// Where zephem keeps the baked lookup table, using zephem's own precedence.
pub fn lookupPath(c: vars.Ctx) ![]u8 {
    if (c.get("ZEPHEM_LOOKUP")) |p| return c.gpa.dupe(u8, p);
    const home = c.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(c.gpa, &.{ home, ".config", "zephem", "lookup.tsv" });
}

/// zephem's dataset directory, for the PINNED stamp.
pub fn dataDir(c: vars.Ctx) !?[]u8 {
    if (c.get("ZEPHEM_DATA")) |p| return try c.gpa.dupe(u8, p);
    const home = c.get("ZEPHEM_HOME") orelse return null;
    return try std.fs.path.join(c.gpa, &.{ home, "data", "std" });
}

pub const Map = struct {
    gpa: std.mem.Allocator,
    text: []u8,
    index: std.StringHashMapUnmanaged(Entry),

    pub fn deinit(m: *Map) void {
        m.index.deinit(m.gpa);
        m.gpa.free(m.text);
    }

    pub fn get(m: Map, path: []const u8) ?Entry {
        return m.index.get(path);
    }

    pub fn count(m: Map) usize {
        return m.index.count();
    }
};

/// Load and index the lookup table. Fails loudly with zephem's own remedy if it is absent —
/// there is deliberately no fallback to model memory, per zephem's stated design.
pub fn load(c: vars.Ctx) LoadError!Map {
    const path = try lookupPath(c);
    defer c.gpa.free(path);

    const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return error.NoLookupTable,
        else => return e,
    };
    errdefer c.gpa.free(text);
    return parse(c.gpa, text);
}

/// Index an already-read lookup table. Split out from `load` so the parsing can be tested
/// against a synthetic table without depending on the ambient environment.
/// Takes ownership of `text`; entries slice into it.
pub fn parse(gpa: std.mem.Allocator, text: []u8) !Map {
    var index: std.StringHashMapUnmanaged(Entry) = .empty;
    errdefer index.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (first) {
            first = false;
            if (std.mem.startsWith(u8, line, "path\t")) continue;
        }
        var f: [Col.count][]const u8 = @splat("");
        var it = std.mem.splitScalar(u8, line, '\t');
        var n: usize = 0;
        while (it.next()) |field| : (n += 1) {
            if (n >= Col.count) break;
            f[n] = field;
        }
        if (n < Col.count) continue;
        try index.put(gpa, f[Col.path], .{
            .path = f[Col.path],
            .kind = f[Col.kind],
            .sig = f[Col.sig],
            .doc = f[Col.doc],
            .rdetail = f[Col.rdetail],
            .canon = f[Col.canon],
            .vis = f[Col.vis],
        });
    }
    return .{ .gpa = gpa, .text = text, .index = index };
}

pub const remedy =
    "the zephem lookup table is missing — build it once with `zephem lookup` " ++
    "(and `zephem std` first if the map itself was never generated).";

/// Compare zephem's PINNED stamp against the running zig. Returns a warning to surface, or
/// null when they agree. Never silently downgrades to guessing.
pub fn staleness(c: vars.Ctx, zig_version: []const u8) !?[]const u8 {
    const dir = (try dataDir(c)) orelse return null;
    defer c.gpa.free(dir);
    const pinned_path = try std.fs.path.join(c.gpa, &.{ dir, "PINNED" });
    defer c.gpa.free(pinned_path);

    const text = std.Io.Dir.cwd().readFileAlloc(c.io, pinned_path, c.gpa, .unlimited) catch return null;
    defer c.gpa.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return null;
    const pinned = std.mem.trim(u8, std.mem.trimStart(u8, first, "zig "), " \t\r");
    if (std.mem.eql(u8, pinned, zig_version)) return null;

    return try std.fmt.allocPrint(
        c.gpa,
        "⚠ the zephem map is pinned to zig {s} but you are on {s} — map-derived findings are " ++
            "UNVERIFIED until you regenerate: `zephem std && zephem lookup`.",
        .{ pinned, zig_version },
    );
}

// ---- derived facts --------------------------------------------------------

/// Extract the replacement named in a deprecation doc. zephem records these verbatim from
/// std's own `///` comments, which use several phrasings:
///   "Deprecated; use `array_list.Aligned`."   "Deprecated, use `addFilePath`."
///   "Deprecated, see `getPath3`."
/// Returns the backticked target, or null when the doc names none.
pub fn deprecationOf(doc: []const u8) ?[]const u8 {
    if (doc.len < 10) return null;
    if (!std.ascii.startsWithIgnoreCase(doc, "deprecated")) return null;
    const open = std.mem.findScalar(u8, doc, '`') orelse return null;
    const rest = doc[open + 1 ..];
    const close = std.mem.findScalar(u8, rest, '`') orelse return null;
    const name = rest[0..close];
    return if (name.len == 0) null else name;
}

/// Kinds that can legitimately have members addressed by a further `.name`.
/// Everything else (`const`, `alias`, `tag`, `field`, `fn`) denotes a VALUE, and following a
/// dotted path through a value needs type inference the map cannot give us.
pub fn isContainerKind(kind: []const u8) bool {
    const containers = [_][]const u8{ "ns", "struct", "enum", "union", "opaque" };
    for (containers) |c| if (std.mem.eql(u8, kind, c)) return true;
    return false;
}

/// Walk back to the longest proper prefix of `path` that IS in the map, and return its kind.
/// Null when no prefix resolves at all.
///
/// This is what separates "you invented a std function" from "you addressed a member of a
/// value". `std.mem.copyForwards2` → longest prefix `std.mem` is `ns`, so the missing member
/// is genuinely suspicious. `std.Io.Clock.real.now` → longest prefix `std.Io.Clock.real` is a
/// `tag`, so `.now` is a method on the value's type and the map simply cannot follow it.
/// Without this distinction R013 fired 219 times on Zig's own std, essentially all wrong.
pub fn longestPrefixKind(m: Map, path: []const u8) ?[]const u8 {
    var end = path.len;
    while (std.mem.findScalarLast(u8, path[0..end], '.')) |dot| {
        if (m.get(path[0..dot])) |e| return e.kind;
        end = dot;
    }
    return null;
}

pub fn isDeprecated(doc: []const u8) bool {
    return doc.len >= 10 and std.ascii.startsWithIgnoreCase(doc, "deprecated");
}

/// Strip inline `///` parameter-doc prose from a signature.
///
/// This is the rule zephem itself now applies at display time, ported (zcanon cannot import
/// zephem as a module). It replaced a cruder in-place guess here that an adversarial audit
/// proved wrong on 17 of the 68 affected signatures — `std.Io.Dir.readFileAlloc` (5 params)
/// counted as 3, `AstGen.GenZir.addParam` (7) as 2, and 8 more fell out as "unbalanced".
/// The rule: on `///` at depth d, take the first `:` at depth d not followed by `//` (a URL)
/// with no further `///` before its segment ends; walk back over the identifier and any
/// `comptime`/`noalias` qualifiers. Validated 68/68 against ground truth read from the
/// compiler's own source.
fn stripParamDocs(gpa: std.mem.Allocator, sig: []const u8) ?[]u8 {
    if (std.mem.find(u8, sig, "///") == null) return null; // clean — caller uses sig as-is
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < sig.len) {
        if (i + 2 < sig.len and sig[i] == '/' and sig[i + 1] == '/' and sig[i + 2] == '/') {
            if (docParamStart(sig, i, depth)) |ps| {
                i = ps;
                continue;
            }
        }
        switch (sig[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => {},
        }
        out.append(gpa, sig[i]) catch {
            out.deinit(gpa);
            return null;
        };
        i += 1;
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

fn docParamStart(s: []const u8, doc_start: usize, d: usize) ?usize {
    var dep = d;
    var k = doc_start + 3;
    while (k < s.len) : (k += 1) {
        const ch = s[k];
        if (ch == ':' and dep == d and !(k + 2 < s.len and s[k + 1] == '/' and s[k + 2] == '/')) {
            var dep2 = dep;
            var m = k + 1;
            var seg_end = s.len;
            while (m < s.len) : (m += 1) {
                switch (s[m]) {
                    '(', '[', '{' => dep2 += 1,
                    ')', ']', '}' => {
                        if (dep2 == d) {
                            seg_end = m;
                            break;
                        }
                        dep2 -= 1;
                    },
                    ',' => if (dep2 == d) {
                        seg_end = m;
                        break;
                    },
                    else => {},
                }
            }
            if (std.mem.find(u8, s[k..seg_end], "///") == null) return backToParam(s, k);
        }
        switch (ch) {
            '(', '[', '{' => dep += 1,
            ')', ']', '}' => dep -|= 1,
            else => {},
        }
    }
    return null;
}

fn backToParam(s: []const u8, colon: usize) ?usize {
    var e = colon;
    while (e > 0 and s[e - 1] == ' ') e -= 1;
    var st = e;
    while (st > 0 and (std.ascii.isAlphanumeric(s[st - 1]) or s[st - 1] == '_')) st -= 1;
    if (st == e) return null;
    while (true) {
        var pp = st;
        while (pp > 0 and s[pp - 1] == ' ') pp -= 1;
        var q = pp;
        while (q > 0 and (std.ascii.isAlphanumeric(s[q - 1]) or s[q - 1] == '_')) q -= 1;
        const w = s[q..pp];
        if (q < pp and (std.mem.eql(u8, w, "comptime") or std.mem.eql(u8, w, "noalias"))) st = q else break;
    }
    return st;
}

/// Declared parameter count of a `fn name(a: T, b: U) R` signature — the number of non-empty
/// comma-separated segments in the FIRST parameter list. Returns null when `sig` is not a
/// function signature.
///
/// Prose is stripped FIRST (see stripParamDocs): counting through it is how a two-parameter
/// function read as three (B16), and the in-place skip that replaced it was wrong on 17 of 68.
pub fn arityOf(gpa: std.mem.Allocator, sig: []const u8) ?usize {
    if (stripParamDocs(gpa, sig)) |clean| {
        defer gpa.free(clean);
        return arityOfClean(clean);
    }
    return arityOfClean(sig);
}

fn arityOfClean(sig: []const u8) ?usize {
    const open = std.mem.findScalar(u8, sig, '(') orelse return null;
    var depth: usize = 0;
    var params: usize = 0;
    var seen: bool = false; // content in the current segment
    for (sig[open..]) |ch| {
        switch (ch) {
            '(', '[', '{' => {
                depth += 1;
                if (depth > 1) seen = true;
            },
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return params + @intFromBool(seen);
                seen = true;
            },
            ',' => if (depth == 1) {
                params += @intFromBool(seen);
                seen = false;
            } else {
                seen = true;
            },
            ' ', '\t', '\n', '\r' => {},
            else => if (depth >= 1) {
                seen = true;
            },
        }
    }
    return null; // unbalanced
}
