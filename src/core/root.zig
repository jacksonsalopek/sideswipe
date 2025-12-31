//! Core types and definitions shared across all modules

pub const events = @import("events.zig");
pub const path = @import("path.zig");

// String types
pub const string = @import("string.zig").string;
pub const c_string = @import("string.zig").c_string;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("events.zig");
    _ = @import("path.zig");
    _ = @import("string.zig");
}
