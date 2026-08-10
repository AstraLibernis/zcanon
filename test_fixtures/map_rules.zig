// Fixtures for the zephem-backed rules (R011 deprecated, R012 arity, R013 unknown).
const std = @import("std");

pub fn cases(dst: []u8, src: []const u8, gpa: std.mem.Allocator) !void {
    // R013: invented API, must be flagged as not in the map
    _ = std.mem.copyForwards2;

    // R011: real deprecation; the replacement name must come FROM the map
    _ = std.mem.indexOf(u8, src, "x");

    // R012: parseInt takes 3 args
    _ = try std.fmt.parseInt(u32, "12");

    // correct arity — must stay silent
    _ = try std.fmt.parseInt(u32, "12", 10);

    // trailing comma in a wrapped call — must NOT read as an extra argument
    _ = try std.fmt.allocPrint(
        gpa,
        "{s}",
        .{src},
    );
    _ = dst;
}
