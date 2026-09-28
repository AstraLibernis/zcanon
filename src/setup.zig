// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! `zcanon setup` and `zcanon doctor`: one command that takes a fresh clone to a working,
//! verified hook.
//!
//! Three phases, each a list of checks that print `[ok]`, `[fixed]`, `[FAIL]` or `[info]`:
//!   1. zephem   — zig on PATH, the zephem checkout found and recorded, its binary built,
//!                 the map pinned to this zig, the lookup table present and loadable.
//!   2. hookable — zsnag beside zcanon, Claude Code's settings.json readable and writable.
//!   3. hook     — installed (pointing at this build), enabled, then PROVEN: the command is
//!                 read back from settings.json and run exactly as Claude Code would, on a
//!                 probe file with one known problem per check group. Only if the core rules,
//!                 the zephem map rules and `zig ast-check` all report is the hook "working".
//!
//! `setup` fixes what it safely can (records zephem, builds it, bakes the lookup table,
//! installs and enables the hook, installs the skill). `doctor` runs the same checks and
//! changes nothing. Both exit 1 if anything failed.
//!
//! What setup deliberately does NOT do: clone zephem (network), or regenerate a stale map
//! (`zephem depth` takes minutes and saturates every core). It prints the exact command instead.
const std = @import("std");
const builtin = @import("builtin");
const vars = @import("vars.zig");
const settings = @import("settings.zig");
const zephem = @import("zephem.zig");

pub const Mode = enum { setup, doctor };

const Mark = enum { ok, fixed, removed, fail, info };

const Report = struct {
    w: *std.Io.Writer,
    failed: bool = false,

    fn line(r: *Report, m: Mark, comptime fmt: []const u8, args: anytype) !void {
        if (m == .fail) r.failed = true;
        try r.w.writeAll(switch (m) {
            .ok => "  [ok]      ",
            .fixed => "  [fixed]   ",
            .removed => "  [removed] ",
            .fail => "  [FAIL]    ",
            .info => "  [info]    ",
        });
        try r.w.print(fmt ++ "\n", args);
    }

    /// The exact next step, under a [FAIL].
    fn todo(r: *Report, comptime fmt: []const u8, args: anytype) !void {
        try r.w.print("            -> " ++ fmt ++ "\n", args);
    }

    fn phase(r: *Report, title: []const u8) !void {
        try r.w.print("\n{s}\n", .{title});
    }
};

/// The probe file: one known problem per check group, so the live test can tell which groups
/// actually ran inside the hook. R003 is a core rule, R012 needs the zephem map, and the unused
/// constant is an error only `zig ast-check` reports.
const PROBE_SRC =
    \\const std = @import("std");
    \\pub fn main() void {
    \\    var a: [4]u8 = undefined;
    \\    std.mem.copy(u8, &a, "abcd");
    \\    _ = std.mem.eql(u8, "a");
    \\    const unused = 1;
    \\}
    \\
;

pub fn run(c: vars.Ctx, mode: Mode, args: []const []const u8) !void {
    var buf: [1 << 14]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const w = &fw.interface;

    if (args.len > 0) {
        try w.print("zcanon {s} takes no arguments (got `{s}`)\n", .{ @tagName(mode), args[0] });
        try w.flush();
        std.process.exit(2);
    }

    var r: Report = .{ .w = w };
    try w.print("zcanon {s}{s}\n", .{
        @tagName(mode),
        if (mode == .doctor) " — checking only, nothing will be changed" else "",
    });

    // setup stops at the first failed phase: installing a hook on top of a broken zephem
    // would "succeed" and then check nothing. doctor keeps going to show everything at once.
    const zephem_ok = try phaseZephem(c, &r, mode);
    if (zephem_ok or mode == .doctor) {
        const hookable = try phaseHookable(c, &r);
        if (hookable or mode == .doctor) try phaseHook(c, &r, mode);
    }

    try w.writeAll("\n");
    if (r.failed) {
        try w.print("Not ready. Fix the [FAIL] items above, then run `zcanon setup` again.\n", .{});
    } else if (mode == .setup) {
        try w.writeAll(
            "Done: zcanon is hooked into Claude Code and the hook was verified end to end.\n" ++
                "New Claude Code sessions pick it up; restart any session that is already open.\n",
        );
    } else {
        try w.writeAll("All checks pass.\n");
    }
    try w.flush();
    if (r.failed) std.process.exit(1);
}

