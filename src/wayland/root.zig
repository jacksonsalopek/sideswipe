//! Wayland server protocol implementation
//! Provides Zig wrappers around libwayland-server for compositor development

pub const c = @import("c.zig").c;
pub const client = @import("client.zig");
pub const display = @import("display.zig");
pub const event_loop = @import("event_loop.zig");
pub const global = @import("global.zig");
pub const server = @import("server.zig");
pub const test_setup = @import("test_setup.zig");

// Convenience re-exports
pub const Client = client.Client;
pub const Display = display.Display;
pub const EventLoop = event_loop.EventLoop;
pub const EventSource = event_loop.EventSource;
pub const Global = global.Global;
pub const Server = server.Server;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("c.zig");
    _ = @import("client.zig");
    _ = @import("display.zig");
    _ = @import("event_loop.zig");
    _ = @import("global.zig");
    _ = @import("server.zig");
}
