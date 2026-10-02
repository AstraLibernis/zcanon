// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const zc = @import("zcanon");
const book = zc.book;
const advice = zc.advice;

fn e(rule: []const u8, severity: []const u8, pattern: []const u8, count: u64, last: []const u8) book.Entry {
    return .{ .rule = rule, .severity = severity, .pattern = pattern, .count = count, .first_ts = "2026-09-01 00:00:00", .last_ts = last, .file = "/x.zig", .line = 1, .message = pattern, .snippet = "" };
}

const sample = [_]book.Entry{
    e("ast-check", "error", "local constant shadows declaration of '…'", 9, "2026-09-30 00:00:00"),
    e("compile", "error", "local variable shadows declaration of '…'", 2, "2026-10-02 00:00:00"),
    e("ast-check", "error", "function parameter shadows declaration of '…'", 1, "2026-09-28 00:00:00"),
    e("R007", "info", "this cast can panic/corrupt if out of range; verify first.", 132, "2026-09-30 00:00:00"),
    e("ast-check", "info", "declared here", 8, "2026-09-30 00:00:00"),
    e("ast-check", "error", "use of undeclared identifier '…'", 14, "2026-09-30 00:00:00"),
    e("compile", "error", "unable to load '…': FileNotFound", 5, "2026-09-30 00:00:00"),
    e("R011", "warn", "`std.mem.indexOfScalar` is deprecated — the map says: use `findScalar`.", 4, "2026-09-28 00:00:00"),
    e("compile", "error", "member function expected 4 argument(s), found 3", 3, "2026-09-30 00:00:00"),
    e("compile", "error", "some message nobody wrote advice for", 2, "2026-09-30 00:00:00"),
    e("R004", "warn", "catch unreachable crashes in release if it ever fails; handle the error.", 1, "2026-09-28 00:00:00"),
};

test "select: groups by advice, drops advisories, edits in progress and one-offs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = try advice.select(arena.allocator(), &sample);
    try testing.expectEqual(@as(usize, 4), items.len);
    // All three shadowing errors are one line, summed, with the latest date.
    try testing.expectEqualStrings("Shadowing", items[0].title);
    try testing.expectEqual(@as(u64, 12), items[0].count);
    try testing.expectEqualStrings("2026-10-02 00:00:00", items[0].last_ts);
    // zsnag's own message is the advice, kept verbatim.
    try testing.expectEqualStrings("R011", items[1].title);
    try testing.expect(std.mem.find(u8, items[1].text, "use `findScalar`") != null);
    try testing.expectEqualStrings("Wrong argument count", items[2].title);
    // No advice written: the pattern stands in.
    try testing.expectEqualStrings("some message nobody wrote advice for", items[3].text);
    for (items) |it| {
        try testing.expect(!std.mem.eql(u8, it.title, "R007"));
        try testing.expect(!std.mem.eql(u8, it.title, "R004")); // made once
        try testing.expect(std.mem.find(u8, it.text, "undeclared") == null);
        try testing.expect(std.mem.find(u8, it.text, "declared here") == null);
    }
}

test "select caps the list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var many: [advice.max_items + 5]book.Entry = undefined;
    for (&many, 0..) |*m, i| m.* = e("R011", "warn", try std.fmt.allocPrint(arena.allocator(), "api {d}", .{i}), 2 + i, "2026-09-30 00:00:00");
    const items = try advice.select(arena.allocator(), &many);
    try testing.expectEqual(advice.max_items, items.len);
    try testing.expectEqual(@as(u64, 2 + many.len - 1), items[0].count);
}

test "fill replaces only the marked block, and is stable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skill = "head\n" ++ advice.begin_marker ++ "\nold list\n" ++ advice.end_marker ++ "\ntail\n";
    const once = try advice.fill(a, skill, &sample);
    try testing.expect(std.mem.startsWith(u8, once, "head\n" ++ advice.begin_marker ++ "\n"));
    try testing.expect(std.mem.endsWith(u8, once, advice.end_marker ++ "\ntail\n"));
    try testing.expect(std.mem.find(u8, once, "old list") == null);
    try testing.expect(std.mem.find(u8, once, "- **Shadowing** (12×, last 2026-10-02):") != null);
    try testing.expectEqualStrings(once, try advice.fill(a, once, &sample));

    const empty = try advice.fill(a, skill, &.{});
    try testing.expect(std.mem.find(u8, empty, "None recorded yet") != null);
}

test "fill leaves a skill without markers untouched" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "no markers here\n" ++ advice.begin_marker ++ " but no end\n";
    try testing.expectEqualStrings(text, try advice.fill(arena.allocator(), text, &sample));
}
