//! Backend functionality

pub const allocator = @import("allocator.zig");
pub const attachment = @import("attachment.zig");
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

// Re-export main backend types to avoid redundancy
const backend_impl = @import("backend.zig");
pub const Coordinator = backend_impl.Coordinator;
pub const Type = backend_impl.Type;
pub const RequestMode = backend_impl.RequestMode;
pub const ImplementationOptions = backend_impl.ImplementationOptions;
pub const Options = backend_impl.Options;
pub const PollFd = backend_impl.PollFd;
pub const Implementation = backend_impl.Implementation;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("allocator.zig");
    _ = @import("attachment.zig");
    _ = backend_impl; // Test backend.zig via re-export
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
