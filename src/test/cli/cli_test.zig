// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const h = @import("harness.zig");

const clean_zig = "const std = @import(\"std\");\npub fn add(a: u8, b: u8) u8 {\n    return a + b;\n}\n";
const dirty_zig = "const std = @import(\"std\");\npub fn f() void {\n    const n = foo() catch unreachable;\n    _ = n;\n}\n";

fn box(name: []const u8) !h.Sandbox {
    return h.Sandbox.init(testing.allocator, name);
}

// ---- install / status / uninstall ------------------------------------------

test "cli: install writes the hook and status reports it" {
    var s = try box("install");
    defer s.deinit();
    _ = try s.write("settings.json", "{\"theme\":\"dark\"}");

    const inst = try s.zcanon(&.{"install"});
    try testing.expectEqual(@as(u8, 0), inst.code);

    const st = try s.zcanon(&.{"status"});
    try testing.expect(st.outContains("installed in settings: true"));
    try testing.expect(st.outContains("runtime state: enabled"));

    // The user's own key survives, and a backup was taken.
    const text = try s.read("settings.json");
    try testing.expect(std.mem.find(u8, text, "\"theme\"") != null);
    try testing.expect(std.mem.find(u8, text, "zcanon-zig-hook") != null);
    try testing.expect(s.exists("settings.json.bak"));
}

test "cli: uninstall removes only our entry" {
    var s = try box("uninstall");
    defer s.deinit();
    _ = try s.write("settings.json",
        \\{"theme":"dark","hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other"}]}]}}
    );

    _ = try s.zcanon(&.{"install"});
    const un = try s.zcanon(&.{"uninstall"});
    try testing.expectEqual(@as(u8, 0), un.code);
    try testing.expect(un.outContains("hook removed"));

    const text = try s.read("settings.json");
    try testing.expect(std.mem.find(u8, text, "zcanon-zig-hook") == null);
    try testing.expect(std.mem.find(u8, text, "\"other\"") != null); // foreign hook intact
    try testing.expect(std.mem.find(u8, text, "\"theme\"") != null);
}

test "cli: install is idempotent across repeated runs" {
    var s = try box("idempotent");
    defer s.deinit();
    _ = try s.write("settings.json", "{}");
    _ = try s.zcanon(&.{"install"});
    _ = try s.zcanon(&.{"install"});
    _ = try s.zcanon(&.{"install"});

    // Exactly one occurrence of the marker.
    const text = try s.read("settings.json");
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.findPos(u8, text, i, "zcanon-zig-hook")) |at| : (i = at + 1) n += 1;
    try testing.expectEqual(@as(usize, 1), n);
}

test "cli: status on a fresh sandbox reports not installed" {
    var s = try box("fresh-status");
    defer s.deinit();
    const st = try s.zcanon(&.{"status"});
    try testing.expectEqual(@as(u8, 0), st.code);
    try testing.expect(st.outContains("installed in settings: false"));
}

// ---- the hook --------------------------------------------------------------

test "cli: the hook reports findings and records them" {
    var s = try box("hook-findings");
    defer s.deinit();
    const f = try s.write("t.zig", dirty_zig);

    const r = try s.hook(f);
    try testing.expectEqual(@as(u8, 0), r.code); // PostToolUse must never exit non-zero
    const ctx = (try h.additionalContext(s.gpa(), r.stdout)).?;
    try testing.expect(std.mem.find(u8, ctx, "⚠ [R004] 3:") != null);
    try testing.expect(std.mem.find(u8, ctx, "CORRECTNESS RISK") == null); // short view

    const bookfile = try s.read("config/book.tsv");
    try testing.expect(std.mem.find(u8, bookfile, "R004") != null);
}

test "cli: view full switches the hook to the full layout, and back" {
    var s = try box("hook-view");
    defer s.deinit();
    const f = try s.write("t.zig", dirty_zig);

    try testing.expectEqual(@as(u8, 0), (try s.zcanon(&.{ "view", "full" })).code);
    const full = (try h.additionalContext(s.gpa(), (try s.hook(f)).stdout)).?;
    try testing.expect(std.mem.find(u8, full, "CORRECTNESS RISK") != null);

    try testing.expectEqual(@as(u8, 0), (try s.zcanon(&.{ "view", "short" })).code);
    const short = (try h.additionalContext(s.gpa(), (try s.hook(f)).stdout)).?;
    try testing.expect(std.mem.find(u8, short, "CORRECTNESS RISK") == null);
    try testing.expectEqual(@as(u8, 2), (try s.zcanon(&.{ "view", "wide" })).code);
}

