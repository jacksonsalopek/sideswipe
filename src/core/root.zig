//! Core types and definitions shared across all modules

pub const cli = @import("cli/root.zig");
pub const events = @import("events.zig");
pub const path = @import("path.zig");
pub const vtable = @import("vtable.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("cli/root.zig");
    _ = @import("events.zig");
    _ = @import("path.zig");
    _ = @import("vtable.zig");
}
