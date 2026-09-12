const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn get(name: []const u8) ?[:0]const u8 {
    const name_z = std.posix.toPosixPath(name) catch return null;
    const value = getenv(&name_z) orelse return null;
    return std.mem.span(value);
}

test "get returns process environment values" {
    try std.testing.expect(get("PATH") != null);
}
