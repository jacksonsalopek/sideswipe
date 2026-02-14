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

/// Signal handler for SIGINT and SIGTERM.
/// Terminates the server event loop, allowing cleanup to proceed.
fn handleSignal(sig: i32) callconv(.c) void {
    if (global_logger) |logger| {
        const sig_name: []const u8 = switch (sig) {
            std.posix.SIG.INT => "SIGINT",
            std.posix.SIG.TERM => "SIGTERM",
            else => "UNKNOWN",
        };
        logger.info("Received {s}, shutting down...", .{sig_name});
    }
    
    if (global_server) |srv| {
        srv.terminate();
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
    global_logger = &logger;
    defer global_logger = null;

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
    defer comp.deinit();

    // Register protocol globals
    logger.info("Registering protocol globals...", .{});
    try compositor.protocols.wl_compositor.register(comp);
    try compositor.protocols.xdg_shell.register(comp);
    try compositor.protocols.output.register(comp);
    try compositor.protocols.seat.register(comp);
    try compositor.protocols.data_device.register(comp);
    logger.info("Registered: wl_compositor, xdg_wm_base, wl_output, wl_seat, wl_data_device_manager", .{});

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
                    comp.attachBackend(c) catch |err| {
                        logger.warn("Failed to attach backend: {}", .{err});
                        logger.info("Continuing in display-server-only mode", .{});
                        c.deinit();
                        coord = null;
                        return;
                    };
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

    logger.info("Compositor ready!", .{});
    logger.info("Starting event loop...", .{});
    logger.info("Press Ctrl+C to exit", .{});

    // Run the main event loop
    server.run();

    logger.info("Event loop terminated, cleaning up...", .{});
}
