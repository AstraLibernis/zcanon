const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zsnag: the LLM-footgun linter — written in Zig (the project dogfoods itself).
    // (std discovery/lookup — zlook/zmap — moved to zephem, which owns the std map.)
    const tools = [_][]const u8{"zsnag"};
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
}
