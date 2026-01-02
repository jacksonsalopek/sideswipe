//! OS-level utilities for file operations and system interactions

pub const file = @import("file.zig");
pub const process = @import("process.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("file.zig");
    _ = @import("process.zig");
}
