//! Backend functionality

pub const allocator = @import("allocator.zig");
pub const backend = @import("backend.zig");
pub const buffer = @import("buffer.zig");
pub const input = @import("input.zig");
pub const libinput = @import("libinput.zig");
pub const misc = @import("misc.zig");
pub const session = @import("session.zig");
pub const swapchain = @import("swapchain.zig");
pub const util = @import("util.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("allocator.zig");
    _ = @import("backend.zig");
    _ = @import("buffer.zig");
    _ = @import("input.zig");
    _ = @import("libinput.zig");
    _ = @import("misc.zig");
    _ = @import("session.zig");
    _ = @import("swapchain.zig");
    _ = @import("util.zig");
}
