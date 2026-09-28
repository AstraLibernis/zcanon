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
    \\    const pb = b;
    \\
++ twins_body ++
    \\}
    \\
;

/// The body of the `check` step, shared by the helper `addCheck` appends to a project and the
/// build file `writeWrapper` generates: a no-emit twin of every Compile step reachable from
/// the install and test steps of `pb`, added to `b`'s `check` step.
const twins_body =
    \\    var seen: std.AutoArrayHashMapUnmanaged(*std.Build.Step, void) = .empty;
    \\    var stack: std.ArrayList(*std.Build.Step) = .empty;
    \\    stack.append(b.allocator, pb.getInstallStep()) catch @panic("OOM");
    \\    if (pb.top_level_steps.get("test")) |t| stack.append(b.allocator, &t.step) catch @panic("OOM");
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
    \\
;

/// Write the build file zcanon runs `zig build check` in for a project: `dir/build.zig` plus
/// a `build.zig.zon` naming `root` as a path dependency (relative, as the format requires).
/// The project is checked for the host and for each of `targets` (Zig triples such as
/// `x86_64-windows`): code built only for another OS is otherwise never analysed. Files are
/// rewritten only when they differ, so an identical write does not restart the watcher.
pub fn writeWrapper(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, root: []const u8, targets: []const []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const rel = try std.fs.path.relative(gpa, "/", null, dir, root);

    var build: std.ArrayList(u8) = .empty;
    try build.appendSlice(gpa,
        \\// Generated by zcanon; rewritten when stale. It loads the project as a dependency — its
        \\// build.zig is only read — and adds a `check` step that type-checks everything the
        \\// project builds, without emitting binaries, for zcanon's background compiler.
        \\const std = @import("std");
        \\
        \\/// Checked in addition to the host (`zcanon targets`).
        \\const extra_targets = [_][]const u8{
    );
    for (targets) |t| try build.print(gpa, " \"{s}\",", .{t});
    try build.appendSlice(gpa,
        \\ };
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const check = b.step("check", "Type-check the project without emitting binaries (zcanon)");
        \\    twins(b, check, b.dependency("project", .{}).builder);
        \\    for (extra_targets) |triple| {
        \\        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("zcanon: bad target");
        \\        twins(b, check, b.dependency("project", .{ .target = b.resolveTargetQuery(query) }).builder);
        \\    }
        \\}
        \\
        \\fn twins(b: *std.Build, check: *std.Build.Step, pb: *std.Build) void {
        \\
    );
    try build.appendSlice(gpa, twins_body);
    try build.appendSlice(gpa, "}\n");

    // The fingerprint is Zig's package identity; this one is valid for the name below.
    const zon = try std.fmt.allocPrint(gpa,
        \\.{{
        \\    .name = .zcanon_wrap,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0xbb9e267b1d99cdff,
        \\    .dependencies = .{{ .project = .{{ .path = "{s}" }} }},
        \\    .paths = .{{""}},
        \\}}
        \\
    , .{rel});
    for ([_][2][]const u8{ .{ "build.zig", build.items }, .{ "build.zig.zon", zon } }) |f| {
        const path = try std.fs.path.join(gpa, &.{ dir, f[0] });
        const cur = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch "";
        if (std.mem.eql(u8, cur, f[1])) continue;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = f[1] });
    }
}

/// Extra targets per project, one line each: `<root>\t<triple>,<triple>`. Kept in zcanon's
/// own folder, never in the project.
pub fn readTargets(gpa: std.mem.Allocator, io: std.Io, path: []const u8, root: []const u8) ![]const []const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return &.{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
        if (!std.mem.eql(u8, line[0..tab], root)) continue;
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, line[tab + 1 ..], ',');
        while (it.next()) |t| try out.append(gpa, t);
        return out.items;
    }
    return &.{};
}

/// Set `root`'s extra targets (none removes its line).
pub fn writeTargets(gpa: std.mem.Allocator, io: std.Io, path: []const u8, root: []const u8, targets: []const []const u8) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch "";
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], root)) continue;
        try out.print(gpa, "{s}\n", .{line});
    }
    if (targets.len > 0) {
        try out.print(gpa, "{s}\t", .{root});
        for (targets, 0..) |t, i| try out.print(gpa, "{s}{s}", .{ if (i > 0) "," else "", t });
        try out.append(gpa, '\n');
    }
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

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