test "cli: a clean file produces no output at all" {
    var s = try box("hook-clean");
    defer s.deinit();
    const f = try s.write("t.zig", clean_zig);
    const r = try s.hook(f);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(?[]const u8, null), try h.additionalContext(s.gpa(), r.stdout));
}

test "cli: a non-.zig file is ignored" {
    var s = try box("hook-nonzig");
    defer s.deinit();
    const f = try s.write("notes.md", "# hello\n");
    const r = try s.hook(f);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(?[]const u8, null), try h.additionalContext(s.gpa(), r.stdout));
}

test "cli: a malformed payload is survived, not crashed on" {
    var s = try box("hook-badpayload");
    defer s.deinit();
    for ([_][]const u8{ "not json", "{}", "[1,2,3]", "" }) |p| {
        const r = try s.zcanonStdin(&.{"hook"}, p);
        try testing.expectEqual(@as(u8, 0), r.code);
    }
}

test "cli: disable silences the hook without touching settings" {
    var s = try box("hook-disable");
    defer s.deinit();
    _ = try s.write("settings.json", "{}");
    _ = try s.zcanon(&.{"install"});
    const before = try s.read("settings.json");

    _ = try s.zcanon(&.{"disable"});
    const st = try s.zcanon(&.{"status"});
    try testing.expect(st.outContains("runtime state: disabled"));

    const f = try s.write("t.zig", dirty_zig);
    const r = try s.hook(f);
    try testing.expectEqual(@as(?[]const u8, null), try h.additionalContext(s.gpa(), r.stdout));

    // settings.json is byte-identical: the off switch is a flag file, not an edit.
    try testing.expectEqualStrings(before, try s.read("settings.json"));

    _ = try s.zcanon(&.{"enable"});
    const r2 = try s.hook(f);
    try testing.expect((try h.additionalContext(s.gpa(), r2.stdout)) != null);
}

test "cli: re-saving an unchanged file counts a recurrence, not a new finding" {
    var s = try box("hook-hits");
    defer s.deinit();
    const f = try s.write("t.zig", dirty_zig);
    _ = try s.hook(f);
    _ = try s.hook(f);
    _ = try s.hook(f);

    // Three saves of the same unchanged file: one row per distinct finding, each at 3 hits.
    // (There are two findings here — R004 plus an ast-check error for the undeclared `foo`.)
    const bookfile = try s.read("config/book.tsv");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bookfile, "\n"), '\n');
    _ = lines.next(); // header
    var seen_r004 = false;
    var rows: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        rows += 1;
        var col = std.mem.splitScalar(u8, line, '\t');
        _ = col.next(); // first_ts
        _ = col.next(); // last_ts
        const hits = col.next().?;
        _ = col.next(); // zig_version
        _ = col.next(); // file
        const rule = col.next().?;
        // Every row must be a recurrence count, not a duplicate insert.
        try testing.expectEqualStrings("3", hits);
        if (std.mem.eql(u8, rule, "R004")) seen_r004 = true;
    }
    try testing.expect(seen_r004);
    try testing.expectEqual(@as(usize, 2), rows);
}

test "cli: a syntax error does not erase the structural rules' history" {
    var s = try box("hook-syntaxerror");
    defer s.deinit();
    // A real leak, recorded while the file parses.
    const leaky = "const std = @import(\"std\");\npub fn f(gpa: std.mem.Allocator) void {\n    var l: std.heap.ArenaAllocator = .init(gpa);\n    _ = l;\n}\n";
    const f = try s.write("t.zig", leaky);
    _ = try s.hook(f);
    try testing.expect(std.mem.find(u8, try s.read("config/book.tsv"), "R008") != null);

    // Now the file stops parsing — exactly what an LLM writing stale syntax produces. R008
    // cannot run, so its silence must NOT be read as "the leak was fixed". The leak is still
    // right there in the file.
    _ = try s.write("t.zig", leaky ++ "const x = async foo();\n");
    _ = try s.hook(f);
    try testing.expect(std.mem.find(u8, try s.read("config/book.tsv"), "R008") != null);
}

