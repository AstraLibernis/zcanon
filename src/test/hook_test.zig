// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const hook = @import("zcanon").hook;

fn arena() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

test "file_path is read out of the tool payload" {
    var a = arena();
    defer a.deinit();
    const payload =
        \\{"session_id":"x","hook_event_name":"PostToolUse","tool_name":"Edit",
        \\"tool_input":{"file_path":"/home/u/src/main.zig","old_string":"a"},
        \\"tool_response":{"type":"success"}}
    ;
    const p = try hook.filePathFromPayload(a.allocator(), payload);
    try testing.expectEqualStrings("/home/u/src/main.zig", p.?);
}

test "a payload without a usable file_path yields null, never a crash" {
    var a = arena();
    defer a.deinit();
    const cases = [_][]const u8{
        "{}",
        \\{"tool_input":{}}
        ,
        \\{"tool_input":{"file_path":123}}
        ,
        \\{"tool_input":"notanobject"}
        ,
        "[1,2,3]",
        "not json at all",
        "",
    };
    for (cases) |c| {
        try testing.expect((try hook.filePathFromPayload(a.allocator(), c)) == null);
    }
}

test "ast-check: a path containing a colon still parses (B8)" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    const text =
        \\/home/u/weird:dir/main.zig:7:9: error: local variable is never mutated
        \\
    ;
    try hook.parseAstCheck(a.allocator(), "/home/u/weird:dir/main.zig", text, &out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 7), out.items[0].line);
    try testing.expectEqual(@as(u32, 9), out.items[0].col);
    try testing.expectEqualStrings("local variable is never mutated", out.items[0].message);
    try testing.expectEqualStrings("error", out.items[0].severity);
}

test "ast-check: note lines are kept as advisory, not dropped (B8)" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    const text =
        \\a.zig:3:1: error: expected ';'
        \\a.zig:2:5: note: struct declared here
        \\a.zig: not a diagnostic line
        \\
    ;
    try hook.parseAstCheck(a.allocator(), "a.zig", text, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("error", out.items[0].severity);
    try testing.expectEqualStrings("info", out.items[1].severity);
    try testing.expectEqualStrings("struct declared here", out.items[1].message);
}

test "an echoed source line is never mistaken for a diagnostic" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    // Verbatim `zig ast-check` output. It echoes the offending source line under each
    // diagnostic — and here that line contains ": error: " inside a string literal.
    const text =
        "phantom.zig:3:11: error: unused local constant\n" ++
        "    const msg = \"x.zig:1:2: error: boom\";\n" ++
        "          ^~~\n";
    try hook.parseAstCheck(a.allocator(), "phantom.zig", text, &out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 3), out.items[0].line);
    try testing.expectEqualStrings("unused local constant", out.items[0].message);
}

test "a diagnostic naming a different file is ignored" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    // Unindented, well-formed, but about some other file — ast-check only reports on the
    // file it was given, so this is an echo, not a diagnostic.
    const text = "other.zig:1:2: error: boom\nreal.zig:5:1: error: genuine\n";
    try hook.parseAstCheck(a.allocator(), "real.zig", text, &out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("genuine", out.items[0].message);
}

test "snippet is the trimmed source line" {
    const src = "line one\n    const x = 1;  \nline three\n";
    try testing.expectEqualStrings("line one", hook.snippetFor(src, 1));
    try testing.expectEqualStrings("const x = 1;", hook.snippetFor(src, 2));
    try testing.expectEqualStrings("line three", hook.snippetFor(src, 3));
    try testing.expectEqualStrings("", hook.snippetFor(src, 0));
    try testing.expectEqualStrings("", hook.snippetFor(src, 99));
}

test "context groups by tier in urgency order" {
    var a = arena();
    defer a.deinit();
    const findings = [_]hook.Finding{
        .{ .rule = "R010", .severity = "info", .line = 30, .col = 1, .message = "advisory thing" },
        .{ .rule = "R002", .severity = "error", .line = 10, .col = 1, .message = "blocking thing" },
        .{ .rule = "R004", .severity = "warn", .line = 20, .col = 1, .message = "caution thing" },
    };
    const ctx = (try hook.renderContext(a.allocator(), "main.zig", "src/main.zig", &findings, .full)).?;

    const b = std.mem.find(u8, ctx, "blocking thing").?;
    const c = std.mem.find(u8, ctx, "caution thing").?;
    const d = std.mem.find(u8, ctx, "advisory thing").?;
    try testing.expect(b < c);
    try testing.expect(c < d);
    try testing.expect(std.mem.find(u8, ctx, "▲ BLOCKING") != null);
    try testing.expect(std.mem.find(u8, ctx, "findings in main.zig") != null);
}

