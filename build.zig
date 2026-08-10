const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zsnag: the LLM-footgun linter — written in Zig (the project dogfoods itself).
    // (std discovery/lookup — zlook/zmap — moved to zephem, which owns the std map.)
    const tools = [_][]const u8{ "zsnag", "zcanon" };
    inline for (tools) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(exe);
    }

    // Tests live out-of-line in src/test/, aggregated by all.zig — the modules stay lean.
    // They reach the sources through the `zcanon` module (src/lib.zig), because a test root
    // under src/test/ cannot @import across the module boundary by relative path.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zcanon", lib_mod);
    const tests = b.addTest(.{ .name = "zcanon-test", .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);
}
