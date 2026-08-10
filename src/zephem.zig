//! Reader over the companion zephem std map, so zsnag's advice is *derived from the
//! installed std* rather than recalled from a string literal.
//!
//! It reads zephem's TSVs directly instead of shelling out to the binary, deliberately:
//! zephem's query commands have no JSON mode, always exit 0 (a hit, a miss, and "no map at
//! all" are indistinguishable by exit code), and truncate doc/resolved text by raw byte
//! slice. The TSVs are the actual source of truth and their schema is a stated contract.
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

pub fn isDeprecated(doc: []const u8) bool {
    return doc.len >= 10 and std.ascii.startsWithIgnoreCase(doc, "deprecated");
}

/// Declared parameter count of a `fn name(a: T, b: U) R` signature — the number of non-empty
/// comma-separated segments in the FIRST parameter list. Returns null when `sig` is not a
/// function signature.
///
/// Counting commas alone is wrong: std wraps long signatures and leaves a TRAILING comma,
/// e.g. `fn parseFromSliceLeaky( comptime T: type, allocator: Allocator, s: []const u8,
/// options: ParseOptions, )` — four parameters, four commas. Empty segments are not counted.
pub fn arityOf(sig: []const u8) ?usize {
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
