//! Compositor module
//! Provides Wayland compositor functionality with surface management and protocol support

pub const compositor = @import("compositor.zig");
pub const surface = @import("surface.zig");
pub const output = @import("output.zig");

// Protocol implementations
pub const protocols = struct {
    pub const wl_compositor = @import("protocols/compositor.zig");
    pub const xdg_shell = @import("protocols/xdg_shell.zig");
    pub const output = @import("protocols/output.zig");
    pub const seat = @import("protocols/seat.zig");
    pub const data_device = @import("protocols/data_device.zig");
};

// Convenience re-exports
pub const Compositor = compositor.Compositor;
pub const Surface = surface.Surface;
pub const BufferState = surface.BufferState;
pub const DamageState = surface.DamageState;
pub const Role = surface.Role;
pub const Output = output.Type;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("compositor.zig");
    _ = @import("surface.zig");
    _ = @import("output.zig");
}
