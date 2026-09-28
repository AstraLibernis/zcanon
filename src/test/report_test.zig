// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const zcanon = @import("zcanon");
const report = zcanon.report;
const book = zcanon.book;

fn entry(rule: []const u8, count: u64, ts: []const u8, file: []const u8) book.Entry {
    return .{
        .rule = rule,
        .severity = "warn",
        .pattern = "a message",
        .count = count,
        .first_ts = ts,
        .last_ts = ts,
        .file = file,
        .line = 7,
        .message = "a message",
        .snippet = "const x = 1;",
    };
}

fn render(history: []const book.Entry, mode: report.Mode) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer w.deinit();
    try report.render(testing.allocator, &w.writer, history, &.{}, mode);
    return w.toOwnedSlice();
}

test "mode parsing covers every report" {
    try testing.expectEqual(report.Mode.mistakes, try report.Mode.parse(&.{}));
    try testing.expectEqual(report.Mode.rules, try report.Mode.parse(&.{"rules"}));
    try testing.expectEqual(report.Mode.open, try report.Mode.parse(&.{"open"}));
    try testing.expectEqual(report.Mode.open, try report.Mode.parse(&.{"files"})); // old name
    try testing.expectEqual(@as(usize, 20), (try report.Mode.parse(&.{"recent"})).recent);
    try testing.expectEqual(@as(usize, 5), (try report.Mode.parse(&.{ "recent", "5" })).recent);
    try testing.expectEqualStrings("R004", (try report.Mode.parse(&.{"R004"})).rule);
    try testing.expectEqualStrings("compile", (try report.Mode.parse(&.{"compile"})).rule);
    try testing.expectError(error.UnknownReport, report.Mode.parse(&.{"nonsense"}));
}

test "an empty book says so" {
    const out = try render(&.{}, .mistakes);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "the book is empty") != null);
}

test "one line per mistake: count, date, and a clickable path:line, most frequent first" {
    const h = [_]book.Entry{
        entry("R004", 2, "2026-08-01 00:00:00", "/p/a.zig"),
        entry("R010", 9, "2026-08-02 00:00:00", "/p/b.zig"),
    };
    const out = try render(&h, .mistakes);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "    9×  2026-08-02 00:00  [R010] /p/b.zig:7  a message") != null);
    try testing.expect(std.mem.find(u8, out, "R010").? < std.mem.find(u8, out, "R004").?);
}

test "rules totals times across a rule's mistakes" {
    var two = entry("R010", 1, "2026-08-03 00:00:00", "/p/c.zig");
    two.pattern = "another";
    const h = [_]book.Entry{ entry("R004", 2, "2026-08-01 00:00:00", "/p/a.zig"), entry("R010", 9, "2026-08-02 00:00:00", "/p/b.zig"), two };
    const out = try render(&h, .rules);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "R010        2         10") != null);
}

test "recent is newest first and respects the limit" {
    const h = [_]book.Entry{
        entry("R001", 1, "2026-08-01 00:00:00", "/old.zig"),
        entry("R002", 1, "2026-08-09 00:00:00", "/new.zig"),
        entry("R003", 1, "2026-08-05 00:00:00", "/mid.zig"),
    };
    const out = try render(&h, .{ .recent = 2 });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "new.zig").? < std.mem.find(u8, out, "mid.zig").?);
    try testing.expect(std.mem.find(u8, out, "old.zig") == null);
}

test "rule detail shows the source line, and a miss says so" {
    const h = [_]book.Entry{entry("R004", 1, "2026-08-01 00:00:00", "/p/a.zig")};
    const hit = try render(&h, .{ .rule = "R004" });
    defer testing.allocator.free(hit);
    try testing.expect(std.mem.find(u8, hit, "const x = 1;") != null);
    const miss = try render(&h, .{ .rule = "R999" });
    defer testing.allocator.free(miss);
    try testing.expect(std.mem.find(u8, miss, "no mistakes recorded for R999") != null);
}

test "nowSeconds converts the clock's nanoseconds to seconds" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Compare against an independent read of the same clock rather than a plausibility
    // window: a range check passes against a stub returning any hardcoded constant, so it
    // would not catch the actual risk here, which is a ns/s unit mix-up in the conversion.
    const ns_before = std.Io.Clock.real.now(io).nanoseconds;
    const secs = book.nowSeconds(io);
    const ns_after = std.Io.Clock.real.now(io).nanoseconds;

    try testing.expect(secs >= @divFloor(ns_before, std.time.ns_per_s));
    try testing.expect(secs <= @divFloor(ns_after, std.time.ns_per_s));
}
