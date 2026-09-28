// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const zephem = @import("zcanon").zephem;
const snag = @import("zcanon").snag;

fn scan(gpa: std.mem.Allocator, src: [:0]const u8, out: *std.ArrayList(snag.Finding)) !void {
    try snag.scan(gpa, "t.zig", src, out);
}

fn codes(gpa: std.mem.Allocator, src: [:0]const u8) ![]const []const u8 {
    var out: std.ArrayList(snag.Finding) = .empty;
    try scan(gpa, src, &out);
    var list: std.ArrayList([]const u8) = .empty;
    for (out.items) |f| try list.append(gpa, f.rule().code);
    return list.items;
}

fn has(list: []const []const u8, code: []const u8) bool {
    for (list) |c| if (std.mem.eql(u8, c, code)) return true;
    return false;
}

/// Like `codes`, but REQUIRES the source to parse.
///
/// The AST-backed rules (R008) are skipped entirely on a file with syntax errors, so a test
/// fragment that does not parse makes every "must not fire" assertion pass vacuously — the
/// rule never ran. That is how `var l = …init(gpa); defer l.deinit();` silently became a
/// no-op test: `defer` is not legal at file scope. Any AST-rule test must go through here.
fn codesParsed(gpa: std.mem.Allocator, src: [:0]const u8) ![]const []const u8 {
    var tree = try std.zig.Ast.parse(gpa, src, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len > 0) return error.TestSourceDoesNotParse;
    return codes(gpa, src);
}

// ---- the registry ---------------------------------------------------------

test "every rule has a unique code, a severity and a message" {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(testing.allocator);
    for (snag.rules) |r| {
        try testing.expect(r.code.len == 4);
        try testing.expectEqual(@as(u8, 'R'), r.code[0]);
        try testing.expect(r.msg.len > 0);
        try testing.expect(!has(seen.items, r.code));
        try seen.append(testing.allocator, r.code);
    }
    // Structural, not a magic count: the table must cover the Id enum exactly, and codes
    // must be in declaration order so R0NN matches its position. A bare `rules.len == 13`
    // asserts nothing about behaviour and needs editing every time a rule is added.
    const ids = std.enums.values(snag.Id);
    try testing.expectEqual(ids.len, snag.rules.len);
    for (ids, 1..) |id, n| {
        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&buf, "R{d:0>3}", .{n}),
            snag.ruleOf(id).code,
        );
    }
}

test "the enum and the table agree" {
    // directEnumArray indexes by the enum, so a mismatch is a compile error; this pins the
    // ordering that --list-rules and the ledger refer to.
    try testing.expectEqualStrings("R001", snag.ruleOf(.r001_async).code);
    try testing.expectEqualStrings("R008", snag.ruleOf(.r008_acquire).code);
    try testing.expectEqualStrings("R010", snag.ruleOf(.r010_debug_print).code);
}

// ---- individual rules (ported from the deleted nu/test.nu) ----------------

test "R001 flags the stale keyword syntax" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try testing.expect(has(try codes(a.allocator(), "const x = async foo();"), "R001"));
    try testing.expect(has(try codes(a.allocator(), "const y = await frame;"), "R001"));
}

test "R001 does not fire on async/await as ordinary identifiers" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // Every one of these appears in Zig's own std and is correct code. Matching the bare
    // name produced 8 error-severity findings on lib/std/Io.zig alone.
    const ok = [_][:0]const u8{
        "const x = handle.async();", // method call
        "const y = h.await();",
        "pub fn async(g: *Group) void {}", // declaring a fn named async
        "const E = enum { async, await };", // enum members
        "const v = .{ .async = async, .await = await };", // field init reading a decl
        "await(ev, future, result);", // calling a fn named await
        "async: *const fn () void,", // struct field
    };
    for (ok) |src| {
        try testing.expect(!has(try codes(a.allocator(), src), "R001"));
    }
}

test "R003 flags mem.copy/mem.set only after a mem. qualifier" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try testing.expect(has(try codes(a.allocator(), "std.mem.copy(u8, d, s);"), "R003"));
    try testing.expect(has(try codes(a.allocator(), "std.mem.set(u8, d, 0);"), "R003"));
    // A `set` that is not mem.set must not fire.
    try testing.expect(!has(try codes(a.allocator(), "map.set(k, v);"), "R003"));
}

test "R007 does not fire on a cast used directly as an index" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try testing.expect(has(try codes(a.allocator(), "const n: u8 = @intCast(x);"), "R007"));
    try testing.expect(!has(try codes(a.allocator(), "const v = buf[@intCast(i)];"), "R007"));
}