test "an advisory finding in scratch code renders under EXPECTED" {
    var a = arena();
    defer a.deinit();
    const findings = [_]hook.Finding{
        .{ .rule = "R010", .severity = "info", .line = 5, .col = 1, .message = "debug print" },
    };
    const ctx = (try hook.renderContext(a.allocator(), "x.zig", "/tmp/x.zig", &findings, .full)).?;
    try testing.expect(std.mem.find(u8, ctx, "· EXPECTED") != null);
    try testing.expect(std.mem.find(u8, ctx, "ℹ ADVISORY") == null);
}

test "no findings means no context at all" {
    var a = arena();
    defer a.deinit();
    try testing.expect((try hook.renderContext(a.allocator(), "x.zig", "x.zig", &.{}, .full)) == null);
}

test "context is truncated to the cap" {
    var a = arena();
    defer a.deinit();
    var many: std.ArrayList(hook.Finding) = .empty;
    for (0..2000) |i| {
        try many.append(a.allocator(), .{
            .rule = "R007",
            .severity = "info",
            .line = @intCast(i + 1),
            .col = 1,
            .message = "this cast can panic/corrupt if out of range; verify first.",
        });
    }
    const body = (try hook.renderContext(a.allocator(), "big.zig", "src/big.zig", many.items, .full)).?;
    const ctx = (try hook.compose(a.allocator(), body, &.{}, true)).?;

    try testing.expect(ctx.len <= hook.MAX_CONTEXT);
    // The hint must survive truncation — it is what tells the reader how to check an API.
    try testing.expect(std.mem.endsWith(u8, ctx, hook.HINT));
    // And the result must still be valid UTF-8: the tier headers carry ▲ ⚠ ℹ ·.
    try testing.expect(std.unicode.utf8ValidateSlice(ctx));
}

test "truncation never splits a UTF-8 sequence" {
    // "▲" is three bytes; cut at every offset through a run of them.
    const s = "▲▲▲▲▲▲▲▲";
    var max: usize = 0;
    while (max <= s.len) : (max += 1) {
        const cut = hook.truncateUtf8(s, max);
        try testing.expect(cut.len <= max);
        try testing.expect(std.unicode.utf8ValidateSlice(cut));
    }
}

test "notices are reserved from the budget, not truncated away" {
    var a = arena();
    defer a.deinit();
    const body = try a.allocator().alloc(u8, hook.MAX_CONTEXT * 2);
    @memset(body, 'x');
    const notice = "\n\n⚠ zsnag was NOT run.";

    const ctx = (try hook.compose(a.allocator(), body, &.{notice}, true)).?;
    try testing.expect(ctx.len <= hook.MAX_CONTEXT);
    try testing.expect(std.mem.find(u8, ctx, "zsnag was NOT run") != null);
    try testing.expect(std.mem.endsWith(u8, ctx, hook.HINT));
}

test "a notice with no findings is emitted exactly once" {
    var a = arena();
    defer a.deinit();
    const notice = "\n\n⚠ zsnag was NOT run.";
    const ctx = (try hook.compose(a.allocator(), "", &.{ notice, "" }, true)).?;

    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.findPos(u8, ctx, i, "zsnag was NOT run")) |at| : (i = at + 1) n += 1;
    try testing.expectEqual(@as(usize, 1), n);
}

test "nothing to say composes to null" {
    var a = arena();
    defer a.deinit();
    try testing.expect((try hook.compose(a.allocator(), "", &.{}, true)) == null);
    try testing.expect((try hook.compose(a.allocator(), "", &.{ "", "" }, true)) == null);
    try testing.expect((try hook.compose(a.allocator(), "", &.{}, false)) == null);
}

test "response uses the nested hookSpecificOutput form" {
    var a = arena();
    defer a.deinit();
    const json = try hook.renderResponse(a.allocator(), "some findings");

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const hso = parsed.value.object.get("hookSpecificOutput").?.object;
    try testing.expectEqualStrings("PostToolUse", hso.get("hookEventName").?.string);
    try testing.expectEqualStrings("some findings", hso.get("additionalContext").?.string);
    try testing.expect(parsed.value.object.get("additionalContext") == null);
}

