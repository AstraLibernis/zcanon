// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zcanon — one binary: the PostToolUse hook, its install/uninstall management, and the
//! reader over the book. Replaces `nu/zhook.nu` + `nu/zbook.nu`; no `nu` and no `sqlite3`
//! on the hook path.
const std = @import("std");
const builtin = @import("builtin");
const vars = @import("vars.zig");
const settings = @import("settings.zig");
const hook = @import("hook.zig");
const book = @import("book.zig");
const report = @import("report.zig");
const tier = @import("tier.zig");
const setup = @import("setup.zig");
const snag = @import("snag.zig");
const zephem = @import("zephem.zig");
const daemon = @import("daemon.zig");
const semantic = @import("semantic.zig");
const bugs = @import("bugs.zig");

const usage =
    \\zcanon <command> [args]
    \\
    \\  setup              check zephem + Claude Code, install the hook, then prove it works
    \\  doctor             the same checks as setup, changing nothing
    \\  check [--full] <file>...
    \\                     run the hook's checks on files by hand; exit 1 = something blocking.
    \\                     Short view by default; --full prints every message
    \\  hook               run as a PostToolUse hook (reads the payload on stdin)
    \\  install            add only the hook entry, unverified (prefer `setup`)
    \\  uninstall [--purge] remove the hook and the skill (only ours), then verify;
    \\                     --purge also deletes ~/.config/zcanon (the book)
    \\  status             is it installed, and is it enabled?
    \\  disable | enable   toggle at runtime without touching settings.json
    \\  view [short|full]  how the hook reports findings (default short); no argument prints it
    \\  add-check [dir]    add a `check` step to dir's build.zig (default: .), so the background
    \\                     compiler can report semantic errors on every edit
    \\  daemon status|stop [dir]
    \\                     the project's background process (started by the hook; exits when idle)
    \\  book [report]      the book: every mistake, how often, when, and where it last was:
    \\                     (default: most frequent) | rules | recent [N] | open | R0NN
    \\  bugs               the bug report: mistakes made 5+ times (never pruned)
    \\  prune              forget open findings in files that no longer exist
    \\
;

pub fn main(init: std.process.Init) !void {
    // zsnag:ok — R009: page_allocator is the arena's BACKING allocator here, not a general
    // allocator handed to callers. Same idiom as zephem's dispatcher.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator); // zsnag:ok
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c: vars.Ctx = .{ .gpa = arena, .io = init.io, .env = init.environ_map };
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return fail(c, usage);

    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "setup")) return setup.run(c, .setup, rest);
    if (std.mem.eql(u8, cmd, "doctor")) return setup.run(c, .doctor, rest);
    if (std.mem.eql(u8, cmd, "check")) return runCheck(c, rest);
    if (std.mem.eql(u8, cmd, "hook")) return runHook(c);
    if (std.mem.eql(u8, cmd, "install")) return runInstall(c);
    if (std.mem.eql(u8, cmd, "uninstall")) return setup.uninstall(c, rest);
    if (std.mem.eql(u8, cmd, "status")) return runStatus(c);
    if (std.mem.eql(u8, cmd, "disable")) return setDisabled(c, true);
    if (std.mem.eql(u8, cmd, "enable")) return setDisabled(c, false);
    if (std.mem.eql(u8, cmd, "view")) return runView(c, rest);
    if (std.mem.eql(u8, cmd, "add-check")) return runAddCheck(c, rest);
    if (std.mem.eql(u8, cmd, "daemon")) return runDaemon(c, rest);
    if (std.mem.eql(u8, cmd, "book")) return runBook(c, rest);
    if (std.mem.eql(u8, cmd, "prune")) return runPrune(c);
    if (std.mem.eql(u8, cmd, "bugs")) return runBugs(c);

    return fail(c, usage);
}

fn stdout(c: vars.Ctx, buf: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(c.io, buf);
}

