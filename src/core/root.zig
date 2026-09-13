//! Core types and definitions shared across all modules

pub const backend = @import("backend.zig");
pub const config = @import("config.zig");
pub const env = @import("env.zig");
pub const events = @import("events.zig");
pub const path = @import("path.zig");
pub const testing = @import("testing.zig");
pub const unix = @import("unix.zig");
pub const vtable = @import("vtable.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("backend.zig");
    _ = @import("config.zig");
    _ = @import("env.zig");
    _ = @import("events.zig");
    _ = @import("path.zig");
    _ = @import("testing.zig");
    _ = @import("unix.zig");
    _ = @import("vtable.zig");
}
