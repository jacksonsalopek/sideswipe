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

/// Resolves the wayland-protocols data directory.
/// Prefers `pkg-config wayland-protocols --variable=pkgdatadir`,
/// falls back to the conventional `/usr/share/wayland-protocols`.
fn resolveProtocolDir(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "pkg-config", "wayland-protocols", "--variable=pkgdatadir" },
        &code,
        .ignore,
    ) catch return "/usr/share/wayland-protocols";
    if (code != 0) return "/usr/share/wayland-protocols";
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) return "/usr/share/wayland-protocols";
    return trimmed;
}

/// Resolves a protocol XML path, preferring the system directory and
/// falling back to a vendored copy under `protocols/xml/` when present.
fn resolveProtocolXml(b: *std.Build, dir: []const u8, rel: []const u8) []const u8 {
    const system_path = b.pathJoin(&.{ dir, rel });
    const io = b.graph.io;
    std.Io.Dir.accessAbsolute(io, system_path, .{}) catch {
        const vendored = b.pathJoin(&.{ "protocols", "xml", std.fs.path.basename(rel) });
        b.build_root.handle.access(io, vendored, .{}) catch return system_path;
        return vendored;
    };
    return system_path;
}

const ProtocolSpec = struct {
    xml_rel: []const u8,
    out_base: []const u8,
};

/// Protocols to generate server headers, client headers, and private code for.
/// Client headers are unused by the compositor today but keep the M3 shell
/// client build working from the same generated tree.
const protocol_specs = [_]ProtocolSpec{
    .{ .xml_rel = "stable/xdg-shell/xdg-shell.xml", .out_base = "xdg-shell-protocol" },
    .{ .xml_rel = "unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml", .out_base = "linux-dmabuf-unstable-v1-protocol" },
    .{ .xml_rel = "staging/xdg-activation/xdg-activation-v1.xml", .out_base = "xdg-activation-v1-protocol" },
    .{ .xml_rel = "stable/viewporter/viewporter.xml", .out_base = "viewporter-protocol" },
    .{ .xml_rel = "staging/fractional-scale/fractional-scale-v1.xml", .out_base = "fractional-scale-v1-protocol" },
};

fn generateProtocolOutputs(
    b: *std.Build,
    protocols_step: *std.Build.Step,
    mkdir_step: *std.Build.Step,
    xml_path: []const u8,
    out_base: []const u8,
) void {
    const short_base = if (std.mem.endsWith(u8, out_base, "-protocol"))
        out_base[0 .. out_base.len - "-protocol".len]
    else
        out_base;
    const modes = [_]struct { scanner_arg: []const u8, file: []const u8 }{
        .{ .scanner_arg = "server-header", .file = b.fmt("{s}.h", .{out_base}) },
        .{ .scanner_arg = "client-header", .file = b.fmt("{s}-client-protocol.h", .{short_base}) },
        .{ .scanner_arg = "private-code", .file = b.fmt("{s}.c", .{out_base}) },
    };
    for (modes) |mode| {
        const out_path = b.pathJoin(&.{ "protocols", mode.file });
        const args = [_][]const u8{ "wayland-scanner", mode.scanner_arg, xml_path, out_path };
        const cmd = b.addSystemCommand(&args);
        cmd.step.dependOn(mkdir_step);
        protocols_step.dependOn(&cmd.step);
    }
}

fn setupWaylandProtocols(b: *std.Build) *std.Build.Step {
    // Create protocols directory
    const mkdir_protocols = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        "protocols",
    });

    const proto_dir = resolveProtocolDir(b);

    // Create a step that depends on all protocol generation
    const protocols_step = b.step("_protocols_internal", "Internal step for all protocol generation");
    for (protocol_specs) |spec| {
        const xml_path = resolveProtocolXml(b, proto_dir, spec.xml_rel);
        generateProtocolOutputs(b, protocols_step, &mkdir_protocols.step, xml_path, spec.out_base);
    }

    return protocols_step;
}