fn fail(c: vars.Ctx, msg: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(c.io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
    std.process.exit(2);
}

fn exists(c: vars.Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(c.io, path, .{}) catch return false;
    return true;
}

// ---- the hook -------------------------------------------------------------
// Always exits 0: PostToolUse cannot block, and a nonzero exit would surface as a hook
// error rather than as findings.

fn runHook(c: vars.Ctx) !void {
    const flag = try vars.disableFlagPath(c);
    if (exists(c, flag)) return; // off switch: silent no-op, settings untouched

    var in_buf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(c.io, &in_buf);
    const payload = reader.interface.allocRemaining(c.gpa, .unlimited) catch return;

    // Every run moves the stamp forward, so a Bash run only sees edits made since the last
    // tool call — never a file the Edit hook already reported.
    const stamp = try vars.stampPath(c);
    const since = stampTime(c, stamp);
    defer touch(c, stamp);

    var paths: std.ArrayList([]const u8) = .empty;
    var walk_notice: []const u8 = "";
    const tool = hook.toolNameFromPayload(c.gpa, payload) orelse "";
    if (std.mem.eql(u8, tool, "Bash")) {
        // No stamp yet (first run after install): nothing to compare against, so check nothing
        // rather than every .zig file in the tree.
        const t = since orelse return;
        const run = hook.bashFromPayload(c.gpa, payload) orelse return;
        const roots = try hook.bashRoots(c.gpa, run.cwd, vars.home(c) catch "/", run.command);
        walk_notice = try changedZig(c, roots, t, &paths);
    } else {
        const path = (hook.filePathFromPayload(c.gpa, payload) catch return) orelse return;
        if (!std.mem.endsWith(u8, path, ".zig")) return;
        try paths.append(c.gpa, path);
    }
    if (paths.items.len == 0 and walk_notice.len == 0) return;

    const view: hook.View = if (exists(c, try vars.fullViewFlagPath(c))) .full else .short;
    var body: std.Io.Writer.Allocating = .init(c.gpa);
    var notices: std.ArrayList([]const u8) = .empty;
    if (walk_notice.len > 0) try notices.append(c.gpa, walk_notice);
    var hint = false;

    const files = try readAll(c, paths.items);
    var run = try Run.init(c, files);
    try addNotices(c.gpa, &notices, run.notices.items);
    for (files, 0..) |f, i| {
        const src = f.src orelse continue;
        const a = try run.analyze(i, f.path, src);
        if (try hook.renderContext(c.gpa, std.fs.path.basename(f.path), f.path, a.findings, view)) |b| {
            if (body.written().len > 0) try body.writer.writeAll("\n\n");
            try body.writer.writeAll(b);
        }
        if (hook.wantsHint(view, a.findings)) hint = true;
    }
    try run.semanticBlocks(view, &body, &notices);
    try addNotices(c.gpa, &notices, &.{run.finish()});
    const ctx = (try hook.compose(c.gpa, body.written(), notices.items, hint)) orelse return;

    var out_buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &out_buf);
    try w.interface.writeAll(try hook.renderResponse(c.gpa, ctx));
    try w.interface.flush();
}

/// Append each non-empty notice not already present.
fn addNotices(gpa: std.mem.Allocator, notices: *std.ArrayList([]const u8), new: []const []const u8) !void {
    for (new) |n| {
        if (n.len == 0) continue;
        for (notices.items) |seen| {
            if (std.mem.eql(u8, seen, n)) break;
        } else try notices.append(gpa, n);
    }
}

/// Most `.zig` files one Bash run is checked for, and most directory entries walked to find
/// them. Both bound the hook's cost when the working directory is large (`/`, a home dir).
const max_bash_files = 20;
const max_walk_entries = 50_000;

/// Directories never walked: build output, caches, VCS and dependency trees.
fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true; // .git, .zig-cache, .venv, …
    const skip = [_][]const u8{ "zig-out", "zig-cache", "node_modules", "target", "__pycache__" };
    for (skip) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

/// Collect `.zig` files under `roots` modified after `since`. Returns a notice when a budget
/// cut the search short — "no findings" must never hide "not everything was checked".
fn changedZig(c: vars.Ctx, roots: []const []const u8, since: i96, out: *std.ArrayList([]const u8)) ![]const u8 {
    var seen: usize = 0;
    var truncated = false;
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(c.io);
        var walker = try dir.walkSelectively(c.gpa);
        defer walker.deinit();
        while (walker.next(c.io) catch null) |entry| {
            seen += 1;
            if (seen > max_walk_entries) {
                truncated = true;
                break;
            }
            switch (entry.kind) {
                .directory => if (!skipDir(entry.basename)) walker.enter(c.io, entry) catch {}, // zsnag:ok — an unreadable directory is skipped, not fatal
                .file => {
                    if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                    const st = dir.statFile(c.io, entry.path, .{}) catch continue;
                    if (st.mtime.nanoseconds <= since) continue;
                    if (out.items.len == max_bash_files) {
                        truncated = true;
                        break;
                    }
                    try out.append(c.gpa, try std.fs.path.join(c.gpa, &.{ root, entry.path }));
                },
                else => {},
            }
        }
    }
    if (!truncated) return "";
    return std.fmt.allocPrint(c.gpa, "\n\n⚠ a shell command changed .zig files, but the search stopped at its limit " ++
        "({d} files / {d} entries) — run `zcanon check <file>` on anything it did not list.", .{ max_bash_files, max_walk_entries });
}

/// The stamp's modification time, or null if there is no stamp yet.
fn stampTime(c: vars.Ctx, path: []const u8) ?i96 {
    const st = std.Io.Dir.cwd().statFile(c.io, path, .{}) catch return null;
    return st.mtime.nanoseconds;
}

/// Best-effort: a failure here only means the next Bash run looks further back.
fn touch(c: vars.Ctx, path: []const u8) void {
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(c.io, d) catch return;
    std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = "" }) catch {}; // zsnag:ok — best-effort, see doc comment
}

const File = struct { path: []const u8, src: ?[:0]const u8, mtime: i96 = 0 };

