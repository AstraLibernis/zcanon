// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Drives the real `zcanon` and `zsnag` binaries in an isolated sandbox.
//!
//! Everything the tools touch is redirected through env vars — `ZCANON_SETTINGS`,
//! `ZCANON_CONFIG` — so a CLI test can install, uninstall and write a book without going
//! anywhere near the developer's own `~/.claude/settings.json` or `~/.config/zcanon`.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Result = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,

    pub fn outContains(r: Result, needle: []const u8) bool {
        return std.mem.find(u8, r.stdout, needle) != null;
    }
    pub fn errContains(r: Result, needle: []const u8) bool {
        return std.mem.find(u8, r.stderr, needle) != null;
    }
};

pub const Sandbox = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    threaded: *std.Io.Threaded,
    dir: []const u8,
    bin: []const u8,
    /// Counter so each invocation gets its own stdin/stdout/stderr files.
    n: usize = 0,

    pub fn init(backing: std.mem.Allocator, name: []const u8) !Sandbox {
        var arena: std.heap.ArenaAllocator = .init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();

        const threaded = try a.create(std.Io.Threaded);
        threaded.* = .init(backing, .{});
        const io = threaded.io();

        // Where `zig build` installed the binaries under test.
        const bin = build_options.bin_dir;

        const dir = try std.fmt.allocPrint(a, ".zig-cache/zcanon-cli/{s}", .{name});
        // deleteTree succeeds on an absent path, so a leftover sandbox from a previous run is
        // cleared and a first run is a no-op. Any other failure is real and must surface.
        try std.Io.Dir.cwd().deleteTree(io, dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);

        return .{ .arena = arena, .io = io, .threaded = threaded, .dir = dir, .bin = bin };
    }

    pub fn deinit(s: *Sandbox) void {
        s.threaded.deinit();
        s.arena.deinit();
    }

    pub fn gpa(s: *Sandbox) std.mem.Allocator {
        return s.arena.allocator();
    }

    pub fn path(s: *Sandbox, rel: []const u8) ![]const u8 {
        return std.fs.path.join(s.gpa(), &.{ s.dir, rel });
    }

    pub fn write(s: *Sandbox, rel: []const u8, contents: []const u8) ![]const u8 {
        const p = try s.path(rel);
        if (std.fs.path.dirname(p)) |d| try std.Io.Dir.cwd().createDirPath(s.io, d);
        try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = p, .data = contents });
        return p;
    }

    pub fn read(s: *Sandbox, rel: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(s.io, try s.path(rel), s.gpa(), .unlimited);
    }

    pub fn exists(s: *Sandbox, rel: []const u8) bool {
        std.Io.Dir.cwd().access(s.io, s.path(rel) catch return false, .{}) catch return false;
        return true;
    }

    /// Run `zcanon <args...>` with the sandbox's settings and config redirected.
    pub fn zcanon(s: *Sandbox, args: []const []const u8) !Result {
        return s.runTool("zcanon", args, null);
    }

    /// Run `zcanon hook` with `payload` on stdin.
    pub fn hook(s: *Sandbox, file: []const u8) !Result {
        // JSON-escape the path: Windows paths carry backslashes, which are invalid JSON
        // escapes when pasted raw (Claude Code itself escapes them).
        const payload = try std.fmt.allocPrint(
            s.gpa(),
            "{{\"tool_name\":\"Edit\",\"tool_input\":{{\"file_path\":{f}}}}}",
            .{std.json.fmt(file, .{})},
        );
        return s.runTool("zcanon", &.{"hook"}, payload);
    }

    /// `zcanon <args...>` with an arbitrary stdin payload — for exercising malformed input.
    pub fn zcanonStdin(s: *Sandbox, args: []const []const u8, stdin: []const u8) !Result {
        return s.runTool("zcanon", args, stdin);
    }

    pub fn zsnag(s: *Sandbox, args: []const []const u8) !Result {
        return s.runTool("zsnag", args, null);
    }

    /// zcanon with extra environment on top of the sandbox's (name, value pairs).
    pub fn zcanonEnv(s: *Sandbox, args: []const []const u8, extra: []const [2][]const u8) !Result {
        return s.runToolEnv("zcanon", args, null, extra);
    }

    fn runTool(s: *Sandbox, tool: []const u8, args: []const []const u8, stdin: ?[]const u8) !Result {
        return s.runToolEnv(tool, args, stdin, &.{});
    }

    fn runToolEnv(s: *Sandbox, tool: []const u8, args: []const []const u8, stdin: ?[]const u8, extra: []const [2][]const u8) !Result {
        const a = s.gpa();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, try std.fs.path.join(a, &.{ s.bin, tool }));
        try argv.appendSlice(a, args);

        // A MINIMAL environment, built from scratch rather than inherited. Everything zcanon
        // writes is redirected into the sandbox, so a CLI test can never reach the developer's
        // real ~/.claude/settings.json or ~/.config/zcanon even if a path resolution regresses.
        var env: std.process.Environ.Map = .init(a);
        try env.put("ZCANON_SETTINGS", try s.path("settings.json"));
        try env.put("ZCANON_CONFIG", try s.path("config"));
        if (build_options.path_env.len > 0) try env.put("PATH", build_options.path_env);
        // Windows resolves a bare `zig` to `zig.exe` through PATHEXT; without it the
        // hook's `zig ast-check` never starts.
        if (builtin.os.tag == .windows) try env.put("PATHEXT", ".COM;.EXE;.BAT;.CMD");
        if (build_options.zephem_home.len > 0) try env.put("ZEPHEM_HOME", build_options.zephem_home);
        for (extra) |kv| try env.put(kv[0], kv[1]);
        // HOME is deliberately absent: if a path ever falls back to it, these tests fail
        // loudly rather than quietly writing to the real home directory.

        // `std.process.run` cannot feed stdin, and the hook reads its payload from there — so
        // spawn directly and route all three streams through files in the sandbox. Files
        // rather than pipes: no reader plumbing, and the raw streams stay on disk for
        // inspection when a test fails.
        s.n += 1;
        const in_path = try std.fmt.allocPrint(a, "io/{d}.in", .{s.n});
        const out_path = try std.fmt.allocPrint(a, "io/{d}.out", .{s.n});
        const err_path = try std.fmt.allocPrint(a, "io/{d}.err", .{s.n});
        _ = try s.write(in_path, stdin orelse "");

        const in_file = try std.Io.Dir.cwd().openFile(s.io, try s.path(in_path), .{});
        defer in_file.close(s.io);
        const out_file = try std.Io.Dir.cwd().createFile(s.io, try s.path(out_path), .{});
        defer out_file.close(s.io);
        const err_file = try std.Io.Dir.cwd().createFile(s.io, try s.path(err_path), .{});
        defer err_file.close(s.io);

        var child = try std.process.spawn(s.io, .{
            .argv = argv.items,
            .environ_map = &env,
            .stdin = .{ .file = in_file },
            .stdout = .{ .file = out_file },
            .stderr = .{ .file = err_file },
        });
        const term = try child.wait(s.io);

        return .{
            .code = switch (term) {
                .exited => |c| c,
                else => 255,
            },
            .stdout = try s.read(out_path),
            .stderr = try s.read(err_path),
        };
    }
};

/// The `additionalContext` string out of a hook response, or null if none was emitted.
pub fn additionalContext(gpa: std.mem.Allocator, stdout: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, gpa, trimmed, .{});
    const hso = switch (v.object.get("hookSpecificOutput") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (hso.get("additionalContext") orelse return null) {
        .string => |str| str,
        else => null,
    };
}
