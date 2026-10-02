// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Publishing the book: a shared history of mistakes, committed into a git repo (by default
//! zcanon's own checkout) under `history/`, so the record outlives any one machine's
//! `~/.config/zcanon`.
//!
//! What leaves the machine is SANITIZED: rule, severity, count, first/last date, the project's
//! name and the message *pattern* (compiler messages with every quoted name already turned
//! into '…' by `book.pattern`). Never a file path, a line number, the message as reported or
//! the source line: the book records mistakes made in private repos too, and the target repo
//! may be public.
//!
//! Counts merge by maximum, never by sum: the local book only ever grows, so re-publishing the
//! same book is a no-op, and a book that was reset (a fresh install) cannot shrink the shared
//! record. The cost: two machines contributing to one history undercount (each row shows the
//! larger of the two).
//!
//! Off by default. `zcanon book publish on` turns on the daily run; the hook then starts
//! `zcanon book publish --auto` in the background at most once per `interval_secs`. The commit
//! is made in a private worktree beside the book, on top of the remote branch, and touches only
//! `history/`, so it never picks up the work in progress in the developer's own checkout.
const std = @import("std");
const book = @import("book.zig");
const vars = @import("vars.zig");

pub const interval_secs: i64 = 24 * 60 * 60;
pub const dir_name = "history";
pub const tsv_name = "mistakes.tsv";
pub const md_name = "README.md";

/// One mistake in one project.
pub const Row = struct {
    rule: []const u8,
    severity: []const u8,
    count: u64,
    first_ts: []const u8,
    last_ts: []const u8,
    project: []const u8,
    pattern: []const u8,

    fn sameKey(a: Row, b: Row) bool {
        return std.mem.eql(u8, a.project, b.project) and
            std.mem.eql(u8, a.rule, b.rule) and
            std.mem.eql(u8, a.pattern, b.pattern);
    }
};

pub const header = "rule\tseverity\tcount\tfirst_ts\tlast_ts\tproject\tpattern";
const n_cols = 7;

/// A book entry with everything that could identify code taken out. `project` comes from the
/// caller (`projectOf`); the file it was derived from is dropped here.
pub fn sanitize(e: book.Entry, project: []const u8) Row {
    return .{
        .rule = e.rule,
        .severity = e.severity,
        .count = e.count,
        .first_ts = e.first_ts,
        .last_ts = e.last_ts,
        .project = project,
        .pattern = e.pattern,
    };
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8, rows: *std.ArrayList(Row)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "rule\t")) continue;
        var f: [n_cols][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, '\t');
        var n: usize = 0;
        while (it.next()) |field| : (n += 1) {
            if (n >= n_cols) break;
            f[n] = field;
        }
        if (n != n_cols) continue;
        try rows.append(gpa, .{
            .rule = try book.unescape(gpa, f[0]),
            .severity = try book.unescape(gpa, f[1]),
            .count = std.fmt.parseInt(u64, f[2], 10) catch continue,
            .first_ts = try book.unescape(gpa, f[3]),
            .last_ts = try book.unescape(gpa, f[4]),
            .project = try book.unescape(gpa, f[5]),
            .pattern = try book.unescape(gpa, f[6]),
        });
    }
}

/// Sorted by project, then rule, then pattern, so a re-publish diffs line by line.
pub fn write(w: *std.Io.Writer, rows: []Row) !void {
    std.mem.sortUnstable(Row, rows, {}, lessThan);
    try w.writeAll(header);
    try w.writeByte('\n');
    for (rows) |r| {
        try book.escape(w, r.rule);
        try w.writeByte('\t');
        try book.escape(w, r.severity);
        try w.print("\t{d}\t", .{r.count});
        try book.escape(w, r.first_ts);
        try w.writeByte('\t');
        try book.escape(w, r.last_ts);
        try w.writeByte('\t');
        try book.escape(w, r.project);
        try w.writeByte('\t');
        try book.escape(w, r.pattern);
        try w.writeByte('\n');
    }
}

