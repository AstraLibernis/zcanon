// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The background process: one per project, started by the hook on first use and gone after
//! 30 idle minutes. It keeps two things warm that each hook run would otherwise pay for:
//!
//!   - the zephem map, fully indexed once, so a hook asks for its rows instead of scanning
//!     the 9.5 MB table (~1.8 ms) on every edit;
//!   - Zig's incremental compiler, `zig build check --watch -fincremental`, so every edit is
//!     semantically checked (types, calls, fields) in ~10 ms — errors `zig ast-check` cannot
//!     see at all. Needs the project's `check` step; see `semantic.addCheck`.
//!
//! The hook never waits on the compiler: it reports the last finished build and says when
//! that build predates the edit. Anything wrong with the daemon (not running, stale binary,
//! socket trouble) makes the hook fall back to doing everything itself — the daemon is an
//! accelerator, never a dependency.
//!
//! Protocol, one request per connection, newline-separated:
//!   → `zcanon-daemon 1`, `cmd query|status|stop`, `exe <stamp>`, `key <path>`…, blank line
//!   ← `ok` | `stale`, then `zig <ver>`, `map ok|missing <why>`, `row <tsv>`…,
//!     `sem <state>\t<finished ns>\t<detail>`, `diag <path>\t<line>\t<col>\t<sev>\t<msg>`…,
//!     `offer <text>`, `end`
const std = @import("std");
const builtin = @import("builtin");
const vars = @import("vars.zig");
const zephem = @import("zephem.zig");
const semantic = @import("semantic.zig");

pub const version_line = "zcanon-daemon 1";

/// Exit after this long without a request.
const idle_ns: i96 = 30 * std.time.ns_per_min;

/// The daemon is off on Windows (untested there) and when `ZCANON_DAEMON=0` — the CLI tests
/// set that so a test never leaves a process behind; the hook then does everything itself.
pub fn enabled(c: vars.Ctx) bool {
    if (builtin.os.tag == .windows) return false;
    const v = c.get("ZCANON_DAEMON") orelse return true;
    return !std.mem.eql(u8, v, "0");
}

/// `<config>/d/<hash of root>`: `.sock` for the socket, `.lock` held for the daemon's life.
fn basePath(c: vars.Ctx, root: []const u8) ![]u8 {
    const dir = try vars.configDir(c);
    var name: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "{x:0>16}", .{std.hash.Wyhash.hash(0, root)}) catch unreachable; // zsnag:ok — 16 hex digits fit exactly
    return std.fs.path.join(c.gpa, &.{ dir, "d", &name });
}

/// This binary's identity: path and modification time. A daemon started by an older build
/// answers `stale` and exits, so a rebuilt zcanon never talks to old code.
pub fn exeStamp(c: vars.Ctx) ![]const u8 {
    const self = try vars.selfExe(c);
    const st = try std.Io.Dir.cwd().statFile(c.io, self, .{});
    return std.fmt.allocPrint(c.gpa, "{s}\t{d}", .{ self, st.mtime.nanoseconds });
}

// ---- client ------------------------------------------------------------------

pub const SemState = enum {
    /// build.zig has no `check` step; semantic checks are off for this project.
    no_check,
    /// The watcher has not finished its first build yet.
    starting,
    ok,
    errors,
    /// The watcher is not running; `detail` says why.
    down,
};

pub const Reply = struct {
    zig_version: []const u8 = "",
    /// Null: the daemon's map is unavailable; `map_missing` says why.
    rows: ?[]u8 = null,
    map_missing: []const u8 = "",
    sem: SemState = .down,
    /// When the reported build finished (real clock, ns); 0 when none has.
    finished_ns: i96 = 0,
    detail: []const u8 = "",
    diags: []semantic.Diag = &.{},
    offer: []const u8 = "",
};

pub const Cmd = enum { query, status, stop };

/// Ask the project's daemon. Null when there is none (or it is stale); the caller falls back.
pub fn request(c: vars.Ctx, root: []const u8, cmd: Cmd, keys: ?*const zephem.Keys) ?Reply {
    return requestInner(c, root, cmd, keys) catch null;
}

