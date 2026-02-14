//! Compositor module
//! Provides Wayland compositor functionality with surface management and protocol support

pub const compositor = @import("compositor.zig");
pub const surface = @import("surface.zig");

// Protocol implementations
pub const protocols = struct {
    pub const wl_compositor = @import("protocols/compositor.zig");
    pub const xdg_shell = @import("protocols/xdg_shell.zig");
};

// Convenience re-exports
pub const Compositor = compositor.Compositor;
pub const Surface = surface.Surface;
pub const BufferState = surface.BufferState;
pub const DamageState = surface.DamageState;
pub const Role = surface.Role;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("compositor.zig");
    _ = @import("surface.zig");
}
