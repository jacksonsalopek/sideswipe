//! Thread-safe, general purpose logger inspired by hyprutils
//! Supports multiple log levels, colored output, file logging, and rolling logs

const std = @import("std");
const builtin = @import("builtin");

/// Log level enumeration
pub const LogLevel = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    crit = 5,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERR",
            .crit => "CRIT",
        };
    }

    pub fn toColorString(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "\x1b[1;34mTRACE\x1b[0m",
            .debug => "\x1b[1;32mDEBUG\x1b[0m",
            .info => "\x1b[1;36mINFO\x1b[0m",
            .warn => "\x1b[1;33mWARN\x1b[0m",
            .err => "\x1b[1;31mERR\x1b[0m",
            .crit => "\x1b[1;35mCRIT\x1b[0m",
        };
    }
};

/// Thread-safe logger with configurable output destinations
pub const Logger = struct {
    allocator: std.mem.Allocator,
    log_level: LogLevel,
    mutex: std.Thread.Mutex,

    // Configuration flags
    time_enabled: bool,
    stdout_enabled: bool,
    file_enabled: bool,
    color_enabled: bool,
    rolling_enabled: bool,

    // File output
    log_file: ?std.fs.File,
    log_file_path: ?[]const u8,

    // Rolling log buffer
    rolling_log: std.ArrayList(u8),

    const Self = @This();
    const ROLLING_LOG_SIZE: usize = 4096;

    /// Initialize a new logger with default settings
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .log_level = .debug,
            .mutex = .{},
            .time_enabled = false,
            .stdout_enabled = true,
            .file_enabled = false,
            .color_enabled = true,
            .rolling_enabled = false,
            .log_file = null,
            .log_file_path = null,
            .rolling_log = std.ArrayList(u8){},
        };
    }

    /// Clean up logger resources
    pub fn deinit(self: *Self) void {
        if (self.log_file) |file| {
            file.close();
        }
        if (self.log_file_path) |path| {
            self.allocator.free(path);
        }
        self.rolling_log.deinit(self.allocator);
    }

    /// Set the minimum log level
    pub fn setLogLevel(self: *Self, level: LogLevel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.log_level = level;
    }

    /// Enable or disable timestamps in log messages
    pub fn setTime(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.time_enabled = enabled;
    }

    /// Enable or disable stdout output
    pub fn setEnableStdout(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stdout_enabled = enabled;
    }

    /// Enable or disable color output (only affects stdout)
    pub fn setEnableColor(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.color_enabled = enabled;
    }

    /// Enable or disable rolling log buffer
    pub fn setEnableRolling(self: *Self, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.rolling_enabled = enabled;
    }

    /// Set output file for logging
    pub fn setOutputFile(self: *Self, file_path: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Close existing file if any
        if (self.log_file) |file| {
            file.close();
            self.log_file = null;
        }
        if (self.log_file_path) |path| {
            self.allocator.free(path);
            self.log_file_path = null;
        }

        if (file_path) |path| {
            // Open or create the log file
            const file = try std.fs.cwd().createFile(path, .{
                .truncate = true,
                .read = false,
            });
            self.log_file = file;
            self.log_file_path = try self.allocator.dupe(u8, path);
            self.file_enabled = true;
        } else {
            self.file_enabled = false;
        }
    }

    /// Get the current rolling log buffer contents
    pub fn getRollingLog(self: *Self) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.rolling_log.items;
    }

    /// Log a message at the specified level
    pub fn log(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        // Quick check without lock for optimization
        if (@intFromEnum(level) < @intFromEnum(self.log_level)) {
            return;
        }
        if (!self.stdout_enabled and !self.file_enabled and !self.rolling_enabled) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-check with lock held
        if (@intFromEnum(level) < @intFromEnum(self.log_level)) {
            return;
        }

        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(self.allocator);

        const writer = buffer.writer(self.allocator);

        // Build the log message
        self.buildLogMessage(writer, level, fmt, args) catch return;

        const message = buffer.items;

        // Output to stdout
        if (self.stdout_enabled) {
            self.writeToStdout(level, message) catch {};
        }

        // Output to file
        if (self.file_enabled) {
            if (self.log_file) |file| {
                const prefix = level.toString();
                var file_buffer: [4096]u8 = undefined;
                var file_writer = file.writer(&file_buffer);
                var file_io = &file_writer.interface;
                file_io.print("{s} ]: {s}\n", .{ prefix, message }) catch {};
                file_io.flush() catch {};
            }
        }

        // Append to rolling log
        if (self.rolling_enabled) {
            const prefix = level.toString();
            var rolling_buffer = std.ArrayList(u8){};
            defer rolling_buffer.deinit(self.allocator);

            rolling_buffer.writer(self.allocator).print("{s} ]: {s}", .{ prefix, message }) catch return;
            self.appendToRolling(rolling_buffer.items) catch {};
        }
    }

    /// Build the formatted log message
    fn buildLogMessage(
        self: *Self,
        writer: anytype,
        level: LogLevel,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        _ = level;
        _ = self;

        // Just add the actual message (timestamp and level are handled in writeToStdout)
        try writer.print(fmt, args);
    }

    /// Write message to stdout with optional coloring
    fn writeToStdout(self: *Self, level: LogLevel, message: []const u8) !void {
        const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        var buffer: [4096]u8 = undefined;
        var stdout_writer = stdout_file.writer(&buffer);
        var stdout = &stdout_writer.interface;

        // Print timestamp first if enabled
        if (self.time_enabled) {
            const timestamp = std.time.timestamp();
            const seconds_in_day = @rem(timestamp, 86400);
            const hours: u64 = @intCast(@divFloor(seconds_in_day, 3600));
            const minutes: u64 = @intCast(@divFloor(@rem(seconds_in_day, 3600), 60));
            const seconds: u64 = @intCast(@rem(seconds_in_day, 60));

            try stdout.print("[{d:0>2}:{d:0>2}:{d:0>2}] ", .{ hours, minutes, seconds });
        }

        // Print log level with optional coloring
        const prefix = if (self.color_enabled) level.toColorString() else level.toString();
        try stdout.print("{s}: {s}\n", .{ prefix, message });
        try stdout.flush();
    }

    /// Append message to rolling log buffer
    fn appendToRolling(self: *Self, message: []const u8) !void {
        if (self.rolling_log.items.len > 0) {
            try self.rolling_log.append(self.allocator, '\n');
        }
        try self.rolling_log.appendSlice(self.allocator, message);

        // Trim if over size
        if (self.rolling_log.items.len > ROLLING_LOG_SIZE) {
            // Find the first newline after the excess data
            const excess = self.rolling_log.items.len - ROLLING_LOG_SIZE;
            var newline_pos: usize = excess;

            while (newline_pos < self.rolling_log.items.len) : (newline_pos += 1) {
                if (self.rolling_log.items[newline_pos] == '\n') {
                    break;
                }
            }

            if (newline_pos < self.rolling_log.items.len) {
                // Remove everything before this newline
                const new_start = newline_pos + 1;
                const new_len = self.rolling_log.items.len - new_start;
                std.mem.copyForwards(u8, self.rolling_log.items[0..new_len], self.rolling_log.items[new_start..]);
                self.rolling_log.shrinkRetainingCapacity(new_len);
            }
        }
    }

    /// Convenience method: log at trace level
    pub fn trace(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    /// Convenience method: log at debug level
    pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    /// Convenience method: log at info level
    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    /// Convenience method: log at warn level
    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    /// Convenience method: log at error level
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    /// Convenience method: log at critical level
    pub fn crit(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.crit, fmt, args);
    }
};