test "R008 is satisfied by a matching deinit or close" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const leaked =
        \\fn f(gpa: Allocator) void {
        \\    var l = std.ArrayList(u8).init(gpa);
        \\    _ = l;
        \\}
    ;
    const released =
        \\fn f(gpa: Allocator) void {
        \\    var l = std.ArrayList(u8).init(gpa);
        \\    defer l.deinit();
        \\    _ = l;
        \\}
    ;
    try testing.expect(has(try codesParsed(a.allocator(), leaked), "R008"));
    try testing.expect(!has(try codesParsed(a.allocator(), released), "R008"));

    const f_leaked =
        \\fn g(dir: Dir, p: []const u8) !void {
        \\    const fd = try dir.openFile(p, .{});
        \\    _ = fd;
        \\}
    ;
    const f_closed =
        \\fn g(dir: Dir, p: []const u8) !void {
        \\    const fd = try dir.openFile(p, .{});
        \\    defer fd.close();
        \\    _ = fd;
        \\}
    ;
    try testing.expect(has(try codesParsed(a.allocator(), f_leaked), "R008"));
    try testing.expect(!has(try codesParsed(a.allocator(), f_closed), "R008"));
}

test "R008 does not fire on a type definition that owns an allocator" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // The old scan read `const Book` forward to the next `;` — the whole struct body — saw
    // ArenaAllocator plus `.init(`, and hunted for a `Book.deinit` that will never exist.
    const src =
        \\const Book = struct {
        \\    arena: std.heap.ArenaAllocator,
        \\    pub fn init(gpa: Allocator) Book {
        \\        return .{ .arena = .init(gpa) };
        \\    }
        \\    pub fn deinit(b: *Book) void {
        \\        b.arena.deinit();
        \\    }
        \\};
    ;
    try testing.expect(!has(try codesParsed(a.allocator(), src), "R008"));
}

test "R008 does not read `const` inside a type expression as a declaration" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // `[]const u8` bound to `u8` and swallowed the function body. It appears in nearly every
    // Zig file, so this fired almost everywhere.
    const src =
        \\fn takesSlice(s: []const u8, gpa: Allocator) usize {
        \\    var l = std.ArrayList(u8).init(gpa);
        \\    defer l.deinit();
        \\    return s.len + l.items.len;
        \\}
    ;
    try testing.expect(!has(try codesParsed(a.allocator(), src), "R008"));
}

test "R008 does not fire when the resource is returned to the caller" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // Ownership transfers; releasing it here would be the bug. Shape taken from
    // std's tar.zig createDirAndFile, which the file-scoped check flagged.
    const direct =
        \\fn open(dir: Dir, p: []const u8) !File {
        \\    const fd = try dir.openFile(p, .{});
        \\    return fd;
        \\}
    ;
    const wrapped =
        \\fn make(gpa: Allocator) !Holder {
        \\    var l = std.ArrayList(u8).init(gpa);
        \\    return .{ .list = l };
        \\}
    ;
    try testing.expect(!has(try codesParsed(a.allocator(), direct), "R008"));
    try testing.expect(!has(try codesParsed(a.allocator(), wrapped), "R008"));
}

test "R008 scopes the release to the declaration's own function" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    // A file-global name search reported NOTHING here — a rule claiming clean code over a
    // real leak, because some *other* function released a variable of the same name.
    const src =
        \\fn released(gpa: Allocator) void {
        \\    var l = std.ArrayList(u8).init(gpa);
        \\    defer l.deinit();
        \\    _ = l;
        \\}
        \\fn leaked(gpa: Allocator) void {
        \\    var l = std.ArrayList(u8).init(gpa);
        \\    _ = l;
        \\}
    ;
    try testing.expect(has(try codesParsed(a.allocator(), src), "R008"));
}

test "a rule the map contradicts emits nothing" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const src = "pub fn f(d: []u8, s: []const u8) void { std.mem.copy(u8, d, s); }";

    // Premise holds: the rule fires.
    var on: std.ArrayList(snag.Finding) = .empty;
    try snag.scanWithOpts(gpa, "t.zig", src, &on, .{});
    var fired = false;
    for (on.items) |f| if (std.mem.eql(u8, f.rule().code, "R003")) {
        fired = true;
    };
    try testing.expect(fired);

    // Premise contradicted: the rule is silent, not merely warned about. Continuing to assert
    // "this API was removed" after the map says otherwise is the exact staleness the zephem
    // integration exists to prevent.
    var off: std.ArrayList(snag.Finding) = .empty;
    try snag.scanWithOpts(gpa, "t.zig", src, &off, .{ .stale = &.{.r003_mem_copy} });
    for (off.items) |f| try testing.expect(!std.mem.eql(u8, f.rule().code, "R003"));
}