/// Read every file up front: the zephem map is then loaded once, with only the paths these
/// files reference. `src` is null for a file that cannot be read.
fn readAll(c: vars.Ctx, paths: []const []const u8) ![]File {
    const files = try c.gpa.alloc(File, paths.len);
    for (paths, files) |p, *f| f.* = .{
        .path = p,
        .src = std.Io.Dir.cwd().readFileAllocOptions(c.io, p, c.gpa, .unlimited, .of(u8), 0) catch null,
        .mtime = if (std.Io.Dir.cwd().statFile(c.io, p, .{})) |st| st.mtime.nanoseconds else |_| 0,
    };
    return files;
}

const Analysis = struct {
    findings: []hook.Finding,
};

/// One file's syntax check on another thread. `smp_allocator` because the run's arena is not
/// thread-safe; the result lives until the process exits.
fn astTask(path: []const u8, src: [:0]const u8) hook.AstCheckError![]const u8 {
    return hook.astCheck(std.heap.smp_allocator, path, src);
}

/// A child process started now and collected later, so its run overlaps the in-process work.
/// Only stdout is piped, so reading it to the end cannot deadlock.
const Pending = struct {
    child: ?std.process.Child,

    fn start(c: vars.Ctx, argv: []const []const u8) Pending {
        return .{ .child = std.process.spawn(c.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch null };
    }

    /// The child's stdout; null when it could not be started, read, or did not exit 0.
    fn finish(p: *Pending, c: vars.Ctx) ?[]u8 {
        var child = p.child orelse return null;
        p.child = null;
        defer child.kill(c.io);
        var buf: [4096]u8 = undefined;
        var r = (child.stdout orelse return null).readerStreaming(c.io, &buf);
        const out = r.interface.allocRemaining(c.gpa, .unlimited) catch return null;
        const term = child.wait(c.io) catch return null;
        return switch (term) {
            .exited => |code| if (code == 0) out else null,
            else => null,
        };
    }
};

/// State shared by every file one hook run or `zcanon check` looks at: the map, the rules the
/// map has disabled, and the zig version, each computed once.
///
/// The linter runs in-process. zcanon used to spawn zsnag per file and parse its JSONL back,
/// which re-indexed the whole zephem lookup table for every file checked. The syntax check is
/// in-process too (`hook.astCheck`); `zig version` is started first and collected after the
/// map loads.
const Run = struct {
    c: vars.Ctx,
    /// Each file's syntax check, started in `init` so it runs alongside the map load; null
    /// when the file was unreadable or no concurrency was available (then it runs inline).
    ast: []?std.Io.Future(hook.AstCheckError![]const u8),
    map: ?zephem.Map,
    stale: []const snag.Id,
    zver: []const u8,
    /// Why a check did not run, or ran against a stale map. "No findings" must never be
    /// indistinguishable from "never checked".
    notices: std.ArrayList([]const u8),
    /// Each project's latest background-compiler result, from its daemon.
    sem: std.ArrayList(Sem) = .empty,
    /// The open set and the history, loaded on first `record` and written by `finish`.
    ledger: ?book.Book = null,
    history: ?book.History = null,
    ledger_failed: ?anyerror = null,
    /// This run's timestamp, "" if the clock is unusable.
    now: []const u8 = "",
    /// Syntax findings by file, so a compiler error that repeats one is not shown twice.
    ast_seen: std.ArrayList(struct { path: []const u8, f: hook.Finding }) = .empty,

    const Sem = struct { root: []const u8, reply: daemon.Reply, newest_edit: i96 };

    fn init(c: vars.Ctx, files: []const File) !Run {
        const ast = try c.gpa.alloc(?std.Io.Future(hook.AstCheckError![]const u8), files.len);
        for (files, ast) |f, *fut| fut.* = if (f.src) |src|
            c.io.concurrent(astTask, .{ f.path, src }) catch null
        else
            null;

        var r: Run = .{ .c = c, .ast = ast, .map = null, .stale = &.{}, .zver = "unknown", .notices = .empty };
        const stamp_buf = try c.gpa.create([20]u8);
        r.now = book.stamp(stamp_buf, book.nowSeconds(c.io)) catch "";
        var keys: zephem.Keys = .empty;
        for (files) |f| if (f.src) |src| try snag.mapKeys(c.gpa, src, &keys);

        // Each file's project daemon: the first one also serves the map rows and zig version.
        // No daemon yet → start one for next time and do everything here.
        var from_daemon: ?zephem.Map = null;
        if (daemon.enabled(c)) {
            var roots: std.ArrayList([]const u8) = .empty;
            var newest: std.ArrayList(i96) = .empty;
            for (files) |f| {
                if (f.src == null) continue;
                const abs = vars.absolute(c, f.path) catch continue;
                const root = (semantic.projectRoot(c.gpa, c.io, abs) catch null) orelse continue;
                for (roots.items, 0..) |seen, i| {
                    if (std.mem.eql(u8, seen, root)) {
                        newest.items[i] = @max(newest.items[i], f.mtime);
                        break;
                    }
                } else {
                    try roots.append(c.gpa, root);
                    try newest.append(c.gpa, f.mtime);
                }
            }
            for (roots.items, newest.items) |root, edit| {
                if (daemon.unusable(c, root) != null) continue; // `zcanon daemon status` says why
                const reply = daemon.request(c, root, .query, if (from_daemon == null) &keys else null) orelse {
                    daemon.start(c, root);
                    continue;
                };
                if (from_daemon == null) if (reply.rows) |rows| {
                    from_daemon = try zephem.parse(c.gpa, rows, null);
                    r.zver = reply.zig_version;
                };
                try r.sem.append(c.gpa, .{ .root = root, .reply = reply, .newest_edit = edit });
            }
        }
        var version: Pending = if (from_daemon == null) Pending.start(c, &.{ "zig", "version" }) else .{ .child = null };
        const loaded: zephem.LoadError!zephem.Map = from_daemon orelse zephem.load(c, &keys);
        if (version.finish(c)) |v| r.zver = std.mem.trim(u8, v, " \t\r\n");
        // The syntax check runs on the std this binary was built with.
        if (!std.mem.eql(u8, r.zver, "unknown") and !std.mem.eql(u8, r.zver, builtin.zig_version_string))
            try r.notices.append(c.gpa, try std.fmt.allocPrint(
                c.gpa,
                "\n\n⚠ zcanon was built with zig {s} but `zig` is {s}: the syntax check follows {s}. " ++
                    "Rebuild zcanon (`zig build`) with the new zig.",
                .{ builtin.zig_version_string, r.zver, builtin.zig_version_string },
            ));
        if (loaded) |m| {
            r.map = m;
            if (try zephem.staleness(c, r.zver)) |warn|
                try r.notices.append(c.gpa, try std.fmt.allocPrint(c.gpa, "\n\n{s}", .{warn}));
            r.stale = try snag.stalePremises(c.gpa, &r.map.?);
            for (r.stale) |id| try r.notices.append(c.gpa, try std.fmt.allocPrint(
                c.gpa,
                "\n\n⚠ rule {s} is DISABLED — the map contradicts its premise: {s}",
                .{ snag.ruleOf(id).code, snag.ruleOf(id).premise },
            ));
        } else |e| try r.notices.append(c.gpa, try std.fmt.allocPrint(
            c.gpa,
            "\n\n⚠ R011/R012/R013 (the zephem map rules) did NOT run — {s}",
            .{switch (e) {
                error.NoLookupTable => zephem.remedy,
                error.ZephemNotFound => "zephem not found; run `zcanon setup`",
                else => @errorName(e),
            }},
        ));
        return r;
    }

    /// The background compiler's results, one block per project with errors, plus notices for
    /// projects where it is off, starting, or down. Call after every `analyze`.
    fn semanticBlocks(r: *Run, view: hook.View, body: *std.Io.Writer.Allocating, notices: *std.ArrayList([]const u8)) !void {
        const c = r.c;
        for (r.sem.items) |s| {
            const rep = s.reply;
            if (rep.offer.len > 0) try addNotices(c.gpa, notices, &.{try std.fmt.allocPrint(
                c.gpa,
                "\n\nℹ semantic checks are off for {s}: its build.zig has no `check` step. Ask the user " ++
                    "whether to add one with `zcanon add-check {s}`; the compiler then type-checks every edit.",
                .{ rep.offer, rep.offer },
            )});
            switch (rep.sem) {
                .starting => try addNotices(c.gpa, notices, &.{try std.fmt.allocPrint(c.gpa, "\n\n⋯ the background compiler for {s} is on its first build; its errors follow on a later edit.", .{s.root})}),
                .down => try addNotices(c.gpa, notices, &.{try std.fmt.allocPrint(c.gpa, "\n\n⚠ semantic checks are down for {s}: {s}", .{ s.root, rep.detail })}),
                .no_check => {},
                .ok, .errors => {
                    // A build that finished after the newest edit speaks for the project now:
                    // record its errors, and close the ones it no longer reports.
                    if (rep.finished_ns >= s.newest_edit) {
                        var fresh: std.ArrayList(book.Record) = .empty;
                        for (rep.diags) |d| {
                            if (!std.mem.eql(u8, d.severity, "error")) continue;
                            const abs = try std.fs.path.resolve(c.gpa, &.{ s.root, d.path });
                            try fresh.append(c.gpa, r.recordOf(abs, book.COMPILE_RULE, "error", d.line, d.col, d.message, ""));
                        }
                        r.record(.{ .under = s.root }, fresh.items, &.{book.GROUP_COMPILE});
                    }
                    if (rep.sem == .ok) continue;
                    // Drop what the syntax check already reported for a file checked this run.
                    var diags: std.ArrayList(semantic.Diag) = .empty;
                    for (rep.diags) |d| {
                        const abs = try std.fs.path.resolve(c.gpa, &.{ s.root, d.path });
                        const dup = for (r.ast_seen.items) |a| {
                            const same_file = std.mem.eql(u8, try std.fs.path.resolve(c.gpa, &.{a.path}), abs);
                            if (same_file and a.f.line == d.line and a.f.col == d.col and std.mem.eql(u8, a.f.message, d.message)) break true;
                        } else false;
                        if (!dup) try diags.append(c.gpa, d);
                    }
                    const before_edit = rep.finished_ns < s.newest_edit;
                    if (try hook.renderSemantic(c.gpa, s.root, diags.items, before_edit, view)) |b| {
                        if (body.written().len > 0) try body.writer.writeAll("\n\n");
                        try body.writer.writeAll(b);
                    }
                },
            }
        }
    }

    /// zsnag + `zig ast-check` on one file, deduped, sorted, and recorded to the book.
    fn analyze(r: *Run, i: usize, path: []const u8, src: [:0]const u8) !Analysis {
        const c = r.c;
        var findings: std.ArrayList(hook.Finding) = .empty;

        // Which rule groups actually ran: the book prunes a file's history only for those, so
        // a group that did not run cannot erase its own record.
        var active: std.ArrayList([]const u8) = .empty;
        var snags: std.ArrayList(snag.Finding) = .empty;
        var parsed = false;
        try snag.scanWithOpts(c.gpa, path, src, &snags, .{
            .map = if (r.map) |*m| m else null,
            .ran_structural = &parsed,
            .stale = r.stale,
        });
        try active.append(c.gpa, book.GROUP_CORE);
        if (parsed) try active.append(c.gpa, book.GROUP_STRUCTURAL);
        if (r.map != null) try active.append(c.gpa, book.GROUP_MAP);
        for (snags.items) |f| try findings.append(c.gpa, .{
            .rule = f.rule().code,
            .severity = f.rule().sev.name(),
            .line = f.line,
            .col = f.col,
            .message = f.msg,
        });

        // Always runs: it is in-process, so there is no spawn to fail.
        try active.append(c.gpa, book.GROUP_AST);
        const diag = if (r.ast[i]) |*fut| try fut.await(c.io) else try hook.astCheck(c.gpa, path, src);
        const before = findings.items.len;
        try hook.parseAstCheck(c.gpa, path, diag, &findings);
        for (findings.items[before..]) |f| try r.ast_seen.append(c.gpa, .{ .path = path, .f = f });

        // Dedup on the book's key before anything consumes the list — otherwise a duplicate
        // renders twice and double-counts `hits`.
        const deduped = try hook.dedup(c.gpa, src, findings.items);
        hook.sortFindings(deduped);

        var fresh: std.ArrayList(book.Record) = .empty;
        for (deduped) |f| try fresh.append(c.gpa, r.recordOf(path, f.rule, f.severity, f.line, f.col, f.message, hook.snippetFor(src, f.line)));
        r.record(.{ .file = path }, fresh.items, active.items);
        return .{ .findings = deduped };
    }

    fn recordOf(r: *Run, file: []const u8, rule: []const u8, severity: []const u8, line: u32, col: u32, message: []const u8, snippet: []const u8) book.Record {
        return .{
            .first_ts = r.now,
            .last_ts = r.now,
            .hits = 1,
            .zig_version = r.zver,
            .file = file,
            .rule = rule,
            .severity = severity,
            .line = line,
            .col = col,
            .message = message,
            .snippet = snippet,
        };
    }

    /// Record one scan to the book, loaded on first use and written once by `finish`. The
    /// book is best-effort: a failure here must not propagate, because a non-zero exit
    /// surfaces as a hook ERROR with no findings. `finish` says so in-band instead.
    fn record(r: *Run, scope: book.Book.Scope, fresh: []const book.Record, active: []const []const u8) void {
        if (r.ledger_failed != null) return;
        r.recordInner(scope, fresh, active) catch |e| {
            r.ledger_failed = e;
        };
    }

    fn recordInner(r: *Run, scope: book.Book.Scope, fresh: []const book.Record, active: []const []const u8) !void {
        if (r.now.len == 0) return error.NegativeTimestamp;
        if (r.ledger == null) try r.load();
        // A finding not already open is a new occurrence: +1 to its mistake in the history.
        var new: std.ArrayList(book.Record) = .empty;
        r.ledger.?.prune(scope, fresh, active);
        try r.ledger.?.upsertTracking(fresh, &new);
        for (new.items) |n| try r.history.?.bump(n, r.now);
    }

    /// Write the open set, the history, and the bug report.
    fn save(r: *Run, open: *const book.Book, history: *const book.History) !void {
        try writeBook(r.c, open, try openPath(r.c));
        try writeHistory(r.c, history);
        try updateBugs(r.c, history.entries.items, r.now);
    }

    /// Load the open set and the history (see `loadLedger`).
    fn load(r: *Run) !void {
        r.ledger = .init(r.c.gpa);
        r.history = .init(r.c.gpa);
        try loadLedger(r.c, &r.ledger.?, &r.history.?);
    }

    /// Write the book, then fold it into the bug report. Returns a notice when either failed.
    fn finish(r: *Run) []const u8 {
        if (r.ledger_failed == null) if (r.ledger) |*b| {
            r.save(b, &r.history.?) catch |e| {
                r.ledger_failed = e;
            };
        };
        const e = r.ledger_failed orelse return "";
        return std.fmt.allocPrint(r.c.gpa, "\n\n⚠ the book was not updated ({s}) — findings above are still valid.", .{@errorName(e)}) catch "";
    }
};

// ---- check: the same analysis, for any agent ------------------------------
// Agents without Claude Code's hook system can run this after each edit. Findings go to
// stdout in the same grouped form the hook feeds Claude; exit 1 means something BLOCKING.

fn runCheck(c: vars.Ctx, args: []const []const u8) !void {
    var view: hook.View = .short;
    var paths: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--full")) view = .full else try paths.append(c.gpa, a);
    }
    if (paths.items.len == 0) return fail(c, "usage: zcanon check [--full] <file.zig>...\n");
    var buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &buf);
    var blocking = false;
    var unreadable = false;

    const files = try readAll(c, paths.items);
    var run = try Run.init(c, files);
    for (run.notices.items) |n| try w.interface.print("{s}\n", .{std.mem.trimStart(u8, n, "\n")});
    var hint = false;
    for (files, 0..) |f, i| {
        const src = f.src orelse {
            try w.interface.print("{s}: cannot read file\n", .{f.path});
            unreadable = true;
            continue;
        };
        const a = try run.analyze(i, f.path, src);
        for (a.findings) |finding| {
            if (tier.classify(finding.severity, f.path) == .blocking) blocking = true;
        }
        if (hook.wantsHint(view, a.findings)) hint = true;
        const base = std.fs.path.basename(f.path);
        if (try hook.renderContext(c.gpa, base, f.path, a.findings, view)) |body| {
            try w.interface.print("{s}\n", .{body});
        } else {
            try w.interface.print("{s}: no findings\n", .{base});
        }
    }
    var sem_body: std.Io.Writer.Allocating = .init(c.gpa);
    var sem_notices: std.ArrayList([]const u8) = .empty;
    try run.semanticBlocks(view, &sem_body, &sem_notices);
    try addNotices(c.gpa, &sem_notices, &.{run.finish()});
    if (sem_body.written().len > 0) try w.interface.print("{s}\n", .{sem_body.written()});
    for (sem_notices.items) |n| try w.interface.print("{s}\n", .{std.mem.trimStart(u8, n, "\n")});
    if (hint) try w.interface.print("{s}\n", .{std.mem.trimStart(u8, hook.HINT, "\n")});
    try w.interface.flush();
    if (unreadable) std.process.exit(3);
    if (blocking) std.process.exit(1);
}

