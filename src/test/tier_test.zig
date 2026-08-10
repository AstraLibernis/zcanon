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

test "every tier has a distinct, non-empty header" {
    // The rank ordering itself is comptime-fixed by the enum declaration, so asserting it
    // here would prove nothing. What matters behaviourally — that renderContext emits the
    // blocks in urgency order — is covered in hook_test.zig.
    const all = std.enums.values(tier.Tier);
    for (all, 0..) |a, i| {
        try testing.expect(a.head().len > 0);
        for (all[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.head(), b.head()));
        }
    }
}
