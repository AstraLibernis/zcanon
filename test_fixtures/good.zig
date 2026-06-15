const std = @import("std");

fn readLoop(reader: anytype, w: anytype) !void {
    while (true) {
        const n = try reader.stream(w, .unlimited);
        if (n == 0) continue;   // correct: keep going
        if (done()) break;
    }
}

fn ok(gpa: std.mem.Allocator) !void {
    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();        // released
    // note: the string "usingnamespace async await" must NOT trip rules
    try list.append('x');
}