test "mapKeys asks for every chain, its prefixes, std, and the premise paths" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    var keys: zephem.Keys = .empty;
    try snag.mapKeys(gpa, "const x = std.fmt.parseInt(u8, s, 10); const y = foo.std.bar;", &keys);
    for ([_][]const u8{ "std.fmt.parseInt", "std.fmt", "std", "std.mem.copy", "std.mem.set" }) |k|
        try testing.expect(keys.contains(k));
    // `foo.std.bar` is not rooted at std.
    try testing.expect(!keys.contains("std.bar"));
    try testing.expectEqual(@as(usize, 5), keys.count());
}

test "structural rules report whether they ran" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var ok = false;
    var out1: std.ArrayList(snag.Finding) = .empty;
    try snag.scanWithOpts(gpa, "t.zig", "pub fn f() void {}", &out1, .{ .ran_structural = &ok });
    try testing.expect(ok);

    // A file with a syntax error cannot be parsed, so R008 never runs — and the caller must be
    // able to tell that from "R008 found nothing", or the book prunes real findings.
    var broken = false;
    var out2: std.ArrayList(snag.Finding) = .empty;
    try snag.scanWithOpts(gpa, "t.zig", "const x = async foo();", &out2, .{ .ran_structural = &broken });
    try testing.expect(!broken);
}

// ---- suppression ----------------------------------------------------------

test "zsnag:ok silences only the finding's own line" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const src =
        \\std.debug.print("a", .{}); // zsnag:ok
        \\std.debug.print("b", .{});
        \\
    ;
    var out: std.ArrayList(snag.Finding) = .empty;
    try scan(a.allocator(), src, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 2), out.items[0].line);
}

test "zsnag:allow silences a rule file-wide" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const src =
        \\// zsnag:allow R010
        \\std.debug.print("a", .{});
        \\std.debug.print("b", .{});
        \\
    ;
    try testing.expect(!has(try codes(a.allocator(), src), "R010"));
}

test "more than 32 allow codes are all honoured (B4)" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var src: std.ArrayList(u8) = .empty;
    // A long allow line: many repeats, with R010 last so it lands well past the old cap.
    try src.appendSlice(a.allocator(), "// zsnag:allow");
    for (0..60) |_| try src.appendSlice(a.allocator(), " R999");
    try src.appendSlice(a.allocator(), " R010\n");
    try src.appendSlice(a.allocator(), "std.debug.print(\"a\", .{});\n");
    const z = try a.allocator().dupeZ(u8, src.items);

    var out: std.ArrayList(snag.Finding) = .empty;
    try scan(a.allocator(), z, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// ---- output ---------------------------------------------------------------

test "findings come out sorted by position" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const src =
        \\fn f(gpa: Allocator) void {
        \\    var l = std.ArrayList(u8).init(gpa);
        \\    std.debug.print("x", .{});
        \\    const y = foo() catch unreachable;
        \\    _ = .{ l, y };
        \\}
    ;
    var out: std.ArrayList(snag.Finding) = .empty;
    try scan(a.allocator(), src, &out);
    try testing.expect(out.items.len >= 3);
    for (out.items[1..], out.items[0 .. out.items.len - 1]) |cur, prev| {
        try testing.expect(prev.line < cur.line or (prev.line == cur.line and prev.col <= cur.col));
    }
}

test "JSON output escapes quotes and backslashes in the path (B2)" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var out: std.ArrayList(snag.Finding) = .empty;
    try snag.scan(gpa, "we\"ird\\path.zig", "std.debug.print(\"x\", .{});\n", &out);

    var w: std.Io.Writer.Allocating = .init(gpa);
    try snag.renderJson(&w.writer, out.items);

    // Must re-parse as real JSON with the path intact.
    const line = std.mem.trimEnd(u8, w.written(), "\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("we\"ird\\path.zig", parsed.value.object.get("file").?.string);
    try testing.expectEqualStrings("R010", parsed.value.object.get("rule").?.string);
}

test "anyError is true only for error-severity findings" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();

    var errs: std.ArrayList(snag.Finding) = .empty;
    try scan(a.allocator(), "usingnamespace foo;", &errs);
    try testing.expect(snag.anyError(errs.items));

    var infos: std.ArrayList(snag.Finding) = .empty;
    try scan(a.allocator(), "std.debug.print(\"x\", .{});", &infos);
    try testing.expect(infos.items.len > 0);
    try testing.expect(!snag.anyError(infos.items));
}

test "clean source produces nothing" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const src =
        \\const std = @import("std");
        \\pub fn add(x: u8, y: u8) u8 {
        \\    return x + y;
        \\}
        \\
    ;
    var out: std.ArrayList(snag.Finding) = .empty;
    try scan(a.allocator(), src, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
