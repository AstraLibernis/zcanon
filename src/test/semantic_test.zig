// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const semantic = @import("zcanon").semantic;
const hook = @import("zcanon").hook;

test "diagnostic lines parse; echoes, carets and runner lines do not" {
    const d = semantic.parseDiagLine("src/tier.zig:74:23: error: expected type 'u32', found '*const [3:0]u8'").?;
    try testing.expectEqualStrings("src/tier.zig", d.path);
    try testing.expectEqual(@as(u32, 74), d.line);
    try testing.expectEqual(@as(u32, 23), d.col);
    try testing.expectEqualStrings("error", d.severity);
    try testing.expectEqualStrings("expected type 'u32', found '*const [3:0]u8'", d.message);

    try testing.expectEqualStrings("note", semantic.parseDiagLine("/a/b.zig:1:1: note: struct declared here").?.severity);
    for ([_][]const u8{
        "    const oops: u32 = \"str\";", // source echo
        "                      ^~~~~", // caret
        "error: 1 compilation errors",
        "+- compile exe zcanon ReleaseSafe native 1 errors",
        "Build Summary: 3/6 steps succeeded (2 failed)",
        "    test_0: src/test/all.zig:7:17", // reference trace
        "",
    }) |line| try testing.expectEqual(@as(?semantic.Diag, null), semantic.parseDiagLine(line));
}

test "a build's diagnostics are collected up to its summary, deduplicated" {
    var k: semantic.Collector = .{ .gpa = testing.allocator };
    defer k.deinit();
    // The same error reported by the exe and by its tests, as `zig build check` prints it.
    const out =
        \\check
        \\+- compile test t ReleaseSafe native 1 errors
        \\src/a.zig:3:5: error: bad
        \\    x
        \\    ^
        \\check
        \\+- compile exe e ReleaseSafe native 1 errors
        \\src/a.zig:3:5: error: bad
        \\src/b.zig:9:1: note: declared here
        \\Build Summary: 1/3 steps succeeded (2 failed)
    ;
    var lines = std.mem.splitScalar(u8, out, '\n');
    var done = false;
    while (lines.next()) |line| done = try k.feed(line);
    try testing.expect(done);
    try testing.expectEqual(@as(usize, 2), k.diags.items.len);
    try testing.expectEqualStrings("src/b.zig", k.diags.items[1].path);
    k.clear();
    try testing.expectEqual(@as(usize, 0), k.diags.items.len);
}

test "addCheck calls the helper from build with build's own parameter name" {
    const src =
        \\const std = @import("std");
        \\
        \\// fn build(fake: u8) — a comment, not the function
        \\pub fn build(bld: *std.Build) void {
        \\    _ = bld;
        \\}
        \\
    ;
    const out = try semantic.addCheck(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.find(u8, out, "    zcanonCheck(bld); // zcanon") != null);
    // The call lands inside build's body, before its closing brace.
    const call = std.mem.find(u8, out, "zcanonCheck(bld)").?;
    const helper = std.mem.find(u8, out, "fn zcanonCheck(").?;
    try testing.expect(call < helper);
    try testing.expect(std.mem.find(u8, out[call..helper], "}") != null);
    // The result is still valid Zig.
    const z = try testing.allocator.dupeZ(u8, out);
    defer testing.allocator.free(z);
    var tree = try std.zig.Ast.parse(testing.allocator, z, .zig);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "addCheck refuses twice, a broken file, and a file with no build fn" {
    const good = "const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    _ = b;\n}\n";
    const once = try semantic.addCheck(testing.allocator, good);
    defer testing.allocator.free(once);
    const z = try testing.allocator.dupeZ(u8, once);
    defer testing.allocator.free(z);
    try testing.expectError(error.AlreadyAdded, semantic.addCheck(testing.allocator, z));
    try testing.expectError(error.BuildZigInvalid, semantic.addCheck(testing.allocator, "pub fn build( {"));
    try testing.expectError(error.NoBuildFn, semantic.addCheck(testing.allocator, "const x = 1;\n"));
}

test "semantic block: errors only in the short view, notes in the full one, staleness said" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const diags = [_]semantic.Diag{
        .{ .path = "src/a.zig", .line = 3, .col = 5, .severity = "error", .message = "bad" },
        .{ .path = "src/b.zig", .line = 9, .col = 1, .severity = "note", .message = "declared here" },
    };
    const short = (try hook.renderSemantic(a.allocator(), "/p", &diags, false, .short)).?;
    try testing.expectEqualStrings("zcanon: zig build check in /p — 1 error\n▲ [compile] src/a.zig:3:5  bad", short);
    const full = (try hook.renderSemantic(a.allocator(), "/p", &diags, true, .full)).?;
    try testing.expect(std.mem.find(u8, full, "note: src/b.zig:9:1  declared here") != null);
    try testing.expect(std.mem.find(u8, full, "before this edit") != null);
    // Notes alone are nothing to report.
    try testing.expectEqual(@as(?[]const u8, null), try hook.renderSemantic(a.allocator(), "/p", diags[1..], false, .short));
}
