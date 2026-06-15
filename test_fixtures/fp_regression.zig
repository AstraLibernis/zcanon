// False-positive regression — patterns found in real code (zls, zig-clap) that
// zsnag must NOT flag. If any rule fires here, we've regressed.
const std = @import("std");

fn methodsNamedAsyncAwait(wg: anytype, io: anytype) !void {
    wg.async(io, .{}); // method named `async` — NOT the removed keyword (no R001)
    try wg.await(io);  // method named `await` — NOT the removed keyword (no R001)
}

fn noDeinitNeeded() void {
    const fba = std.heap.FixedBufferAllocator.init(""); // no deinit exists (no R008)
    _ = fba;
}
