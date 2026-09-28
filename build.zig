// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default, not Debug: the hook runs on every edit, and the installed binary
    // is whatever plain `zig build` produced. Safety checks stay live. `-Doptimize=Debug` to debug.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;

    // zsnag: the LLM-footgun linter — written in Zig (the project dogfoods itself).
    // (std discovery/lookup — zlook/zmap — moved to zephem, which owns the std map.)
    const tools = [_][]const u8{ "zsnag", "zcanon" };
    var exes: [tools.len]*std.Build.Step.Compile = undefined;
    inline for (tools, 0..) |name, idx| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(exe);
        exes[idx] = exe;
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
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_tests.step);

    // CLI tests drive the REAL binaries end to end — install/uninstall/status/hook/book/prune.
    // Those paths had no automated coverage at all: every subcommand was only ever exercised
    // by hand, which is how the notice-duplication bug survived its own manual check.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/test/cli/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The install prefix comes in as a build option rather than an env var: the tests need it
    // before they spawn anything, and reading the ambient environment from a test is awkward.
    const cli_opts = b.addOptions();
    cli_opts.addOption([]const u8, "bin_dir", b.getInstallPath(.bin, ""));
    // The child needs PATH to find `zig` for ast-check. A test process cannot read the
    // ambient environment on posix (Environ.Block is a slice with no global accessor), so it
    // comes through here, where the build graph does have it.
    cli_opts.addOption([]const u8, "path_env", b.graph.environ_map.get("PATH") orelse "");
    // `zig build` run by the tests (add-check, the daemon's compiler) needs a global cache, and
    // the tests' environment has no HOME to derive one from.
    cli_opts.addOption([]const u8, "zig_global_cache", b.graph.global_cache_root.path orelse "");
    cli_opts.addOption([]const u8, "zephem_home", b.graph.environ_map.get("ZEPHEM_HOME") orelse "");
    // The setup tests need zephem's lookup table: $ZEPHEM_LOOKUP, else inside $ZEPHEM_HOME,
    // else inside a zephem checkout beside this one. Missing → those tests skip, not fail.
    const lookup: []const u8 = b.graph.environ_map.get("ZEPHEM_LOOKUP") orelse if (b.graph.environ_map.get("ZEPHEM_HOME")) |zh|
        b.pathJoin(&.{ zh, "data", "lookup.tsv" })
    else
        b.pathFromRoot("../zephem/data/lookup.tsv");
    cli_opts.addOption([]const u8, "zephem_lookup", lookup);
    cli_mod.addOptions("build_options", cli_opts);

    const cli_tests = b.addTest(.{ .name = "zcanon-cli-test", .root_module = cli_mod });
    const run_cli = b.addRunArtifact(cli_tests);
    run_cli.step.dependOn(b.getInstallStep());
    for (exes) |exe| run_cli.step.dependOn(&exe.step);

    const cli_step = b.step("test-cli", "Run the end-to-end CLI tests against the built binaries");
    cli_step.dependOn(&run_cli.step);
    test_step.dependOn(&run_cli.step);
}