/// A connection handle to a logger that can have its own log level and name
pub const LoggerConnection = struct {
    logger: *Logger,
    log_level: LogLevel,
    name: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new connection to a logger
    pub fn init(allocator: std.mem.Allocator, logger: *Logger) Self {
        return .{
            .logger = logger,
            .log_level = logger.log_level,
            .name = null,
            .allocator = allocator,
        };
    }

    /// Clean up connection resources
    pub fn deinit(self: *Self) void {
        if (self.name) |name| {
            self.allocator.free(name);
        }
    }

    /// Set the name for this connection (will be included in log messages)
    pub fn setName(self: *Self, name: []const u8) !void {
        if (self.name) |old_name| {
            self.allocator.free(old_name);
        }
        self.name = try self.allocator.dupe(u8, name);
    }

    /// Set the log level for this connection
    pub fn setLogLevel(self: *Self, level: LogLevel) void {
        self.log_level = level;
    }

    /// Log a message through this connection
    pub fn log(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.log_level)) {
            return;
        }

        if (self.name) |name| {
            // Build the full message with the name prefix
            var buffer = std.ArrayList(u8){};
            defer buffer.deinit(self.allocator);

            buffer.writer(self.allocator).print("from {s} ", .{name}) catch return;
            buffer.writer(self.allocator).print(fmt, args) catch return;

            self.logger.log(level, "{s}", .{buffer.items});
        } else {
            self.logger.log(level, fmt, args);
        }
    }

    /// Convenience method: log at trace level
    pub fn trace(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    /// Convenience method: log at debug level
    pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    /// Convenience method: log at info level
    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    /// Convenience method: log at warn level
    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    /// Convenience method: log at error level
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    /// Convenience method: log at critical level
    pub fn crit(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.crit, fmt, args);
    }
};

