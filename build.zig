const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zigsh",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zigsh");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_printf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const integration_tests = b.addTest(.{
        .root_module = integration_test_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(b.getInstallStep());

    const integration_test_step = b.step("test-printf", "Run printf integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    const read_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_read.zig"),
        .target = target,
        .optimize = optimize,
    });

    const read_tests = b.addTest(.{
        .root_module = read_test_mod,
    });
    const run_read_tests = b.addRunArtifact(read_tests);
    run_read_tests.step.dependOn(b.getInstallStep());

    const read_test_step = b.step("test-read", "Run read integration tests");
    read_test_step.dependOn(&run_read_tests.step);
    test_step.dependOn(&run_read_tests.step);

    const posix_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_posix.zig"),
        .target = target,
        .optimize = optimize,
    });

    const posix_tests = b.addTest(.{
        .root_module = posix_test_mod,
    });
    const run_posix_tests = b.addRunArtifact(posix_tests);
    run_posix_tests.step.dependOn(b.getInstallStep());

    const posix_test_step = b.step("test-posix", "Run POSIX integration tests");
    posix_test_step.dependOn(&run_posix_tests.step);
    test_step.dependOn(&run_posix_tests.step);
}