/// The open set lives beside the book.
fn openPath(c: vars.Ctx) ![]const u8 {
    const book_path = try vars.bookPath(c);
    return std.fs.path.join(c.gpa, &.{ std.fs.path.dirname(book_path) orelse ".", "open.tsv" });
}

fn writeHistory(c: vars.Ctx, h: *const book.History) !void {
    const path = try vars.bookPath(c);
    try std.Io.Dir.cwd().createDirPath(c.io, std.fs.path.dirname(path) orelse ".");
    var w: std.Io.Writer.Allocating = .init(c.gpa);
    try h.write(&w.writer);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = w.written() });
}

/// Fold the history into the bug report beside it; rewrite both files only when it changed.
fn updateBugs(c: vars.Ctx, entries: []const book.Entry, now: []const u8) !void {
    const book_path = try vars.bookPath(c);
    const dir = std.fs.path.dirname(book_path) orelse ".";
    const tsv = try std.fs.path.join(c.gpa, &.{ dir, "bugs.tsv" });
    var list: std.ArrayList(bugs.Bug) = .empty;
    if (std.Io.Dir.cwd().readFileAlloc(c.io, tsv, c.gpa, .unlimited)) |text| {
        try bugs.parse(c.gpa, text, &list);
    } else |_| {}
    if (!try bugs.update(c.gpa, entries, &list, now)) return;

    var w: std.Io.Writer.Allocating = .init(c.gpa);
    try bugs.write(&w.writer, list.items);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = tsv, .data = w.written() });
    var md: std.Io.Writer.Allocating = .init(c.gpa);
    try bugs.render(&md.writer, list.items);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try std.fs.path.join(c.gpa, &.{ dir, "bugs.md" }), .data = md.written() });
}

