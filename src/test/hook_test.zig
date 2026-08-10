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

test "zsnag JSONL parses, and non-JSON lines are skipped" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    const text =
        \\{"file":"a.zig","line":2,"col":1,"rule":"R002","severity":"error","message":"usingnamespace was removed"}
        \\usage: zsnag [--json] file.zig ...
        \\{"file":"a.zig","line":24,"col":21,"rule":"R004","severity":"warn","message":"catch unreachable"}
        \\
    ;
    try hook.parseSnagJson(a.allocator(), text, &out, null);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("R002", out.items[0].rule);
    try testing.expectEqual(@as(u32, 2), out.items[0].line);
    try testing.expectEqualStrings("warn", out.items[1].severity);
    try testing.expectEqual(@as(u32, 21), out.items[1].col);
}

test "the status record reports which rule groups ran" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    var groups: std.ArrayList([]const u8) = .empty;
    const text =
        \\{"zsnag":"status","ran":["core","map"]}
        \\{"file":"a.zig","line":2,"col":1,"rule":"R011","severity":"warn","message":"deprecated"}
        \\
    ;
    try hook.parseSnagJson(a.allocator(), text, &out, &groups);

    try testing.expectEqual(@as(usize, 2), groups.items.len);
    try testing.expectEqualStrings("core", groups.items[0]);
    try testing.expectEqualStrings("map", groups.items[1]);
    // The status record is not itself a finding.
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "a status record reporting only core leaves map inactive" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    var groups: std.ArrayList([]const u8) = .empty;
    // What zsnag emits when the zephem map could not be loaded.
    try hook.parseSnagJson(a.allocator(), "{\"zsnag\":\"status\",\"ran\":[\"core\"]}\n", &out, &groups);

    try testing.expectEqual(@as(usize, 1), groups.items.len);
    try testing.expectEqualStrings("core", groups.items[0]);
    try testing.expectEqual(@as(usize, 0), out.items.len);
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
    const ctx = (try hook.renderContext(a.allocator(), "main.zig", "src/main.zig", &findings)).?;

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
    const ctx = (try hook.renderContext(a.allocator(), "x.zig", "/tmp/x.zig", &findings)).?;
    try testing.expect(std.mem.find(u8, ctx, "· EXPECTED") != null);
    try testing.expect(std.mem.find(u8, ctx, "ℹ ADVISORY") == null);
}

test "no findings means no context at all" {
    var a = arena();
    defer a.deinit();
    try testing.expect((try hook.renderContext(a.allocator(), "x.zig", "x.zig", &.{})) == null);
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
    const body = (try hook.renderContext(a.allocator(), "big.zig", "src/big.zig", many.items)).?;
    const ctx = (try hook.compose(a.allocator(), body, &.{})).?;

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

    const ctx = (try hook.compose(a.allocator(), body, &.{notice})).?;
    try testing.expect(ctx.len <= hook.MAX_CONTEXT);
    try testing.expect(std.mem.find(u8, ctx, "zsnag was NOT run") != null);
    try testing.expect(std.mem.endsWith(u8, ctx, hook.HINT));
}

test "a notice with no findings is emitted exactly once" {
    var a = arena();
    defer a.deinit();
    const notice = "\n\n⚠ zsnag was NOT run.";
    const ctx = (try hook.compose(a.allocator(), "", &.{ notice, "" })).?;

    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.findPos(u8, ctx, i, "zsnag was NOT run")) |at| : (i = at + 1) n += 1;
    try testing.expectEqual(@as(usize, 1), n);
}

test "nothing to say composes to null" {
    var a = arena();
    defer a.deinit();
    try testing.expect((try hook.compose(a.allocator(), "", &.{})) == null);
    try testing.expect((try hook.compose(a.allocator(), "", &.{ "", "" })) == null);
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
