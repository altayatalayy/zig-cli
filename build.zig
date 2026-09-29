const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("cli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "cli-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cli", .module = mod }},
        }),
    });
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    if (b.args) |args| run_example.addArgs(args);
    b.step("example", "Run the example (pass args after --)").dependOn(&run_example.step);
}