test "identical findings on identical source lines collapse to one" {
    var a = arena();
    defer a.deinit();
    // Two lines with the same trimmed text, same rule, same message — one finding in the
    // book's terms. Rendering both, and counting `hits` twice for them, was the divergence
    // from the Nushell original.
    const src = "x();\ny();\nx();\n";
    const items = [_]hook.Finding{
        .{ .rule = "R010", .severity = "info", .line = 1, .col = 1, .message = "m" },
        .{ .rule = "R010", .severity = "info", .line = 3, .col = 1, .message = "m" },
    };
    const out = try hook.dedup(a.allocator(), src, &items);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].line);
}

test "dedup keeps findings that differ in rule, message or source line" {
    var a = arena();
    defer a.deinit();
    const src = "x();\ny();\n";
    const items = [_]hook.Finding{
        .{ .rule = "R010", .severity = "info", .line = 1, .col = 1, .message = "m" },
        .{ .rule = "R004", .severity = "warn", .line = 1, .col = 1, .message = "m" }, // rule differs
        .{ .rule = "R010", .severity = "info", .line = 1, .col = 1, .message = "other" }, // message differs
        .{ .rule = "R010", .severity = "info", .line = 2, .col = 1, .message = "m" }, // snippet differs
    };
    const out = try hook.dedup(a.allocator(), src, &items);
    try testing.expectEqual(@as(usize, 4), out.len);
}

test "findings sort by line then column" {
    var items = [_]hook.Finding{
        .{ .rule = "a", .severity = "warn", .line = 20, .col = 5, .message = "m" },
        .{ .rule = "b", .severity = "warn", .line = 3, .col = 9, .message = "m" },
        .{ .rule = "c", .severity = "warn", .line = 20, .col = 1, .message = "m" },
    };
    hook.sortFindings(&items);
    try testing.expectEqualStrings("b", items[0].rule);
    try testing.expectEqualStrings("c", items[1].rule);
    try testing.expectEqualStrings("a", items[2].rule);
}

// ---- Bash runs: a shell command can edit .zig files that no file_path names ----------------

test "tool_name and a Bash payload's cwd + command are read" {
    var a = arena();
    defer a.deinit();
    const payload =
        \\{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/home/u/ws",
        \\"tool_input":{"command":"sed -i 's/a/b/' src/x.zig","description":"d"}}
    ;
    try testing.expectEqualStrings("Bash", hook.toolNameFromPayload(a.allocator(), payload).?);
    const run = hook.bashFromPayload(a.allocator(), payload).?;
    try testing.expectEqualStrings("/home/u/ws", run.cwd);
    try testing.expectEqualStrings("sed -i 's/a/b/' src/x.zig", run.command);
}

test "a Bash payload missing cwd or command yields null" {
    var a = arena();
    defer a.deinit();
    try testing.expect(hook.bashFromPayload(a.allocator(), "{\"tool_input\":{\"command\":\"ls\"}}") == null);
    try testing.expect(hook.bashFromPayload(a.allocator(), "{\"cwd\":\"/x\",\"tool_input\":{}}") == null);
    try testing.expect(hook.bashFromPayload(a.allocator(), "not json") == null);
}

