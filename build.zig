const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "MEML CLI version") orelse "0.2.1";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const example = b.addExecutable(.{
        .name = "meml-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/meml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(example);

    const run = b.addRunArtifact(example);
    const run_step = b.step("example", "Run the MEML context-aware memory example");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/meml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run MEML unit and integration tests");
    test_step.dependOn(&test_run.step);

    const bench = b.addExecutable(.{
        .name = "meml-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run the MEML deterministic retrieval benchmark");
    bench_step.dependOn(&bench_run.step);

    const eval = b.addExecutable(.{
        .name = "meml-eval",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/eval.zig"), .target = target, .optimize = optimize }),
    });
    const eval_run = b.addRunArtifact(eval);
    const eval_step = b.step("eval", "Run the frozen retrieval-v1 quality baseline");
    eval_step.dependOn(&eval_run.step);

    const demo = b.addExecutable(.{
        .name = "meml-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const demo_run = b.addRunArtifact(demo);
    const demo_step = b.step("demo", "Run the MEML end-to-end demo (examples/demo.meml)");
    demo_step.dependOn(&demo_run.step);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = "meml",
        .root_module = cli_module,
    });
    b.installArtifact(exe);
    const cli_run = b.addRunArtifact(exe);
    const cli_step = b.step("run", "Run the MEML JSON-lines CLI (see src/cli.zig for the request protocol)");
    cli_step.dependOn(&cli_run.step);

    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_module.addOptions("build_options", build_options);
    const cli_tests = b.addTest(.{ .root_module = cli_test_module });
    const cli_test_run = b.addRunArtifact(cli_tests);
    test_step.dependOn(&cli_test_run.step);
}
