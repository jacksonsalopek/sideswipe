//! Backend functionality

pub const allocator = @import("allocator.zig");
pub const attachment = @import("attachment.zig");
pub const backend = @import("backend.zig");
pub const buffer = @import("buffer.zig");
pub const drm = @import("drm.zig");
pub const egl_formats = @import("egl_formats.zig");
pub const gbm = @import("gbm.zig");
pub const input = @import("input.zig");
pub const libinput = @import("libinput.zig");
pub const misc = @import("misc.zig");
pub const output = @import("output.zig");
pub const renderer = @import("renderer.zig");
pub const session = @import("session.zig");
pub const swapchain = @import("swapchain.zig");
pub const util = @import("util.zig");
pub const wayland = @import("wayland.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("allocator.zig");
    _ = @import("attachment.zig");
    _ = @import("backend.zig");
    _ = @import("buffer.zig");
    _ = @import("drm.zig");
    _ = @import("egl_formats.zig");
    _ = @import("gbm.zig");
    _ = @import("input.zig");
    _ = @import("libinput.zig");
    _ = @import("misc.zig");
    _ = @import("output.zig");
    _ = @import("renderer.zig");
    _ = @import("session.zig");
    _ = @import("swapchain.zig");
    _ = @import("util.zig");
    _ = @import("wayland.zig");
}
