// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Install / uninstall the PostToolUse hook in Claude Code's settings.json.
//!
//! The file belongs to the user, not to us: everything outside our own marker-tagged entry
//! is round-tripped untouched, and we back up before writing. The marker rides as a shell
//! comment on the command string — the same convention the Nushell version used, so either
//! implementation can uninstall the other's entry.
const std = @import("std");
const builtin = @import("builtin");
const vars = @import("vars.zig");

pub const MARKER = "zcanon-zig-hook";
pub const MATCHER = "Edit|Write|MultiEdit";
pub const TIMEOUT_SECS = 30;

const Value = std.json.Value;

/// The command string written into settings.json, marker included.
///
/// The path is double-quoted: Claude Code runs the command through a shell, and an unquoted
/// path with a space in it (`C:/Users/Jane Doe/...`, `~/My Projects/...`) splits into two
/// words and the hook never runs.
pub fn command(gpa: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    const cmd = try std.fmt.allocPrint(gpa, "\"{s}\" hook  # {s}", .{ exe_path, MARKER });
    // Windows: Claude Code runs hook commands through Git Bash, where `C:\Users\...` loses
    // every backslash even inside double quotes. Forward slashes work in bash, cmd and PowerShell.
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, cmd[1 .. exe_path.len + 1], '\\', '/');
    return cmd;
}

/// The executable an installed command runs: the quoted path, or (for entries written before
/// quoting) everything before ` hook`. Null for a command that isn't one of ours.
pub fn exeFromCommand(cmd: []const u8) ?[]const u8 {
    if (std.mem.find(u8, cmd, MARKER) == null) return null;
    if (cmd.len > 0 and cmd[0] == '"') {
        const close = std.mem.findScalarPos(u8, cmd, 1, '"') orelse return null;
        return cmd[1..close];
    }
    const at = std.mem.find(u8, cmd, " hook") orelse return null;
    return cmd[0..at];
}

/// The command string of our installed entry, if there is one.
pub fn ourCommand(gpa: std.mem.Allocator, root: *Value) ?[]const u8 {
    const arr = (postToolUse(gpa, root, false) catch return null) orelse return null;
    for (arr.items) |e| {
        if (!isOurs(e)) continue;
        for (e.object.get("hooks").?.array.items) |h| {
            const ho = switch (h) {
                .object => |o| o,
                else => continue,
            };
            switch (ho.get("command") orelse continue) {
                .string => |s| if (std.mem.find(u8, s, MARKER) != null) return s,
                else => {},
            }
        }
    }
    return null;
}

fn isOurs(entry: Value) bool {
    const obj = switch (entry) {
        .object => |o| o,
        else => return false,
    };
    const hooks = switch (obj.get("hooks") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    for (hooks.items) |h| {
        const ho = switch (h) {
            .object => |o| o,
            else => continue,
        };
        const cmd = switch (ho.get("command") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.find(u8, cmd, MARKER) != null) return true;
    }
    return false;
}

/// Read and parse, treating "file absent" and "file empty" as an empty object — a first
/// install must not require the user to pre-create settings.json.
///
/// Parsed *leaky* into `arena`: the mutations below allocate into the same arena as the
/// parsed tree, so ownership is one lifetime rather than two that must not be mixed.
pub fn load(c: vars.Ctx, arena: std.mem.Allocator, path: []const u8) !Value {
    const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => try arena.dupe(u8, "{}"),
        else => return e,
    };
    // A UTF-8 BOM is legal in a file an editor wrote and is not whitespace, so trimming alone
    // left it in and every command died on a syntax error.
    const no_bom = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
    const trimmed = std.mem.trim(u8, no_bom, " \t\r\n");
    return std.json.parseFromSliceLeaky(Value, arena, if (trimmed.len == 0) "{}" else trimmed, .{
        // std defaults to error.DuplicateField. A settings file with a repeated key is
        // something a JSON reader accepts (last wins) — refusing to install against it is
        // worse than matching that behaviour.
        .duplicate_field_behavior = .use_last,
    });
}

