//! IPC module for inter-process communication and event signaling
//! Provides signal definitions for backend → compositor → external client communication
//! Implements protocol for external client communication

pub const signals = @import("signals.zig");
pub const protocol = @import("protocol.zig");
pub const message = @import("message.zig");
pub const socket = @import("socket.zig");
pub const object = @import("object.zig");
pub const spec = @import("spec.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("signals.zig");
    _ = @import("protocol.zig");
    _ = @import("message.zig");
    _ = @import("socket.zig");
    _ = @import("object.zig");
    _ = @import("spec.zig");
}
