// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Semantic checking: the pure parts of the background compiler. The daemon runs
//! `zig build check --watch -fincremental` in a project; this file parses what that prints,
//! finds a file's project, and adds the `check` step to a build.zig that lacks one.
//!
//! Why a `check` step: it is the convention ZLS uses for build-on-save. It compiles every
//! artifact without emitting a binary, so the compiler does full semantic analysis (types,
//! calls, fields) and skips codegen. Kept warm with -fincremental it re-checks a project in
//! ~10 ms per edit, against ~240 ms cold.
const std = @import("std");

pub const Diag = struct {
    /// As the compiler printed it: relative to the build root, or absolute.
    path: []const u8,
    line: u32,
    col: u32,
    /// "error" or "note".
    severity: []const u8,
    message: []const u8,
};

/// One diagnostic line: `<path>:<line>:<col>: error: <msg>` (or `note:`), at column 0.
/// The indented source echo, carets, "referenced by" traces and the build runner's own
/// lines never match. Returns null for anything else.
pub fn parseDiagLine(line: []const u8) ?Diag {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return null;
    const sev: []const u8, const sep: []const u8 = if (std.mem.find(u8, line, ": error: ") != null)
        .{ "error", ": error: " }
    else if (std.mem.find(u8, line, ": note: ") != null)
        .{ "note", ": note: " }
    else
        return null;
    const at = std.mem.find(u8, line, sep).?;
    const loc = line[0..at];
    const c2 = std.mem.findScalarLast(u8, loc, ':') orelse return null;
    const c1 = std.mem.findScalarLast(u8, loc[0..c2], ':') orelse return null;
    if (c1 == 0) return null;
    return .{
        .path = loc[0..c1],
        .line = std.fmt.parseInt(u32, loc[c1 + 1 .. c2], 10) catch return null,
        .col = std.fmt.parseInt(u32, loc[c2 + 1 ..], 10) catch return null,
        .severity = sev,
        .message = line[at + sep.len ..],
    };
}

/// Accumulates the watcher's output one line at a time. Each rebuild ends with a
/// `Build Summary:` line; `feed` returns true on that line, and `diags` then holds that
/// build's diagnostics, deduplicated (the same error is reported once per compile step that
/// includes the file — the exe and its tests, say).
pub const Collector = struct {
    gpa: std.mem.Allocator,
    diags: std.ArrayList(Diag) = .empty,
    /// Text the current `diags` slice into; owned.
    strings: std.ArrayList([]u8) = .empty,

    pub fn deinit(k: *Collector) void {
        k.clear();
        k.diags.deinit(k.gpa);
        k.strings.deinit(k.gpa);
    }

    pub fn clear(k: *Collector) void {
        for (k.strings.items) |s| k.gpa.free(s);
        k.strings.clearRetainingCapacity();
        k.diags.clearRetainingCapacity();
    }

    pub fn feed(k: *Collector, line: []const u8) !bool {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "Build Summary:")) return true;
        const d = parseDiagLine(trimmed) orelse return false;
        for (k.diags.items) |seen| {
            if (seen.line == d.line and seen.col == d.col and std.mem.eql(u8, seen.path, d.path) and
                std.mem.eql(u8, seen.severity, d.severity) and std.mem.eql(u8, seen.message, d.message)) return false;
        }
        const owned = try k.gpa.dupe(u8, trimmed);
        errdefer k.gpa.free(owned);
        try k.strings.append(k.gpa, owned);
        var copy = parseDiagLine(owned).?;
        copy.severity = if (std.mem.eql(u8, d.severity, "error")) "error" else "note";
        try k.diags.append(k.gpa, copy);
        return false;
    }
};

/// The nearest directory at or above `file`'s own that holds a build.zig, or null.
pub fn projectRoot(gpa: std.mem.Allocator, io: std.Io, file: []const u8) !?[]const u8 {
    var dir: []const u8 = std.fs.path.dirname(file) orelse return null;
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ dir, "build.zig" });
        defer gpa.free(candidate);
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| {
            return try gpa.dupe(u8, dir);
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// The helper `addCheck` appends, and the marker it is recognised by.
pub const marker = "zcanonCheck";

const helper =
    \\
    \\// Added by zcanon: `zig build check` type-checks every artifact the install and test steps
    \\// build, without emitting binaries. zcanon's background compiler runs it incrementally on
    \\// each edit to report real compile errors. Safe to delete (with its call in `build`).
    \\fn zcanonCheck(b: *std.Build) void {
    \\    const check = b.step("check", "Type-check without emitting binaries (added by zcanon)");
    \\    var seen: std.AutoArrayHashMapUnmanaged(*std.Build.Step, void) = .empty;
    \\    var stack: std.ArrayList(*std.Build.Step) = .empty;
    \\    stack.append(b.allocator, b.getInstallStep()) catch @panic("OOM");
    \\    if (b.top_level_steps.get("test")) |t| stack.append(b.allocator, &t.step) catch @panic("OOM");
    \\    while (stack.pop()) |step| {
    \\        if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) continue;
    \\        stack.appendSlice(b.allocator, step.dependencies.items) catch @panic("OOM");
    \\        const a = step.cast(std.Build.Step.Compile) orelse continue;
    \\        const twin = switch (a.kind) {
    \\            .exe => b.addExecutable(.{ .name = a.name, .root_module = a.root_module }),
    \\            .lib => b.addLibrary(.{ .name = a.name, .root_module = a.root_module, .linkage = a.linkage orelse .static }),
    \\            .@"test" => b.addTest(.{ .name = a.name, .root_module = a.root_module }),
    \\            else => continue,
    \\        };
    \\        check.dependOn(&twin.step);
    \\    }
    \\}
    \\
;

pub const AddCheckError = error{
    /// build.zig does not parse; nothing to edit safely.
    BuildZigInvalid,
    /// No top-level `fn build(<param>: …)` to call the helper from.
    NoBuildFn,
    /// The helper is already there.
    AlreadyAdded,
} || std.mem.Allocator.Error;

/// build.zig's source with the `check` step added: a call at the end of `build`'s body, using
/// its own parameter name, and the helper appended to the file. Located with the parser, not
/// by text search, so a comment or string that looks like `fn build` cannot misplace it.
pub fn addCheck(gpa: std.mem.Allocator, src: [:0]const u8) AddCheckError![]u8 {
    if (std.mem.find(u8, src, marker) != null) return error.AlreadyAdded;
    var tree = try std.zig.Ast.parse(gpa, src, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.BuildZigInvalid;

    for (tree.rootDecls()) |node| {
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_tok), "build")) continue;
        var params = proto.iterate(&tree);
        const p = params.next() orelse return error.NoBuildFn;
        const param = tree.tokenSlice(p.name_token orelse return error.NoBuildFn);

        // The fn decl's last token is its body's closing brace.
        const close = tree.tokenStart(tree.lastToken(node));
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const head = std.mem.trimEnd(u8, src[0..close], " \t\r\n");
        try out.appendSlice(gpa, head);
        try out.print(gpa, "\n\n    {s}({s}); // zcanon: the `check` step\n", .{ marker, param });
        try out.appendSlice(gpa, src[close..]);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.appendSlice(gpa, helper);
        return out.toOwnedSlice(gpa);
    }
    return error.NoBuildFn;
}
