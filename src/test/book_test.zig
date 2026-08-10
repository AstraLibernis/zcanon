const std = @import("std");
const testing = std.testing;
const book = @import("zcanon").book;

fn rec(file: []const u8, rule: []const u8, msg: []const u8, snip: []const u8) book.Record {
    return .{
        .first_ts = "2026-08-10 06:00:00",
        .last_ts = "2026-08-10 06:00:00",
        .hits = 1,
        .zig_version = "0.16.0",
        .file = file,
        .rule = rule,
        .severity = "warn",
        .line = 1,
        .col = 1,
        .message = msg,
        .snippet = snip,
    };
}

test "stamp formats sqlite's datetime('now') shape" {
    // Vectors cross-checked against `date -u -d @N`.
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("2026-08-11 04:30:45", try book.stamp(&buf, 1786422645));
    try testing.expectEqualStrings("1970-01-01 00:00:00", try book.stamp(&buf, 0));
    // Leap day, and the century rule either side of it (2000 is a leap year, 1900 is not).
    try testing.expectEqualStrings("2024-02-29 12:00:00", try book.stamp(&buf, 1709208000));
    try testing.expectEqualStrings("1999-12-31 23:59:59", try book.stamp(&buf, 946684799));
    try testing.expectEqualStrings("2000-03-01 00:00:00", try book.stamp(&buf, 951868800));
}

test "stamp rejects a negative timestamp rather than casting it" {
    var buf: [20]u8 = undefined;
    try testing.expectError(error.NegativeTimestamp, book.stamp(&buf, -1));
}

test "escape round-trips tabs, newlines and backslashes" {
    const gpa = testing.allocator;
    const cases = [_][]const u8{
        "plain",
        "has\ttab",
        "has\nnewline",
        "has\\backslash",
        "\t\n\\\r",
        "mixed \\t literal and \t real",
        "",
    };
    for (cases) |c| {
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try book.escape(&w.writer, c);
        const round = try book.unescape(gpa, w.written());
        defer gpa.free(round);
        try testing.expectEqualStrings(c, round);
    }
}

test "escaped text never contains a raw delimiter" {
    const gpa = testing.allocator;
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try book.escape(&w.writer, "a\tb\nc");
    try testing.expect(std.mem.findScalar(u8, w.written(), '\t') == null);
    try testing.expect(std.mem.findScalar(u8, w.written(), '\n') == null);
}

test "upsert inserts once then bumps hits on recurrence" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();

    const r = rec("a.zig", "R004", "catch unreachable", "x catch unreachable;");
    try b.upsert(&.{r});
    try testing.expectEqual(@as(usize, 1), b.recs.items.len);
    try testing.expectEqual(@as(u64, 1), b.recs.items[0].hits);

    try b.upsert(&.{r});
    try testing.expectEqual(@as(usize, 1), b.recs.items.len);
    try testing.expectEqual(@as(u64, 2), b.recs.items[0].hits);
}

test "dedup key ignores line and col so a shifted finding is the same finding" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();

    var r = rec("a.zig", "R004", "catch unreachable", "x catch unreachable;");
    try b.upsert(&.{r});
    r.line = 99;
    r.col = 42;
    try b.upsert(&.{r});

    try testing.expectEqual(@as(usize, 1), b.recs.items.len);
    try testing.expectEqual(@as(u64, 2), b.recs.items[0].hits);
    // fresh position wins
    try testing.expectEqual(@as(u32, 99), b.recs.items[0].line);
    try testing.expectEqual(@as(u32, 42), b.recs.items[0].col);
}

test "differing file, rule, message or snippet are distinct findings" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();
    try b.upsert(&.{
        rec("a.zig", "R004", "m", "s"),
        rec("b.zig", "R004", "m", "s"),
        rec("a.zig", "R005", "m", "s"),
        rec("a.zig", "R004", "other", "s"),
        rec("a.zig", "R004", "m", "other"),
    });
    try testing.expectEqual(@as(usize, 5), b.recs.items.len);
}

test "prune drops resolved findings for the scanned file only" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();

    const keep = rec("a.zig", "R004", "still here", "s1");
    try b.upsert(&.{ keep, rec("a.zig", "R005", "fixed", "s2"), rec("other.zig", "R005", "untouched", "s3") });
    try testing.expectEqual(@as(usize, 3), b.recs.items.len);

    b.pruneFile("a.zig", &.{keep}, &.{ book.GROUP_CORE, book.GROUP_AST });
    try testing.expectEqual(@as(usize, 2), b.recs.items.len);
    try testing.expectEqualStrings("still here", b.recs.items[0].message);
    try testing.expectEqualStrings("untouched", b.recs.items[1].message);
}

test "a checker that did not run cannot prune its own history" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();

    try b.upsert(&.{
        rec("a.zig", "R004", "zsnag finding", "s1"),
        rec("a.zig", book.AST_RULE, "ast finding", "s2"),
    });

    // zsnag crashed: only ast-check results are trustworthy this round.
    b.pruneFile("a.zig", &.{}, &.{book.GROUP_AST});
    try testing.expectEqual(@as(usize, 1), b.recs.items.len);
    try testing.expectEqualStrings("zsnag finding", b.recs.items[0].message);

    // now the reverse: ast-check did not run.
    try b.upsert(&.{rec("a.zig", book.AST_RULE, "ast finding", "s2")});
    b.pruneFile("a.zig", &.{}, &.{book.GROUP_CORE});
    try testing.expectEqual(@as(usize, 1), b.recs.items.len);
    try testing.expectEqualStrings("ast finding", b.recs.items[0].message);
}

