//! Compositor module
//! Provides Wayland compositor functionality with surface management and protocol support

pub const compositor = @import("compositor.zig");
pub const surface = @import("surface.zig");
pub const output = @import("output.zig");
pub const scale = @import("scale.zig");
pub const layout = struct {
    pub const strip = @import("layout/strip.zig");
    pub const sheet = @import("layout/sheet.zig");
    pub const overrides = @import("layout/overrides.zig");
    pub const anim = @import("layout/anim.zig");
};
pub const scene = @import("scene/scene.zig");
pub const ring_geometry = @import("ring_geometry.zig");
pub const input = struct {
    pub const focus = @import("input/focus.zig");
    pub const gesture = @import("input/gesture.zig");
    pub const seat = @import("input/seat.zig");
    pub const trackpad = @import("input/trackpad.zig");
    pub const touch = @import("input/touch.zig");
    pub const accelerators = @import("input/accelerators.zig");
};

// Protocol implementations
pub const protocols = struct {
    pub const wl_compositor = @import("protocols/compositor.zig");
    pub const xdg_shell = @import("protocols/xdg_shell.zig");
    pub const output = @import("protocols/output.zig");
    pub const seat = @import("protocols/seat.zig");
    pub const data_device = @import("protocols/data_device.zig");
    pub const linux_dmabuf = @import("protocols/linux_dmabuf.zig");
    pub const wl_subcompositor = @import("protocols/subcompositor.zig");
    pub const xdg_activation = @import("protocols/xdg_activation.zig");
    pub const hidpi = @import("protocols/hidpi.zig");
    pub const sideswipe_shell = @import("protocols/sideswipe_shell.zig");
    pub const xdg_dialog = @import("protocols/xdg_dialog.zig");
    pub const xdg_decoration = @import("protocols/xdg_decoration.zig");
    pub const color = @import("protocols/color.zig");
    pub const tearing = @import("protocols/tearing.zig");
    pub const session_lock = @import("protocols/session_lock.zig");
    pub const idle = @import("protocols/idle.zig");
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
    _ = @import("input/focus.zig");
    _ = @import("input/gesture.zig");
    _ = @import("input/seat.zig");
    _ = @import("input/trackpad.zig");
    _ = @import("input/touch.zig");
    _ = @import("input/accelerators.zig");
    _ = @import("color.zig");
    _ = @import("lock.zig");
    _ = @import("font.zig");
    _ = @import("log_overlay.zig");
    _ = @import("layout/strip.zig");
    _ = @import("layout/sheet.zig");
    _ = @import("layout/overrides.zig");
    _ = @import("layout/anim.zig");
    _ = @import("ring_geometry.zig");
    _ = @import("scene/scene.zig");
    _ = @import("scale.zig");
    _ = @import("protocols/compositor.zig");
    _ = @import("protocols/output.zig");
    _ = @import("protocols/subcompositor.zig");
    _ = @import("protocols/sideswipe_shell.zig");
    _ = @import("protocols/xdg_dialog.zig");
    _ = @import("protocols/xdg_decoration.zig");
    _ = @import("protocols/color.zig");
    _ = @import("protocols/tearing.zig");
    _ = @import("protocols/session_lock.zig");
    _ = @import("protocols/idle.zig");
}
