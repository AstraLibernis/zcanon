// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const zc = @import("zcanon");
const book = zc.book;
const publish = zc.publish;

fn entry(rule: []const u8, pattern: []const u8, count: u64, first: []const u8, last: []const u8) book.Entry {
    return .{
        .rule = rule,
        .severity = "error",
        .pattern = pattern,
        .count = count,
        .first_ts = first,
        .last_ts = last,
        .file = "/home/me/secret-project/src/private.zig",
        .line = 42,
        .message = "use of undeclared identifier 'launchCodes'",
        .snippet = "const x = launchCodes(key);",
    };
}

fn row(project: []const u8, pattern: []const u8, count: u64, first: []const u8, last: []const u8) publish.Row {
    return publish.sanitize(entry("compile", pattern, count, first, last), project);
}

test "what is published carries no path, line, message or source" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var rows = [_]publish.Row{row("proj", "use of undeclared identifier '…'", 3, "2026-09-01 00:00:00", "2026-09-02 00:00:00")};
    try publish.write(&out.writer, &rows);
    var md: std.Io.Writer.Allocating = .init(testing.allocator);
    defer md.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try publish.render(arena.allocator(), &md.writer, &rows);
    for ([_][]const u8{ out.written(), md.written() }) |text| {
        for ([_][]const u8{ "secret-project", "private.zig", "launchCodes", "key", "42" }) |leak| {
            try testing.expect(std.mem.find(u8, text, leak) == null);
        }
        try testing.expect(std.mem.find(u8, text, "use of undeclared identifier '…'") != null);
    }
}

test "merge takes the larger count and widens the dates; same book twice is a no-op" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(publish.Row) = .empty;
    try rows.append(a, row("p", "x", 5, "2026-09-05 00:00:00", "2026-09-06 00:00:00"));

    // A reset book (smaller count, later first date) cannot shrink the shared record.
    const smaller = [_]publish.Row{row("p", "x", 2, "2026-09-10 00:00:00", "2026-09-06 00:00:00")};
    try testing.expect(!try publish.merge(a, &rows, &smaller));
    try testing.expectEqual(@as(u64, 5), rows.items[0].count);
    try testing.expectEqualStrings("2026-09-05 00:00:00", rows.items[0].first_ts);

    const bigger = [_]publish.Row{row("p", "x", 9, "2026-09-01 00:00:00", "2026-09-20 00:00:00")};
    try testing.expect(try publish.merge(a, &rows, &bigger));
    try testing.expectEqual(@as(u64, 9), rows.items[0].count);
    try testing.expectEqualStrings("2026-09-01 00:00:00", rows.items[0].first_ts);
    try testing.expectEqualStrings("2026-09-20 00:00:00", rows.items[0].last_ts);
    try testing.expect(!try publish.merge(a, &rows, &bigger));

    // Same mistake in another project is its own row.
    const other = [_]publish.Row{row("q", "x", 1, "2026-09-01 00:00:00", "2026-09-01 00:00:00")};
    try testing.expect(try publish.merge(a, &rows, &other));
    try testing.expectEqual(@as(usize, 2), rows.items.len);
}

test "write then parse round-trips, sorted, with tabs and backslashes intact" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows = [_]publish.Row{
        row("zz", "b\tc\\d", 1, "2026-09-01 00:00:00", "2026-09-01 00:00:00"),
        row("aa", "a", 7, "2026-09-02 00:00:00", "2026-09-03 00:00:00"),
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try publish.write(&out.writer, &rows);
    var back: std.ArrayList(publish.Row) = .empty;
    try publish.parse(a, out.written(), &back);
    try testing.expectEqual(@as(usize, 2), back.items.len);
    try testing.expectEqualStrings("aa", back.items[0].project);
    try testing.expectEqual(@as(u64, 7), back.items[0].count);
    try testing.expectEqualStrings("b\tc\\d", back.items[1].pattern);
}

test "render sums a mistake across projects, most frequent first, and escapes pipes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = [_]publish.Row{
        row("p", "rare", 1, "2026-09-01 00:00:00", "2026-09-01 00:00:00"),
        row("p", "a | b", 3, "2026-09-02 00:00:00", "2026-09-04 00:00:00"),
        row("q", "a | b", 4, "2026-09-01 00:00:00", "2026-09-03 00:00:00"),
    };
    var md: std.Io.Writer.Allocating = .init(a);
    try publish.render(a, &md.writer, &rows);
    const text = md.written();
    try testing.expect(std.mem.find(u8, text, "2 mistakes made 8 times, across: p, q") != null);
    try testing.expect(std.mem.find(u8, text, "| 7 | compile | a \\| b | p, q | 2026-09-01 | 2026-09-04 |") != null);
    try testing.expect(std.mem.find(u8, text, "| 7 |").? < std.mem.find(u8, text, "| 1 |").?);
}