// ---- phase 1: zephem ------------------------------------------------------

fn phaseZephem(c: vars.Ctx, r: *Report, mode: Mode) !bool {
    try r.phase("1. zephem, the std map zcanon checks against");

    const zv = zigVersion(c) orelse {
        try r.line(.fail, "`zig` is not on PATH", .{});
        try r.todo("install Zig {s} and put it on PATH", .{builtin.zig_version_string});
        return false;
    };
    if (!std.mem.eql(u8, zv, builtin.zig_version_string)) {
        try r.line(.fail, "zig on PATH is {s}, but zcanon was built with {s}", .{ zv, builtin.zig_version_string });
        try r.todo("put Zig {s} first on PATH, or rebuild zcanon and zephem with {s}", .{ builtin.zig_version_string, zv });
        return false;
    }
    try r.line(.ok, "zig {s} on PATH", .{zv});

    const home = zephem.locateHome(c) orelse {
        if (c.get("ZEPHEM_HOME")) |h| {
            try r.line(.fail, "$ZEPHEM_HOME is {s}, which is not a zephem checkout (no data/std/PINNED)", .{h});
            try r.todo("point ZEPHEM_HOME at your zephem clone, or unset it", .{});
        } else {
            try r.line(.fail, "zephem not found: no $ZEPHEM_HOME, nothing recorded, no zephem/ beside zcanon", .{});
            try r.todo("git clone https://github.com/AstraLibernis/zephem.git  (next to zcanon), then rerun", .{});
        }
        return false;
    };
    try r.line(.ok, "zephem at {s} ({s})", .{ home.path, home.source.describe() });

    // Record it, so the hook finds zephem no matter what environment Claude Code starts it in.
    const already = if (zephem.recorded(c)) |rec| std.mem.eql(u8, rec, home.path) else false;
    if (!already) {
        const rec = try vars.zephemRecordPath(c);
        if (mode == .setup) {
            try writeFileMkdir(c, rec, home.path);
            try r.line(.fixed, "recorded that location in {s}; ZEPHEM_HOME is no longer needed", .{rec});
        } else {
            try r.line(.info, "location not recorded yet; `zcanon setup` will record it", .{});
        }
    }

    const exe = try zephem.exePath(c, home.path);
    if (!exists(c, exe)) {
        if (mode == .doctor) {
            try r.line(.fail, "zephem is not built (no {s})", .{exe});
            try r.todo("cd {s} && zig build", .{home.path});
            return false;
        }
        try r.w.print("            building zephem (zig build in {s}) ...\n", .{home.path});
        try r.w.flush();
        if (!try runIn(c, r, home.path, &.{ "zig", "build" })) return false;
        try r.line(.fixed, "built zephem", .{});
    } else {
        try r.line(.ok, "zephem binary built", .{});
    }

    if (try zephem.staleness(c, zv)) |warn| {
        try r.line(.fail, "{s}", .{warn});
        try r.todo("cd {s} && zig-out/bin/zephem std && zig-out/bin/zephem depth && " ++
            "zig-out/bin/zephem overlays && zig-out/bin/zephem lookup   (depth takes minutes)", .{home.path});
        return false;
    }
    try r.line(.ok, "map is pinned to zig {s}", .{zv});

    const lp = try zephem.lookupPath(c); // zephem was located above, so this cannot miss
    if (!exists(c, lp)) {
        if (mode == .doctor) {
            try r.line(.fail, "lookup table missing ({s})", .{lp});
            try r.todo("cd {s} && zig-out/bin/zephem lookup", .{home.path});
            return false;
        }
        if (!try runIn(c, r, home.path, &.{ exe, "lookup" })) return false;
        try r.line(.fixed, "baked the lookup table ({s})", .{lp});
    }
    var map = zephem.load(c, null) catch |e| {
        try r.line(.fail, "lookup table at {s} could not be read: {s}", .{ lp, @errorName(e) });
        return false;
    };
    defer map.deinit();
    try r.line(.ok, "lookup table loads: {d} std declarations", .{map.count()});
    return true;
}

