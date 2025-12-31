const std = @import("std");
const backend = @import("backend");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Welcome to Sideswipe!\n", .{});

    // Test backend functionality
    const is_enabled = backend.util.Env.enabled("SIDESWIPE_ENABLED");
    const is_disabled = backend.util.Env.explicitlyDisabled("SIDESWIPE_DISABLED");
    const trace = backend.util.Env.isTrace();

    std.debug.print("Backend enabled: {}\n", .{is_enabled});
    std.debug.print("Backend explicitly disabled: {}\n", .{is_disabled});
    std.debug.print("Trace enabled: {}\n", .{trace});

    // Test format name conversion
    const invalid_format_name = try backend.util.Fmt.fourccToName(0, allocator);
    defer allocator.free(invalid_format_name);
    std.debug.print("Format 0 name: {s}\n", .{invalid_format_name});

    // Test with a known format (XRGB8888)
    const DRM_FORMAT_XRGB8888: u32 = ('X') | (@as(u32, 'R') << 8) | (@as(u32, '2') << 16) | (@as(u32, '4') << 24);
    const xrgb_name = try backend.util.Fmt.fourccToName(DRM_FORMAT_XRGB8888, allocator);
    defer allocator.free(xrgb_name);
    std.debug.print("XRGB8888 format name: {s}\n", .{xrgb_name});
}
