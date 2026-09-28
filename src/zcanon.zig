// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zcanon — one binary: the PostToolUse hook, its install/uninstall management, and the
//! reader over the book. Replaces `nu/zhook.nu` + `nu/zbook.nu`; no `nu` and no `sqlite3`
//! on the hook path.
const std = @import("std");
const vars = @import("vars.zig");
const settings = @import("settings.zig");
const hook = @import("hook.zig");
const book = @import("book.zig");
const report = @import("report.zig");
const tier = @import("tier.zig");
const setup = @import("setup.zig");

const usage =
    \\zcanon <command> [args]
    \\
    \\  setup              check zephem + Claude Code, install the hook, then prove it works
    \\  doctor             the same checks as setup, changing nothing
    \\  check <file>...    run the hook's checks on files by hand; exit 1 = something blocking
    \\  hook               run as a PostToolUse hook (reads the payload on stdin)
    \\  install            add only the hook entry, unverified (prefer `setup`)
    \\  uninstall [--purge] remove the hook and the skill (only ours), then verify;
    \\                     --purge also deletes ~/.config/zcanon (the book)
    \\  status             is it installed, and is it enabled?
    \\  disable | enable   toggle at runtime without touching settings.json
    \\  book [report]      read the book: (default) | recent [N] | files | R0NN
    \\  prune              drop findings for files that no longer exist
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
    if (std.mem.eql(u8, cmd, "book")) return runBook(c, rest);
    if (std.mem.eql(u8, cmd, "prune")) return runPrune(c);

    return fail(c, usage);
}

fn stdout(c: vars.Ctx, buf: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writer(c.io, buf);
}

fn fail(c: vars.Ctx, msg: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(c.io, &buf);
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

    var body: std.Io.Writer.Allocating = .init(c.gpa);
    var notices: std.ArrayList([]const u8) = .empty;
    if (walk_notice.len > 0) try notices.append(c.gpa, walk_notice);
    for (paths.items) |path| {
        const a = (try analyze(c, path)) orelse continue;
        if (try hook.renderContext(c.gpa, a.base, path, a.findings)) |b| {
            if (body.written().len > 0) try body.writer.writeAll("\n\n");
            try body.writer.writeAll(b);
        }
        for ([_][]const u8{ a.notice, a.book_notice }) |n| {
            if (n.len == 0) continue;
            for (notices.items) |seen| {
                if (std.mem.eql(u8, seen, n)) break;
            } else try notices.append(c.gpa, n);
        }
    }
    const ctx = (try hook.compose(c.gpa, body.written(), notices.items)) orelse return;

    var out_buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &out_buf);
    try w.interface.writeAll(try hook.renderResponse(c.gpa, ctx));
    try w.interface.flush();
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

const Analysis = struct {
    base: []const u8,
    findings: []hook.Finding,
    notice: []const u8,
    book_notice: []const u8,
};

/// The check itself, shared by the Claude Code hook and `zcanon check`: zsnag + `zig ast-check`
/// on one file, deduped, sorted, and recorded to the book. Null when the file can't be read.
fn analyze(c: vars.Ctx, path: []const u8) !?Analysis {
    const src = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited) catch return null;

    var findings: std.ArrayList(hook.Finding) = .empty;

    // zsnag lives beside this binary. If it is missing we say so loudly in-band rather than
    // skipping silently — "no findings" must never be indistinguishable from "never checked".
    const zsnag_path = try vars.zsnagPath(c);

    // Which rule groups actually ran. zsnag REPORTS this in its status record rather than
    // us inferring it from an exit code — inference is what let a failed zephem map load look
    // like "the map rules found nothing", which then erased their history from the book.
    var active: std.ArrayList([]const u8) = .empty;
    var notice: []const u8 = "";
    if (exists(c, zsnag_path)) {
        const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ zsnag_path, "--json", path } }) catch null;
        if (r) |res| {
            const usable = switch (res.term) {
                // 0 = clean, 1 = error-severity findings. 3 = a file could not be read, and
                // 2 = usage; neither is a scan whose absence of findings means anything.
                .exited => |code| code == 0 or code == 1,
                else => false,
            };
            if (usable) {
                try hook.parseSnagJson(c.gpa, res.stdout, &findings, &active);
                try hook.parseSnagJson(c.gpa, res.stderr, &findings, &active);
            }
        }
    } else {
        notice = try std.fmt.allocPrint(
            c.gpa,
            "\n\n⚠ zsnag was NOT run: no binary at {s}. Footgun checks did not happen — " ++
                "build it with `zig build` in the zcanon repo.",
            .{zsnag_path},
        );
    }

    if (std.process.run(c.gpa, c.io, .{ .argv = &.{ "zig", "ast-check", path } }) catch null) |res| {
        // Only a normal exit counts. A killed or signalled ast-check produces no diagnostics,
        // and treating that as "ran" erased the file's whole ast history from the book.
        switch (res.term) {
            .exited => {
                try active.append(c.gpa, book.GROUP_AST);
                try hook.parseAstCheck(c.gpa, path, res.stderr, &findings);
            },
            else => {},
        }
    }

    // Dedup on the book's key before anything consumes the list, matching the Nushell
    // original — otherwise a duplicate renders twice and double-counts `hits`.
    const deduped = try hook.dedup(c.gpa, src, findings.items);
    hook.sortFindings(deduped);

    // The book is best-effort. A write failure (or error.NegativeTimestamp from a bad clock)
    // must not propagate: a non-zero exit surfaces as a hook ERROR with no findings, which is
    // the opposite of the always-report invariant above. Say so in-band instead.
    var book_notice: []const u8 = "";
    recordToBook(c, path, src, deduped, active.items) catch |e| {
        book_notice = std.fmt.allocPrint(
            c.gpa,
            "\n\n⚠ the book was not updated ({s}) — findings above are still valid.",
            .{@errorName(e)},
        ) catch "";
    };

    return .{
        .base = std.fs.path.basename(path),
        .findings = deduped,
        .notice = notice,
        .book_notice = book_notice,
    };
}