/// Ensure `root.hooks.PostToolUse` exists as an array and return it.
fn postToolUse(gpa: std.mem.Allocator, root: *Value, create: bool) !?*std.json.Array {
    const robj = switch (root.*) {
        .object => |*o| o,
        else => return error.SettingsNotAnObject,
    };
    if (robj.getPtr("hooks") == null) {
        if (!create) return null;
        try robj.put(gpa, "hooks", .{ .object = .empty });
    }
    const hooks = switch (robj.getPtr("hooks").?.*) {
        .object => |*o| o,
        else => return error.HooksNotAnObject,
    };
    if (hooks.getPtr("PostToolUse") == null) {
        if (!create) return null;
        // std.json.Array is the *managed* list (unlike ObjectMap, which is unmanaged).
        try hooks.put(gpa, "PostToolUse", .{ .array = .init(gpa) });
    }
    return switch (hooks.getPtr("PostToolUse").?.*) {
        .array => |*a| a,
        else => error.PostToolUseNotAnArray,
    };
}

/// Filter our entries out of an array in place. Does not touch surrounding structure — that
/// separation is what keeps `addOurs` from disturbing the user's key order.
fn filterOurs(arr: *std.json.Array) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < arr.items.len) {
        if (isOurs(arr.items[i])) {
            _ = arr.orderedRemove(i);
            removed += 1;
        } else i += 1;
    }
    return removed;
}

/// Drop every marker-tagged entry. Returns how many were removed.
pub fn removeOurs(gpa: std.mem.Allocator, root: *Value) !usize {
    const arr = (try postToolUse(gpa, root, false)) orelse return 0;
    const removed = filterOurs(arr);

    // Clean up scaffolding ONLY if we actually removed something. Running this
    // unconditionally deleted a user's own pre-existing empty "PostToolUse": [] — a key we
    // never created — which is exactly what this module promises not to do.
    if (removed > 0 and arr.items.len == 0) {
        const robj = &root.object;
        const hooks = &robj.getPtr("hooks").?.object;
        _ = hooks.orderedRemove("PostToolUse");
        if (hooks.count() == 0) _ = robj.orderedRemove("hooks");
    }
    return removed;
}

/// Idempotent: any prior marker-tagged entry is replaced, never duplicated.
pub fn addOurs(gpa: std.mem.Allocator, root: *Value, cmd: []const u8) !void {
    // Filter in place rather than calling removeOurs: that would delete an emptied
    // `PostToolUse` and recreate it at the END of `hooks`, silently reordering the user's keys.
    const arr = (try postToolUse(gpa, root, true)).?;
    _ = filterOurs(arr);

    var hook: std.json.ObjectMap = .empty;
    try hook.put(gpa, "type", .{ .string = "command" });
    try hook.put(gpa, "command", .{ .string = cmd });
    try hook.put(gpa, "timeout", .{ .integer = TIMEOUT_SECS });

    var inner: std.json.Array = .init(gpa);
    try inner.append(.{ .object = hook });

    var entry: std.json.ObjectMap = .empty;
    try entry.put(gpa, "matcher", .{ .string = MATCHER });
    try entry.put(gpa, "hooks", .{ .array = inner });

    try arr.append(.{ .object = entry });
}

pub fn isInstalled(gpa: std.mem.Allocator, root: *Value) bool {
    const arr = (postToolUse(gpa, root, false) catch return false) orelse return false;
    for (arr.items) |e| if (isOurs(e)) return true;
    return false;
}

pub fn render(gpa: std.mem.Allocator, root: Value) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
}

/// Write via a sibling temp file + rename, so an interrupted write cannot leave the user
/// with a truncated settings.json. The `.bak` copy is taken first, as the Nushell version did.
pub fn save(c: vars.Ctx, path: []const u8, text: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    // Fail loudly: if the directory can't be made, the write below cannot succeed either,
    // and a swallowed error here is how you end up "installed" with nothing on disk.
    try std.Io.Dir.cwd().createDirPath(c.io, dir);

    if (std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited)) |old| {
        defer c.gpa.free(old);
        const bak = try std.fmt.allocPrint(c.gpa, "{s}.bak", .{path});
        defer c.gpa.free(bak);
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = bak, .data = old });
    } else |_| {}

    const tmp = try std.fmt.allocPrint(c.gpa, "{s}.zcanon-tmp", .{path});
    defer c.gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = tmp, .data = text });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, c.io);
}