test "cli: the status record reports structural only when the file parses" {
    var s = try box("status-structural");
    defer s.deinit();
    const ok = try s.write("ok.zig", clean_zig);
    const broken = try s.write("broken.zig", "const x = async foo();\n");

    const a = try s.zsnag(&.{ "--json", "--no-map", ok });
    try testing.expect(std.mem.find(u8, a.stdout, "\"structural\"") != null);

    const b = try s.zsnag(&.{ "--json", "--no-map", broken });
    try testing.expect(std.mem.find(u8, b.stdout, "\"structural\"") == null);
    try testing.expect(std.mem.find(u8, b.stdout, "\"core\"") != null);
}

test "cli: fixing the problem prunes it from the book" {
    var s = try box("hook-prune-fix");
    defer s.deinit();
    const f = try s.write("t.zig", dirty_zig);
    _ = try s.hook(f);
    try testing.expect(std.mem.find(u8, try s.read("config/book.tsv"), "R004") != null);

    _ = try s.write("t.zig", clean_zig);
    _ = try s.hook(f);
    try testing.expect(std.mem.find(u8, try s.read("config/book.tsv"), "R004") == null);
}

// ---- the book --------------------------------------------------------------

test "cli: book reports render, and an empty book says so" {
    var s = try box("book");
    defer s.deinit();
    const empty = try s.zcanon(&.{"book"});
    try testing.expect(empty.outContains("the book is empty"));

    const f = try s.write("t.zig", dirty_zig);
    _ = try s.hook(f);

    try testing.expect((try s.zcanon(&.{"book"})).outContains("R004"));
    try testing.expect((try s.zcanon(&.{ "book", "files" })).outContains("t.zig"));
    try testing.expect((try s.zcanon(&.{ "book", "recent", "5" })).outContains("R004"));
    try testing.expect((try s.zcanon(&.{ "book", "R004" })).outContains("catch unreachable"));
    try testing.expect((try s.zcanon(&.{ "book", "R999" })).outContains("no findings recorded"));
}

test "cli: prune drops findings for files that no longer exist" {
    var s = try box("prune");
    defer s.deinit();
    const f = try s.write("gone.zig", dirty_zig);
    _ = try s.hook(f);
    try testing.expect(std.mem.find(u8, try s.read("config/book.tsv"), "R004") != null);

    try std.Io.Dir.cwd().deleteFile(s.io, f);
    const r = try s.zcanon(&.{"prune"});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.find(u8, try s.read("config/book.tsv"), "R004") == null);
}

// ---- zsnag -----------------------------------------------------------------

test "cli: zsnag exit codes are distinct" {
    var s = try box("zsnag-exits");
    defer s.deinit();
    const clean = try s.write("clean.zig", clean_zig);
    const err = try s.write("err.zig", "usingnamespace foo;\n");

    try testing.expectEqual(@as(u8, 0), (try s.zsnag(&.{ "--no-map", clean })).code);
    try testing.expectEqual(@as(u8, 1), (try s.zsnag(&.{ "--no-map", err })).code);
    try testing.expectEqual(@as(u8, 2), (try s.zsnag(&.{"--no-map"})).code);
    try testing.expectEqual(@as(u8, 3), (try s.zsnag(&.{ "--no-map", "/does/not/exist.zig" })).code);
}

test "cli: zsnag writes findings to stdout, diagnostics to stderr" {
    var s = try box("zsnag-streams");
    defer s.deinit();
    const f = try s.write("t.zig", dirty_zig);
    const r = try s.zsnag(&.{ "--no-map", f });
    try testing.expect(r.outContains("R004"));
    try testing.expect(!r.errContains("R004"));
}