fn expectRoots(want: []const []const u8, cwd: []const u8, command: []const u8) !void {
    var a = arena();
    defer a.deinit();
    const got = try hook.bashRoots(a.allocator(), cwd, "/home/u", command);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "roots: the working directory alone for a plain command" {
    try expectRoots(&.{"/home/u/ws"}, "/home/u/ws", "sed -i 's/x/y/' src/a.zig");
}

test "roots: a cd outside the working directory is walked too" {
    try expectRoots(&.{ "/home/u/ws", "/home/u/other" }, "/home/u/ws", "cd ~/other && python3 - <<'EOF'");
    try expectRoots(&.{ "/home/u/ws", "/srv/repo" }, "/home/u/ws", "cd \"/srv/repo\"; zig fmt .");
}

test "roots: a cd beneath the working directory is already covered" {
    try expectRoots(&.{"/home/u/ws"}, "/home/u/ws", "cd sub/dir && sed -i x main.zig");
}

test "roots: an absolute .zig path adds its directory" {
    try expectRoots(&.{ "/home/u/ws", "/tmp/scratch" }, "/home/u/ws", "sed -i 's/a/b/' /tmp/scratch/t.zig");
    try expectRoots(&.{ "/home/u/ws", "/home/u/lib/src" }, "/home/u/ws", "cat > ~/lib/src/m.zig");
}

test "roots: a working directory nested in a cd target is dropped, duplicates collapse" {
    try expectRoots(&.{"/home/u"}, "/home/u/ws", "cd ~ && cd ~/ && cd /home/u/ws");
}

test "roots: `cd -` and a bare trailing cd add nothing" {
    try expectRoots(&.{"/home/u/ws"}, "/home/u/ws", "cd - && echo cd");
}

// ---- the short view ---------------------------------------------------------

test "short view: tally, one row per blocking/caution finding, advisory collapsed" {
    var a = arena();
    defer a.deinit();
    const findings = [_]hook.Finding{
        .{ .rule = "R002", .severity = "error", .line = 2, .col = 1, .message = "blocking thing" },
        .{ .rule = "R007", .severity = "info", .line = 9, .col = 3, .message = "advisory thing" },
        .{ .rule = "R004", .severity = "warn", .line = 20, .col = 4, .message = "caution thing" },
        .{ .rule = "R007", .severity = "info", .line = 30, .col = 3, .message = "advisory thing" },
        .{ .rule = "R010", .severity = "info", .line = 40, .col = 1, .message = "other advisory" },
    };
    const ctx = (try hook.renderContext(a.allocator(), "main.zig", "src/main.zig", &findings, .short)).?;
    try testing.expectEqualStrings(
        "zcanon: main.zig — 1 blocking, 1 caution, 3 advisory\n" ++
            "▲ [R002] 2:1  blocking thing\n" ++
            "⚠ [R004] 20:4  caution thing\n" ++
            "ℹ advisory: [R007]×2 9,30 · [R010] 40\n" ++
            "full messages: zcanon check --full src/main.zig",
        ctx,
    );
}

test "short view: scratch-file advisories collapse under expected" {
    var a = arena();
    defer a.deinit();
    const findings = [_]hook.Finding{
        .{ .rule = "R010", .severity = "info", .line = 5, .col = 1, .message = "debug print" },
    };
    const ctx = (try hook.renderContext(a.allocator(), "x.zig", "/tmp/x.zig", &findings, .short)).?;
    try testing.expect(std.mem.find(u8, ctx, "· expected (test/bench code): [R010] 5") != null);
    try testing.expect(std.mem.find(u8, ctx, "debug print") == null);
}

test "short view: a long message is cut, on a UTF-8 boundary, with an ellipsis" {
    var a = arena();
    defer a.deinit();
    const long = "▲" ** 200; // 600 bytes of three-byte codepoints
    const findings = [_]hook.Finding{
        .{ .rule = "R012", .severity = "warn", .line = 1, .col = 1, .message = long },
    };
    const ctx = (try hook.renderContext(a.allocator(), "x.zig", "x.zig", &findings, .short)).?;
    try testing.expect(std.unicode.utf8ValidateSlice(ctx));
    try testing.expect(std.mem.endsWith(u8, ctx, "…"));
    try testing.expect(ctx.len < long.len);
}

test "short view: many findings of one rule stay on one line" {
    var a = arena();
    defer a.deinit();
    var many: std.ArrayList(hook.Finding) = .empty;
    for (0..2000) |i| try many.append(a.allocator(), .{
        .rule = "R007",
        .severity = "info",
        .line = @intCast(i + 1),
        .col = 1,
        .message = "this cast can panic/corrupt if out of range; verify first.",
    });
    const ctx = (try hook.renderContext(a.allocator(), "big.zig", "big.zig", many.items, .short)).?;
    try testing.expect(std.mem.find(u8, ctx, "[R007]×2000 1,2,3,4,5,6 …") != null);
    try testing.expect(ctx.len < 200);
}

test "the lookup hint: always in the full view, only for map rules in the short one" {
    const core = [_]hook.Finding{.{ .rule = "R004", .severity = "warn", .line = 1, .col = 1, .message = "m" }};
    const map = [_]hook.Finding{.{ .rule = "R012", .severity = "warn", .line = 1, .col = 1, .message = "m" }};
    try testing.expect(hook.wantsHint(.full, &core));
    try testing.expect(!hook.wantsHint(.short, &core));
    try testing.expect(hook.wantsHint(.short, &map));
}
