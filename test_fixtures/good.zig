const std = @import("std");

fn readLoop(reader: anytype, w: anytype) !void {
    var remaining: usize = 8;
    while (remaining > 0) : (remaining -= 1) {
        const n = try reader.stream(w, .unlimited);
        if (n == 0) continue; // correct: 0 means "switched modes", keep going
    }
}

fn ok(gpa: std.mem.Allocator) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa); // released
    // the words usingnamespace async await in a comment must NOT trip rules
    try list.append(gpa, 'x');
}