test "rules map to the group that owns them" {
    try testing.expectEqualStrings(book.GROUP_AST, book.groupOf(book.AST_RULE));
    try testing.expectEqualStrings(book.GROUP_CORE, book.groupOf("R001"));
    try testing.expectEqualStrings(book.GROUP_CORE, book.groupOf("R010"));
    try testing.expectEqualStrings(book.GROUP_MAP, book.groupOf("R011"));
    try testing.expectEqualStrings(book.GROUP_MAP, book.groupOf("R013"));
    try testing.expectEqualStrings(book.GROUP_CORE, book.groupOf("nonsense"));
}

test "a zephem map failure cannot erase the map rules' history" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();

    try b.upsert(&.{
        rec("a.zig", "R004", "core finding", "s1"),
        rec("a.zig", "R011", "deprecated API", "s2"),
        rec("a.zig", "R012", "wrong arity", "s3"),
    });

    // zsnag ran, but the zephem map failed to load — so only `core` is active. The map rules
    // produced nothing, and that silence must NOT be read as "resolved".
    b.pruneFile("a.zig", &.{rec("a.zig", "R004", "core finding", "s1")}, &.{book.GROUP_CORE});

    try testing.expectEqual(@as(usize, 3), b.recs.items.len);
    try testing.expectEqualStrings("R011", b.recs.items[1].rule);
    try testing.expectEqualStrings("R012", b.recs.items[2].rule);
}

test "when the map group IS active, resolved map findings are pruned" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();
    try b.upsert(&.{
        rec("a.zig", "R004", "core finding", "s1"),
        rec("a.zig", "R011", "deprecated API", "s2"),
    });

    b.pruneFile("a.zig", &.{rec("a.zig", "R004", "core finding", "s1")}, &.{ book.GROUP_CORE, book.GROUP_MAP });

    try testing.expectEqual(@as(usize, 1), b.recs.items.len);
    try testing.expectEqualStrings("R004", b.recs.items[0].rule);
}

test "no active groups prunes nothing at all" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();
    try b.upsert(&.{ rec("a.zig", "R004", "m1", "s1"), rec("a.zig", book.AST_RULE, "m2", "s2") });

    b.pruneFile("a.zig", &.{}, &.{});
    try testing.expectEqual(@as(usize, 2), b.recs.items.len);
}

test "write then parse round-trips the whole book" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();
    try b.upsert(&.{
        rec("a.zig", "R004", "msg with\ttab", "    const x = 1; // snippet"),
        rec("b/c.zig", book.AST_RULE, "error: expected ';'", "line\\with\\backslashes"),
    });
    b.recs.items[0].hits = 7;

    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try b.write(&w.writer);

    var b2: book.Book = .init(gpa);
    defer b2.deinit();
    try b2.parse(w.written());

    try testing.expectEqual(b.recs.items.len, b2.recs.items.len);
    for (b.recs.items, b2.recs.items) |x, y| {
        try testing.expectEqualStrings(x.file, y.file);
        try testing.expectEqualStrings(x.rule, y.rule);
        try testing.expectEqualStrings(x.message, y.message);
        try testing.expectEqualStrings(x.snippet, y.snippet);
        try testing.expectEqualStrings(x.first_ts, y.first_ts);
        try testing.expectEqual(x.hits, y.hits);
        try testing.expectEqual(x.line, y.line);
        try testing.expectEqual(x.col, y.col);
    }
}

test "parse tolerates a corrupt row without losing the rest" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();
    const text =
        book.header ++ "\n" ++
        "2026-08-10 06:00:00\t2026-08-10 06:00:00\t1\t0.16.0\ta.zig\tR004\twarn\t1\t1\tgood\tsnip\n" ++
        "not\tenough\tcolumns\n" ++
        "2026-08-10 06:00:00\t2026-08-10 06:00:00\tNOTANUMBER\t0.16.0\tb.zig\tR004\twarn\t1\t1\tbad\tsnip\n" ++
        "2026-08-10 06:00:00\t2026-08-10 06:00:00\t2\t0.16.0\tc.zig\tR005\twarn\t3\t4\talso good\tsnip\n";
    try b.parse(text);

    try testing.expectEqual(@as(usize, 2), b.recs.items.len);
    try testing.expectEqualStrings("good", b.recs.items[0].message);
    try testing.expectEqualStrings("also good", b.recs.items[1].message);
}

test "parsing an empty or header-only book yields no records" {
    const gpa = testing.allocator;
    var b: book.Book = .init(gpa);
    defer b.deinit();
    try b.parse("");
    try testing.expectEqual(@as(usize, 0), b.recs.items.len);
    try b.parse(book.header ++ "\n");
    try testing.expectEqual(@as(usize, 0), b.recs.items.len);
}
