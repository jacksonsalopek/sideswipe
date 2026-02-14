const std = @import("std");

fn generatePnpIds(b: *std.Build, target: std.Build.ResolvedTarget, core_cli_mod: *std.Build.Module) *std.Build.Step {
    // Build the PNP ID generator executable with logger support
    const gen_exe = b.addExecutable(.{
        .name = "gen_pnp_ids",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/display/edid/gen_pnp_ids.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "core.cli", .module = core_cli_mod },
            },
        }),
    });
    
    // Run it with arguments
    const gen_pnp = b.addRunArtifact(gen_exe);
    gen_pnp.addArg("/usr/share/hwdata/pnp.ids");
    gen_pnp.addArg("src/core/display/edid/pnp_ids.zig");
    
    return &gen_pnp.step;
}

fn generateVicTable(b: *std.Build, target: std.Build.ResolvedTarget, core_cli_mod: *std.Build.Module) *std.Build.Step {
    // Build the VIC table generator executable with logger support
    const gen_exe = b.addExecutable(.{
        .name = "gen_vic_table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/display/cta/gen_vic_table.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "core.cli", .module = core_cli_mod },
            },
        }),
    });
    
    // Run it with arguments
    const gen_vic = b.addRunArtifact(gen_exe);
    gen_vic.addArg("vendor/libdisplay-info/cta-vic-table.c");
    gen_vic.addArg("src/core/display/cta/vic_table.zig");
    
    return &gen_vic.step;
}

