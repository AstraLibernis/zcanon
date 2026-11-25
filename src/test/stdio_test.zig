// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! B37: output through an asynchronous Windows pipe (what Git Bash hands a program) arrives whole.
const std = @import("std");
const builtin = @import("builtin");
const stdio = @import("zcanon").stdio;

const windows = std.os.windows;

/// An inbound pipe: [0] the synchronous reading end, [1] the writing end in `write_mode`.
fn pipe(write_mode: windows.FILE.MODE) ![2]windows.HANDLE {
    return std.testing.io_instance.windowsCreatePipe(.{
        .server = .{ .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
        .client = .{ .mode = write_mode },
        .inbound = true,
    });
}

test "prepare marks only an asynchronous handle nonblocking" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    inline for (.{ .{ windows.FILE.MODE{ .IO = .ASYNCHRONOUS }, true }, .{ windows.FILE.MODE{ .IO = .SYNCHRONOUS_NONALERT }, false } }) |case| {
        const ends = try pipe(case[0]);
        const read_end: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
        const write_end: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
        defer read_end.close(io);
        defer write_end.close(io);
        try std.testing.expectEqual(case[1], stdio.prepare(write_end).flags.nonblocking);
    }
}

fn drain(file: std.Io.File, got: *usize) void {
    var buf: [512]u8 = undefined;
    var r = file.readerStreaming(std.testing.io, &buf);
    got.* = r.interface.discardRemaining() catch 0;
}

test "a full asynchronous pipe takes every byte (std alone panics here)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const ends = try pipe(.{ .IO = .ASYNCHRONOUS });
    const read_end: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    defer read_end.close(io);

    var got: usize = 0;
    const reader = try std.Thread.spawn(.{}, drain, .{ read_end, &got });

    // The pipe holds 4 KiB; 256 KiB written in 1 KiB pieces fills it many times over.
    const total: usize = 256 * 1024;
    {
        const write_end = stdio.prepare(.{ .handle = ends[1], .flags = .{ .nonblocking = false } });
        defer write_end.close(io);
        var buf: [1024]u8 = undefined;
        var w = write_end.writerStreaming(io, &buf);
        const chunk: [1024]u8 = @splat('x');
        for (0..total / chunk.len) |_| try w.interface.writeAll(&chunk);
        try w.interface.flush();
    }
    reader.join();
    try std.testing.expectEqual(total, got);
}
