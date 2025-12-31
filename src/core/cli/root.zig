//! CLI utilities including logging and argument parsing

pub const args = @import("args.zig");
pub const logger = @import("logger.zig");

// Re-export commonly used types
pub const Logger = logger.Logger;
pub const LoggerConnection = logger.LoggerConnection;
pub const LogLevel = logger.LogLevel;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("args.zig");
    _ = @import("logger.zig");
}