fn writeBook(c: vars.Ctx, b: *const book.Book, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(c.io, dir);
    var w: std.Io.Writer.Allocating = .init(c.gpa);
    try b.write(&w.writer);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = w.written() });
}

// ---- management -----------------------------------------------------------

fn runInstall(c: vars.Ctx) !void {
    const path = try vars.settingsPath(c);
    var root = try settings.load(c, c.gpa, path);
    const self = try vars.selfExe(c);
    const cmd = try settings.command(c.gpa, self);
    try settings.addOurs(c.gpa, &root, cmd);
    try settings.save(c, path, try settings.render(c.gpa, root));

    var buf: [2048]u8 = undefined;
    var w = stdout(c, &buf);
    try w.interface.print(
        "Installed into {s} (backup: {s}.bak).\nOff switch: zcanon disable   |   Full removal: zcanon uninstall\n",
        .{ path, path },
    );
    try w.interface.flush();
}

fn runStatus(c: vars.Ctx) !void {
    const path = try vars.settingsPath(c);
    var root = try settings.load(c, c.gpa, path);
    const installed = settings.isInstalled(c.gpa, &root);
    const flag = try vars.disableFlagPath(c);
    const enabled = !exists(c, flag);

    const zsnag_path = try vars.zsnagPath(c);
    const book_path = try vars.bookPath(c);

    var buf: [2048]u8 = undefined;
    var w = stdout(c, &buf);
    try w.interface.print("installed in settings: {}\n", .{installed});
    try w.interface.print("runtime state: {s}\n", .{if (enabled) "enabled" else "disabled"});
    try w.interface.print("zsnag binary (the standalone linter): {s}{s}\n", .{
        zsnag_path,
        if (exists(c, zsnag_path)) "" else "   ← missing; the hook does not need it",
    });
    try w.interface.print("hook view: {s}\n", .{if (exists(c, try vars.fullViewFlagPath(c))) "full" else "short"});
    try w.interface.print("book: {s}{s}\n", .{
        book_path,
        if (exists(c, book_path)) "" else "   (empty — nothing recorded yet)",
    });
    try w.interface.flush();
}

