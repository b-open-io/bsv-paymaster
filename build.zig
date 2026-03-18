const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const runar_dep = b.dependency("runar_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const runar_module = runar_dep.module("runar");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("Paymaster_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("runar", runar_module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run contract tests");
    test_step.dependOn(&run_tests.step);
}