fn setupWaylandProtocols(b: *std.Build) *std.Build.Step {
    // Create protocols directory
    const mkdir_protocols = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        "protocols",
    });

    // Generate xdg-shell protocol (server-side)
    const xdg_shell_header = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
        "protocols/xdg-shell-protocol.h",
    });
    xdg_shell_header.step.dependOn(&mkdir_protocols.step);

    const xdg_shell_code = b.addSystemCommand(&.{
        "wayland-scanner",
        "private-code",
        "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
        "protocols/xdg-shell-protocol.c",
    });
    xdg_shell_code.step.dependOn(&mkdir_protocols.step);

    // Generate linux-dmabuf protocol
    const dmabuf_header = b.addSystemCommand(&.{
        "wayland-scanner",
        "client-header",
        "/usr/share/wayland-protocols/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml",
        "protocols/linux-dmabuf-unstable-v1-client-protocol.h",
    });
    dmabuf_header.step.dependOn(&mkdir_protocols.step);

    const dmabuf_code = b.addSystemCommand(&.{
        "wayland-scanner",
        "private-code",
        "/usr/share/wayland-protocols/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml",
        "protocols/linux-dmabuf-unstable-v1-protocol.c",
    });
    dmabuf_code.step.dependOn(&mkdir_protocols.step);

    // Create a step that depends on all protocol generation
    const protocols_step = b.step("_protocols_internal", "Internal step for all protocol generation");
    protocols_step.dependOn(&xdg_shell_header.step);
    protocols_step.dependOn(&xdg_shell_code.step);
    protocols_step.dependOn(&dmabuf_header.step);
    protocols_step.dependOn(&dmabuf_code.step);

    return protocols_step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Clean step
    const clean_step = b.step("clean", "Clear Zig build caches and generated files");
    const clean_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "rm -rf .zig-cache protocols zig-out src/core/display/edid/pnp_ids.zig src/core/display/cta/vic_table.zig && echo 'Zig caches and generated files cleared'",
    });
    clean_step.dependOn(&clean_cmd.step);

    // CLI module for generators
    const core_cli_mod = b.addModule("core.cli", .{
        .root_source_file = b.path("src/core/cli/root.zig"),
        .target = target,
        .link_libc = true,
    });

    // Generate PNP ID database
    const generate_pnp_step = b.step("generate-pnp-ids", "Generate PNP ID database from hwdata");
    const generate_pnp = generatePnpIds(b, target, core_cli_mod);
    generate_pnp_step.dependOn(generate_pnp);

    // Generate VIC timing table
    const generate_vic_step = b.step("generate-vic-table", "Generate VIC timing table from libdisplay-info");
    const generate_vic = generateVicTable(b, target, core_cli_mod);
    generate_vic_step.dependOn(generate_vic);

    // Generate Wayland protocol headers
    const generate_protocols_step = b.step("generate-protocols", "Generate Wayland protocol headers");
    const generate_protocols = setupWaylandProtocols(b);
    generate_protocols_step.dependOn(generate_protocols);

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

    const core_graphics_mod = b.addModule("core.graphics", .{
        .root_source_file = b.path("src/core/graphics/root.zig"),
        .target = target,
        .link_libc = true,
    });
    core_graphics_mod.addImport("core.math", core_math_mod);

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

    _ = b.addModule("core.display", .{
        .root_source_file = b.path("src/core/display/root.zig"),
        .target = target,
        .link_libc = true,
    });

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
    backend_mod.addIncludePath(b.path("protocols"));
    backend_mod.linkSystemLibrary("libdrm", .{});
    backend_mod.linkSystemLibrary("libinput", .{});
    backend_mod.linkSystemLibrary("pixman-1", .{});
    backend_mod.linkSystemLibrary("gbm", .{});
    backend_mod.linkSystemLibrary("EGL", .{});
    backend_mod.linkSystemLibrary("GLESv2", .{});
    backend_mod.linkSystemLibrary("libudev", .{});
    backend_mod.linkSystemLibrary("libseat", .{});
    backend_mod.linkSystemLibrary("wayland-client", .{});
    backend_mod.linkSystemLibrary("wayland-cursor", .{});
    // libdisplay-info no longer needed - using native Zig implementation
    // backend_mod.linkSystemLibrary("libdisplay-info", .{});
    backend_mod.addImport("core.string", core_string_mod);
    backend_mod.addImport("core.math", core_math_mod);

    // Note: backend.drm uses relative imports and is tested via backend module tests
    // Cannot be tested standalone due to module path restrictions

    // IPC module for inter-process communication
    const ipc_mod = b.addModule("ipc", .{
        .root_source_file = b.path("src/ipc/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "backend", .module = backend_mod },
        },
    });
    ipc_mod.addImport("core.math", core_math_mod);
    ipc_mod.addImport("core.os", core_os_mod);

    // Wayland server module
    const wayland_mod = b.addModule("wayland", .{
        .root_source_file = b.path("src/wayland/root.zig"),
        .target = target,
        .link_libc = true,
    });
    wayland_mod.addIncludePath(b.path("protocols"));
    wayland_mod.linkSystemLibrary("wayland-server", .{});

    // Compositor module
    const compositor_mod = b.addModule("compositor", .{
        .root_source_file = b.path("src/compositor/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "core.math", .module = core_math_mod },
            .{ .name = "wayland", .module = wayland_mod },
            .{ .name = "backend", .module = backend_mod },
        },
    });
    compositor_mod.addIncludePath(b.path("protocols"));
    compositor_mod.linkSystemLibrary("wayland-server", .{});

    // Wayland protocol sources
    const xdg_shell_c = b.addObject(.{
        .name = "xdg-shell-protocol",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    xdg_shell_c.step.dependOn(generate_protocols);
    xdg_shell_c.addCSourceFile(.{
        .file = b.path("protocols/xdg-shell-protocol.c"),
        .flags = &.{"-std=c99"},
    });
    xdg_shell_c.addIncludePath(b.path("protocols"));
    xdg_shell_c.linkLibC();

    const dmabuf_c = b.addObject(.{
        .name = "linux-dmabuf-protocol",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    dmabuf_c.step.dependOn(generate_protocols);
    dmabuf_c.addCSourceFile(.{
        .file = b.path("protocols/linux-dmabuf-unstable-v1-protocol.c"),
        .flags = &.{"-std=c99"},
    });
    dmabuf_c.addIncludePath(b.path("protocols"));
    dmabuf_c.linkLibC();

    // Main executable
    const exe = b.addExecutable(.{
        .name = "sideswipe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "core.cli", .module = core_cli_mod },
                .{ .name = "backend", .module = backend_mod },
                .{ .name = "ipc", .module = ipc_mod },
                .{ .name = "wayland", .module = wayland_mod },
                .{ .name = "compositor", .module = compositor_mod },
            },
        }),
    });
    exe.addIncludePath(b.path("protocols"));
    exe.addObject(xdg_shell_c);
    exe.addObject(dmabuf_c);
    exe.linkSystemLibrary("libdrm");
    exe.linkSystemLibrary("libinput");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("gbm");
    exe.linkSystemLibrary("EGL");
    exe.linkSystemLibrary("GLESv2");
    exe.linkSystemLibrary("libudev");
    exe.linkSystemLibrary("libseat");
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("wayland-cursor");
    // libdisplay-info no longer needed - using native Zig implementation
    // exe.linkSystemLibrary("libdisplay-info");
    exe.linkLibC();

    // Ensure generated files are created before build
    exe.step.dependOn(generate_pnp);
    exe.step.dependOn(generate_vic);

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Comparison benchmark against C libdisplay-info
    const display_compare_mod = b.addModule("display_compare", .{
        .root_source_file = b.path("src/core/display/root.zig"),
        .target = target,
        .link_libc = true,
    });
    
    const compare_c_exe = b.addExecutable(.{
        .name = "compare_c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/display/compare_c.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "display", .module = display_compare_mod },
                .{ .name = "core.cli", .module = core_cli_mod },
            },
        }),
    });
    compare_c_exe.linkLibC();
    compare_c_exe.linkSystemLibrary("libdisplay-info");
    compare_c_exe.step.dependOn(generate_pnp);
    b.installArtifact(compare_c_exe);

    const run_compare = b.step("compare-c", "Benchmark Zig vs C libdisplay-info");
    const compare_cmd = b.addRunArtifact(compare_c_exe);
    run_compare.dependOn(&compare_cmd.step);

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

    // Test core.graphics module
    const core_graphics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/graphics/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core.math", .module = core_math_mod },
            },
        }),
    });
    core_graphics_tests.linkSystemLibrary("pixman-1");
    core_graphics_tests.linkLibC();
    const run_core_graphics_tests = b.addRunArtifact(core_graphics_tests);
    test_step.dependOn(&run_core_graphics_tests.step);

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

    // Test core.cli module
    const core_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/cli/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    core_cli_tests.linkLibC();
    const run_core_cli_tests = b.addRunArtifact(core_cli_tests);
    test_step.dependOn(&run_core_cli_tests.step);

    // Test core.display module
    const core_display_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/display/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    core_display_tests.linkLibC();
    // Display tests depend on generated PNP IDs and VIC table
    core_display_tests.step.dependOn(generate_pnp);
    core_display_tests.step.dependOn(generate_vic);
    const run_core_display_tests = b.addRunArtifact(core_display_tests);
    test_step.dependOn(&run_core_display_tests.step);

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
    backend_tests.addIncludePath(b.path("protocols"));
    backend_tests.addObject(xdg_shell_c);
    backend_tests.addObject(dmabuf_c);
    backend_tests.linkSystemLibrary("libdrm");
    backend_tests.linkSystemLibrary("libinput");
    backend_tests.linkSystemLibrary("pixman-1");
    backend_tests.linkSystemLibrary("gbm");
    backend_tests.linkSystemLibrary("EGL");
    backend_tests.linkSystemLibrary("GLESv2");
    backend_tests.linkSystemLibrary("libudev");
    backend_tests.linkSystemLibrary("libseat");
    backend_tests.linkSystemLibrary("wayland-client");
    backend_tests.linkSystemLibrary("wayland-cursor");
    // libdisplay-info no longer needed - using native Zig implementation
    // backend_tests.linkSystemLibrary("libdisplay-info");
    backend_tests.linkLibC();
    const run_backend_tests = b.addRunArtifact(backend_tests);
    test_step.dependOn(&run_backend_tests.step);

    // Test backend.drm module (uses relative imports, tested via backend tests)

    // Test IPC module
    const ipc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "backend", .module = backend_mod },
                .{ .name = "core.math", .module = core_math_mod },
                .{ .name = "core.os", .module = core_os_mod },
            },
        }),
    });
    ipc_tests.linkLibC();
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    test_step.dependOn(&run_ipc_tests.step);

    // Test Wayland module
    const wayland_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wayland/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
            },
        }),
    });
    wayland_tests.linkSystemLibrary("wayland-server");
    wayland_tests.linkLibC();
    const run_wayland_tests = b.addRunArtifact(wayland_tests);
    test_step.dependOn(&run_wayland_tests.step);

    // Test Compositor module
    const compositor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compositor/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "core.math", .module = core_math_mod },
                .{ .name = "wayland", .module = wayland_mod },
                .{ .name = "backend", .module = backend_mod },
            },
        }),
    });
    compositor_tests.addIncludePath(b.path("protocols"));
    compositor_tests.addObject(xdg_shell_c);
    compositor_tests.linkSystemLibrary("wayland-server");
    compositor_tests.linkSystemLibrary("libdrm");
    compositor_tests.linkSystemLibrary("libinput");
    compositor_tests.linkSystemLibrary("pixman-1");
    compositor_tests.linkSystemLibrary("gbm");
    compositor_tests.linkSystemLibrary("EGL");
    compositor_tests.linkSystemLibrary("GLESv2");
    compositor_tests.linkSystemLibrary("libudev");
    compositor_tests.linkSystemLibrary("libseat");
    compositor_tests.linkSystemLibrary("wayland-client");
    compositor_tests.linkSystemLibrary("wayland-cursor");
    compositor_tests.linkLibC();
    const run_compositor_tests = b.addRunArtifact(compositor_tests);
    test_step.dependOn(&run_compositor_tests.step);

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
                    .{ .name = "core.anim", .module = core_anim_mod },
                    .{ .name = "core.cli", .module = core_cli_mod },
                    .{ .name = "core.i18n", .module = core_i18n_mod },
                    .{ .name = "core.math", .module = core_math_mod },
                    .{ .name = "core.os", .module = core_os_mod },
                    .{ .name = "core.string", .module = core_string_mod },
                    .{ .name = "backend", .module = backend_mod },
                    .{ .name = "ipc", .module = ipc_mod },
                    .{ .name = "wayland", .module = wayland_mod },
                    .{ .name = "compositor", .module = compositor_mod },
                },
            }),
        });
        file_tests.addIncludePath(b.path("protocols"));
        file_tests.addObject(xdg_shell_c);
        file_tests.addObject(dmabuf_c);
        file_tests.linkSystemLibrary("libdrm");
        file_tests.linkSystemLibrary("libinput");
        file_tests.linkSystemLibrary("pixman-1");
        file_tests.linkSystemLibrary("gbm");
        file_tests.linkSystemLibrary("EGL");
        file_tests.linkSystemLibrary("GLESv2");
        file_tests.linkSystemLibrary("libudev");
        file_tests.linkSystemLibrary("libseat");
        file_tests.linkSystemLibrary("wayland-client");
        file_tests.linkSystemLibrary("wayland-server");
        file_tests.linkSystemLibrary("wayland-cursor");
        // libdisplay-info no longer needed - using native Zig implementation
        // file_tests.linkSystemLibrary("libdisplay-info");
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