fn setDisabled(c: vars.Ctx, off: bool) !void {
    const flag = try vars.disableFlagPath(c);
    const dir = std.fs.path.dirname(flag) orelse ".";
    try std.Io.Dir.cwd().createDirPath(c.io, dir);
    if (off) {
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = flag, .data = "" });
    } else {
        std.Io.Dir.cwd().deleteFile(c.io, flag) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
    var buf: [256]u8 = undefined;
    var w = stdout(c, &buf);
    try w.interface.print("hook {s} (settings.json untouched)\n", .{if (off) "disabled" else "enabled"});
    try w.interface.flush();
}

/// `zcanon add-check [dir]`: add the `check` step to dir's build.zig, then prove the build
/// still configures and lists it. On any failure the original is put back.
fn runAddCheck(c: vars.Ctx, args: []const []const u8) !void {
    const dir = if (args.len > 0) args[0] else ".";
    const path = try std.fs.path.join(c.gpa, &.{ dir, "build.zig" });
    const src = std.Io.Dir.cwd().readFileAllocOptions(c.io, path, c.gpa, .unlimited, .of(u8), 0) catch
        return fail(c, try std.fmt.allocPrint(c.gpa, "no build.zig in {s}\n", .{dir}));
    const edited = semantic.addCheck(c.gpa, src) catch |e| return fail(c, switch (e) {
        error.AlreadyAdded => "build.zig already has zcanon's check step.\n",
        error.BuildZigInvalid => "build.zig does not parse; fix it first.\n",
        error.NoBuildFn => "build.zig has no `pub fn build(b: *std.Build)` to add the step to.\n",
        error.OutOfMemory => "out of memory\n",
    });

    // The original goes to zcanon's own folder, not the project's.
    const backup_dir = try std.fs.path.join(c.gpa, &.{ try vars.configDir(c), "backups" });
    try std.Io.Dir.cwd().createDirPath(c.io, backup_dir);
    var name: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "{x:0>16}", .{std.hash.Wyhash.hash(0, path)}) catch unreachable; // zsnag:ok — 16 hex digits fit exactly
    const backup = try std.fmt.allocPrint(c.gpa, "{s}/{s}-build.zig", .{ backup_dir, &name });
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = backup, .data = src });
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = edited });

    const listed = std.process.run(c.gpa, c.io, .{ .argv = &.{ "zig", "build", "-l" }, .cwd = .{ .path = dir } }) catch null;
    const ok = if (listed) |res| switch (res.term) {
        .exited => |code| code == 0 and std.mem.find(u8, res.stdout, "check") != null,
        else => false,
    } else false;
    if (!ok) {
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = src });
        const why = if (listed) |res| std.mem.trim(u8, res.stderr, " \t\r\n") else "could not run `zig build -l`";
        return fail(c, try std.fmt.allocPrint(c.gpa, "adding the check step broke the build, so build.zig was restored:\n{s}\n", .{why}));
    }
    var buf: [1024]u8 = undefined;
    var w = stdout(c, &buf);
    try w.interface.print(
        "Added a `check` step to {s} (original saved as {s}).\n" ++
            "The background compiler picks it up on the next .zig edit; `zig build check` runs it by hand.\n",
        .{ path, backup },
    );
    try w.interface.flush();
}