test "cli: zsnag --json emits a status record then valid JSONL" {
    var s = try box("zsnag-json");
    defer s.deinit();
    const f = try s.write("t.zig", dirty_zig);
    const r = try s.zsnag(&.{ "--json", "--no-map", f });

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    const first = lines.next().?;
    const status = try std.json.parseFromSliceLeaky(std.json.Value, s.gpa(), first, .{});
    try testing.expectEqualStrings("status", status.object.get("zsnag").?.string);
    // --no-map means the map group did NOT run, and the record must say so. The file parses,
    // so the structural group DID run.
    const ran = status.object.get("ran").?.array;
    var saw_core = false;
    var saw_structural = false;
    for (ran.items) |g| {
        if (std.mem.eql(u8, g.string, "core")) saw_core = true;
        if (std.mem.eql(u8, g.string, "structural")) saw_structural = true;
        try testing.expect(!std.mem.eql(u8, g.string, "map"));
    }
    try testing.expect(saw_core);
    try testing.expect(saw_structural);

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, s.gpa(), line, .{});
        try testing.expect(v.object.get("rule") != null);
    }
}

test "cli: zsnag --list-rules covers every rule" {
    var s = try box("zsnag-rules");
    defer s.deinit();
    const r = try s.zsnag(&.{"--list-rules"});
    for ([_][]const u8{ "R001", "R004", "R008", "R010", "R011", "R012", "R013" }) |code| {
        try testing.expect(r.outContains(code));
    }
}

test "cli: argument order is preserved across files" {
    var s = try box("zsnag-order");
    defer s.deinit();
    const a = try s.write("aaa.zig", "const std = @import(\"std\");\npub fn a() void { std.debug.print(\"x\", .{}); }\n");
    const b = try s.write("bbb.zig", "const std = @import(\"std\");\npub fn b() void {\n    std.debug.print(\"y\", .{});\n}\n");

    const r = try s.zsnag(&.{ "--no-map", b, a });
    const at_b = std.mem.find(u8, r.stdout, "bbb.zig").?;
    const at_a = std.mem.find(u8, r.stdout, "aaa.zig").?;
    // b was given first, and its finding is on a LATER line — sorting must not reorder files.
    try testing.expect(at_b < at_a);
}

// ---- setup / doctor / check -------------------------------------------------

const build_options = @import("build_options");

/// setup needs the zephem lookup table; with HOME unset (as in every CLI test) it has to be
/// told where the table is. No table on this machine → skip, don't fail.
fn setupEnv(s: *h.Sandbox) ![2][2][]const u8 {
    if (build_options.zephem_lookup.len == 0) return error.SkipZigTest;
    std.Io.Dir.cwd().access(s.io, build_options.zephem_lookup, .{}) catch return error.SkipZigTest;
    return .{
        .{ "ZEPHEM_LOOKUP", build_options.zephem_lookup },
        .{ "ZCANON_SKILL", try s.path("skills/zcanon/SKILL.md") },
    };
}

test "cli: doctor on a fresh sandbox fails and changes nothing" {
    var s = try box("doctor-fresh");
    defer s.deinit();
    const env = try setupEnv(&s);

    const r = try s.zcanonEnv(&.{"doctor"}, &env);
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(r.outContains("hook not installed"));
    try testing.expect(r.outContains("Not ready"));
    try testing.expect(!s.exists("settings.json"));
    try testing.expect(!s.exists("skills/zcanon/SKILL.md"));
    try testing.expect(!s.exists("config/zephem-home"));
}

test "cli: setup installs the hook, records zephem, and proves the hook fires" {
    var s = try box("setup");
    defer s.deinit();
    const env = try setupEnv(&s);
    _ = try s.write("settings.json", "{\"theme\":\"dark\"}");

    const r = try s.zcanonEnv(&.{"setup"}, &env);
    if (r.code != 0) std.debug.print("setup output:\n{s}\n{s}\n", .{ r.stdout, r.stderr });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(r.outContains("core rules, zephem map rules and zig ast-check all reported"));
    try testing.expect(!r.outContains("[FAIL]"));

    // The command is quoted, the user's key survives, zephem is recorded, the skill is in place.
    const text = try s.read("settings.json");
    try testing.expect(std.mem.find(u8, text, "\\\"") != null);
    try testing.expect(std.mem.find(u8, text, "\"theme\"") != null);
    try testing.expect(s.exists("config/zephem-home"));
    try testing.expect(s.exists("skills/zcanon/SKILL.md"));
    // The installed skill carries real paths, not the repo's placeholders.
    const skill_text = try s.read("skills/zcanon/SKILL.md");
    try testing.expect(std.mem.find(u8, skill_text, "{{") == null);
    try testing.expect(std.mem.find(u8, skill_text, "zig-out/bin/zcanon setup") != null);
    // The live test's probe and its book leave nothing behind.
    try testing.expect(!s.exists("config/probe"));
    try testing.expect(!s.exists("config/book.tsv"));

    // Idempotent, and doctor now agrees.
    const again = try s.zcanonEnv(&.{"setup"}, &env);
    try testing.expectEqual(@as(u8, 0), again.code);
    try testing.expect(!again.outContains("[fixed]"));
    const doc = try s.zcanonEnv(&.{"doctor"}, &env);
    try testing.expectEqual(@as(u8, 0), doc.code);
    try testing.expect(doc.outContains("All checks pass"));
}

