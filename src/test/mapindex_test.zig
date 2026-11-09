// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const zcanon = @import("zcanon");
const zephem = zcanon.zephem;
const mapindex = zcanon.mapindex;

/// A 16-column row: path, then `kind` in column 2 and a marker in `sig` (column 6) so tests
/// can tell duplicate rows apart.
fn row(comptime path: []const u8, comptime marker: []const u8) []const u8 {
    return path ++ "\t-\tfn\t-\t-\t-\t" ++ marker ++ "\t-\t-\t-\t-\t-\t-\t-\tpub\t-\n";
}

/// Every quirk `zephem.index` handles: the header, empty lines, a duplicate path (last row
/// wins), a short row, a row with no tab, paths that prefix each other, and a header-shaped
/// line that is not first (an ordinary row then).
const table =
    "path\tx\tkind\n" ++
    row("std.mem", "ns") ++
    "\n" ++
    row("std.mem.eql", "first") ++
    "std.mem.short\tonly\tthree\n" ++
    "no-tab-at-all\n" ++
    row("std.mem.eqlx", "other") ++
    row("std.mem.eql", "second") ++
    row("path", "late-header-shape") ++
    "\n\n" ++
    row("std.fs", "last");

const asked = [_][]const u8{
    "std.mem", "std.mem.eql", "std.mem.eqlx", "std.mem.short", "no-tab-at-all",
    "path",    "std.fs",      "std.missing",  "std.me",        "",
};

fn keysOf(gpa: std.mem.Allocator, paths: []const []const u8) !zephem.Keys {
    var keys: zephem.Keys = .empty;
    errdefer zephem.freeKeys(gpa, &keys);
    for (paths) |p| try zephem.addKey(gpa, &keys, p);
    return keys;
}

fn zero(_: []const u8) u64 {
    return 0;
}

fn byLength(s: []const u8) u64 {
    return s.len;
}

/// The index must answer exactly what the full scan answers, for every asked path.
fn expectSameAsScan(text: []const u8, paths: []const []const u8, comptime h: mapindex.HashFn) !void {
    const gpa = testing.allocator;
    var keys = try keysOf(gpa, paths);
    defer zephem.freeKeys(gpa, &keys);

    var scanned = try zephem.parse(gpa, try gpa.dupe(u8, text), &keys);
    defer scanned.deinit();

    const key = mapindex.Key.of("lookup.tsv", 7, text);
    const bytes = try mapindex.build(gpa, text, key, h);
    defer gpa.free(bytes);
    const ix = mapindex.open(bytes, key) orelse return error.IndexRefused;
    var via = try zephem.indexVia(gpa, ix, text, &keys, h);
    defer via.deinit();

    try testing.expectEqual(scanned.count(), via.count());
    for (paths) |p| {
        const a = scanned.get(p);
        const b = via.get(p);
        try testing.expectEqual(a == null, b == null);
        if (a) |e| try testing.expectEqualStrings(e.row, b.?.row);
    }
}

test "the index finds exactly what the full scan finds" {
    try expectSameAsScan(table, &asked, mapindex.wyhash);
}

test "the index finds the right rows when every path hashes the same" {
    // Collisions are resolved by comparing the row's path, never trusted from the hash.
    try expectSameAsScan(table, &asked, zero);
    try expectSameAsScan(table, &asked, byLength);

    // Every row `find` yields belongs to the asked path, even for a path of the same length
    // as a real one (`std.me` vs `std.fs`), where the tab position alone cannot tell them apart.
    const gpa = testing.allocator;
    inline for (.{ zero, byLength, mapindex.wyhash }) |h| {
        const key = mapindex.Key.of("t", 0, table);
        const bytes = try mapindex.build(gpa, table, key, h);
        defer gpa.free(bytes);
        const ix = mapindex.open(bytes, key).?;
        for (asked) |p| {
            var hits = ix.find(table, p, h);
            while (hits.next()) |r| {
                try testing.expect(std.mem.startsWith(u8, r, p));
                try testing.expectEqual(@as(u8, '\t'), r[p.len]);
            }
        }
        var none = ix.find(table, "std.me", h);
        try testing.expectEqual(@as(?[]const u8, null), none.next());
    }
}

