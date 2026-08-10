const std = @import("std");
const testing = std.testing;
const zcanon = @import("zcanon");
const report = zcanon.report;
const book = zcanon.book;

fn rec(file: []const u8, rule: []const u8, sev: []const u8, hits: u64, ts: []const u8) book.Record {
    return .{
        .first_ts = ts,
        .last_ts = ts,
        .hits = hits,
        .zig_version = "0.16.0",
        .file = file,
        .rule = rule,
        .severity = sev,
        .line = 1,
        .col = 1,
        .message = "a message",
        .snippet = "const x = 1;",
    };
}

fn render(recs: []const book.Record, mode: report.Mode) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer w.deinit();
    try report.render(testing.allocator, &w.writer, recs, mode);
    return w.toOwnedSlice();
}

test "mode parsing covers every report" {
    try testing.expectEqual(report.Mode.toc, try report.Mode.parse(&.{}));
    try testing.expectEqual(report.Mode.files, try report.Mode.parse(&.{"files"}));
    try testing.expectEqual(@as(usize, 20), (try report.Mode.parse(&.{"recent"})).recent);
    try testing.expectEqual(@as(usize, 5), (try report.Mode.parse(&.{ "recent", "5" })).recent);
    try testing.expectEqual(@as(usize, 20), (try report.Mode.parse(&.{ "recent", "abc" })).recent);
    try testing.expectEqualStrings("R004", (try report.Mode.parse(&.{"R004"})).rule);
    try testing.expectError(error.UnknownReport, report.Mode.parse(&.{"nonsense"}));
}

test "an empty book says so rather than printing an empty table" {
    const out = try render(&.{}, .toc);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "the book is empty") != null);
}

test "toc aggregates by rule and orders by hits" {
    const recs = [_]book.Record{
        rec("a.zig", "R004", "warn", 2, "2026-08-01 00:00:00"),
        rec("b.zig", "R010", "info", 9, "2026-08-02 00:00:00"),
        rec("c.zig", "R010", "info", 1, "2026-08-03 00:00:00"),
    };
    const out = try render(&recs, .toc);
    defer testing.allocator.free(out);

    // R010 totals 10 hits across 2 findings, so it must precede R004's 2.
    const r10 = std.mem.find(u8, out, "R010").?;
    const r04 = std.mem.find(u8, out, "R004").?;
    try testing.expect(r10 < r04);
    try testing.expect(std.mem.find(u8, out, "across 2 rules") != null);
}

test "files rolls up per file" {
    const recs = [_]book.Record{
        rec("a.zig", "R004", "warn", 3, "2026-08-01 00:00:00"),
        rec("a.zig", "R010", "info", 4, "2026-08-01 00:00:00"),
        rec("b.zig", "R010", "info", 1, "2026-08-01 00:00:00"),
    };
    const out = try render(&recs, .files);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "2 files") != null);
    try testing.expect(std.mem.find(u8, out, "a.zig").? < std.mem.find(u8, out, "b.zig").?);
}

test "recent is newest first and respects the limit" {
    const recs = [_]book.Record{
        rec("old.zig", "R001", "error", 1, "2026-08-01 00:00:00"),
        rec("new.zig", "R002", "error", 1, "2026-08-09 00:00:00"),
        rec("mid.zig", "R003", "error", 1, "2026-08-05 00:00:00"),
    };
    const out = try render(&recs, .{ .recent = 2 });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "new.zig") != null);
    try testing.expect(std.mem.find(u8, out, "mid.zig") != null);
    try testing.expect(std.mem.find(u8, out, "old.zig") == null);
}

test "rule detail reports a miss instead of an empty section" {
    const recs = [_]book.Record{rec("a.zig", "R004", "warn", 1, "2026-08-01 00:00:00")};
    const hit = try render(&recs, .{ .rule = "R004" });
    defer testing.allocator.free(hit);
    try testing.expect(std.mem.find(u8, hit, "caution") != null);
    try testing.expect(std.mem.find(u8, hit, "const x = 1;") != null);

    const miss = try render(&recs, .{ .rule = "R999" });
    defer testing.allocator.free(miss);
    try testing.expect(std.mem.find(u8, miss, "no findings recorded for R999") != null);
}

test "nowSeconds is a plausible wall-clock value" {
    // Threaded Io is what the binary uses; any Io works for a clock read.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const secs = book.nowSeconds(threaded.io());
    // Sometime after 2020-01-01 and before 2100-01-01 — catches a unit mix-up (ns vs s).
    try testing.expect(secs > 1_577_836_800);
    try testing.expect(secs < 4_102_444_800);
}
