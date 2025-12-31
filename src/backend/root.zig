//! Backend functionality

pub const util = @import("util.zig");
pub const libinput = @import("libinput.zig");
pub const input = @import("input.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("util.zig");
    _ = @import("libinput.zig");
    _ = @import("input.zig");
}