// ---- phase 2: can we hook in? -------------------------------------------

fn phaseHookable(c: vars.Ctx, r: *Report) !bool {
    try r.phase("2. Claude Code: can zcanon hook itself in?");
    var ok = true;

    const zsnag = try vars.zsnagPath(c);
    if (exists(c, zsnag)) {
        try r.line(.ok, "zsnag is beside zcanon", .{});
    } else {
        try r.line(.fail, "zsnag missing ({s})", .{zsnag});
        try r.todo("run `zig build` in the zcanon checkout", .{});
        ok = false;
    }

    const sp = try vars.settingsPath(c);
    const dir = std.fs.path.dirname(sp) orelse ".";
    if (!exists(c, dir) and c.get("ZCANON_SETTINGS") == null) {
        try r.line(.fail, "no Claude Code config directory at {s}", .{dir});
        try r.todo("install Claude Code and start it once, or set CLAUDE_CONFIG_DIR to where it lives", .{});
        return false;
    }

    _ = settings.load(c, c.gpa, sp) catch |e| {
        try r.line(.fail, "{s} is not valid JSON ({s}); zcanon will not rewrite a file it cannot parse", .{ sp, @errorName(e) });
        try r.todo("fix that file (or move it aside), then rerun", .{});
        return false;
    };
    try r.line(.ok, "settings readable: {s}{s}", .{ sp, if (exists(c, sp)) "" else " (will be created)" });

    // Prove we can write beside it; the install writes a temp file there and renames it.
    std.Io.Dir.cwd().createDirPath(c.io, dir) catch {}; // zsnag:ok — the write below reports it
    const probe = try std.fs.path.join(c.gpa, &.{ dir, ".zcanon-write-test" });
    if (std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = probe, .data = "" })) |_| {
        std.Io.Dir.cwd().deleteFile(c.io, probe) catch {}; // zsnag:ok — cleanup of an empty file
        try r.line(.ok, "settings directory is writable", .{});
    } else |e| {
        try r.line(.fail, "cannot write in {s} ({s})", .{ dir, @errorName(e) });
        ok = false;
    }

    const self = try vars.selfExe(c);
    try r.line(.info, "other agents: run `{s} check <file.zig>` after each edit; same checks, exit 1 = blocking", .{self});
    return ok;
}

// ---- phase 3: install, then prove it ---------------------------------------

fn phaseHook(c: vars.Ctx, r: *Report, mode: Mode) !void {
    try r.phase("3. the hook: install it, then prove it fires");

    const sp = try vars.settingsPath(c);
    const self = try vars.selfExe(c);
    const want = try settings.command(c.gpa, self);

    var root = settings.load(c, c.gpa, sp) catch |e| {
        try r.line(.fail, "cannot read {s}: {s}", .{ sp, @errorName(e) });
        return;
    };
    const have = settings.ourCommand(c.gpa, &root);
    const matcher = settings.ourMatcher(c.gpa, &root) orelse "";
    const matcher_ok = std.mem.eql(u8, matcher, settings.MATCHER);
    if (have != null and std.mem.eql(u8, have.?, want) and matcher_ok) {
        try r.line(.ok, "hook installed in {s} (fires on {s})", .{ sp, settings.MATCHER });
    } else if (mode == .doctor) {
        if (have != null and !matcher_ok) {
            try r.line(.fail, "the installed hook fires on `{s}`, not `{s}` — shell edits to .zig files go unchecked", .{ matcher, settings.MATCHER });
        } else if (have) |h| {
            try r.line(.fail, "the installed hook runs `{s}`, not this build", .{settings.exeFromCommand(h) orelse h});
        } else {
            try r.line(.fail, "hook not installed in {s}", .{sp});
        }
        try r.todo("zcanon setup", .{});
    } else {
        const had_file = exists(c, sp);
        try settings.addOurs(c.gpa, &root, want);
        try settings.save(c, sp, try settings.render(c.gpa, root));
        if (have != null and !matcher_ok) {
            try r.line(.fixed, "hook now fires on `{s}` (was `{s}`)", .{ settings.MATCHER, matcher });
        } else if (have) |h| {
            try r.line(.fixed, "hook updated to run this build (was `{s}`)", .{settings.exeFromCommand(h) orelse h});
        } else {
            try r.line(.fixed, "hook installed in {s}", .{sp});
        }
        if (had_file) try r.line(.info, "previous settings backed up to {s}.bak", .{sp});
        try r.line(.info, "`zcanon uninstall` removes only zcanon's entry; `zcanon disable` switches it off", .{});
    }

    const flag = try vars.disableFlagPath(c);
    if (exists(c, flag)) {
        if (mode == .doctor) {
            try r.line(.fail, "hook is switched off (`zcanon disable` was run)", .{});
            try r.todo("zcanon enable", .{});
        } else {
            try std.Io.Dir.cwd().deleteFile(c.io, flag);
            try r.line(.fixed, "hook was switched off; switched it back on", .{});
        }
    } else {
        try r.line(.ok, "hook is switched on", .{});
    }

    try liveTest(c, r, sp, mode);
    try skill(c, r, mode);
}

