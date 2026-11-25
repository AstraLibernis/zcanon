// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! stdout and stderr as Files the std writer can drive on every OS (B37).
//!
//! Zig 0.17.1's std assumes a standard handle is synchronous. Git Bash (MSYS) hands a Windows
//! program asynchronous pipes, so once the pipe fills `NtWriteFile` returns STATUS_PENDING and
//! std hits `.PENDING => unreachable`, truncating the output. Marking such a handle nonblocking
//! sends std down its APC path, which waits for the pending write. Elsewhere this is a no-op.
const std = @import("std");
const builtin = @import("builtin");

pub fn stdout() std.Io.File {
    return prepare(std.Io.File.stdout());
}

pub fn stderr() std.Io.File {
    return prepare(std.Io.File.stderr());
}

/// `f`, with `flags.nonblocking` set when it is a Windows handle opened for asynchronous I/O.
/// A handle the query cannot read (console, invalid) is returned unchanged.
pub fn prepare(f: std.Io.File) std.Io.File {
    if (builtin.os.tag != .windows) return f;
    var out = f;
    if (isAsync(f.handle)) out.flags.nonblocking = true;
    return out;
}

fn isAsync(handle: std.Io.File.Handle) bool {
    const w = std.os.windows;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var mode: w.FILE.MODE = @bitCast(@as(w.ULONG, 0));
    const status = w.ntdll.NtQueryInformationFile(handle, &iosb, &mode, @sizeOf(w.FILE.MODE), .Mode);
    return status == .SUCCESS and mode.IO == .ASYNCHRONOUS;
}
