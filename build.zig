const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const idx_embed_mod = b.createModule(.{
        .root_source_file = b.path("resources/index_embed.zig"),
        .target = target,
        .optimize = optimize,
    });

    const api_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_mod.addImport("index_embed", idx_embed_mod);

    const api = b.addExecutable(.{
        .name = "api",
        .root_module = api_mod,
    });

    b.installArtifact(api);

    const run_cmd = b.addRunArtifact(api);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the API server on :9999");
    run_step.dependOn(&run_cmd.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_ivf.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("index_embed", idx_embed_mod);
    const bench = b.addExecutable(.{
        .name = "bench_ivf",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    const bench_parse = b.addExecutable(.{
        .name = "bench_parse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_parse.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(bench_parse);

    const test_norm = b.addExecutable(.{
        .name = "test_norm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_norm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(test_norm);
}