/// Read the command back from settings.json on disk and run it the way Claude Code does,
/// through a shell, with a PostToolUse payload naming the probe file. The probe's book is
/// redirected so the test leaves no trace in the real one.
fn liveTest(c: vars.Ctx, r: *Report, sp: []const u8, mode: Mode) !void {
    var root = settings.load(c, c.gpa, sp) catch |e| {
        try r.line(.fail, "live test: cannot re-read {s}: {s}", .{ sp, @errorName(e) });
        return;
    };
    // Not installed is already a [FAIL] above; a second one would only repeat it.
    const cmd = settings.ourCommand(c.gpa, &root) orelse {
        try r.line(.info, "live test skipped: nothing installed to test", .{});
        return;
    };

    const cfg = try vars.configDir(c);
    const dir = try std.fs.path.join(c.gpa, &.{ cfg, "probe" });
    defer std.Io.Dir.cwd().deleteTree(c.io, dir) catch {}; // zsnag:ok — best-effort probe cleanup
    const probe = try std.fs.path.join(c.gpa, &.{ dir, "probe.zig" });
    try writeFileMkdir(c, probe, PROBE_SRC);

    const payload = try std.fmt.allocPrint(c.gpa, "{{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{{\"file_path\":{f}}}}}", .{std.json.fmt(probe, .{})});
    const in_path = try std.fs.path.join(c.gpa, &.{ dir, "payload.json" });
    const out_path = try std.fs.path.join(c.gpa, &.{ dir, "out.json" });
    const err_path = try std.fs.path.join(c.gpa, &.{ dir, "err.txt" });
    try writeFileMkdir(c, in_path, payload);

    var env = try c.env.clone(c.gpa);
    try env.put("ZCANON_BOOK", try std.fs.path.join(c.gpa, &.{ dir, "book.tsv" }));

    const term = runShell(c, cmd, &env, in_path, out_path, err_path) catch |e| {
        try r.line(.fail, "live test: could not run the installed command ({s})", .{@errorName(e)});
        try r.todo("the command is: {s}", .{cmd});
        return;
    };
    const out = std.Io.Dir.cwd().readFileAlloc(c.io, out_path, c.gpa, .unlimited) catch "";
    const err = std.Io.Dir.cwd().readFileAlloc(c.io, err_path, c.gpa, .unlimited) catch "";

    const exited_ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        try r.line(.fail, "live test: the hook command failed", .{});
        try r.todo("command: {s}", .{cmd});
        if (std.mem.trim(u8, err, " \t\r\n").len > 0) try r.todo("stderr: {s}", .{firstLine(err)});
        return;
    }
    const ctx = additionalContext(c.gpa, out) orelse {
        // Silence is expected only from doctor on a switched-off hook, which already failed
        // above. After setup the switch must be on, so silence there is a real failure.
        if (mode == .doctor and exists(c, try vars.disableFlagPath(c))) {
            try r.line(.info, "live test: the hook is switched off, so it stayed silent as it should", .{});
            return;
        }
        try r.line(.fail, "live test: the hook ran but reported nothing for a file with three known problems", .{});
        try r.todo("run `zcanon doctor`; if everything else passes, report this as a zcanon bug", .{});
        return;
    };

    const core = std.mem.find(u8, ctx, "[R003]") != null;
    const map = std.mem.find(u8, ctx, "[R012]") != null;
    const ast = std.mem.find(u8, ctx, "[ast-check]") != null;
    if (core and map and ast) {
        try r.line(.ok, "live test: ran the installed command on a probe file; core rules, zephem map rules and zig ast-check all reported", .{});
        return;
    }
    try r.line(if (core) .ok else .fail, "live test: core rules (R001-R010) {s}", .{if (core) "fired" else "did NOT fire"});
    try r.line(if (map) .ok else .fail, "live test: zephem map rules (R011-R013) {s}", .{if (map) "fired" else "did NOT fire"});
    if (!map) try r.todo("{s}", .{if (core)
        "the hook cannot load the lookup table; check phase 1 above"
    else
        "the map rules run with the core rules, and those did not run either; fix that first"});
    try r.line(if (ast) .ok else .fail, "live test: zig ast-check {s}", .{if (ast) "ran" else "did NOT run"});
    if (!ast) try r.todo("`zig` must be on PATH in the environment Claude Code starts hooks in", .{});
}