fn requestInner(c: vars.Ctx, root: []const u8, cmd: Cmd, keys: ?*const zephem.Keys) !?Reply {
    const base = try basePath(c, root);
    const sock = try std.fmt.allocPrint(c.gpa, "{s}.sock", .{base});
    const addr = try std.Io.net.UnixAddress.init(sock);
    const stream = try addr.connect(c.io);
    defer stream.close(c.io);

    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(c.io, &wbuf);
    try w.interface.print("{s}\ncmd {t}\nexe {s}\n", .{ version_line, cmd, try exeStamp(c) });
    if (keys) |ks| {
        var it = ks.keyIterator();
        while (it.next()) |k| try w.interface.print("key {s}\n", .{k.*});
    }
    try w.interface.writeAll("\n");
    try w.interface.flush();

    var rbuf: [1 << 16]u8 = undefined;
    var r = stream.reader(c.io, &rbuf);
    const first = (try r.interface.takeDelimiter('\n')) orelse return null;
    if (!std.mem.eql(u8, first, "ok")) return null;

    var reply: Reply = .{};
    var rows: std.ArrayList(u8) = .empty;
    var map_ok = false;
    var diags: std.ArrayList(semantic.Diag) = .empty;
    while (try r.interface.takeDelimiter('\n')) |line| {
        if (std.mem.eql(u8, line, "end")) break;
        const sp = std.mem.findScalar(u8, line, ' ') orelse continue;
        const tag = line[0..sp];
        const val = line[sp + 1 ..];
        if (std.mem.eql(u8, tag, "zig")) {
            reply.zig_version = try c.gpa.dupe(u8, val);
        } else if (std.mem.eql(u8, tag, "map")) {
            map_ok = std.mem.eql(u8, val, "ok");
            if (!map_ok) reply.map_missing = try c.gpa.dupe(u8, std.mem.trimStart(u8, val, "missing "));
        } else if (std.mem.eql(u8, tag, "row")) {
            try rows.appendSlice(c.gpa, val);
            try rows.append(c.gpa, '\n');
        } else if (std.mem.eql(u8, tag, "sem")) {
            var f = std.mem.splitScalar(u8, val, '\t');
            reply.sem = std.meta.stringToEnum(SemState, f.next() orelse "") orelse .down;
            reply.finished_ns = std.fmt.parseInt(i96, f.next() orelse "0", 10) catch 0;
            reply.detail = try c.gpa.dupe(u8, f.rest());
        } else if (std.mem.eql(u8, tag, "diag")) {
            var f = std.mem.splitScalar(u8, val, '\t');
            try diags.append(c.gpa, .{
                .path = try c.gpa.dupe(u8, f.next() orelse continue),
                .line = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue,
                .col = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue,
                .severity = if (std.mem.eql(u8, f.next() orelse "", "error")) "error" else "note",
                .message = try c.gpa.dupe(u8, f.rest()),
            });
        } else if (std.mem.eql(u8, tag, "offer")) {
            reply.offer = try c.gpa.dupe(u8, val);
        }
    }
    if (map_ok) reply.rows = rows.items;
    reply.diags = diags.items;
    return reply;
}

/// Start the project's daemon in the background and return at once. Best-effort: a failure
/// only means the next edit falls back again.
pub fn start(c: vars.Ctx, root: []const u8) void {
    const self = vars.selfExe(c) catch return;
    _ = std.process.spawn(c.io, .{
        .argv = &.{ self, "daemon", root },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Its own process group: it must outlive the hook that started it.
        .pgid = 0,
    }) catch return;
}

// ---- server ------------------------------------------------------------------

