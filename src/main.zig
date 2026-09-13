const std = @import("std");
const backend = @import("backend");
const core = @import("core");
const cli = @import("core.cli");
const wayland = @import("wayland");
const compositor = @import("compositor");

/// Global server reference for signal handlers.
/// Signal handlers cannot capture context, so we need a global reference.
var global_server: ?*wayland.Server = null;
var global_logger: ?*cli.Logger = null;
var event_loop_running = std.atomic.Value(bool).init(false);
const Signal = @TypeOf(std.posix.SIG.INT);

fn signalName(sig: Signal) []const u8 {
    return switch (sig) {
        std.posix.SIG.INT => "SIGINT",
        std.posix.SIG.TERM => "SIGTERM",
        else => "UNKNOWN",
    };
}

/// Signal handler for SIGINT and SIGTERM.
/// Terminates the server event loop, allowing cleanup to proceed.
fn handleSignal(sig: Signal) callconv(.c) void {
    if (global_logger) |logger| {
        logger.info("Received {s}, shutting down...", .{signalName(sig)});
    }
    if (global_server) |srv| {
        srv.terminate();
    }
    if (!event_loop_running.load(.seq_cst)) {
        std.c._exit(1);
    }
}

/// Sets up signal handlers for graceful shutdown.
fn setupSignalHandlers() !void {
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

/// Attempts to initialize selected output and input backends.
/// Returns null on failure and logs appropriate messages.
fn tryInitializeBackend(
    allocator: std.mem.Allocator,
    comp: *compositor.Compositor,
    logger: *cli.Logger,
    nested: bool,
    physical_input: bool,
    parent_display: ?[:0]const u8,
    own_socket: []const u8,
) ?*backend.Coordinator {
    logger.info("Initializing selected runtime backends...", .{});

    const backend_opts = [_]backend.ImplementationOptions{
        .{
            .backend_type = selectedBackendType(nested, physical_input),
            .request_mode = .if_available,
        },
    };

    const coord = backend.Coordinator.create(allocator, &backend_opts, .{
        .physical_input = physical_input and !nested,
        .parent_display = parent_display,
        .own_socket = own_socket,
    }) catch |err| {
        logger.warn("Failed to create backend coordinator: {}", .{err});
        logger.info("Continuing in display-server-only mode", .{});
        return null;
    };

    const started = coord.start() catch |err| blk: {
        logger.warn("Failed to start backend: {}", .{err});
        break :blk false;
    };

    if (!started) {
        logger.warn("Backend failed to start", .{});
        logger.info("Continuing in display-server-only mode", .{});
        coord.deinit();
        return null;
    }

    comp.attachBackend(coord) catch |err| {
        logger.warn("Failed to attach backend: {}", .{err});
        logger.info("Continuing in display-server-only mode", .{});
        coord.deinit();
        return null;
    };

    logger.info("Selected runtime backends initialized successfully", .{});
    return coord;
}

fn selectedBackendType(nested: bool, physical_input: bool) backend.Type {
    if (nested) return .wayland;
    if (physical_input) return .drm;
    return .null;
}

fn startSelectedBackend(
    allocator: std.mem.Allocator,
    comp: *compositor.Compositor,
    logger: *cli.Logger,
    enable_backend: bool,
    physical_input: bool,
    parent_display: ?[:0]const u8,
    own_socket: []const u8,
) ?*backend.Coordinator {
    const nested = backend.wayland.shouldStartNested(enable_backend, parent_display, own_socket);
    const has_parent_display = backend.wayland.isUsableParentDisplay(parent_display, own_socket);
    const has_parent = backend.drm.hasLiveParentCompositor(
        has_parent_display,
        core.env.get("XDG_SESSION_TYPE"),
    );
    const native = backend.drm.shouldStartNative(physical_input, has_parent);

    if (enable_backend and !nested) {
        logger.err("Nested backend requires a parent Wayland compositor", .{});
        logger.info("WAYLAND_DISPLAY is unset or points at this process", .{});
        logger.info("Continuing in display-server-only mode", .{});
    }
    if (physical_input and nested) {
        logger.info("Ignoring --physical-input in nested Wayland mode", .{});
    }
    if (physical_input and has_parent and !nested) {
        logger.err("Refusing native DRM while a parent compositor is running", .{});
        logger.info("Switch to a TTY and unset WAYLAND_DISPLAY and XDG_SESSION_TYPE=wayland", .{});
    }

    if (nested) {
        return tryInitializeBackend(allocator, comp, logger, true, false, parent_display, own_socket);
    }
    if (native) {
        logger.info("Starting native DRM backend with physical input", .{});
        return tryInitializeBackend(allocator, comp, logger, false, true, parent_display, own_socket);
    }
    if (!enable_backend and !physical_input) {
        logger.info("Backend disabled - running in display-server-only mode", .{});
        logger.info("Use --backend for nested Wayland or --physical-input for native DRM", .{});
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse command-line arguments
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    var arg_iterator = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_iterator.deinit();
    while (arg_iterator.next()) |arg| try args.append(allocator, arg);

    var parser = cli.args.Parser.init(allocator, args.items);
    defer parser.deinit();

    // Register options
    try parser.registerBoolOption("verbose", "v", "Enable verbose output");
    try parser.registerBoolOption("help", "h", "Show help message");
    try parser.registerBoolOption("backend", "b", "Enable backend for nested mode (Wayland)");
    try parser.registerBoolOption("physical-input", "p", "Enable native DRM and the physical libinput session");
    try parser.registerStringOption("output", "o", "Output file");

    // Try to parse, show help on error
    parser.parse() catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        const help = try parser.getDescription("Sideswipe - A Wayland compositor", null);
        defer allocator.free(help);
        std.debug.print("{s}\n", .{help});
        return;
    };

    // Show help if requested
    if (parser.getBool("help") orelse false) {
        const help = try parser.getDescription("Sideswipe - A Wayland compositor", null);
        defer allocator.free(help);
        std.debug.print("{s}\n", .{help});
        return;
    }

    // Initialize logger
    var logger = cli.Logger.init(allocator);
    defer logger.deinit();
    global_logger = &logger;
    defer global_logger = null;

    // Configure logger based on arguments
    const verbose = parser.getBool("verbose") orelse false;
    const log_level: cli.LogLevel = if (verbose) .trace else .info;

    logger.setTime(true);
    logger.setEnableColor(true);
    logger.setEnableRolling(true);
    logger.setLogLevel(log_level);

    // Initialize and configure global logger for backend/other modules
    cli.initGlobalLogger(allocator);
    defer cli.deinitGlobalLogger();
    cli.configureGlobalLogger(log_level, true, true);

    logger.info("Welcome to Sideswipe!", .{});

    if (verbose) {
        logger.debug("Verbose mode enabled", .{});
        logger.debug("Logger initialized successfully", .{});
    }

    // Initialize Wayland server
    logger.info("Initializing Wayland server...", .{});
    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();
    global_server = &server;
    defer global_server = null;

    const socket_name = server.getSocketName();
    logger.info("Wayland server listening on: {s}", .{socket_name});
    logger.info("Set WAYLAND_DISPLAY={s} to connect clients", .{socket_name});

    // Set up signal handlers for graceful shutdown
    try setupSignalHandlers();
    logger.info("Signal handlers registered (SIGINT, SIGTERM)", .{});

    // Initialize compositor
    logger.info("Initializing compositor...", .{});
    var comp = try compositor.Compositor.init(allocator, &server, &logger);

    // Register protocol globals
    logger.info("Registering protocol globals...", .{});
    try compositor.protocols.wl_compositor.register(comp);
    try compositor.protocols.xdg_shell.register(comp);
    try compositor.protocols.output.register(comp);
    try compositor.protocols.seat.register(comp);
    try compositor.protocols.data_device.register(comp);
    try compositor.protocols.linux_dmabuf.register(comp);
    try compositor.protocols.wl_subcompositor.register(comp);
    try compositor.protocols.xdg_activation.register(comp);
    try compositor.protocols.hidpi.register(comp);
    try compositor.protocols.sideswipe_shell.register(comp);
    try compositor.protocols.xdg_dialog.register(comp);
    try compositor.protocols.xdg_decoration.register(comp);
    try compositor.protocols.color.register(comp);
    try compositor.protocols.tearing.register(comp);
    try compositor.protocols.session_lock.register(comp);
    try compositor.protocols.idle.register(comp);
    logger.info("Registered core globals including fractional-scale, viewporter, dialog, decoration, and sideswipe_shell_v1", .{});

    // Initialize backend if requested
    const enable_backend = parser.getBool("backend") orelse false;
    const enable_physical_input = parser.getBool("physical-input") orelse false;
    const parent_display = core.env.get("WAYLAND_DISPLAY");
    var coord: ?*backend.Coordinator = null;
    defer {
        comp.destroyClients();
        comp.deinit();
        if (coord) |c| c.deinit();
    }

    coord = startSelectedBackend(
        allocator,
        comp,
        &logger,
        enable_backend,
        enable_physical_input,
        parent_display,
        socket_name,
    );

    try compositor.protocols.sideswipe_shell.attach(comp);

    logger.info("Compositor ready!", .{});
    logger.info("Starting event loop...", .{});
    logger.info("Press Super+Shift+Q or Ctrl+C to exit", .{});

    event_loop_running.store(true, .seq_cst);
    server.run();

    logger.info("Event loop terminated, cleaning up...", .{});
}
