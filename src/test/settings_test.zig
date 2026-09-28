// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const settings = @import("zcanon").settings;

const Value = std.json.Value;

/// Mirrors `settings.load`: parse leaky into an arena so the parsed tree and everything
/// `addOurs` grafts onto it share one lifetime.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    fn init(text: []const u8) !Fixture {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer a.deinit();
        const v = try std.json.parseFromSliceLeaky(Value, a.allocator(), text, .{});
        return .{ .arena = a, .value = v };
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }
    fn gpa(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }
};

fn parse(text: []const u8) !Fixture {
    return Fixture.init(text);
}

/// The entry the Nushell implementation wrote, so we can prove cross-compatibility.
const nu_entry =
    \\{"theme":"dark","hooks":{"PostToolUse":[
    \\{"matcher":"Edit|Write|MultiEdit","hooks":[
    \\{"type":"command","command":"nu /home/u/repos/zcanon/nu/zhook.nu  # zcanon-zig-hook","timeout":30}]}]}}
;

test "install into an empty settings file" {
    var p = try parse("{}");
    defer p.deinit();
    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");

    try testing.expect(settings.isInstalled(p.gpa(), &p.value));
    const arr = p.value.object.get("hooks").?.object.get("PostToolUse").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    try testing.expectEqualStrings(settings.MATCHER, arr.items[0].object.get("matcher").?.string);
}

test "unrelated keys survive install and uninstall untouched" {
    var p = try parse(
        \\{"theme":"dark","permissions":{"allow":["mcp__x__y"]},"model":"opus"}
    );
    defer p.deinit();

    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");
    try testing.expectEqualStrings("dark", p.value.object.get("theme").?.string);
    try testing.expectEqualStrings("opus", p.value.object.get("model").?.string);
    try testing.expectEqualStrings(
        "mcp__x__y",
        p.value.object.get("permissions").?.object.get("allow").?.array.items[0].string,
    );

    _ = try settings.removeOurs(p.gpa(), &p.value);
    try testing.expectEqualStrings("dark", p.value.object.get("theme").?.string);
    try testing.expectEqual(@as(usize, 3), p.value.object.count());
}

test "a foreign PostToolUse hook is never disturbed" {
    var p = try parse(
        \\{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-tool"}]}]}}
    );
    defer p.deinit();

    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");
    var arr = p.value.object.get("hooks").?.object.get("PostToolUse").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);

    const removed = try settings.removeOurs(p.gpa(), &p.value);
    try testing.expectEqual(@as(usize, 1), removed);

    arr = p.value.object.get("hooks").?.object.get("PostToolUse").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    try testing.expectEqualStrings("Bash", arr.items[0].object.get("matcher").?.string);
}

test "install is idempotent" {
    var p = try parse("{}");
    defer p.deinit();
    const cmd = "/bin/zcanon hook  # zcanon-zig-hook";
    try settings.addOurs(p.gpa(), &p.value, cmd);
    try settings.addOurs(p.gpa(), &p.value, cmd);
    try settings.addOurs(p.gpa(), &p.value, cmd);

    const arr = p.value.object.get("hooks").?.object.get("PostToolUse").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
}

test "uninstall removes the scaffolding it created" {
    var p = try parse(
        \\{"theme":"dark"}
    );
    defer p.deinit();
    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");
    _ = try settings.removeOurs(p.gpa(), &p.value);

    try testing.expect(p.value.object.get("hooks") == null);
    try testing.expectEqual(@as(usize, 1), p.value.object.count());
    try testing.expect(!settings.isInstalled(p.gpa(), &p.value));
}

test "uninstall keeps a hooks object that holds other events" {
    var p = try parse(
        \\{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]}}
    );
    defer p.deinit();
    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");
    _ = try settings.removeOurs(p.gpa(), &p.value);

    const hooks = p.value.object.get("hooks").?.object;
    try testing.expect(hooks.get("PostToolUse") == null);
    try testing.expect(hooks.get("PreToolUse") != null);
}

test "the Nushell-era entry is recognised and replaced, not duplicated" {
    var p = try parse(nu_entry);
    defer p.deinit();
    try testing.expect(settings.isInstalled(p.gpa(), &p.value));

    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");
    const arr = p.value.object.get("hooks").?.object.get("PostToolUse").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);

    const cmd = arr.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expect(std.mem.find(u8, cmd, "nu ") == null);
    try testing.expect(std.mem.find(u8, cmd, "zcanon hook") != null);
}

test "isInstalled is false for a settings file with no hooks at all" {
    var p = try parse(
        \\{"theme":"dark"}
    );
    defer p.deinit();
    try testing.expect(!settings.isInstalled(p.gpa(), &p.value));
}

test "isInstalled is false when only foreign hooks are present" {
    var p = try parse(
        \\{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other"}]}]}}
    );
    defer p.deinit();
    try testing.expect(!settings.isInstalled(p.gpa(), &p.value));
}

test "command carries the marker" {
    const cmd = try settings.command(testing.allocator, "/opt/zcanon");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.find(u8, cmd, settings.MARKER) != null);
    try testing.expect(std.mem.startsWith(u8, cmd, "\"/opt/zcanon\" hook"));
}

test "command uses forward slashes on Windows, where hooks run through Git Bash" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const cmd = try settings.command(testing.allocator, "C:\\Users\\me\\zcanon.exe");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.startsWith(u8, cmd, "\"C:/Users/me/zcanon.exe\" hook"));
}