/// `zcanon daemon <root>` runs one (the hook starts it); `status` / `stop` talk to one.
fn runDaemon(c: vars.Ctx, args: []const []const u8) !void {
    if (args.len == 0) return fail(c, "usage: zcanon daemon status|stop [dir]\n");
    const is_status = std.mem.eql(u8, args[0], "status");
    const is_stop = std.mem.eql(u8, args[0], "stop");
    if (!is_status and !is_stop) return daemon.serve(c, try vars.absolute(c, args[0]));

    const dir = try vars.absolute(c, if (args.len > 1) args[1] else ".");
    const probe = try std.fs.path.join(c.gpa, &.{ dir, "x.zig" });
    const root = (try semantic.projectRoot(c.gpa, c.io, probe)) orelse
        return fail(c, try std.fmt.allocPrint(c.gpa, "no build.zig at or above {s}\n", .{dir}));
    var buf: [4096]u8 = undefined;
    var w = stdout(c, &buf);
    if (daemon.unusable(c, root)) |why| {
        try w.interface.print("{s}: no daemon can run: {s}\n", .{ root, why });
        return w.interface.flush();
    }
    const reply = daemon.request(c, root, if (is_stop) .stop else .status, null) orelse {
        try w.interface.print("{s}: no daemon running\n", .{root});
        return w.interface.flush();
    };
    if (is_stop) {
        try w.interface.print("{s}: daemon stopped\n", .{root});
        return w.interface.flush();
    }
    try w.interface.print("{s}: daemon running; zig {s}; map {s}; compiler {t}", .{
        root, reply.zig_version, if (reply.rows != null) "loaded" else reply.map_missing, reply.sem,
    });
    if (reply.detail.len > 0) try w.interface.print(" ({s})", .{reply.detail});
    if (reply.sem == .errors or reply.sem == .ok) try w.interface.print(", {d} diagnostics", .{reply.diags.len});
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

fn runView(c: vars.Ctx, args: []const []const u8) !void {
    const flag = try vars.fullViewFlagPath(c);
    var buf: [256]u8 = undefined;
    var w = stdout(c, &buf);
    if (args.len == 0) {
        try w.interface.print("hook view: {s}\n", .{if (exists(c, flag)) "full" else "short"});
        return w.interface.flush();
    }
    const full = if (std.mem.eql(u8, args[0], "full"))
        true
    else if (std.mem.eql(u8, args[0], "short"))
        false
    else
        return fail(c, "usage: zcanon view [short|full]\n");
    const dir = std.fs.path.dirname(flag) orelse ".";
    try std.Io.Dir.cwd().createDirPath(c.io, dir);
    if (full) {
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = flag, .data = "" });
    } else {
        std.Io.Dir.cwd().deleteFile(c.io, flag) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
    try w.interface.print("hook view: {s} (settings.json untouched)\n", .{args[0]});
    try w.interface.flush();
}

