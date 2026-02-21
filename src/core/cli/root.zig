//! CLI utilities including logging and argument parsing

const std = @import("std");

pub const args = @import("args.zig");
pub const logger = @import("logger.zig");

// Re-export commonly used types
pub const Logger = logger.Logger;
pub const LoggerConnection = logger.LoggerConnection;
pub const LogLevel = logger.LogLevel;

/// Global logger instance
/// This should be initialized at application startup
var global_logger: Logger = undefined;
var global_logger_initialized: bool = false;

/// Initialize the global logger
pub fn initGlobalLogger(allocator: std.mem.Allocator) void {
    global_logger = Logger.init(allocator);
    global_logger_initialized = true;
}

/// Deinitialize the global logger
pub fn deinitGlobalLogger() void {
    if (global_logger_initialized) {
        global_logger.deinit();
        global_logger_initialized = false;
    }
}

/// Configure the global logger settings
pub fn configureGlobalLogger(level: LogLevel, time_enabled: bool, color_enabled: bool) void {
    if (global_logger_initialized) {
        global_logger.setLogLevel(level);
        global_logger.setTime(time_enabled);
        global_logger.setEnableColor(color_enabled);
    }
}

/// Global log interface
pub const log = struct {
    pub fn trace(comptime fmt: []const u8, args_: anytype) void {
        if (global_logger_initialized) {
            global_logger.trace(fmt, args_);
        }
    }

    pub fn debug(comptime fmt: []const u8, args_: anytype) void {
        if (global_logger_initialized) {
            global_logger.debug(fmt, args_);
        }
    }

    pub fn info(comptime fmt: []const u8, args_: anytype) void {
        if (global_logger_initialized) {
            global_logger.info(fmt, args_);
        }
    }

    pub fn warn(comptime fmt: []const u8, args_: anytype) void {
        if (global_logger_initialized) {
            global_logger.warn(fmt, args_);
        }
    }

    pub fn err(comptime fmt: []const u8, args_: anytype) void {
        if (global_logger_initialized) {
            global_logger.err(fmt, args_);
        }
    }

    pub fn crit(comptime fmt: []const u8, args_: anytype) void {
        if (global_logger_initialized) {
            global_logger.crit(fmt, args_);
        }
    }
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("args.zig");
    _ = @import("logger.zig");
}
