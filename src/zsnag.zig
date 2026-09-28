// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zsnag — catch the mistakes an LLM tends to make writing Zig 0.16.
//!
//!   zsnag file.zig [more.zig ...]    check files
//!   zsnag --json file.zig           one JSON object per finding (JSONL)
//!   zsnag --list-rules              print the rule registry
//!
//! Findings go to STDOUT (they are the output); diagnostics go to stderr.
//! Exit code is non-zero if any 'error'-severity finding is present.
//!
//! The rules and the scan live in snag.zig; this is argument handling and rendering.
const std = @import("std");
const snag = @import("snag.zig");
const zephem = @import("zephem.zig");
const vars = @import("vars.zig");

const usage =
    \\usage: zsnag [--json] [--no-map] [--check-existence] [--list-rules] file.zig ...
    \\
    \\  --json            one JSON object per finding (JSONL)
    \\  --no-map          skip the zephem-backed rules (R011 deprecated, R012 arity)
    \\  --check-existence enable R013: flag a std path with no map entry (opt-in)
    \\  --list-rules      print the rule registry
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var out_buf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const out = &ow.interface;

    var json = false;
    var no_map = false;
    var check_existence = false;
    var nfiles: usize = 0;
    var bad_read = false;
    var all_parsed = true;
    var stale: []const snag.Id = &.{};
    var findings: std.ArrayList(snag.Finding) = .empty;

    // Flags are read in a first pass so `zsnag a.zig --json b.zig` formats both files the
    // same way, rather than switching format midstream.
    var argv: std.ArrayList([]const u8) = .empty;
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--no-map")) {
            no_map = true;
        } else if (std.mem.eql(u8, a, "--check-existence")) {
            check_existence = true;
        } else if (std.mem.eql(u8, a, "--list-rules")) {
            try snag.listRules(out);
            try out.flush();
            return;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            return;
        } else {
            try argv.append(gpa, a);
        }
    }

    // The zephem map backs R011/R012/R013. Its absence is REPORTED, never silently skipped:
    // "no findings" must not be indistinguishable from "those rules never ran".
    const c: vars.Ctx = .{ .gpa = gpa, .io = io, .env = init.environ_map };
    var map: ?zephem.Map = null;
    defer if (map) |*m| m.deinit();
    if (!no_map) {
        if (zephem.load(c)) |m| {
            map = m;
            if (try zephem.staleness(c, zigVersion(c))) |warn|
                try stderr(io, "zsnag: {s}\n", .{warn});
            stale = try snag.stalePremises(gpa, &map.?);
            for (stale) |id| {
                try stderr(io, "zsnag: rule {s} is DISABLED — the map contradicts its premise: {s}\n", .{
                    snag.ruleOf(id).code, snag.ruleOf(id).premise,
                });
            }
        } else |e| switch (e) {
            error.NoLookupTable => try stderr(io, "zsnag: R011/R012/R013 did NOT run — {s}\n", .{zephem.remedy}),
            else => try stderr(io, "zsnag: R011/R012/R013 did NOT run — {s}\n", .{@errorName(e)}),
        }
    }

    for (argv.items) |path| {
        nfiles += 1;
        const src = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch |e| {
            // A file we cannot read is a real failure, not a silent skip.
            try stderr(io, "zsnag: cannot read {s}: {s}\n", .{ path, @errorName(e) });
            bad_read = true;
            continue;
        };
        var parsed = false;
        try snag.scanWithOpts(gpa, path, src, &findings, .{
            .map = if (map) |*m| m else null,
            .check_existence = check_existence,
            .ran_structural = &parsed,
            .stale = stale,
        });
        // One unparseable file is enough to make the structural rules' silence meaningless
        // for this invocation.
        if (!parsed) all_parsed = false;
    }

    if (nfiles == 0) {
        try stderr(io, usage, .{});
        std.process.exit(2);
    }

    if (json) {
        // Status first, so a consumer knows which groups ran before it reads any findings.
        var groups: std.ArrayList(snag.Group) = .empty;
        try groups.append(gpa, .core);
        if (all_parsed) try groups.append(gpa, .structural);
        if (map != null) try groups.append(gpa, .map);
        try snag.renderStatus(out, groups.items);
        try snag.renderJson(out, findings.items);
    } else {
        try snag.renderText(out, findings.items);
    }
    try out.flush();

    // Distinct exit codes: an unreadable file is not the same event as "found error-severity
    // findings", and conflating them let a failed read be recorded as a successful scan.
    if (bad_read) std.process.exit(3);
    if (snag.anyError(findings.items)) std.process.exit(1);
}

fn zigVersion(c: vars.Ctx) []const u8 {
    const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ "zig", "version" } }) catch return "unknown";
    return std.mem.trim(u8, r.stdout, " \t\r\n");
}

fn stderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
