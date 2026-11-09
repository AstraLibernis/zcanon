// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zcanon = @import("zcanon");
const zigver = zcanon.zigver;
const vars = zcanon.vars;

const exe: zigver.Exe = .{ .path = "/opt/zig-0.17.1/zig", .size = 123456, .mtime = 1_762_600_000_123_456_789 };

test "a cache line answers only for the exact binary it was written for" {
    const gpa = testing.allocator;
    const line = try zigver.render(gpa, exe, "0.17.1");
    defer gpa.free(line);
    try testing.expectEqualStrings("0.17.1", zigver.match(line, exe).?);

    var other = exe;
    other.path = "/opt/zig-0.16.0/zig";
    try testing.expectEqual(@as(?[]const u8, null), zigver.match(line, other));
    other = exe;
    other.size += 1;
    try testing.expectEqual(@as(?[]const u8, null), zigver.match(line, other));
    other = exe;
    other.mtime += 1;
    try testing.expectEqual(@as(?[]const u8, null), zigver.match(line, other));
}

test "a malformed cache line is a miss" {
    const bad = [_][]const u8{
        "",
        "/opt/zig-0.17.1/zig",
        "/opt/zig-0.17.1/zig\t123456\t1762600000123456789",
        "/opt/zig-0.17.1/zig\t123456\t1762600000123456789\t",
        "/opt/zig-0.17.1/zig\t123456\t1762600000123456789\t0.17.1\textra",
        "/opt/zig-0.17.1/zig\tx\t1762600000123456789\t0.17.1",
        "/opt/zig-0.17.1/zig\t123456\t1762600000123456789\t0.17 .1",
    };
    for (bad) |b| try testing.expectEqual(@as(?[]const u8, null), zigver.match(b, exe));
    // a CRLF-terminated line still matches
    try testing.expectEqualStrings("0.17.1", zigver.match("/opt/zig-0.17.1/zig\t123456\t1762600000123456789\t0.17.1\r\n", exe).?);
}

test "only a single printable token is stored as a version" {
    try testing.expect(zigver.validVersion("0.17.1"));
    try testing.expect(zigver.validVersion("0.18.0-dev.123+abcdef"));
    try testing.expect(!zigver.validVersion(""));
    try testing.expect(!zigver.validVersion("0.17.1\n"));
    try testing.expect(!zigver.validVersion("a b"));
    try testing.expect(!zigver.validVersion("a\tb"));
}

/// A Ctx whose PATH is `path_var` and whose config dir is `cfg`, in an arena.
fn ctxWith(arena: std.mem.Allocator, env: *std.process.Environ.Map, path_var: []const u8, cfg: []const u8) !vars.Ctx {
    try env.put("PATH", path_var);
    try env.put("ZCANON_CONFIG", cfg);
    return .{ .gpa = arena, .io = testing.io, .env = env };
}

const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

fn putExe(dir: std.Io.Dir, sub: []const u8, data: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = sub, .data = data, .flags = .{ .permissions = .executable_file } });
}

test "resolve finds the first zig on PATH and keys it by path, size and mtime" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(testing.io, "empty");
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try putExe(tmp.dir, "a/" ++ zig_name, "first");
    try putExe(tmp.dir, "b/" ++ zig_name, "second binary");

    const base = try std.Io.Dir.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const d: []const u8 = &.{std.Io.Dir.path.delimiter};
    const path_var = try std.mem.concat(arena, u8, &.{
        try std.Io.Dir.path.join(arena, &.{ base, "empty" }), d,
        try std.Io.Dir.path.join(arena, &.{ base, "a" }),     d,
        try std.Io.Dir.path.join(arena, &.{ base, "b" }),
    });
    var env = std.process.Environ.Map.init(arena);
    const c = try ctxWith(arena, &env, path_var, try std.Io.Dir.path.join(arena, &.{ base, "cfg" }));

    const e = zigver.resolve(c) orelse return error.NotResolved;
    try testing.expect(std.Io.Dir.path.isAbsolute(e.path));
    try testing.expect(std.mem.endsWith(u8, e.path, std.Io.Dir.path.sep_str ++ "a" ++ std.Io.Dir.path.sep_str ++ zig_name));
    try testing.expectEqual(@as(u64, 5), e.size);

    // store, then hit; a changed binary (other size) misses
    try testing.expectEqual(@as(?[]const u8, null), zigver.cached(c, e));
    zigver.store(c, e, "9.9.9");
    try testing.expectEqualStrings("9.9.9", zigver.cached(c, e).?);
    try putExe(tmp.dir, "a/" ++ zig_name, "first, rebuilt");
    const e2 = zigver.resolve(c).?;
    try testing.expectEqual(@as(?[]const u8, null), zigver.cached(c, e2));
    // a version that is not one token is never stored
    zigver.store(c, e2, "not one token");
    try testing.expectEqual(@as(?[]const u8, null), zigver.cached(c, e2));
}

test "resolve gives up when the first match is a script, and finds nothing on an empty PATH" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try std.Io.Dir.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var env = std.process.Environ.Map.init(arena);
    const nothing = try ctxWith(arena, &env, try std.Io.Dir.path.join(arena, &.{ base, "none" }), base);
    try testing.expectEqual(@as(?zigver.Exe, null), zigver.resolve(nothing));

    if (builtin.os.tag == .windows) {
        // zig.bat beside zig.exe: the spawn search could pick either; never cache.
        try tmp.dir.createDirPath(testing.io, "s");
        try putExe(tmp.dir, "s/zig.exe", "exe");
        try putExe(tmp.dir, "s/zig.bat", "@echo 1.0.0");
        try putExe(tmp.dir, "zig.exe", "later");
        var env2 = std.process.Environ.Map.init(arena);
        const pv = try std.mem.concat(arena, u8, &.{ try std.Io.Dir.path.join(arena, &.{ base, "s" }), ";", base });
        const c = try ctxWith(arena, &env2, pv, base);
        try testing.expectEqual(@as(?zigver.Exe, null), zigver.resolve(c));
    } else {
        // a non-executable `zig` is skipped, as execvp skips it
        try tmp.dir.createDirPath(testing.io, "s");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "s/zig", .data = "not executable" });
        try putExe(tmp.dir, "zig", "later");
        var env2 = std.process.Environ.Map.init(arena);
        const pv = try std.mem.concat(arena, u8, &.{ try std.Io.Dir.path.join(arena, &.{ base, "s" }), ":", base });
        const c = try ctxWith(arena, &env2, pv, base);
        const e = zigver.resolve(c) orelse return error.NotResolved;
        try testing.expectEqual(@as(u64, 5), e.size);
    }
}
