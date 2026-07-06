//! zlook — fast structured lookup over the denormalized zephem "lookup" table.
//!
//! The discovery half of zcanon: keyword search over the WHOLE mapped std in one
//! shot — name · path · as-written signature · `///` doc · resolved type/error-set
//! · canonical alias — all pre-joined into one row per decl by `nu/build_lookup.nu`.
//! Every term must appear (case-insensitive, AND) somewhere in the row; matches are
//! ranked name-first and the parsed columns are printed, not the raw line.
//!
//!   zlook parse int                decls whose row contains BOTH "parse" and "int"
//!   zlook "constant time"          a multi-word term is just two terms here
//!   zlook OutOfMemory              finds fns by RESOLVED behavior (error set), not just name
//!   zlook parse int --limit 20     cap the printed hits (default 12)
//!
//! The first-byte scan is SIMD (`@Vector(32, u8)` → AVX2 `vpcmpeqb`), so it greps the
//! ~2 MB table in single-digit ms. Reads `$ZEPHEM_DATA/lookup.tsv` (default
//! ~/projects/zephem/data/std/lookup.tsv); regenerate it with `nu/build_lookup.nu`.
//! Confirm the CURRENT signature of a chosen name with `zfact <name>` (reads live std).
const std = @import("std");
const Io = std.Io;
const V = @Vector(32, u8);

// lookup.tsv columns (built by nu/build_lookup.nu), tab-separated:
//   0 path · 1 depth · 2 kind · 3 name · 4 n_children · 5 detail
//   6 sig  · 7 doc   · 8 rkind · 9 rdetail · 10 canon
const COL_PATH = 0;
const COL_KIND = 2;
const COL_NAME = 3;
const COL_SIG = 6;
const COL_DOC = 7;
const COL_RDETAIL = 9;

inline fn lo(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
inline fn matchAt(hay: []const u8, pos: usize, needle: []const u8) bool {
    var j: usize = 1;
    while (j < needle.len and lo(hay[pos + j]) == needle[j]) j += 1;
    return j == needle.len;
}

/// Case-insensitive substring (needle pre-lowercased). SIMD first-byte scan: load
/// 32 bytes, compare to both cases of needle[0] (vpcmpeqb), verify each hit.
fn ciContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    const f = needle[0];
    const fu: u8 = if (f >= 'a' and f <= 'z') f - 32 else f;
    const last = hay.len - needle.len;
    const sl: V = @splat(f);
    const su: V = @splat(fu);
    var i: usize = 0;
    while (i + 32 <= hay.len) : (i += 32) {
        const chunk: V = hay[i..][0..32].*;
        const ml: u32 = @bitCast(chunk == sl);
        const mu: u32 = @bitCast(chunk == su);
        var mask: u32 = ml | mu;
        while (mask != 0) {
            const pos = i + @ctz(mask);
            if (pos <= last and matchAt(hay, pos, needle)) return true;
            mask &= mask - 1;
        }
    }
    while (i <= last) : (i += 1) {
        if (lo(hay[i]) == f and matchAt(hay, i, needle)) return true;
    }
    return false;
}

fn allContain(hay: []const u8, terms: []const []const u8) bool {
    for (terms) |t| if (!ciContains(hay, t)) return false;
    return true;
}

/// The Nth tab-separated field of a row (or "" if absent).
fn field(line: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) if (i == n) return f;
    return "";
}

const Hit = struct { line: []const u8, rank: u8, plen: usize };

fn lessThan(_: void, a: Hit, b: Hit) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    return a.plen < b.plen;
}

fn truncField(s: []const u8, max: usize) []const u8 {
    return if (s.len > max) s[0..max] else s;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var obuf: [1 << 16]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    // ---- args: terms + --limit N ----
    var terms_raw: std.ArrayList([]const u8) = .empty;
    var limit: usize = 12;
    const args = try init.minimal.args.toSlice(a);
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];
        if ((std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) and ai + 1 < args.len) {
            ai += 1;
            limit = std.fmt.parseInt(usize, args[ai], 10) catch limit;
        } else {
            try terms_raw.append(a, arg);
        }
    }
    if (terms_raw.items.len == 0) {
        try out.print("usage: zlook <term...> [--limit N]   keyword search over the zephem lookup table\n", .{});
        try out.flush();
        return;
    }
    // lowercase the terms once (the haystack is matched case-insensitively in place).
    const terms = try a.alloc([]const u8, terms_raw.items.len);
    for (terms_raw.items, 0..) |t, i| {
        const d = try a.alloc(u8, t.len);
        for (t, 0..) |c, k| d[k] = lo(c);
        terms[i] = d;
    }

    // ---- locate lookup.tsv: $ZCANON_LOOKUP, else ~/.config/zcanon/lookup.tsv ----
    const path = if (init.environ_map.get("ZCANON_LOOKUP")) |p|
        p
    else if (init.environ_map.get("HOME")) |h|
        try std.fs.path.join(a, &.{ h, ".config", "zcanon", "lookup.tsv" })
    else
        "lookup.tsv";

    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch {
        try out.print("zlook: no lookup table at {s}\n  build it: nu ~/projects/zcanon/nu/build_lookup.nu  (needs zephem's data/std)\n", .{path});
        try out.flush();
        return;
    };

    // ---- scan: every term must appear in the row; rank name-first ----
    var hits: std.ArrayList(Hit) = .empty;
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    _ = it.next(); // header
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (!allContain(line, terms)) continue;
        total += 1;
        const name = field(line, COL_NAME);
        const p = field(line, COL_PATH);
        const rank: u8 = if (allContain(name, terms)) 0 else if (allContain(p, terms)) 1 else 2;
        try hits.append(a, .{ .line = line, .rank = rank, .plen = p.len });
    }
    if (total == 0) {
        try out.print("no lookup entry matches: {s}\n", .{try std.mem.join(a, " ", terms_raw.items)});
        try out.flush();
        return;
    }
    std.mem.sort(Hit, hits.items, {}, lessThan);

    const shown = @min(limit, hits.items.len);
    try out.print("# zlook: {s}  ({d} shown of {d} hits)\n\n", .{ try std.mem.join(a, " ", terms_raw.items), shown, total });
    for (hits.items[0..shown]) |h| {
        try out.print("  {s}  ({s})\n", .{ field(h.line, COL_PATH), field(h.line, COL_KIND) });
        const sig = field(h.line, COL_SIG);
        const res = field(h.line, COL_RDETAIL);
        const doc = field(h.line, COL_DOC);
        if (sig.len > 0) try out.print("      {s}\n", .{sig});
        if (res.len > 0) try out.print("      → {s}\n", .{truncField(res, 140)});
        if (doc.len > 0) try out.print("      ⌁ {s}\n", .{truncField(doc, 120)});
    }
    try out.print("\n(snapshot — confirm the CURRENT signature with: zfact <name>)\n", .{});
    try out.flush();
}
