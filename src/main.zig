const std = @import("std");
const backend = @import("backend");
const core = @import("core");
const cli = @import("core.cli");

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

    if (parser.getString("output")) |output| {
        logger.info("Output file: {s}", .{output});
    }

    // Test backend functionality
    const is_enabled = backend.util.Env.enabled("SIDESWIPE_ENABLED");
    const is_disabled = backend.util.Env.explicitlyDisabled("SIDESWIPE_DISABLED");
    const trace = backend.util.Env.isTrace();

    logger.debug("Backend enabled: {}", .{is_enabled});
    logger.debug("Backend explicitly disabled: {}", .{is_disabled});
    logger.trace("Trace enabled: {}", .{trace});

    // Test format name conversion
    const invalid_format_name = try backend.util.Fmt.fourccToName(0, allocator);
    defer allocator.free(invalid_format_name);
    logger.debug("Format 0 name: {s}", .{invalid_format_name});

    // Test with a known format (XRGB8888)
    const DRM_FORMAT_XRGB8888: u32 = ('X') | (@as(u32, 'R') << 8) | (@as(u32, '2') << 16) | (@as(u32, '4') << 24);
    const xrgb_name = try backend.util.Fmt.fourccToName(DRM_FORMAT_XRGB8888, allocator);
    defer allocator.free(xrgb_name);
    logger.debug("XRGB8888 format name: {s}", .{xrgb_name});

    // Demonstrate different log levels
    logger.trace("This is a trace message", .{});
    logger.warn("This is a warning", .{});
    logger.err("This is an error (don't worry, it's just a demo)", .{});

    // Demonstrate logger connection
    var conn = cli.LoggerConnection.init(allocator, &logger);
    defer conn.deinit();
    try conn.setName("MainModule");
    conn.debug("Message from logger connection", .{});

    logger.info("Sideswipe initialization complete", .{});
}
