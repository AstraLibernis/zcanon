// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Path resolution. Every location is env-overridable and derived from `$HOME` otherwise —
//! nothing is hardcoded to a particular checkout. `$HOME` itself has no fallback: if it is
//! missing we fail loudly rather than silently writing state somewhere surprising.
const std = @import("std");

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

fn home(c: Ctx) Error![]const u8 {
    return c.get("HOME") orelse error.HomeNotSet;
}

/// The Claude Code settings file the hook installs itself into.
/// `$ZCANON_SETTINGS` overrides, which is what the tests use.
pub fn settingsPath(c: Ctx) Error![]u8 {
    if (c.get("ZCANON_SETTINGS")) |p| return c.gpa.dupe(u8, p);
    return std.fs.path.join(c.gpa, &.{ try home(c), ".claude", "settings.json" });
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
