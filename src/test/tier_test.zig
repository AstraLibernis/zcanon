const std = @import("std");
const testing = std.testing;
const tier = @import("zcanon").tier;

test "severity maps to base tier" {
    try testing.expectEqual(tier.Tier.blocking, tier.classify("error", "src/main.zig"));
    try testing.expectEqual(tier.Tier.caution, tier.classify("warn", "src/main.zig"));
    try testing.expectEqual(tier.Tier.advisory, tier.classify("info", "src/main.zig"));
}

test "unknown severity falls through to advisory" {
    try testing.expectEqual(tier.Tier.advisory, tier.classify("", "src/main.zig"));
    try testing.expectEqual(tier.Tier.advisory, tier.classify("note", "src/main.zig"));
}

test "advisory demotes to expected in throwaway code" {
    const scratch_paths = [_][]const u8{
        "/tmp/x.zig",
        "/home/u/scratchpad/x.zig",
        "bench/run.zig",
        "src/experiment.zig",
        "src/tier_test.zig",
        "src/test/x.zig",
        "src/tests/x.zig",
    };
    for (scratch_paths) |p| {
        try testing.expectEqual(tier.Tier.expected, tier.classify("info", p));
    }
}

test "demotion is case-insensitive" {
    try testing.expectEqual(tier.Tier.expected, tier.classify("info", "/TMP/x.zig"));
    try testing.expectEqual(tier.Tier.expected, tier.classify("info", "BENCH/run.zig"));
    try testing.expectEqual(tier.Tier.expected, tier.classify("info", "src/Foo_TEST.ZIG"));
}

test "blocking and caution never demote, however throwaway the path" {
    try testing.expectEqual(tier.Tier.blocking, tier.classify("error", "/tmp/x.zig"));
    try testing.expectEqual(tier.Tier.caution, tier.classify("warn", "/tmp/x.zig"));
}

test "ordinary paths do not match the scratch pattern" {
    const real_paths = [_][]const u8{
        "src/main.zig",
        "/home/u/repos/zvx/src/gather.zig",
        "src/latest.zig", // contains "test" only as a substring of a longer word
        "src/contest.zig",
    };
    for (real_paths) |p| {
        try testing.expectEqual(tier.Tier.advisory, tier.classify("info", p));
    }
}

test "tier rank is display order and heads are distinct" {
    try testing.expect(@intFromEnum(tier.Tier.blocking) < @intFromEnum(tier.Tier.caution));
    try testing.expect(@intFromEnum(tier.Tier.caution) < @intFromEnum(tier.Tier.advisory));
    try testing.expect(@intFromEnum(tier.Tier.advisory) < @intFromEnum(tier.Tier.expected));

    const all = [_]tier.Tier{ .blocking, .caution, .advisory, .expected };
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.head(), b.head()));
        }
    }
}

test "key matches the nushell tier names" {
    try testing.expectEqualStrings("blocking", tier.Tier.blocking.key());
    try testing.expectEqualStrings("caution", tier.Tier.caution.key());
    try testing.expectEqualStrings("advisory", tier.Tier.advisory.key());
    try testing.expectEqualStrings("expected", tier.Tier.expected.key());
}
