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
    try hook.parseSnagJson(a.allocator(), text, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("R002", out.items[0].rule);
    try testing.expectEqual(@as(u32, 2), out.items[0].line);
    try testing.expectEqualStrings("warn", out.items[1].severity);
    try testing.expectEqual(@as(u32, 21), out.items[1].col);
}

test "ast-check: a path containing a colon still parses (B8)" {
    var a = arena();
    defer a.deinit();
    var out: std.ArrayList(hook.Finding) = .empty;
    const text =
        \\/home/u/weird:dir/main.zig:7:9: error: local variable is never mutated
        \\
    ;
    try hook.parseAstCheck(a.allocator(), text, &out);

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
    try hook.parseAstCheck(a.allocator(), text, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("error", out.items[0].severity);
    try testing.expectEqualStrings("info", out.items[1].severity);
    try testing.expectEqualStrings("struct declared here", out.items[1].message);
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
    const ctx = (try hook.renderContext(a.allocator(), "big.zig", "src/big.zig", many.items)).?;
    try testing.expectEqual(@as(usize, hook.MAX_CONTEXT), ctx.len);
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