const Daemon = struct {
    c: vars.Ctx,
    root: []const u8,
    sock_path: []const u8,
    exe: []const u8,
    zig_version: []const u8,

    mutex: std.Io.Mutex = .init,
    last_request_ns: i96,

    map: ?zephem.Map = null,
    map_missing: []const u8 = "",
    map_mtime: i96 = 0,

    sem: SemState = .starting,
    detail: []const u8 = "",
    finished_ns: i96 = 0,
    /// The last finished build's diagnostics; owned by `diag_text` (one allocation each).
    diags: std.ArrayList(semantic.Diag) = .empty,
    diag_text: std.ArrayList([]u8) = .empty,
    offered: bool = false,
    watcher_pid: ?std.posix.pid_t = null,
    stopping: bool = false,

    fn now(d: *Daemon) i96 {
        return std.Io.Clock.real.now(d.c.io).nanoseconds;
    }

    fn lock(d: *Daemon) void {
        d.mutex.lockUncancelable(d.c.io);
    }

    fn unlock(d: *Daemon) void {
        d.mutex.unlock(d.c.io);
    }

    /// Replace the published build result. Caller holds the lock.
    fn publish(d: *Daemon, state: SemState, detail: []const u8, diags: []const semantic.Diag) void {
        for (d.diag_text.items) |t| d.c.gpa.free(t);
        d.diag_text.clearRetainingCapacity();
        d.diags.clearRetainingCapacity();
        for (diags) |x| {
            const text = std.fmt.allocPrint(d.c.gpa, "{s}{s}", .{ x.path, x.message }) catch continue;
            d.diag_text.append(d.c.gpa, text) catch {
                d.c.gpa.free(text);
                continue;
            };
            d.diags.append(d.c.gpa, .{
                .path = text[0..x.path.len],
                .line = x.line,
                .col = x.col,
                .severity = x.severity,
                .message = text[x.path.len..],
            }) catch continue;
        }
        d.sem = state;
        d.detail = detail;
    }

    fn setState(d: *Daemon, state: SemState, detail: []const u8) void {
        d.lock();
        defer d.unlock();
        d.publish(state, detail, &.{});
    }

    /// Reload the map when zephem rebuilt its table. Caller holds the lock.
    fn refreshMap(d: *Daemon) void {
        const path = zephem.lookupPath(d.c) catch {
            d.map_missing = "zephem not found; run `zcanon setup`";
            return;
        };
        const mtime: i96 = if (std.Io.Dir.cwd().statFile(d.c.io, path, .{})) |st| st.mtime.nanoseconds else |_| 0;
        if (d.map != null and mtime == d.map_mtime) return;
        if (d.map) |*m| m.deinit();
        d.map = null;
        d.map = zephem.load(d.c, null) catch |e| {
            d.map_missing = switch (e) {
                error.NoLookupTable => zephem.remedy,
                else => @errorName(e),
            };
            return;
        };
        d.map_mtime = mtime;
    }

    fn handle(d: *Daemon, stream: std.Io.net.Stream, arena: std.mem.Allocator) !void {
        var rbuf: [1 << 14]u8 = undefined;
        var r = stream.reader(d.c.io, &rbuf);
        var wbuf: [1 << 16]u8 = undefined;
        var w = stream.writer(d.c.io, &wbuf);
        const out = &w.interface;

        const hello = (try r.interface.takeDelimiter('\n')) orelse return;
        if (!std.mem.eql(u8, hello, version_line)) {
            try out.writeAll("stale\n");
            return out.flush();
        }
        var cmd: Cmd = .query;
        var exe_ok = false;
        var keys: std.ArrayList([]const u8) = .empty;
        while (try r.interface.takeDelimiter('\n')) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "cmd ")) {
                cmd = std.meta.stringToEnum(Cmd, line[4..]) orelse .query;
            } else if (std.mem.startsWith(u8, line, "exe ")) {
                exe_ok = std.mem.eql(u8, line[4..], d.exe);
            } else if (std.mem.startsWith(u8, line, "key ")) {
                try keys.append(arena, try arena.dupe(u8, line[4..]));
            }
        }
        // A rebuilt zcanon must not be answered by old code: say so, then go.
        if (!exe_ok or cmd == .stop) {
            try out.writeAll(if (exe_ok) "ok\nsem down\t0\tstopping\nend\n" else "stale\n");
            try out.flush();
            d.stopping = true;
            return;
        }

        d.lock();
        defer d.unlock();
        d.last_request_ns = d.now();
        if (cmd == .query) d.refreshMap();

        try out.print("ok\nzig {s}\n", .{d.zig_version});
        if (d.map) |m| {
            try out.writeAll("map ok\n");
            for (keys.items) |k| if (m.get(k)) |e| try out.print("row {s}\n", .{e.row});
        } else try out.print("map missing {s}\n", .{d.map_missing});
        try out.print("sem {t}\t{d}\t{s}\n", .{ d.sem, d.finished_ns, d.detail });
        for (d.diags.items) |x| try out.print("diag {s}\t{d}\t{d}\t{s}\t{s}\n", .{ x.path, x.line, x.col, x.severity, x.message });
        if (d.sem == .no_check and !d.offered and cmd == .query) {
            d.offered = true;
            try out.print("offer {s}\n", .{d.root});
        }
        try out.writeAll("end\n");
        try out.flush();
    }

    /// Does `zig build -l` list a `check` step? Null when build.zig itself does not build.
    fn hasCheckStep(d: *Daemon) ?bool {
        const res = std.process.run(d.c.gpa, d.c.io, .{
            .argv = &.{ "zig", "build", "-l" },
            .cwd = .{ .path = d.root },
        }) catch return null;
        defer d.c.gpa.free(res.stdout);
        defer d.c.gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) return null,
            else => return null,
        }
        var lines = std.mem.splitScalar(u8, res.stdout, '\n');
        while (lines.next()) |line| {
            var toks = std.mem.tokenizeAny(u8, line, " \t");
            if (std.mem.eql(u8, toks.next() orelse "", "check")) return true;
        }
        return false;
    }

    fn buildZigMtime(d: *Daemon) i96 {
        const p = std.fs.path.join(d.c.gpa, &.{ d.root, "build.zig" }) catch return 0;
        defer d.c.gpa.free(p);
        const st = std.Io.Dir.cwd().statFile(d.c.io, p, .{}) catch return 0;
        return st.mtime.nanoseconds;
    }

    /// Run the watcher; restart it when it exits, and wait for build.zig to change while there
    /// is no `check` step or build.zig does not build.
    fn watchLoop(d: *Daemon) void {
        var quick_exits: u32 = 0;
        while (!d.stopping) {
            const seen_mtime = d.buildZigMtime();
            const has = d.hasCheckStep();
            if (has == null or has.? == false) {
                if (has == null)
                    d.setState(.down, "build.zig does not build (`zig build -l` failed); waiting for it to change")
                else
                    d.setState(.no_check, "");
                while (!d.stopping and d.buildZigMtime() == seen_mtime) d.c.io.sleep(.fromSeconds(2), .awake) catch return;
                continue;
            }
            const began = d.now();
            d.runWatcher() catch {}; // zsnag:ok — exit is handled below, whatever the cause
            if (d.stopping) return;
            if (d.now() - began < 60 * std.time.ns_per_s) quick_exits += 1 else quick_exits = 0;
            if (quick_exits >= 5) {
                d.setState(.down, "`zig build check --watch` keeps exiting; run it by hand to see why");
                while (!d.stopping and d.buildZigMtime() == seen_mtime) d.c.io.sleep(.fromSeconds(2), .awake) catch return;
                quick_exits = 0;
                continue;
            }
            d.setState(.down, "the compiler watcher exited; restarting");
            d.c.io.sleep(.fromSeconds(2), .awake) catch return;
        }
    }

    fn runWatcher(d: *Daemon) !void {
        d.setState(.starting, "");
        var child = try std.process.spawn(d.c.io, .{
            // A short debounce: with 0 the watcher compiled a half-written file and reported
            // an error that was not there.
            .argv = &.{ "zig", "build", "check", "--watch", "-fincremental", "--debounce", "50" },
            .cwd = .{ .path = d.root },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
            .pgid = 0,
        });
        d.watcher_pid = child.id;
        defer {
            d.killWatcher();
            _ = child.wait(d.c.io) catch {}; // zsnag:ok — already killed; reaping only
        }

        var buf: [1 << 16]u8 = undefined;
        var r = child.stderr.?.readerStreaming(d.c.io, &buf);
        var k: semantic.Collector = .{ .gpa = d.c.gpa };
        defer k.deinit();
        while (true) {
            const line = r.interface.takeDelimiter('\n') catch |e| switch (e) {
                error.StreamTooLong => {
                    // An over-long line (a huge `failed command:`) is dropped, not fatal.
                    r.interface.toss(r.interface.buffered().len);
                    continue;
                },
                else => return e,
            } orelse break;
            if (!try k.feed(line)) continue;
            var errors = false;
            for (k.diags.items) |x| if (std.mem.eql(u8, x.severity, "error")) {
                errors = true;
            };
            d.lock();
            d.publish(if (errors) .errors else .ok, "", k.diags.items);
            d.finished_ns = d.now();
            d.unlock();
            k.clear();
        }
    }

    /// The watcher and everything it started (the build runner, the compiler) share its
    /// process group.
    fn killWatcher(d: *Daemon) void {
        const pid = d.watcher_pid orelse return;
        d.watcher_pid = null;
        std.posix.kill(-pid, .TERM) catch {}; // zsnag:ok — already gone is fine
        reapOrphans(d.c.io);
    }

    fn idleLoop(d: *Daemon) void {
        while (true) {
            d.c.io.sleep(.fromSeconds(5), .awake) catch return;
            d.lock();
            const idle = d.now() - d.last_request_ns > idle_ns;
            d.unlock();
            if (idle or d.stopping) d.exit();
        }
    }

    fn exit(d: *Daemon) noreturn {
        d.stopping = true;
        d.killWatcher();
        std.Io.Dir.cwd().deleteFile(d.c.io, d.sock_path) catch {}; // zsnag:ok — best-effort cleanup
        std.process.exit(0);
    }
};