// Tests
test "Logger - basic initialization" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    try testing.expect(logger.log_level == .debug);
    try testing.expect(logger.stdout_enabled == true);
    try testing.expect(logger.color_enabled == true);
}

test "Logger - basic logging with rolling" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);
    logger.setEnableRolling(true);

    logger.debug("Hello!", .{});

    const rolling = logger.getRollingLog();
    try testing.expect(std.mem.indexOf(u8, rolling, "DEBUG ]: Hello!") != null);
}

test "Logger - log level filtering" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);
    logger.setEnableRolling(true);

    // Default level is debug, so trace should be filtered
    logger.trace("This is a trace message", .{});
    logger.debug("Hello!", .{});

    var rolling = logger.getRollingLog();
    try testing.expect(std.mem.indexOf(u8, rolling, "TRACE") == null);
    try testing.expect(std.mem.indexOf(u8, rolling, "DEBUG ]: Hello!") != null);

    // Now set to trace level
    logger.setLogLevel(.trace);
    logger.trace("Hello, {s}!", .{"Trace"});

    rolling = logger.getRollingLog();
    try testing.expect(std.mem.indexOf(u8, rolling, "TRACE ]: Hello, Trace!") != null);
}

test "Logger - log level filtering warn and above" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setLogLevel(.warn);
    logger.setEnableStdout(false);
    logger.setEnableRolling(true);

    // These should be filtered out
    logger.trace("This is a trace message", .{});
    logger.debug("This is a debug message", .{});

    // These should appear
    logger.warn("This is a warning", .{});
    logger.err("This is an error", .{});

    const rolling = logger.getRollingLog();
    try testing.expect(std.mem.indexOf(u8, rolling, "trace") == null);
    try testing.expect(std.mem.indexOf(u8, rolling, "debug") == null);
    try testing.expect(std.mem.indexOf(u8, rolling, "warning") != null);
    try testing.expect(std.mem.indexOf(u8, rolling, "error") != null);
}

test "Logger - rolling log size limit" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);
    logger.setEnableRolling(true);

    // Spam many messages to exceed rolling log size (similar to hyprutils test)
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        logger.err("Oh noes!!!", .{});
    }

    const rolling = logger.getRollingLog();
    try testing.expect(rolling.len < Logger.ROLLING_LOG_SIZE);
    // Test that trimming is done correctly - should start with ERR
    try testing.expect(std.mem.startsWith(u8, rolling, "ERR"));
}

