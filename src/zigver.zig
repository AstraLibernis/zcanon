// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The `zig` a hook run would spawn, and its version, cached by the binary's identity.
//!
//! Spawning `zig version` on every hook run was the largest single cost on Windows, where
//! process starts are expensive. The answer only changes when the binary does, so it is cached
//! under the key (resolved path, size, mtime) of the executable found exactly the way
//! `std.process.spawn` finds `zig`: on Windows the working directory first, then PATH, with
//! PATHEXT; on POSIX the PATH entries. Links and junctions are resolved, so pointing a
//! version junction (or symlink) at another Zig changes the key. When the lookup is
//! ambiguous (a `zig.bat` or `zig.cmd` next to, or instead of, `zig.exe`), nothing is cached
//! and the caller spawns `zig` by name, as before.
const std = @import("std");
const builtin = @import("builtin");
const vars = @import("vars.zig");

pub const Exe = struct {
    /// Absolute, links resolved. Spawn this path so the version matches the key.
    path: []const u8,
    size: u64,
    mtime: i96,
};

/// The executable `zig` resolves to, or null when there is none or it cannot be pinned down.
pub fn resolve(c: vars.Ctx) ?Exe {
    if (builtin.os.tag == .windows) {
        // CreateProcess semantics as std implements them: the working directory first.
        if (inDir(c, ".")) |hit| return hit.exe;
    }
    const path_var = c.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (inDir(c, dir)) |hit| return hit.exe;
    }
    return null;
}

/// What one directory says about `zig`: nothing (keep searching), or a final answer, which
/// is null when the directory holds a candidate we will not cache.
const Hit = struct { exe: ?Exe };

fn inDir(c: vars.Ctx, dir: []const u8) ?Hit {
    if (builtin.os.tag == .windows) {
        // Any of these would be picked by the spawn search in this directory; only a lone
        // zig.exe is unambiguous (and a script's "version" is not a binary we can key).
        const names = [_][]const u8{ "zig", "zig.com", "zig.exe", "zig.bat", "zig.cmd" };
        var found_exe = false;
        var found_other = false;
        for (names) |n| {
            const p = std.fs.path.join(c.gpa, &.{ dir, n }) catch return .{ .exe = null };
            defer c.gpa.free(p);
            const st = std.Io.Dir.cwd().statFile(c.io, p, .{}) catch continue;
            if (st.kind != .file) continue;
            if (std.mem.eql(u8, n, "zig.exe")) found_exe = true else found_other = true;
        }
        if (!found_exe and !found_other) return null;
        if (found_other) return .{ .exe = null };
        const p = std.fs.path.join(c.gpa, &.{ dir, "zig.exe" }) catch return .{ .exe = null };
        defer c.gpa.free(p);
        return .{ .exe = identify(c, p) };
    }
    const p = std.fs.path.join(c.gpa, &.{ dir, "zig" }) catch return .{ .exe = null };
    defer c.gpa.free(p);
    // execvp skips entries it cannot execute, so must we.
    std.Io.Dir.cwd().access(c.io, p, .{ .execute = true }) catch return null;
    return .{ .exe = identify(c, p) };
}

fn identify(c: vars.Ctx, p: []const u8) ?Exe {
    const real = std.Io.Dir.cwd().realPathFileAlloc(c.io, p, c.gpa) catch return null;
    const st = std.Io.Dir.cwd().statFile(c.io, real, .{}) catch {
        c.gpa.free(real);
        return null;
    };
    if (st.kind != .file) {
        c.gpa.free(real);
        return null;
    }
    return .{ .path = real, .size = st.size, .mtime = st.mtime.nanoseconds };
}

pub fn cachePath(c: vars.Ctx) ![]u8 {
    const dir = try vars.configDir(c);
    defer c.gpa.free(dir);
    return std.fs.path.join(c.gpa, &.{ dir, "zig-version" });
}

/// One line: `<path>\t<size>\t<mtime ns>\t<version>`. Caller frees.
pub fn render(gpa: std.mem.Allocator, e: Exe, version: []const u8) ![]u8 {
    return gpa.print("{s}\t{d}\t{d}\t{s}\n", .{ e.path, e.size, e.mtime, version });
}

/// The cached version when the cache's key matches `e` exactly; null otherwise.
/// The result slices into `text`.
pub fn match(text: []const u8, e: Exe) ?[]const u8 {
    const line = std.mem.trimEnd(u8, text, "\r\n");
    var f = std.mem.splitScalar(u8, line, '\t');
    const path = f.next() orelse return null;
    const size = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
    const mtime = std.fmt.parseInt(i96, f.next() orelse return null, 10) catch return null;
    const version = f.next() orelse return null;
    if (f.next() != null) return null;
    if (!validVersion(version)) return null;
    if (!std.mem.eql(u8, path, e.path) or size != e.size or mtime != e.mtime) return null;
    return version;
}

/// What `zig version` printed, trimmed, is safe to store: one non-empty token.
pub fn validVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 128) return false;
    for (v) |ch| if (ch <= ' ' or ch == 0x7f) return false;
    return true;
}

/// The cached version for `e`, or null on a miss. The result lives in `c.gpa` until the run's
/// arena goes away (it slices the file's text, which is freed only on a miss).
pub fn cached(c: vars.Ctx, e: Exe) ?[]const u8 {
    const path = cachePath(c) catch return null;
    defer c.gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(8192)) catch return null;
    return match(text, e) orelse {
        c.gpa.free(text);
        return null;
    };
}

/// Store `version` for `e`. Best effort: a failed write only costs the next run a spawn.
/// Written to a temp file named after this process's clock, then renamed, so concurrent hook
/// runs never interleave into one file.
pub fn store(c: vars.Ctx, e: Exe, version: []const u8) void {
    if (!validVersion(version)) return;
    const path = cachePath(c) catch return;
    defer c.gpa.free(path);
    const text = render(c.gpa, e, version) catch return;
    defer c.gpa.free(text);
    const now = std.Io.Timestamp.now(c.io, .awake).nanoseconds;
    const tmp = c.gpa.print("{s}.{d}.tmp", .{ path, now }) catch return;
    defer c.gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(c.io, d) catch return;
    cwd.writeFile(c.io, .{ .sub_path = tmp, .data = text }) catch return;
    cwd.rename(tmp, cwd, path, c.io) catch {
        cwd.deleteFile(c.io, tmp) catch {}; // zsnag:ok — best-effort cleanup of our own temp file
    };
}
