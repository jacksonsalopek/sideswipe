//! Core types and definitions shared across all modules

pub const events = @import("events.zig");
pub const path = @import("path.zig");
pub const testing = @import("testing.zig");
pub const vtable = @import("vtable.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("events.zig");
    _ = @import("path.zig");
    _ = @import("testing.zig");
    _ = @import("vtable.zig");
}
