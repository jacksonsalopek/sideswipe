//! Core types and definitions shared across all modules

pub const events = @import("events.zig");
pub const path = @import("path.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("events.zig");
    _ = @import("path.zig");
}