/// Keep the installed skill identical to the one in this checkout.
fn skill(c: vars.Ctx, r: *Report, mode: Mode) !void {
    const self = try vars.selfExe(c);
    // <repo>/zig-out/bin/zcanon -> <repo>/skill/SKILL.md
    const bin = std.fs.path.dirname(self) orelse ".";
    const repo = std.fs.path.dirname(std.fs.path.dirname(bin) orelse ".") orelse ".";
    const src_path = try std.fs.path.join(c.gpa, &.{ repo, "skill", "SKILL.md" });
    const template = std.Io.Dir.cwd().readFileAlloc(c.io, src_path, c.gpa, .unlimited) catch {
        try r.line(.info, "skill: no skill/SKILL.md beside this build; skipped", .{});
        return;
    };
    const src = try renderSkill(c, template);

    const dst = try vars.skillPath(c);
    const cur: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(c.io, dst, c.gpa, .unlimited) catch null;
    if (cur != null and std.mem.eql(u8, cur.?, src)) {
        try r.line(.ok, "skill installed and current ({s})", .{dst});
        return;
    }
    if (mode == .doctor) {
        try r.line(.fail, "skill {s} ({s})", .{ if (cur == null) "not installed" else "out of date", dst });
        try r.todo("zcanon setup", .{});
        return;
    }
    if (cur) |old| {
        const bak = try std.fmt.allocPrint(c.gpa, "{s}.bak", .{dst});
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = bak, .data = old });
        try r.line(.fixed, "skill updated ({s}); the previous one is saved as SKILL.md.bak", .{dst});
    } else {
        try writeFileMkdir(c, dst, src);
        try r.line(.fixed, "skill installed ({s})", .{dst});
        return;
    }
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = dst, .data = src });
}

/// Fill the skill's `{{ZCANON}}`, `{{ZSNAG}}` and `{{ZEPHEM}}` with this machine's real paths,
/// so the model can run every command in it verbatim with no environment variables set.
pub fn renderSkill(c: vars.Ctx, template: []const u8) ![]u8 {
    const zephem_exe: []const u8 = if (zephem.locateHome(c)) |h| try zephem.exePath(c, h.path) else "zephem";
    const subs = [_][2][]const u8{
        .{ "{{ZCANON}}", try shellWord(c.gpa, try vars.selfExe(c)) },
        .{ "{{ZSNAG}}", try shellWord(c.gpa, try vars.zsnagPath(c)) },
        .{ "{{ZEPHEM}}", try shellWord(c.gpa, zephem_exe) },
    };
    var out: []u8 = try c.gpa.dupe(u8, template);
    for (subs) |s| {
        const n = std.mem.replacementSize(u8, out, s[0], s[1]);
        const next = try c.gpa.alloc(u8, n);
        _ = std.mem.replace(u8, out, s[0], s[1], next);
        out = next;
    }
    return out;
}

/// A path the model can paste into a shell: quoted only when it has to be.
fn shellWord(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, path, ' ') == null) return path;
    return std.fmt.allocPrint(gpa, "\"{s}\"", .{path});
}