fn lessThan(_: void, a: Row, b: Row) bool {
    inline for (.{ "project", "rule", "pattern" }) |name| {
        switch (std.mem.order(u8, @field(a, name), @field(b, name))) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    return false;
}

/// Fold `fresh` into `rows`: count is the maximum of the two, the dates widen. True when
/// anything changed.
pub fn merge(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), fresh: []const Row) !bool {
    var changed = false;
    next: for (fresh) |f| {
        for (rows.items) |*r| {
            if (!r.sameKey(f)) continue;
            if (f.count > r.count) {
                r.count = f.count;
                changed = true;
            }
            if (std.mem.order(u8, f.first_ts, r.first_ts) == .lt) {
                r.first_ts = f.first_ts;
                changed = true;
            }
            if (std.mem.order(u8, f.last_ts, r.last_ts) == .gt) {
                r.last_ts = f.last_ts;
                r.severity = f.severity;
                changed = true;
            }
            continue :next;
        }
        try rows.append(gpa, f);
        changed = true;
    }
    return changed;
}

/// The readable copy: one row per mistake, its counts summed across projects, most frequent
/// first.
pub fn render(gpa: std.mem.Allocator, w: *std.Io.Writer, rows: []const Row) !void {
    const Agg = struct {
        rule: []const u8,
        pattern: []const u8,
        total: u64,
        first_ts: []const u8,
        last_ts: []const u8,
        projects: std.ArrayList([]const u8),
    };
    var aggs: std.ArrayList(Agg) = .empty;
    var total: u64 = 0;
    var projects: std.ArrayList([]const u8) = .empty;
    for (rows) |r| {
        total += r.count;
        if (!contains(projects.items, r.project)) try projects.append(gpa, r.project);
        const a = for (aggs.items) |*a| {
            if (std.mem.eql(u8, a.rule, r.rule) and std.mem.eql(u8, a.pattern, r.pattern)) break a;
        } else blk: {
            try aggs.append(gpa, .{ .rule = r.rule, .pattern = r.pattern, .total = 0, .first_ts = r.first_ts, .last_ts = r.last_ts, .projects = .empty });
            break :blk &aggs.items[aggs.items.len - 1];
        };
        a.total += r.count;
        if (std.mem.order(u8, r.first_ts, a.first_ts) == .lt) a.first_ts = r.first_ts;
        if (std.mem.order(u8, r.last_ts, a.last_ts) == .gt) a.last_ts = r.last_ts;
        if (!contains(a.projects.items, r.project)) try a.projects.append(gpa, r.project);
    }
    std.mem.sortUnstable(Agg, aggs.items, {}, struct {
        fn lt(_: void, a: Agg, b: Agg) bool {
            if (a.total != b.total) return a.total > b.total;
            return switch (std.mem.order(u8, a.rule, b.rule)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a.pattern, b.pattern) == .lt,
            };
        }
    }.lt);
    std.mem.sortUnstable([]const u8, projects.items, {}, strLess);

    try w.writeAll(
        \\# zcanon mistake history
        \\
        \\Every mistake zcanon's hook has caught in Zig written with it: zsnag rules (`R0NN`), `zig ast-check`
        \\and the background compiler (`compile`). Generated by `zcanon book publish`; do not edit by hand.
        \\Sanitized: message patterns only (quoted names shown as '…'), never code or file paths.
        \\Raw data: [mistakes.tsv](mistakes.tsv), one row per mistake per project.
        \\
        \\
    );
    try w.print("{d} mistakes made {d} times, across: ", .{ aggs.items.len, total });
    for (projects.items, 0..) |p, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", p });
    try w.writeAll("\n\n| Count | Rule | Mistake | Projects | First | Last |\n|---:|---|---|---|---|---|\n");
    for (aggs.items) |*a| {
        std.mem.sortUnstable([]const u8, a.projects.items, {}, strLess);
        try w.print("| {d} | {s} | ", .{ a.total, a.rule });
        try cell(w, a.pattern);
        try w.writeAll(" | ");
        for (a.projects.items, 0..) |p, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", p });
        try w.print(" | {s} | {s} |\n", .{ day(a.first_ts), day(a.last_ts) });
    }
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn day(ts: []const u8) []const u8 {
    return ts[0..@min(ts.len, 10)];
}

/// A markdown table cell: `|` would end it and a newline would end the table.
fn cell(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '|' => try w.writeAll("\\|"),
        '\n', '\r' => try w.writeByte(' '),
        else => try w.writeByte(ch),
    };
}

