// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Path resolution. Every location is env-overridable and derived from `$HOME` otherwise —
//! nothing is hardcoded to a particular checkout. `$HOME` itself has no fallback: if it is
//! missing we fail loudly rather than silently writing state somewhere surprising.
//! (Windows only: `%USERPROFILE%` stands in for an unset `$HOME`, since Windows doesn't set it.)
const std = @import("std");
const builtin = @import("builtin");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,

    pub fn get(c: Ctx, name: []const u8) ?[]const u8 {
        const v = c.env.get(name) orelse return null;
        return if (v.len == 0) null else v;
    }
};

pub const Error = error{HomeNotSet} || std.mem.Allocator.Error;

pub fn home(c: Ctx) Error![]const u8 {
    if (c.get("HOME")) |h| return h;
    if (builtin.os.tag == .windows) {
        if (c.get("USERPROFILE")) |h| return h;
    }
    return error.HomeNotSet;
}

/// Claude Code's config directory: `$CLAUDE_CONFIG_DIR` when Claude Code was pointed
/// elsewhere, else `~/.claude`.
pub fn claudeDir(c: Ctx) Error![]u8 {
    if (c.get("CLAUDE_CONFIG_DIR")) |p| return c.gpa.dupe(u8, p);
    return std.fs.path.join(c.gpa, &.{ try home(c), ".claude" });
}

/// The Claude Code settings file the hook installs itself into.
/// `$ZCANON_SETTINGS` overrides, which is what the tests use.
pub fn settingsPath(c: Ctx) Error![]u8 {
    if (c.get("ZCANON_SETTINGS")) |p| return c.gpa.dupe(u8, p);
    const dir = try claudeDir(c);
    defer c.gpa.free(dir);
    return std.fs.path.join(c.gpa, &.{ dir, "settings.json" });
}

/// Where the skill is installed. `$ZCANON_SKILL` overrides, which is what the tests use.
pub fn skillPath(c: Ctx) Error![]u8 {
    if (c.get("ZCANON_SKILL")) |p| return c.gpa.dupe(u8, p);
    const dir = try claudeDir(c);
    defer c.gpa.free(dir);
    return std.fs.path.join(c.gpa, &.{ dir, "skills", "zcanon", "SKILL.md" });
}

/// Local state: the book and the hook's off switch.
pub fn configDir(c: Ctx) Error![]u8 {
    if (c.get("ZCANON_CONFIG")) |p| return c.gpa.dupe(u8, p);
    return std.fs.path.join(c.gpa, &.{ try home(c), ".config", "zcanon" });
}

/// `$ZCANON_BOOK` overrides. Note the extension change from the sqlite era: the book is a
/// TSV now, so a stale `book.db` alongside it is inert rather than half-read.
pub fn bookPath(c: Ctx) Error![]u8 {
    if (c.get("ZCANON_BOOK")) |p| return c.gpa.dupe(u8, p);
    const dir = try configDir(c);
    defer c.gpa.free(dir);
    return std.fs.path.join(c.gpa, &.{ dir, "book.tsv" });
}

/// `zcanon setup` records the zephem checkout it found here, so nothing needs
/// `$ZEPHEM_HOME` set afterwards.
pub fn zephemRecordPath(c: Ctx) Error![]u8 {
    const dir = try configDir(c);
    defer c.gpa.free(dir);
    return std.fs.path.join(c.gpa, &.{ dir, "zephem-home" });
}

/// Touched at the end of every hook run. A Bash run checks every `.zig` file modified since —
/// the edits a shell command made (`sed -i`, a heredoc, a script) that no file_path names.
pub fn stampPath(c: Ctx) Error![]u8 {
    if (c.get("ZCANON_STAMP")) |p| return c.gpa.dupe(u8, p);
    const dir = try configDir(c);
    defer c.gpa.free(dir);
    return std.fs.path.join(c.gpa, &.{ dir, "last-hook" });
}

/// Presence of this file disables the hook without touching settings.json.
pub fn disableFlagPath(c: Ctx) Error![]u8 {
    const dir = try configDir(c);
    defer c.gpa.free(dir);
    return std.fs.path.join(c.gpa, &.{ dir, "hook.disabled" });
}

/// Absolute path to this binary, so the installed hook command points at the running build
/// rather than a guessed checkout. `std.fs.selfExePath` was removed in 0.16; the lookup now
/// lives on the Io layer.
pub fn selfExe(c: Ctx) ![:0]u8 {
    return std.process.executablePathAlloc(c.io, c.gpa);
}

/// The linter's file name beside zcanon (Windows executables carry `.exe`).
pub const zsnag_name = if (builtin.os.tag == .windows) "zsnag.exe" else "zsnag";

/// zsnag lives beside the running zcanon binary.
pub fn zsnagPath(c: Ctx) ![]u8 {
    const self = try selfExe(c);
    const bin_dir = std.fs.path.dirname(self) orelse ".";
    return std.fs.path.join(c.gpa, &.{ bin_dir, zsnag_name });
}
