//! zcanon — one binary: the PostToolUse hook, its install/uninstall management, and the
//! reader over the book. Replaces `nu/zhook.nu` + `nu/zbook.nu`; no `nu` and no `sqlite3`
//! on the hook path.
const std = @import("std");
const vars = @import("vars.zig");
const settings = @import("settings.zig");
const hook = @import("hook.zig");
const book = @import("book.zig");
const report = @import("report.zig");

const usage =
    \\zcanon <command> [args]
    \\
    \\  hook               run as a PostToolUse hook (reads the payload on stdin)
    \\  install            add the hook to Claude Code's settings.json (backs up first)
    \\  uninstall          remove ONLY our entry; leave other settings intact
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

    if (std.mem.eql(u8, cmd, "hook")) return runHook(c);
    if (std.mem.eql(u8, cmd, "install")) return runInstall(c);
    if (std.mem.eql(u8, cmd, "uninstall")) return runUninstall(c);
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

    const path = (hook.filePathFromPayload(c.gpa, payload) catch return) orelse return;
    if (!std.mem.endsWith(u8, path, ".zig")) return;
    const src = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited) catch return;

    var findings: std.ArrayList(hook.Finding) = .empty;

    // zsnag lives beside this binary. If it is missing we say so loudly in-band rather than
    // skipping silently — "no findings" must never be indistinguishable from "never checked".
    const self = try vars.selfExe(c);
    const bin_dir = std.fs.path.dirname(self) orelse ".";
    const zsnag_path = try std.fs.path.join(c.gpa, &.{ bin_dir, "zsnag" });

    var ran_zsnag = false;
    var notice: []const u8 = "";
    if (exists(c, zsnag_path)) {
        const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ zsnag_path, "--json", path } }) catch null;
        if (r) |res| {
            // zsnag prints findings on stderr today (ledger B3), so read both streams.
            ran_zsnag = switch (res.term) {
                .exited => |code| code <= 1,
                else => false,
            };
            if (ran_zsnag) {
                try hook.parseSnagJson(c.gpa, res.stdout, &findings);
                try hook.parseSnagJson(c.gpa, res.stderr, &findings);
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

    var ran_ast = false;
    if (std.process.run(c.gpa, c.io, .{ .argv = &.{ "zig", "ast-check", path } }) catch null) |res| {
        ran_ast = true;
        try hook.parseAstCheck(c.gpa, res.stderr, &findings);
    }

    hook.sortFindings(findings.items);
    const base = std.fs.path.basename(path);
    try recordToBook(c, path, src, findings.items, ran_zsnag, ran_ast);

    const ctx = (try hook.renderContext(c.gpa, base, path, findings.items)) orelse
        (if (notice.len == 0) return else notice);
    const full = if (notice.len == 0) ctx else try std.mem.concat(c.gpa, u8, &.{ ctx, notice });

    var out_buf: [1 << 16]u8 = undefined;
    var w = stdout(c, &out_buf);
    try w.interface.writeAll(try hook.renderResponse(c.gpa, full));
    try w.interface.flush();
}

fn recordToBook(
    c: vars.Ctx,
    path: []const u8,
    src: []const u8,
    findings: []const hook.Finding,
    ran_zsnag: bool,
    ran_ast: bool,
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

    b.pruneFile(path, fresh.items, ran_zsnag, ran_ast);
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

fn runUninstall(c: vars.Ctx) !void {
    const path = try vars.settingsPath(c);
    var root = try settings.load(c, c.gpa, path);
    const n = try settings.removeOurs(c.gpa, &root);
    try settings.save(c, path, try settings.render(c.gpa, root));

    var buf: [1024]u8 = undefined;
    var w = stdout(c, &buf);
    try w.interface.print("Removed {d} zcanon entr{s} from {s}.\n", .{ n, if (n == 1) "y" else "ies", path });
    try w.interface.flush();
}

fn runStatus(c: vars.Ctx) !void {
    const path = try vars.settingsPath(c);
    var root = try settings.load(c, c.gpa, path);
    const installed = settings.isInstalled(c.gpa, &root);
    const flag = try vars.disableFlagPath(c);
    const enabled = !exists(c, flag);

    const self = try vars.selfExe(c);
    const bin_dir = std.fs.path.dirname(self) orelse ".";
    const zsnag_path = try std.fs.path.join(c.gpa, &.{ bin_dir, "zsnag" });
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
