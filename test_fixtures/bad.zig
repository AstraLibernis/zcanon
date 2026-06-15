const std = @import("std");
usingnamespace @import("foo.zig");

fn oldAsync() void {
    const x = async something();   // removed
    _ = await x;                    // removed
}

fn copies(dst: []u8, src: []const u8) void {
    std.mem.copy(u8, dst, src);     // removed -> @memcpy
}

fn readLoop(reader: anytype, w: anytype) !void {
    while (true) {
        const n = try reader.stream(w, .unlimited);
        if (n == 0) break;          // footgun: 0 != EOF
    }
}

fn risky(gpa: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(gpa);   // acquired, never deinit'd
    const f = try std.fs.cwd().openFile("x", .{});  // never closed
    const v: u8 = @intCast(someBig());          // can panic
    doThing() catch unreachable;                // crashes in release
    other() catch {};                           // swallowed error
    std.debug.print("dbg {}\n", .{v});          // leftover
    _ = std.heap.page_allocator;                // default allocator smell
    _ = list; _ = f;
}