test "cli: setup refuses a settings file it cannot parse, and leaves it alone" {
    var s = try box("setup-badjson");
    defer s.deinit();
    const env = try setupEnv(&s);
    const bad = "{\"theme\": \"dark\",";
    _ = try s.write("settings.json", bad);

    const r = try s.zcanonEnv(&.{"setup"}, &env);
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(r.outContains("is not valid JSON"));
    try testing.expectEqualStrings(bad, try s.read("settings.json"));
}

test "cli: setup switches a disabled hook back on; doctor reports it off" {
    var s = try box("setup-disabled");
    defer s.deinit();
    const env = try setupEnv(&s);
    _ = try s.zcanonEnv(&.{"setup"}, &env);
    _ = try s.zcanon(&.{"disable"});

    const doc = try s.zcanonEnv(&.{"doctor"}, &env);
    try testing.expectEqual(@as(u8, 1), doc.code);
    try testing.expect(doc.outContains("switched off"));

    const r = try s.zcanonEnv(&.{"setup"}, &env);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(r.outContains("switched it back on"));
    try testing.expect(r.outContains("all reported"));
    try testing.expect(!s.exists("config/hook.disabled"));
}

test "cli: check exits 1 on blocking findings, 0 when clean, 3 when unreadable" {
    var s = try box("check");
    defer s.deinit();
    const dirty = try s.write("dirty.zig", "const std = @import(\"std\");\npub fn f() void {\n    const unused = 1;\n}\n");
    const clean = try s.write("clean.zig", clean_zig);

    const d = try s.zcanon(&.{ "check", dirty });
    try testing.expectEqual(@as(u8, 1), d.code);
    try testing.expect(d.outContains("[ast-check]"));

    const c = try s.zcanon(&.{ "check", clean });
    try testing.expectEqual(@as(u8, 0), c.code);
    try testing.expect(c.outContains("no findings"));

    const m = try s.zcanon(&.{ "check", try s.path("missing.zig") });
    try testing.expectEqual(@as(u8, 3), m.code);
}

test "cli: uninstall after setup removes the hook and skill, keeps the book; --purge removes it" {
    var s = try box("uninstall-full");
    defer s.deinit();
    const env = try setupEnv(&s);
    _ = try s.write("settings.json", "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"guard\"}]}]}}");
    const r0 = try s.zcanonEnv(&.{"setup"}, &env);
    try testing.expectEqual(@as(u8, 0), r0.code);
    const dirty = try s.write("dirty.zig", dirty_zig);
    _ = try s.zcanon(&.{ "check", dirty });
    try testing.expect(s.exists("config/book.tsv"));

    const u = try s.zcanonEnv(&.{"uninstall"}, &env);
    try testing.expectEqual(@as(u8, 0), u.code);
    const text = try s.read("settings.json");
    try testing.expect(std.mem.find(u8, text, "zcanon-zig-hook") == null);
    try testing.expect(std.mem.find(u8, text, "\"guard\"") != null);
    try testing.expect(!s.exists("skills/zcanon/SKILL.md"));
    try testing.expect(!s.exists("skills/zcanon"));
    try testing.expect(s.exists("config/book.tsv"));

    const p = try s.zcanonEnv(&.{ "uninstall", "--purge" }, &env);
    try testing.expectEqual(@as(u8, 0), p.code);
    try testing.expect(!s.exists("config"));
}