// ---- the machine side ------------------------------------------------------------------

/// The project a file belongs to: the name of the nearest enclosing directory that holds a
/// `.git`. A file in no repository is `-`, so a stray scratch path never leaks its folders.
pub fn projectOf(c: vars.Ctx, file: []const u8) []const u8 {
    var dir = std.fs.path.dirname(file);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const dot_git = std.fs.path.join(c.gpa, &.{ d, ".git" }) catch return "-";
        if (exists(c, dot_git)) return std.fs.path.basename(d);
    }
    return "-";
}

fn exists(c: vars.Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(c.io, path, .{}) catch return false;
    return true;
}

/// A file kept beside the book.
pub fn sidePath(c: vars.Ctx, name: []const u8) ![]const u8 {
    const book_path = try vars.bookPath(c);
    return std.fs.path.join(c.gpa, &.{ std.fs.path.dirname(book_path) orelse ".", name });
}

/// The repo the daily run publishes into; its presence is the on switch.
pub fn repoFlagPath(c: vars.Ctx) ![]const u8 {
    return sidePath(c, "publish.repo");
}

/// The configured repo, or null when publishing is off.
pub fn configuredRepo(c: vars.Ctx) ?[]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(c.io, repoFlagPath(c) catch return null, c.gpa, .limited(4096)) catch return null;
    const repo = std.mem.trim(u8, text, " \t\r\n");
    return if (repo.len == 0) null else repo;
}

/// Called by every hook run. Cheap when off (one failed open). When on and the last attempt
/// is a day old, claim the slot and start the publish in the background; the hook never waits
/// for git or the network.
pub fn maybeStart(c: vars.Ctx) void {
    if (configuredRepo(c) == null) return;
    const stamp_path = sidePath(c, "publish.stamp") catch return;
    const now = book.nowSeconds(c.io);
    if (lastAttempt(c, stamp_path)) |last| {
        if (now - last < interval_secs) return;
    }
    // Claimed before starting, so two hooks in the same second cannot both start one, and a
    // failing publish is retried tomorrow rather than on every tool call.
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{now}) catch return;
    std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = stamp_path, .data = text }) catch return;
    const self = vars.selfExe(c) catch return;
    _ = std.process.spawn(c.io, .{
        .argv = &.{ self, "book", "publish", "--auto" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Its own process group: it must outlive the hook that started it.
        .pgid = 0,
    }) catch return;
}

fn lastAttempt(c: vars.Ctx, path: []const u8) ?i64 {
    const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(64)) catch return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \r\n"), 10) catch null;
}

const Git = struct {
    ok: bool,
    out: []const u8,
    err: []const u8,
};

fn git(c: vars.Ctx, cwd: []const u8, args: []const []const u8) !Git {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.gpa, &.{ "git", "-C", cwd });
    try argv.appendSlice(c.gpa, args);
    const res = try std.process.run(c.gpa, c.io, .{ .argv = argv.items });
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .out = std.mem.trim(u8, res.stdout, " \r\n"), .err = std.mem.trim(u8, res.stderr, " \r\n") };
}

/// A git step that must succeed, its stderr kept for the log.
fn must(c: vars.Ctx, cwd: []const u8, args: []const []const u8, why: *[]const u8) !Git {
    const g = try git(c, cwd, args);
    if (!g.ok) {
        why.* = try std.fmt.allocPrint(c.gpa, "git {s} failed: {s}", .{ args[0], g.err });
        return error.GitFailed;
    }
    return g;
}

/// The top of the git checkout containing `dir`, or null if it is not in one.
pub fn repoRoot(c: vars.Ctx, dir: []const u8) ?[]const u8 {
    const g = git(c, dir, &.{ "rev-parse", "--show-toplevel" }) catch return null;
    return if (g.ok and g.out.len > 0) g.out else null;
}

/// The checkout this binary was built from (`<repo>/zig-out/bin/zcanon`).
pub fn defaultRepo(c: vars.Ctx) ?[]const u8 {
    const self = vars.selfExe(c) catch return null;
    return repoRoot(c, std.fs.path.dirname(self) orelse return null);
}

pub const Outcome = union(enum) {
    /// Committed and pushed: the short commit id and the rows now in the shared file.
    pushed: struct { commit: []const u8, rows: usize },
    /// The remote already holds everything this book knows.
    unchanged,
    failed: []const u8,
};

