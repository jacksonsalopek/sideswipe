const std = @import("std");
const backend = @import("backend");
const core = @import("core");
const cli = @import("core.cli");
const wayland = @import("wayland");

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

    // TODO: Set up signal handlers for graceful shutdown (SIGINT, SIGTERM)

    // TODO: Register protocol globals
    // - wl_compositor for surface creation
    // - wl_subcompositor for subsurfaces
    // - xdg_wm_base for XDG shell protocol
    // - wl_seat for input devices
    // - wl_output for display information
    // - wl_data_device_manager for clipboard/drag-and-drop

    // TODO: Initialize backend
    // - Detect and initialize DRM/KMS for native rendering
    // - Or use Wayland backend for nested compositor testing
    // - Set up output configuration
    // - Initialize renderer (EGL/OpenGL ES)

    // TODO: Initialize input management
    // - Set up libinput for keyboard/mouse/touch
    // - Create seat and input device handlers

    logger.info("Starting compositor event loop...", .{});
    logger.info("Press Ctrl+C to exit", .{});

    // Run the main event loop
    // In production, we'd integrate with:
    // - Backend rendering loop
    // - Input event processing
    // - Client protocol handlers
    // - Animation frame callbacks
    server.run();
}