test "cli: uninstall leaves a skill that is not zcanon's" {
    var s = try box("uninstall-foreign-skill");
    defer s.deinit();
    const skill = [_][2][]const u8{.{ "ZCANON_SKILL", try s.path("skills/zcanon/SKILL.md") }};
    const mine = "---\nname: myskill\n---\nmine\n";
    _ = try s.write("skills/zcanon/SKILL.md", mine);

    const u = try s.zcanonEnv(&.{"uninstall"}, &skill);
    try testing.expectEqual(@as(u8, 0), u.code);
    try testing.expect(u.outContains("not a zcanon skill"));
    try testing.expectEqualStrings(mine, try s.read("skills/zcanon/SKILL.md"));
}

test "cli: uninstall refuses to rewrite an unparseable settings file" {
    var s = try box("uninstall-badjson");
    defer s.deinit();
    const bad = "{\"a\":";
    _ = try s.write("settings.json", bad);

    const u = try s.zcanon(&.{"uninstall"});
    try testing.expectEqual(@as(u8, 1), u.code);
    try testing.expectEqualStrings(bad, try s.read("settings.json"));
}

// ---- the background compiler ----------------------------------------------------

const demo_build =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{
    \\        .name = "demo",
    \\        .root_module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = b.graph.host }),
    \\    });
    \\    b.installArtifact(exe);
    \\}
    \\
;

test "cli: add-check adds a working check step, and refuses a second time" {
    var s = try box("add-check");
    defer s.deinit();
    _ = try s.write("proj/build.zig", demo_build);
    _ = try s.write("proj/main.zig", "pub fn main() void {}\n");
    const r = try s.zcanon(&.{ "add-check", try s.path("proj") });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.find(u8, try s.read("proj/build.zig"), "zcanonCheck(b)") != null);
    try testing.expectEqual(@as(u8, 2), (try s.zcanon(&.{ "add-check", try s.path("proj") })).code);
}

test "cli: add-check restores build.zig when the result does not build" {
    var s = try box("add-check-restore");
    defer s.deinit();
    // A project that already has its own `check` step: a second one fails at configure time.
    const own = demo_build[0 .. demo_build.len - 2] ++ "    _ = b.step(\"check\", \"mine\");\n}\n";
    _ = try s.write("proj/build.zig", own);
    _ = try s.write("proj/main.zig", "pub fn main() void {}\n");
    const r = try s.zcanon(&.{ "add-check", try s.path("proj") });
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expectEqualStrings(own, try s.read("proj/build.zig"));
}

test "cli: the daemon reports a type error ast-check cannot see, then stops" {
    var s = try box("daemon");
    defer s.deinit();
    _ = try s.write("proj/build.zig", demo_build);
    const main = try s.write("proj/main.zig", "pub fn main() void {\n    const x: u32 = \"five\";\n    _ = x;\n}\n");
    try testing.expectEqual(@as(u8, 0), (try s.zcanon(&.{ "add-check", try s.path("proj") })).code);
    const on = [_][2][]const u8{.{ "ZCANON_DAEMON", "1" }};
    const proj = try s.path("proj");
    // Stop it even when an assertion below fails. zsnag:ok — nothing to do if already gone
    defer _ = s.zcanonEnv(&.{ "daemon", "stop", proj }, &on) catch {}; // zsnag:ok — see above

    // The first run starts the daemon; wait (bounded) for its first build to finish.
    _ = try s.hookEnv(main, &on);
    var ctx: ?[]const u8 = null;
    for (0..300) |_| {
        try s.io.sleep(.fromMilliseconds(100), .awake);
        const r = try s.hookEnv(main, &on);
        try testing.expectEqual(@as(u8, 0), r.code);
        ctx = try h.additionalContext(s.gpa(), r.stdout);
        if (ctx != null and std.mem.find(u8, ctx.?, "[compile]") != null) break;
    }
    try testing.expect(ctx != null);
    try testing.expect(std.mem.find(u8, ctx.?, "[compile] main.zig:2:20  expected type 'u32'") != null);

    const st = try s.zcanonEnv(&.{ "daemon", "status", proj }, &on);
    try testing.expect(std.mem.find(u8, st.stdout, "compiler errors") != null);
    const stop = try s.zcanonEnv(&.{ "daemon", "stop", proj }, &on);
    try testing.expect(std.mem.find(u8, stop.stdout, "daemon stopped") != null);
}
