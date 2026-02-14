const std = @import("std");
const backend = @import("backend");
const core = @import("core");
const cli = @import("core.cli");
const wayland = @import("wayland");
const compositor = @import("compositor");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var parser = cli.args.Parser.init(allocator, args);
    defer parser.deinit();

    // Register options
    try parser.registerBoolOption("verbose", "v", "Enable verbose output");
    try parser.registerBoolOption("help", "h", "Show help message");
    try parser.registerBoolOption("backend", "b", "Enable backend for nested mode (Wayland)");
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

    // Configure logger based on arguments
    const verbose = parser.getBool("verbose") orelse false;
    logger.setTime(true);
    logger.setEnableColor(true);
    logger.setEnableRolling(true);
    logger.setLogLevel(if (verbose) .trace else .info);

    logger.info("Welcome to Sideswipe!", .{});

    if (verbose) {
        logger.debug("Verbose mode enabled", .{});
        logger.debug("Logger initialized successfully", .{});
    }

    // Initialize Wayland server
    logger.info("Initializing Wayland server...", .{});
    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    const socket_name = server.getSocketName();
    logger.info("Wayland server listening on: {s}", .{socket_name});
    logger.info("Set WAYLAND_DISPLAY={s} to connect clients", .{socket_name});

    // Initialize compositor
    logger.info("Initializing compositor...", .{});
    var comp = try compositor.Compositor.init(allocator, &server);
    defer comp.deinit();

    // Register protocol globals
    logger.info("Registering protocol globals...", .{});
    try compositor.protocols.wl_compositor.register(comp);
    try compositor.protocols.xdg_shell.register(comp);
    logger.info("Registered: wl_compositor, xdg_wm_base", .{});

    // Initialize backend if requested
    const enable_backend = parser.getBool("backend") orelse false;
    var coord: ?*backend.Coordinator = null;
    defer if (coord) |c| c.deinit();

    if (enable_backend) {
        logger.info("Initializing backend (nested Wayland mode)...", .{});

        const backend_opts = [_]backend.ImplementationOptions{
            .{ .backend_type = .wayland, .request_mode = .if_available },
        };

        // Create backend coordinator with logging
        const log_fn = struct {
            fn logBackend(level: backend.LogLevel, message: []const u8) void {
                const log_level: cli.LogLevel = switch (level) {
                    .trace => .trace,
                    .debug => .debug,
                    .warning => .warn,
                    .err => .err,
                    .critical => .err,
                };
                // Note: This is a simplified logger call - ideally we'd use the actual logger instance
                std.debug.print("[backend:{s}] {s}\n", .{ @tagName(log_level), message });
            }
        }.logBackend;

        if (backend.Coordinator.create(allocator, &backend_opts, .{
            .log_function = log_fn,
        })) |c| {
            // Try to start the backend
            if (c.start()) |started| {
                if (started) {
                    comp.attachBackend(c);
                    coord = c;
                    logger.info("Backend initialized successfully", .{});
                } else {
                    logger.warn("Backend failed to start", .{});
                    logger.info("Continuing in display-server-only mode", .{});
                    c.deinit();
                }
            } else |err| {
                logger.warn("Failed to start backend: {}", .{err});
                logger.info("Continuing in display-server-only mode", .{});
                c.deinit();
            }
        } else |err| {
            logger.warn("Failed to create backend coordinator: {}", .{err});
            logger.info("Continuing in display-server-only mode", .{});
        }
    } else {
        logger.info("Backend disabled - running in display-server-only mode", .{});
        logger.info("Use --backend flag to enable nested Wayland mode", .{});
    }

    // TODO: Set up signal handlers for graceful shutdown (SIGINT, SIGTERM)
    // TODO: Initialize input management (wl_seat, libinput)
    // TODO: Initialize output management (wl_output)

    logger.info("Compositor ready!", .{});
    logger.info("Starting event loop...", .{});
    logger.info("Press Ctrl+C to exit", .{});

    // Run the main event loop
    server.run();
}