test "a duplicate path keeps the last row, as the scan does" {
    const gpa = testing.allocator;
    var keys = try keysOf(gpa, &.{"std.mem.eql"});
    defer zephem.freeKeys(gpa, &keys);
    const key = mapindex.Key.of("t", 0, table);
    const bytes = try mapindex.build(gpa, table, key, zero);
    defer gpa.free(bytes);
    var via = try zephem.indexVia(gpa, mapindex.open(bytes, key).?, table, &keys, zero);
    defer via.deinit();
    try testing.expectEqualStrings("second", via.get("std.mem.eql").?.sig);
}

test "the header is skipped only as the first non-empty line" {
    const gpa = testing.allocator;
    const key = mapindex.Key.of("t", 0, table);
    const bytes = try mapindex.build(gpa, table, key, mapindex.wyhash);
    defer gpa.free(bytes);
    const ix = mapindex.open(bytes, key).?;
    var hits = ix.find(table, "path", mapindex.wyhash);
    try testing.expect(std.mem.endsWith(u8, hits.next().?, "pub\t-"));
    try testing.expectEqual(@as(?[]const u8, null), hits.next());
}

test "an empty table and a table of only a header index to nothing" {
    try expectSameAsScan("", &asked, mapindex.wyhash);
    try expectSameAsScan("path\tkind\n", &asked, mapindex.wyhash);
}

test "an index is refused for any other table or when damaged" {
    const gpa = testing.allocator;
    const key = mapindex.Key.of("lookup.tsv", 1234, table);
    const bytes = try mapindex.build(gpa, table, key, mapindex.wyhash);
    defer gpa.free(bytes);
    try testing.expect(mapindex.open(bytes, key) != null);

    // another path, mtime, size, or content at either end
    try testing.expect(mapindex.open(bytes, mapindex.Key.of("other.tsv", 1234, table)) == null);
    try testing.expect(mapindex.open(bytes, mapindex.Key.of("lookup.tsv", 1235, table)) == null);
    try testing.expect(mapindex.open(bytes, mapindex.Key.of("lookup.tsv", 1234, table[0 .. table.len - 1])) == null);
    const edited = try gpa.dupe(u8, table);
    defer gpa.free(edited);
    edited[edited.len - 2] = 'X';
    try testing.expect(mapindex.open(bytes, mapindex.Key.of("lookup.tsv", 1234, edited)) == null);

    // truncated, extended, flipped bits in the header or in any record
    try testing.expect(mapindex.open(bytes[0 .. bytes.len - 1], key) == null);
    try testing.expect(mapindex.open(bytes[0 .. mapindex.header_len - 1], key) == null);
    const longer = try std.mem.concat(gpa, u8, &.{ bytes, "\x00" });
    defer gpa.free(longer);
    try testing.expect(mapindex.open(longer, key) == null);
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    for (0..copy.len) |i| {
        copy[i] ^= 0x01;
        try testing.expect(mapindex.open(copy, key) == null);
        copy[i] ^= 0x01;
    }
    try testing.expect(mapindex.open(copy, key) != null);
}

test "rows pointing outside the table are skipped, not read" {
    // An index built for a longer text, opened over a shorter one with the same key fields,
    // cannot happen through `open` (the size is in the key); `find` still bounds-checks.
    const gpa = testing.allocator;
    const key = mapindex.Key.of("t", 0, table);
    const bytes = try mapindex.build(gpa, table, key, mapindex.wyhash);
    defer gpa.free(bytes);
    const ix = mapindex.open(bytes, key).?;
    var hits = ix.find(table[0..10], "std.fs", mapindex.wyhash);
    try testing.expectEqual(@as(?[]const u8, null), hits.next());
}

test "a realistic table: every path in it is found exactly as the scan finds it" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "path\tkind\n");
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    for (0..3000) |i| {
        // ~1 in 8 paths repeats an earlier one, as overlays and aliases do in the real table
        const n = if (i > 0 and r.uintLessThan(u8, 8) == 0) r.uintLessThan(usize, i) else i;
        const p = try gpa.print("std.m{d}.f{d}", .{ n % 97, n });
        try paths.append(gpa, p);
        try text.print(gpa, "{s}\t-\tfn\t-\t-\t-\tsig{d}\t-\t-\t-\t-\t-\t-\t-\tpub\t-\n", .{ p, i });
    }
    try expectSameAsScan(text.items, paths.items, mapindex.wyhash);
}