// ---- helpers --------------------------------------------------------------

fn exists(c: vars.Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(c.io, path, .{}) catch return false;
    return true;
}

fn writeFileMkdir(c: vars.Ctx, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(c.io, d);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = data });
}

fn zigVersion(c: vars.Ctx) ?[]const u8 {
    const res = std.process.run(c.gpa, c.io, .{ .argv = &.{ "zig", "version" } }) catch return null;
    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const v = std.mem.trim(u8, res.stdout, " \t\r\n");
    return if (v.len == 0) null else v;
}

/// Run a build step in `cwd`, reporting failure with the tail of its output.
fn runIn(c: vars.Ctx, r: *Report, cwd: []const u8, argv: []const []const u8) !bool {
    const res = std.process.run(c.gpa, c.io, .{ .argv = argv, .cwd = .{ .path = cwd } }) catch |e| {
        try r.line(.fail, "could not run `{s}` in {s}: {s}", .{ argv[argv.len - 1], cwd, @errorName(e) });
        return false;
    };
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        try r.line(.fail, "`{s}` failed in {s}", .{ argv[argv.len - 1], cwd });
        const out = std.mem.trim(u8, if (res.stderr.len > 0) res.stderr else res.stdout, " \t\r\n");
        if (out.len > 0) try r.todo("{s}", .{lastLines(out, 6)});
    }
    return ok;
}

/// Claude Code runs hook commands through a shell (`sh` on Linux/macOS, Git Bash on
/// Windows), so the live test does too; that is what catches quoting problems.
fn runShell(
    c: vars.Ctx,
    cmd: []const u8,
    env: *const std.process.Environ.Map,
    in_path: []const u8,
    out_path: []const u8,
    err_path: []const u8,
) !std.process.Child.Term {
    const in_file = try std.Io.Dir.cwd().openFile(c.io, in_path, .{});
    defer in_file.close(c.io);
    const out_file = try std.Io.Dir.cwd().createFile(c.io, out_path, .{});
    defer out_file.close(c.io);
    const err_file = try std.Io.Dir.cwd().createFile(c.io, err_path, .{});
    defer err_file.close(c.io);

    const shell: []const u8 = if (builtin.os.tag == .windows) "bash" else "sh";
    var child = try std.process.spawn(c.io, .{
        .argv = &.{ shell, "-c", cmd },
        .environ_map = env,
        .stdin = .{ .file = in_file },
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = err_file },
    });
    return child.wait(c.io);
}