test "LoggerConnection - basic usage" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);
    logger.setEnableRolling(true);
    logger.setLogLevel(.trace);

    logger.debug("Hello!", .{});

    var conn = LoggerConnection.init(testing.allocator, &logger);
    defer conn.deinit();

    try conn.setName("conn");
    conn.trace("Hello from connection!", .{});

    const rolling = logger.getRollingLog();
    try testing.expect(std.mem.indexOf(u8, rolling, "DEBUG ]: Hello!") != null);
    try testing.expect(std.mem.indexOf(u8, rolling, "from conn") != null);
    try testing.expect(std.mem.indexOf(u8, rolling, "Hello from connection!") != null);
}

test "LoggerConnection - per-connection log level" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);
    logger.setEnableRolling(true);
    logger.setLogLevel(.trace);

    var conn = LoggerConnection.init(testing.allocator, &logger);
    defer conn.deinit();

    try conn.setName("conn");

    // Log should appear
    conn.trace("Hello from connection!", .{});
    var rolling = logger.getRollingLog();
    const len_before = rolling.len;
    try testing.expect(std.mem.indexOf(u8, rolling, "Hello from connection!") != null);

    // Set connection level to WARN
    conn.setLogLevel(.warn);

    // Debug should be filtered by connection
    conn.debug("This should not appear", .{});
    rolling = logger.getRollingLog();
    try testing.expect(rolling.len == len_before);
    try testing.expect(std.mem.indexOf(u8, rolling, "This should not appear") == null);
}

test "Logger - disable rolling stops logging to buffer" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);
    logger.setEnableRolling(true);

    logger.debug("Should be in rolling", .{});
    var rolling = logger.getRollingLog();
    const len_with_rolling = rolling.len;
    try testing.expect(len_with_rolling > 0);

    // Disable rolling
    logger.setEnableRolling(false);
    logger.err("Should not be in rolling", .{});

    rolling = logger.getRollingLog();
    try testing.expect(rolling.len == len_with_rolling);
    try testing.expect(std.mem.indexOf(u8, rolling, "Should not be in rolling") == null);
}

test "Logger - disable stdout and file stops logging when rolling disabled" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);
    logger.setEnableRolling(true);

    logger.debug("In rolling", .{});

    // Disable rolling, now nothing should log
    logger.setEnableRolling(false);
    logger.err("Should not log anywhere", .{});

    const rolling = logger.getRollingLog();
    try testing.expect(std.mem.indexOf(u8, rolling, "Should not log anywhere") == null);
}

test "Logger - file output" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    logger.setEnableStdout(false);

    // Set output file
    try logger.setOutputFile("/tmp/test_logger.log");
    logger.debug("Hi file!", .{});

    // Clear file output
    try logger.setOutputFile(null);

    // Read and verify
    const file_content = std.fs.cwd().readFileAlloc(testing.allocator, "/tmp/test_logger.log", 1024) catch |err| {
        std.debug.print("Failed to read log file: {}\n", .{err});
        return err;
    };
    defer testing.allocator.free(file_content);

    try testing.expect(std.mem.indexOf(u8, file_content, "DEBUG ]: Hi file!") != null);

    // Clean up
    std.fs.cwd().deleteFile("/tmp/test_logger.log") catch {};
}

test "Logger - time and color configuration" {
    const testing = std.testing;
    var logger = Logger.init(testing.allocator);
    defer logger.deinit();

    // Just verify these don't crash
    logger.setTime(true);
    logger.setEnableColor(true);
    logger.setEnableStdout(false);
    logger.setEnableRolling(true);

    logger.warn("Timed warning!", .{});

    logger.setEnableColor(false);
    logger.crit("Critical!", .{});

    const rolling = logger.getRollingLog();
    try testing.expect(rolling.len > 0);
}