test "render round-trips through a re-parse" {
    var p = try parse(
        \\{"theme":"dark","permissions":{"allow":["a"]}}
    );
    defer p.deinit();
    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");

    const text = try settings.render(p.gpa(), p.value); // owned by the fixture arena
    try testing.expect(std.mem.find(u8, text, "\n  ") != null); // indent_2

    var again = try parse(text);
    defer again.deinit();
    try testing.expect(settings.isInstalled(again.gpa(), &again.value));
    try testing.expectEqualStrings("dark", again.value.object.get("theme").?.string);
}

test "uninstall does NOT delete a pre-existing empty PostToolUse we never created" {
    var p = try parse(
        \\{"theme":"dark","hooks":{"PostToolUse":[]}}
    );
    defer p.deinit();
    const removed = try settings.removeOurs(p.gpa(), &p.value);

    try testing.expectEqual(@as(usize, 0), removed);
    const hooks = p.value.object.get("hooks").?.object;
    try testing.expect(hooks.get("PostToolUse") != null);
    try testing.expectEqual(@as(usize, 0), hooks.get("PostToolUse").?.array.items.len);
}

test "install preserves the user's key order inside hooks" {
    var p = try parse(
        \\{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}],"PreToolUse":[],"Stop":[]}}
    );
    defer p.deinit();
    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");

    const hooks = p.value.object.get("hooks").?.object;
    const keys = hooks.keys();
    try testing.expectEqualStrings("PostToolUse", keys[0]);
    try testing.expectEqualStrings("PreToolUse", keys[1]);
    try testing.expectEqualStrings("Stop", keys[2]);
}

test "reinstalling over our own entry still preserves order" {
    var p = try parse(
        \\{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"old  # zcanon-zig-hook"}]}],"PreToolUse":[]}}
    );
    defer p.deinit();
    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");

    const hooks = p.value.object.get("hooks").?.object;
    try testing.expectEqualStrings("PostToolUse", hooks.keys()[0]);
    try testing.expectEqual(@as(usize, 1), hooks.get("PostToolUse").?.array.items.len);
}

test "a settings file with a UTF-8 BOM still parses" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    // load() reads from disk, so exercise the same normalisation directly.
    const with_bom = "\xEF\xBB\xBF{\"theme\":\"dark\"}";
    const no_bom = if (std.mem.startsWith(u8, with_bom, "\xEF\xBB\xBF")) with_bom[3..] else with_bom;
    const v = try std.json.parseFromSliceLeaky(Value, gpa, no_bom, .{ .duplicate_field_behavior = .use_last });
    try testing.expectEqualStrings("dark", v.object.get("theme").?.string);
}

test "a duplicate key takes the last value instead of aborting" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const text =
        \\{"theme":"light","theme":"dark"}
    ;
    // std's default is error.DuplicateField, which broke install/uninstall/status outright.
    try testing.expectError(
        error.DuplicateField,
        std.json.parseFromSliceLeaky(Value, a.allocator(), text, .{}),
    );
    const v = try std.json.parseFromSliceLeaky(Value, a.allocator(), text, .{
        .duplicate_field_behavior = .use_last,
    });
    try testing.expectEqualStrings("dark", v.object.get("theme").?.string);
}

test "floats and nulls survive a render round-trip" {
    var p = try parse(
        \\{"a":1.5,"b":null,"c":[],"d":{"e":true},"f":"ünïcøde"}
    );
    defer p.deinit();
    try settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook  # zcanon-zig-hook");
    const text = try settings.render(p.gpa(), p.value);

    var again = try parse(text);
    defer again.deinit();
    try testing.expectEqual(@as(f64, 1.5), again.value.object.get("a").?.float);
    try testing.expectEqual(std.json.Value.null, again.value.object.get("b").?);
    try testing.expectEqual(@as(usize, 0), again.value.object.get("c").?.array.items.len);
    try testing.expect(again.value.object.get("d").?.object.get("e").?.bool);
    try testing.expectEqualStrings("ünïcøde", again.value.object.get("f").?.string);
}

test "a non-object settings root is refused rather than overwritten" {
    var p = try parse("[1,2,3]");
    defer p.deinit();
    try testing.expectError(
        error.SettingsNotAnObject,
        settings.addOurs(p.gpa(), &p.value, "/bin/zcanon hook"),
    );
}

test "exeFromCommand reads quoted, legacy unquoted, and rejects foreign commands" {
    try testing.expectEqualStrings("/a b/zcanon", settings.exeFromCommand("\"/a b/zcanon\" hook  # zcanon-zig-hook").?);
    try testing.expectEqualStrings("/bin/zcanon", settings.exeFromCommand("/bin/zcanon hook  # zcanon-zig-hook").?);
    try testing.expect(settings.exeFromCommand("other-tool --flag") == null);
}

test "command quotes the path so a space cannot split it" {
    const cmd = try settings.command(testing.allocator, "/home/u/My Projects/zcanon");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.startsWith(u8, cmd, "\"/home/u/My Projects/zcanon\" hook"));
    try testing.expectEqualStrings("/home/u/My Projects/zcanon", settings.exeFromCommand(cmd).?);
}

test "ourCommand finds our entry among foreign ones" {
    var p = try parse(
        \\{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other"}]}]}}
    );
    defer p.deinit();
    try testing.expect(settings.ourCommand(p.gpa(), &p.value) == null);
    try settings.addOurs(p.gpa(), &p.value, "\"/x/zcanon\" hook  # zcanon-zig-hook");
    try testing.expectEqualStrings("\"/x/zcanon\" hook  # zcanon-zig-hook", settings.ourCommand(p.gpa(), &p.value).?);
}