/// Collect exited descendants the subreaper inherited. Waits briefly for the ones just
/// signalled; never blocks on one that is still running.
fn reapOrphans(io: std.Io) void {
    if (builtin.os.tag != .linux) return;
    for (0..20) |_| {
        var status: u32 = 0;
        while (true) {
            const rc: isize = @bitCast(std.os.linux.waitpid(-1, &status, std.os.linux.W.NOHANG));
            if (rc <= 0) break;
        }
        io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
}

/// `zcanon daemon <root>`: serve until idle. Exits quietly if another daemon owns the root.
pub fn serve(parent: vars.Ctx, root: []const u8) !void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.setsid();
        // Orphans of the compiler watcher (the build runner, the compiler) are re-parented to
        // us rather than to PID 1, so `reapOrphans` can collect them. A container whose PID 1
        // never reaps would otherwise keep them as zombies.
        _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
    }
    // Long-lived, multi-threaded state: a thread-safe allocator, not the per-run arena.
    const c: vars.Ctx = .{ .gpa = std.heap.smp_allocator, .io = parent.io, .env = parent.env };

    const base = try basePath(c, root);
    if (std.fs.path.dirname(base)) |dir| try std.Io.Dir.cwd().createDirPath(c.io, dir);
    const lock_path = try std.fmt.allocPrint(c.gpa, "{s}.lock", .{base});
    const lock_file = try std.Io.Dir.cwd().createFile(c.io, lock_path, .{ .truncate = false });
    defer lock_file.close(c.io);
    if (!try lock_file.tryLock(c.io, .exclusive)) return; // another daemon owns this root

    // We own the lock, so any socket file left behind is from a daemon that died.
    const sock_path = try std.fmt.allocPrint(c.gpa, "{s}.sock", .{base});
    std.Io.Dir.cwd().deleteFile(c.io, sock_path) catch {}; // zsnag:ok — absent is the normal case
    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(c.io, .{});
    defer server.deinit(c.io);

    const zv = std.process.run(c.gpa, c.io, .{ .argv = &.{ "zig", "version" } }) catch null;
    var d: Daemon = .{
        .c = c,
        .root = root,
        .sock_path = sock_path,
        .exe = try exeStamp(c),
        .zig_version = if (zv) |r| std.mem.trim(u8, r.stdout, " \t\r\n") else "unknown",
        .last_request_ns = 0,
    };
    d.last_request_ns = d.now();
    d.lock();
    d.refreshMap();
    d.unlock();

    var watch = try c.io.concurrent(Daemon.watchLoop, .{&d});
    defer watch.cancel(c.io);
    var idle = try c.io.concurrent(Daemon.idleLoop, .{&d});
    defer idle.cancel(c.io);

    while (!d.stopping) {
        const stream = server.accept(c.io) catch continue;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        d.handle(stream, arena.allocator()) catch {}; // zsnag:ok — one bad client must not stop the daemon
        arena.deinit();
        stream.close(c.io);
    }
    d.exit();
}