/// Publish `entries` into `repo`'s default branch on origin. Retries a rejected push (someone
/// pushed in between) and a failed fetch (the network) a few times.
pub fn run(c: vars.Ctx, repo: []const u8, entries: []const book.Entry) Outcome {
    var why: []const u8 = "";
    var attempt: u6 = 0;
    while (attempt < 4) : (attempt += 1) {
        if (attempt > 0) c.io.sleep(.fromSeconds(@as(i64, 2) << (attempt - 1)), .awake) catch {}; // zsnag:ok — a cancelled backoff just retries sooner
        const out = attemptOnce(c, repo, entries, &why) catch |e| switch (e) {
            error.GitFailed, error.PushRejected => continue,
            else => return .{ .failed = @errorName(e) },
        };
        return out;
    }
    return .{ .failed = why };
}

fn attemptOnce(c: vars.Ctx, repo: []const u8, entries: []const book.Entry, why: *[]const u8) !Outcome {
    const head = try must(c, repo, &.{ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, why);
    const remote_ref = head.out; // "origin/main"
    const branch = remote_ref[(std.mem.findScalar(u8, remote_ref, '/') orelse return error.GitFailed) + 1 ..];
    _ = try must(c, repo, &.{ "fetch", "--quiet", "origin", branch }, why);

    // A private worktree, reset to the remote branch: the developer's checkout (its branch,
    // its index, its unpushed commits) is never touched.
    const wt = try sidePath(c, "publish-worktree");
    if (repoRoot(c, wt) == null) {
        _ = try git(c, repo, &.{ "worktree", "prune" });
        std.Io.Dir.cwd().deleteTree(c.io, wt) catch {}; // zsnag:ok — absent is the normal case
        _ = try must(c, repo, &.{ "worktree", "add", "--quiet", "--detach", wt, remote_ref }, why);
    } else {
        _ = try must(c, wt, &.{ "reset", "--quiet", "--hard", remote_ref }, why);
    }

    const hist_dir = try std.fs.path.join(c.gpa, &.{ wt, dir_name });
    const tsv = try std.fs.path.join(c.gpa, &.{ hist_dir, tsv_name });
    var rows: std.ArrayList(Row) = .empty;
    if (std.Io.Dir.cwd().readFileAlloc(c.io, tsv, c.gpa, .unlimited)) |text| {
        try parse(c.gpa, text, &rows);
    } else |_| {}

    var fresh: std.ArrayList(Row) = .empty;
    for (entries) |e| try fresh.append(c.gpa, sanitize(e, projectOf(c, e.file)));
    if (!try merge(c.gpa, &rows, fresh.items)) return .unchanged;

    try std.Io.Dir.cwd().createDirPath(c.io, hist_dir);
    var t: std.Io.Writer.Allocating = .init(c.gpa);
    try write(&t.writer, rows.items);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = tsv, .data = t.written() });
    var md: std.Io.Writer.Allocating = .init(c.gpa);
    try render(c.gpa, &md.writer, rows.items);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try std.fs.path.join(c.gpa, &.{ hist_dir, md_name }), .data = md.written() });

    _ = try must(c, wt, &.{ "add", "--", dir_name }, why);
    if ((try git(c, wt, &.{ "diff", "--cached", "--quiet" })).ok) return .unchanged;
    var sbuf: [20]u8 = undefined;
    const msg = try std.fmt.allocPrint(c.gpa, "history: mistake log as of {s}", .{book.stamp(&sbuf, book.nowSeconds(c.io)) catch "now"});
    _ = try must(c, wt, &.{ "commit", "--quiet", "-m", msg }, why);
    const push = try git(c, wt, &.{ "push", "--quiet", "origin", try std.fmt.allocPrint(c.gpa, "HEAD:refs/heads/{s}", .{branch}) });
    if (!push.ok) {
        why.* = try std.fmt.allocPrint(c.gpa, "git push failed: {s}", .{push.err});
        return error.PushRejected;
    }
    const sha = try must(c, wt, &.{ "rev-parse", "--short", "HEAD" }, why);
    return .{ .pushed = .{ .commit = sha.out, .rows = rows.items.len } };
}