// ---- the book -------------------------------------------------------------

/// Load the open set and the history. A book in the old per-finding format (before the
/// history existed) is migrated: it becomes the open set, and each of its rows counts as one
/// occurrence in the history. Rows an interim build had marked fixed go to the history only.
fn loadLedger(c: vars.Ctx, open: *book.Book, history: *book.History) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(c.io, try vars.bookPath(c), c.gpa, .unlimited) catch "";
    if (book.isOpenFormat(text)) {
        var old: book.Book = .init(c.gpa);
        try old.parse(text);
        for (old.recs.items) |rec| {
            try history.bump(rec, rec.first_ts);
            if (rec.fixed_ts.len == 0) try open.recs.append(c.gpa, rec);
        }
        return;
    }
    try history.parse(text);
    if (std.Io.Dir.cwd().readFileAlloc(c.io, try openPath(c), c.gpa, .unlimited)) |open_text| {
        try open.parse(open_text);
    } else |_| {}
}

fn runBook(c: vars.Ctx, args: []const []const u8) !void {
    var open: book.Book = .init(c.gpa);
    var history: book.History = .init(c.gpa);
    try loadLedger(c, &open, &history);
    const mode = report.Mode.parse(args) catch return fail(c, "unknown report; try: book | book rules | book recent [N] | book open | book R0NN\n");

    var buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &buf);
    try report.render(c.gpa, &w.interface, history.entries.items, open.recs.items, mode);
    try w.interface.flush();
}

fn runPrune(c: vars.Ctx) !void {
    var open: book.Book = .init(c.gpa);
    var history: book.History = .init(c.gpa);
    try loadLedger(c, &open, &history);
    const before = open.recs.items.len;

    // Only the open set: a file that is gone has no findings in it any more. The history is
    // never touched.
    var i: usize = 0;
    while (i < open.recs.items.len) {
        if (exists(c, open.recs.items[i].file)) i += 1 else _ = open.recs.orderedRemove(i);
    }
    try writeBook(c, &open, try openPath(c));
    try writeHistory(c, &history);

    var buf: [256]u8 = undefined;
    var w = stdout(c, &buf);
    try w.interface.print("dropped {d} open findings in files that no longer exist; the history is unchanged.\n", .{before - open.recs.items.len});
    try w.interface.flush();
}

fn runBugs(c: vars.Ctx) !void {
    const book_path = try vars.bookPath(c);
    const dir = std.fs.path.dirname(book_path) orelse ".";
    var list: std.ArrayList(bugs.Bug) = .empty;
    if (std.Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(c.gpa, &.{ dir, "bugs.tsv" }), c.gpa, .unlimited)) |text| {
        try bugs.parse(c.gpa, text, &list);
    } else |_| {}
    var buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &buf);
    try bugs.render(&w.interface, list.items);
    try w.interface.print("\n(stored in {s}/bugs.tsv, readable copy in bugs.md)\n", .{dir});
    try w.interface.flush();
}