// ---- check: the same analysis, for any agent ------------------------------
// Agents without Claude Code's hook system can run this after each edit. Findings go to
// stdout in the same grouped form the hook feeds Claude; exit 1 means something BLOCKING.

fn runCheck(c: vars.Ctx, files: []const []const u8) !void {
    if (files.len == 0) return fail(c, "usage: zcanon check <file.zig>...\n");
    var buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &buf);
    var blocking = false;
    var unreadable = false;
    for (files) |path| {
        const a = (try analyze(c, path)) orelse {
            try w.interface.print("{s}: cannot read file\n", .{path});
            unreadable = true;
            continue;
        };
        for (a.findings) |f| {
            if (tier.classify(f.severity, path) == .blocking) blocking = true;
        }
        if (try hook.renderContext(c.gpa, a.base, path, a.findings)) |body| {
            try w.interface.print("{s}{s}{s}\n", .{ body, a.notice, a.book_notice });
        } else {
            try w.interface.print("{s}: no findings{s}{s}\n", .{ a.base, a.notice, a.book_notice });
        }
    }
    try w.interface.flush();
    if (unreadable) std.process.exit(3);
    if (blocking) std.process.exit(1);
}

fn recordToBook(
    c: vars.Ctx,
    path: []const u8,
    src: []const u8,
    findings: []const hook.Finding,
    active: []const []const u8,
) !void {
    var b: book.Book = .init(c.gpa);
    const book_path = try vars.bookPath(c);
    if (std.Io.Dir.cwd().readFileAlloc(c.io, book_path, c.gpa, .unlimited)) |text| {
        try b.parse(text);
    } else |_| {}

    var stamp_buf: [20]u8 = undefined;
    const now = try book.stamp(&stamp_buf, book.nowSeconds(c.io));
    const zver = zigVersion(c);

    var fresh: std.ArrayList(book.Record) = .empty;
    for (findings) |f| {
        try fresh.append(c.gpa, .{
            .first_ts = now,
            .last_ts = now,
            .hits = 1,
            .zig_version = zver,
            .file = path,
            .rule = f.rule,
            .severity = f.severity,
            .line = f.line,
            .col = f.col,
            .message = f.message,
            .snippet = hook.snippetFor(src, f.line),
        });
    }

    b.pruneFile(path, fresh.items, active);
    try b.upsert(fresh.items);
    try writeBook(c, &b, book_path);
}

fn writeBook(c: vars.Ctx, b: *const book.Book, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(c.io, dir);
    var w: std.Io.Writer.Allocating = .init(c.gpa);
    try b.write(&w.writer);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = w.written() });
}

fn zigVersion(c: vars.Ctx) []const u8 {
    const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ "zig", "version" } }) catch return "unknown";
    return std.mem.trim(u8, r.stdout, " \t\r\n");
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
    try w.interface.print("zsnag binary: {s}{s}\n", .{
        zsnag_path,
        if (exists(c, zsnag_path)) "" else "   ← MISSING, footgun checks will not run",
    });
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

// ---- the book -------------------------------------------------------------

fn loadBook(c: vars.Ctx, b: *book.Book) !void {
    const path = try vars.bookPath(c);
    const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited) catch return;
    try b.parse(text);
}

fn runBook(c: vars.Ctx, args: []const []const u8) !void {
    var b: book.Book = .init(c.gpa);
    try loadBook(c, &b);
    const mode = report.Mode.parse(args) catch return fail(c, "unknown report; try: book | book recent [N] | book files | book R0NN\n");

    var buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &buf);
    try report.render(c.gpa, &w.interface, b.recs.items, mode);
    try w.interface.flush();
}

fn runPrune(c: vars.Ctx) !void {
    var b: book.Book = .init(c.gpa);
    try loadBook(c, &b);
    const before = b.recs.items.len;

    var i: usize = 0;
    while (i < b.recs.items.len) {
        if (exists(c, b.recs.items[i].file)) i += 1 else _ = b.recs.orderedRemove(i);
    }
    try writeBook(c, &b, try vars.bookPath(c));

    var buf: [256]u8 = undefined;
    var w = stdout(c, &buf);
    try w.interface.print("pruned {d} findings for vanished files ({d} → {d}).\n", .{
        before - b.recs.items.len, before, b.recs.items.len,
    });
    try w.interface.flush();
}
