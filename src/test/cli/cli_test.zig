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
    try testing.expect(un.outContains("Removed 1"));

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
    try testing.expect(std.mem.find(u8, ctx, "R004") != null);
    try testing.expect(std.mem.find(u8, ctx, "CORRECTNESS RISK") != null);

    const bookfile = try s.read("config/book.tsv");
    try testing.expect(std.mem.find(u8, bookfile, "R004") != null);
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
    // --no-map means the map group did NOT run, and the record must say so.
    const ran = status.object.get("ran").?.array;
    try testing.expectEqual(@as(usize, 1), ran.items.len);
    try testing.expectEqualStrings("core", ran.items[0].string);

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