/// Adds a compiled wayland-scanner private-code object to the build.
fn addProtocolObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    generate_protocols: *std.Build.Step,
    name: []const u8,
    c_file: []const u8,
) *std.Build.Step.Compile {
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    obj.step.dependOn(generate_protocols);
    obj.root_module.addCSourceFile(.{
        .file = b.path(c_file),
        .flags = &.{"-std=c99"},
    });
    obj.root_module.addIncludePath(b.path("protocols"));
    obj.root_module.link_libc = true;
    return obj;
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

    const core_display_mod = b.addModule("core.display", .{
        .root_source_file = b.path("src/core/display/root.zig"),
        .target = target,
        .link_libc = true,
    });

    core_mod.linkSystemLibrary("pixman-1", .{});
    core_math_mod.linkSystemLibrary("pixman-1", .{});

    // IPC module for inter-process communication (must be defined before backend to break circular dependency)
    const ipc_mod = b.addModule("ipc", .{
        .root_source_file = b.path("src/ipc/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "core.os", .module = core_os_mod },
        },
    });

    // Backend module
    const backend_mod = b.addModule("backend", .{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .link_libc = true,
        .link_libcpp = false,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "core.cli", .module = core_cli_mod },
            .{ .name = "core.string", .module = core_string_mod },
            .{ .name = "core.math", .module = core_math_mod },
            .{ .name = "ipc", .module = ipc_mod },
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
            .{ .name = "core.cli", .module = core_cli_mod },
            .{ .name = "core.math", .module = core_math_mod },
            .{ .name = "wayland", .module = wayland_mod },
            .{ .name = "backend", .module = backend_mod },
        },
    });
    compositor_mod.addIncludePath(b.path("protocols"));
    compositor_mod.linkSystemLibrary("wayland-server", .{});
    compositor_mod.linkSystemLibrary("xkbcommon", .{});

    // Wayland protocol sources
    const xdg_shell_c = addProtocolObject(b, target, optimize, generate_protocols, "xdg-shell-protocol", "protocols/xdg-shell-protocol.c");
    const dmabuf_c = addProtocolObject(b, target, optimize, generate_protocols, "linux-dmabuf-protocol", "protocols/linux-dmabuf-unstable-v1-protocol.c");
    const activation_c = addProtocolObject(b, target, optimize, generate_protocols, "xdg-activation-protocol", "protocols/xdg-activation-v1-protocol.c");
    const viewporter_c = addProtocolObject(b, target, optimize, generate_protocols, "viewporter-protocol", "protocols/viewporter-protocol.c");
    const fractional_scale_c = addProtocolObject(b, target, optimize, generate_protocols, "fractional-scale-protocol", "protocols/fractional-scale-v1-protocol.c");

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
    exe.root_module.addIncludePath(b.path("protocols"));
    exe.root_module.addObject(xdg_shell_c);
    exe.root_module.addObject(dmabuf_c);
    exe.root_module.addObject(activation_c);
    exe.root_module.addObject(viewporter_c);
    exe.root_module.addObject(fractional_scale_c);
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("libdrm", .{});
    exe.root_module.linkSystemLibrary("libinput", .{});
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    exe.root_module.linkSystemLibrary("gbm", .{});
    exe.root_module.linkSystemLibrary("EGL", .{});
    exe.root_module.linkSystemLibrary("GLESv2", .{});
    exe.root_module.linkSystemLibrary("libudev", .{});
    exe.root_module.linkSystemLibrary("libseat", .{});
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("wayland-server", .{});
    exe.root_module.linkSystemLibrary("wayland-cursor", .{});
    // libdisplay-info no longer needed - using native Zig implementation
    // exe.root_module.linkSystemLibrary("libdisplay-info", .{});
    exe.root_module.link_libc = true;

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
    core_tests.root_module.linkSystemLibrary("pixman-1", .{});
    core_tests.root_module.link_libc = true;
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
    core_math_tests.root_module.linkSystemLibrary("pixman-1", .{});
    core_math_tests.root_module.link_libc = true;
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
    core_anim_tests.root_module.linkSystemLibrary("pixman-1", .{});
    core_anim_tests.root_module.link_libc = true;
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
    core_graphics_tests.root_module.linkSystemLibrary("pixman-1", .{});
    core_graphics_tests.root_module.link_libc = true;
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
    core_os_tests.root_module.link_libc = true;
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
    core_i18n_tests.root_module.link_libc = true;
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
    core_string_tests.root_module.link_libc = true;
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
    core_cli_tests.root_module.link_libc = true;
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
    core_display_tests.root_module.link_libc = true;
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
                .{ .name = "core.cli", .module = core_cli_mod },
                .{ .name = "core.string", .module = core_string_mod },
                .{ .name = "core.math", .module = core_math_mod },
                .{ .name = "core.display", .module = core_display_mod },
                .{ .name = "ipc", .module = ipc_mod },
            },
        }),
    });
    backend_tests.root_module.addIncludePath(b.path("protocols"));
    backend_tests.root_module.addObject(xdg_shell_c);
    backend_tests.root_module.addObject(dmabuf_c);
    backend_tests.root_module.addObject(activation_c);
    backend_tests.root_module.addObject(viewporter_c);
    backend_tests.root_module.addObject(fractional_scale_c);
    backend_tests.step.dependOn(generate_protocols);
    backend_tests.root_module.linkSystemLibrary("libdrm", .{});
    backend_tests.root_module.linkSystemLibrary("libinput", .{});
    backend_tests.root_module.linkSystemLibrary("pixman-1", .{});
    backend_tests.root_module.linkSystemLibrary("gbm", .{});
    backend_tests.root_module.linkSystemLibrary("EGL", .{});
    backend_tests.root_module.linkSystemLibrary("GLESv2", .{});
    backend_tests.root_module.linkSystemLibrary("libudev", .{});
    backend_tests.root_module.linkSystemLibrary("libseat", .{});
    backend_tests.root_module.linkSystemLibrary("wayland-client", .{});
    backend_tests.root_module.linkSystemLibrary("wayland-server", .{});
    backend_tests.root_module.linkSystemLibrary("wayland-cursor", .{});
    // libdisplay-info no longer needed - using native Zig implementation
    // backend_tests.root_module.linkSystemLibrary("libdisplay-info", .{});
    backend_tests.root_module.link_libc = true;
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
                .{ .name = "core.os", .module = core_os_mod },
            },
        }),
    });
    ipc_tests.root_module.link_libc = true;
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
    wayland_tests.root_module.addIncludePath(b.path("protocols"));
    wayland_tests.root_module.addObject(xdg_shell_c);
    wayland_tests.root_module.addObject(viewporter_c);
    wayland_tests.root_module.addObject(fractional_scale_c);
    wayland_tests.step.dependOn(generate_protocols);
    wayland_tests.root_module.linkSystemLibrary("wayland-server", .{});
    wayland_tests.root_module.link_libc = true;
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
                .{ .name = "core.cli", .module = core_cli_mod },
                .{ .name = "core.math", .module = core_math_mod },
                .{ .name = "wayland", .module = wayland_mod },
                .{ .name = "backend", .module = backend_mod },
            },
        }),
    });
    compositor_tests.root_module.addIncludePath(b.path("protocols"));
    compositor_tests.root_module.addObject(xdg_shell_c);
    compositor_tests.root_module.addObject(dmabuf_c);
    compositor_tests.root_module.addObject(activation_c);
    compositor_tests.root_module.addObject(viewporter_c);
    compositor_tests.root_module.addObject(fractional_scale_c);
    compositor_tests.step.dependOn(generate_protocols);
    compositor_tests.root_module.linkSystemLibrary("xkbcommon", .{});
    compositor_tests.root_module.linkSystemLibrary("wayland-server", .{});
    compositor_tests.root_module.linkSystemLibrary("libdrm", .{});
    compositor_tests.root_module.linkSystemLibrary("libinput", .{});
    compositor_tests.root_module.linkSystemLibrary("pixman-1", .{});
    compositor_tests.root_module.linkSystemLibrary("gbm", .{});
    compositor_tests.root_module.linkSystemLibrary("EGL", .{});
    compositor_tests.root_module.linkSystemLibrary("GLESv2", .{});
    compositor_tests.root_module.linkSystemLibrary("libudev", .{});
    compositor_tests.root_module.linkSystemLibrary("libseat", .{});
    compositor_tests.root_module.linkSystemLibrary("wayland-client", .{});
    compositor_tests.root_module.linkSystemLibrary("wayland-cursor", .{});
    compositor_tests.root_module.link_libc = true;
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
        file_tests.root_module.addIncludePath(b.path("protocols"));
        file_tests.root_module.addObject(xdg_shell_c);
        file_tests.root_module.addObject(dmabuf_c);
        file_tests.root_module.addObject(activation_c);
        file_tests.root_module.addObject(viewporter_c);
        file_tests.root_module.addObject(fractional_scale_c);
        file_tests.root_module.linkSystemLibrary("xkbcommon", .{});
        file_tests.root_module.linkSystemLibrary("libdrm", .{});
        file_tests.root_module.linkSystemLibrary("libinput", .{});
        file_tests.root_module.linkSystemLibrary("pixman-1", .{});
        file_tests.root_module.linkSystemLibrary("gbm", .{});
        file_tests.root_module.linkSystemLibrary("EGL", .{});
        file_tests.root_module.linkSystemLibrary("GLESv2", .{});
        file_tests.root_module.linkSystemLibrary("libudev", .{});
        file_tests.root_module.linkSystemLibrary("libseat", .{});
        file_tests.root_module.linkSystemLibrary("wayland-client", .{});
        file_tests.root_module.linkSystemLibrary("wayland-server", .{});
        file_tests.root_module.linkSystemLibrary("wayland-cursor", .{});
        // libdisplay-info no longer needed - using native Zig implementation
        // file_tests.root_module.linkSystemLibrary("libdisplay-info", .{});
        file_tests.root_module.link_libc = true;

        if (b.option([]const u8, "filter", "Test name filter")) |filter| {
            const filters = b.allocator.alloc([]const u8, 1) catch @panic("OOM");
            filters[0] = filter;
            file_tests.filters = filters;
        }

        const run_file_tests = b.addRunArtifact(file_tests);
        test_file_step.dependOn(&run_file_tests.step);
    }

    // Main benchmark executable (runs all benchmarks)
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmarks/root.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Use optimized builds for realistic measurements
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "core.cli", .module = core_cli_mod },
                .{ .name = "core.display", .module = core_display_mod },
                .{ .name = "backend", .module = backend_mod },
            },
        }),
    });
    benchmark_exe.root_module.addIncludePath(b.path("protocols"));
    benchmark_exe.root_module.addObject(xdg_shell_c);
    benchmark_exe.root_module.addObject(dmabuf_c);
    benchmark_exe.root_module.addObject(viewporter_c);
    benchmark_exe.root_module.addObject(fractional_scale_c);
    benchmark_exe.step.dependOn(generate_protocols);
    benchmark_exe.step.dependOn(generate_pnp);
    benchmark_exe.step.dependOn(generate_vic);
    benchmark_exe.root_module.linkSystemLibrary("libdrm", .{});
    benchmark_exe.root_module.linkSystemLibrary("libinput", .{});
    benchmark_exe.root_module.linkSystemLibrary("pixman-1", .{});
    benchmark_exe.root_module.linkSystemLibrary("gbm", .{});
    benchmark_exe.root_module.linkSystemLibrary("EGL", .{});
    benchmark_exe.root_module.linkSystemLibrary("GLESv2", .{});
    benchmark_exe.root_module.linkSystemLibrary("libudev", .{});
    benchmark_exe.root_module.linkSystemLibrary("libseat", .{});
    benchmark_exe.root_module.linkSystemLibrary("wayland-client", .{});
    benchmark_exe.root_module.linkSystemLibrary("wayland-cursor", .{});
    // Try to link libdisplay-info for comparison benchmark (optional)
    benchmark_exe.root_module.linkSystemLibrary("libdisplay-info", .{});
    benchmark_exe.root_module.link_libc = true;

    // Run benchmarks (pass arguments for specific benchmark selection)
    const benchmark_step = b.step("benchmark", "Run benchmarks (use -- --name <name> for specific benchmark)");
    const run_benchmark = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }
    benchmark_step.dependOn(&run_benchmark.step);
}
