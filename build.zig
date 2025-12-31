const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core module with shared types
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const core_string_mod = b.addModule("core.string", .{
        .root_source_file = b.path("src/core/string/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const core_math_mod = b.addModule("core.math", .{
        .root_source_file = b.path("src/core/math/root.zig"),
        .target = target,
        .link_libc = true,
    });
    core_math_mod.addImport("core.string", core_string_mod);

    const core_anim_mod = b.addModule("core.anim", .{
        .root_source_file = b.path("src/core/anim/root.zig"),
        .target = target,
        .link_libc = true,
    });
    core_anim_mod.addImport("core.math", core_math_mod);

    const core_os_mod = b.addModule("core.os", .{
        .root_source_file = b.path("src/core/os/root.zig"),
        .target = target,
        .link_libc = true,
    });
    core_os_mod.addImport("core.string", core_string_mod);

    const core_i18n_mod = b.addModule("core.i18n", .{
        .root_source_file = b.path("src/core/i18n/root.zig"),
        .target = target,
        .link_libc = true,
    });
    core_i18n_mod.addImport("core.string", core_string_mod);

    core_mod.linkSystemLibrary("pixman-1", .{});
    core_math_mod.linkSystemLibrary("pixman-1", .{});

    // Backend module
    const backend_mod = b.addModule("backend", .{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .link_libc = true,
        .link_libcpp = false,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "core.string", .module = core_string_mod },
            .{ .name = "core.math", .module = core_math_mod },
        },
    });
    backend_mod.linkSystemLibrary("libdrm", .{});
    backend_mod.linkSystemLibrary("libinput", .{});
    backend_mod.linkSystemLibrary("pixman-1", .{});
    backend_mod.addImport("core.string", core_string_mod);
    backend_mod.addImport("core.math", core_math_mod);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "sideswipe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "backend", .module = backend_mod },
            },
        }),
    });
    exe.linkSystemLibrary("libdrm");
    exe.linkSystemLibrary("libinput");
    exe.linkSystemLibrary("pixman-1");
    exe.linkLibC();

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test suite
    const test_step = b.step("test", "Run tests");

    // Test core module
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    core_tests.linkSystemLibrary("pixman-1");
    core_tests.linkLibC();
    const run_core_tests = b.addRunArtifact(core_tests);
    test_step.dependOn(&run_core_tests.step);

    // Test core.math module
    const core_math_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/math/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core.string", .module = core_string_mod },
            },
        }),
    });
    core_math_tests.linkSystemLibrary("pixman-1");
    core_math_tests.linkLibC();
    const run_core_math_tests = b.addRunArtifact(core_math_tests);
    test_step.dependOn(&run_core_math_tests.step);

    // Test core.anim module
    const core_anim_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/anim/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core.math", .module = core_math_mod },
            },
        }),
    });
    core_anim_tests.linkSystemLibrary("pixman-1");
    core_anim_tests.linkLibC();
    const run_core_anim_tests = b.addRunArtifact(core_anim_tests);
    test_step.dependOn(&run_core_anim_tests.step);

    // Test core.os module
    const core_os_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/os/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core.string", .module = core_string_mod },
            },
        }),
    });
    core_os_tests.linkLibC();
    const run_core_os_tests = b.addRunArtifact(core_os_tests);
    test_step.dependOn(&run_core_os_tests.step);

    // Test core.i18n module
    const core_i18n_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/i18n/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core.string", .module = core_string_mod },
            },
        }),
    });
    core_i18n_tests.linkLibC();
    const run_core_i18n_tests = b.addRunArtifact(core_i18n_tests);
    test_step.dependOn(&run_core_i18n_tests.step);

    // Test core.string module
    const core_string_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/string/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    core_string_tests.linkLibC();
    const run_core_string_tests = b.addRunArtifact(core_string_tests);
    test_step.dependOn(&run_core_string_tests.step);

    // Test backend module
    const backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/backend/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "core.string", .module = core_string_mod },
                .{ .name = "core.math", .module = core_math_mod },
            },
        }),
    });
    backend_tests.linkSystemLibrary("libdrm");
    backend_tests.linkSystemLibrary("libinput");
    backend_tests.linkSystemLibrary("pixman-1");
    backend_tests.linkLibC();
    const run_backend_tests = b.addRunArtifact(backend_tests);
    test_step.dependOn(&run_backend_tests.step);

    // Test a specific file with module access
    const test_file_step = b.step("test-file", "Run tests for a specific file with module access");
    if (b.option([]const u8, "file", "Path to file to test")) |file_path| {
        const file_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = .{ .cwd_relative = file_path },
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "core", .module = core_mod },
                    .{ .name = "core.math", .module = core_math_mod },
                    .{ .name = "core.anim", .module = core_anim_mod },
                    .{ .name = "core.os", .module = core_os_mod },
                    .{ .name = "core.i18n", .module = core_i18n_mod },
                    .{ .name = "core.string", .module = core_string_mod },
                    .{ .name = "backend", .module = backend_mod },
                },
            }),
        });
        file_tests.linkSystemLibrary("libdrm");
        file_tests.linkSystemLibrary("libinput");
        file_tests.linkSystemLibrary("pixman-1");
        file_tests.linkLibC();

        if (b.option([]const u8, "filter", "Test name filter")) |filter| {
            const filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM");
            filters[0] = filter;
            file_tests.filters = filters;
        }

        const run_file_tests = b.addRunArtifact(file_tests);
        test_file_step.dependOn(&run_file_tests.step);
    }
}