fn additionalContext(gpa: std.mem.Allocator, out: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, gpa, trimmed, .{}) catch return null;
    const root = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const hso = switch (root.get("hookSpecificOutput") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (hso.get("additionalContext") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const nl = std.mem.findScalar(u8, t, '\n') orelse return t;
    return t[0..nl];
}

fn lastLines(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i = s.len;
    while (i > 0) : (i -= 1) {
        if (s[i - 1] == '\n') {
            count += 1;
            if (count == n) return s[i..];
        }
    }
    return s;
}

// ---- uninstall --------------------------------------------------------------

/// `zcanon uninstall [--purge]`: undo everything `setup` put outside the checkout, then check
/// it is really gone.
///   - the hook entry in Claude Code's settings.json (only ours; everything else untouched)
///   - the installed skill, and the SKILL.md.bak setup made, if both are zcanon skills
///   - with --purge: ~/.config/zcanon (the book of findings and the recorded zephem location)
/// It never touches zephem, which is its own project, or the settings.json.bak backup, which is
/// a copy of the user's own settings.
pub fn uninstall(c: vars.Ctx, args: []const []const u8) !void {
    var buf: [1 << 13]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const w = &fw.interface;

    var purge = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--purge")) purge = true else {
            try w.print("usage: zcanon uninstall [--purge]\n", .{});
            try w.flush();
            std.process.exit(2);
        }
    }

    var r: Report = .{ .w = w };
    try w.print("zcanon uninstall{s}\n", .{if (purge) " --purge" else ""});

    // 1. The hook.
    const sp = try vars.settingsPath(c);
    if (exists(c, sp)) {
        var root = settings.load(c, c.gpa, sp) catch |e| {
            try r.line(.fail, "{s} is not valid JSON ({s}); not touching it", .{ sp, @errorName(e) });
            try r.todo("fix it, then rerun; or remove the entry marked {s} by hand", .{settings.MARKER});
            return finish(&r, w);
        };
        const n = try settings.removeOurs(c.gpa, &root);
        if (n > 0) {
            try settings.save(c, sp, try settings.render(c.gpa, root));
            try r.line(.removed, "hook removed from {s} (backup: {s}.bak)", .{ sp, sp });
        } else {
            try r.line(.ok, "no hook in {s}", .{sp});
        }
        // Verify from disk, not from memory.
        var check = try settings.load(c, c.gpa, sp);
        if (settings.isInstalled(c.gpa, &check)) try r.line(.fail, "the hook is STILL in {s}", .{sp});
    } else {
        try r.line(.ok, "no Claude Code settings at {s}; nothing to remove", .{sp});
    }

    // 2. The skill (and setup's backup of an earlier zcanon skill).
    try removeSkill(c, &r);

    // 3. Local state.
    const cfg = try vars.configDir(c);
    if (purge) {
        if (exists(c, cfg)) {
            std.Io.Dir.cwd().deleteTree(c.io, cfg) catch |e| {
                try r.line(.fail, "could not remove {s}: {s}", .{ cfg, @errorName(e) });
            };
            if (exists(c, cfg)) {
                try r.line(.fail, "{s} is STILL there", .{cfg});
            } else {
                try r.line(.removed, "{s} (the book of findings and the recorded zephem location)", .{cfg});
            }
        } else {
            try r.line(.ok, "no local state at {s}", .{cfg});
        }
    } else if (exists(c, cfg)) {
        try r.line(.info, "kept {s} (your book of findings); `zcanon uninstall --purge` removes it", .{cfg});
    }

    try r.line(.info, "not touched: zephem (its own project) and the zcanon checkout itself; delete the folder to finish", .{});
    return finish(&r, w);
}

fn removeSkill(c: vars.Ctx, r: *Report) !void {
    const skill_path = vars.skillPath(c) catch {
        try r.line(.info, "HOME is not set, so the skill's location is unknown; nothing removed there", .{});
        return;
    };
    const bak = try std.fmt.allocPrint(c.gpa, "{s}.bak", .{skill_path});
    for ([_][]const u8{ skill_path, bak }) |p| {
        const text = std.Io.Dir.cwd().readFileAlloc(c.io, p, c.gpa, .limited(1 << 20)) catch continue;
        if (!isZcanonSkill(text)) {
            try r.line(.info, "left {s} alone: it is not a zcanon skill", .{p});
            continue;
        }
        std.Io.Dir.cwd().deleteFile(c.io, p) catch |e| {
            try r.line(.fail, "could not remove {s}: {s}", .{ p, @errorName(e) });
            continue;
        };
        try r.line(.removed, "{s}", .{p});
    }
    if (std.fs.path.dirname(skill_path)) |dir| {
        // Only if now empty; deleteDir refuses a non-empty directory.
        std.Io.Dir.cwd().deleteDir(c.io, dir) catch {}; // zsnag:ok — non-empty means the user keeps it
    }
    if (exists(c, skill_path)) {
        const text = std.Io.Dir.cwd().readFileAlloc(c.io, skill_path, c.gpa, .limited(1 << 20)) catch "";
        if (isZcanonSkill(text)) try r.line(.fail, "the skill is STILL at {s}", .{skill_path});
    }

}

fn finish(r: *Report, w: *std.Io.Writer) !void {
    try w.writeAll(if (r.failed)
        "\nNot fully removed. See the [FAIL] lines above.\n"
    else
        "\nzcanon is unhooked from Claude Code. Restart any open Claude Code session.\n");
    try w.flush();
    if (r.failed) std.process.exit(1);
}

/// A skill file whose frontmatter names it `zcanon`.
fn isZcanonSkill(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "---")) return false;
    const end = std.mem.find(u8, text[3..], "\n---") orelse return false;
    return std.mem.find(u8, text[0 .. end + 3], "\nname: zcanon\n") != null;
}
