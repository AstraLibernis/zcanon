const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Analysis tools that read/judge Zig source — written in Zig (dogfood).
    // zsnag: LLM-footgun linter.  zlook: SIMD keyword search over the zephem lookup table
    // (the map is the single source of std truth; regenerate zephem to refresh it).
    const tools = [_][]const u8{ "zsnag", "zlook" };
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
