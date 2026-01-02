//! Miscellaneous backend structures from aquamarine

const std = @import("std");
const core = @import("core");

/// OpenGL format structure
pub const GLFormat = struct {
    drm_format: u32 = 0,
    modifier: u64 = 0,
    external: bool = false,
};

/// DRM format with modifiers
pub const DRMFormat = struct {
    drm_format: u32 = 0, // DRM_FORMAT_INVALID
    modifiers: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) DRMFormat {
        _ = allocator;
        return .{
            .modifiers = std.ArrayList(u64){},
        };
    }

    pub fn deinit(self: *DRMFormat, allocator: std.mem.Allocator) void {
        self.modifiers.deinit(allocator);
    }

    pub fn addModifier(self: *DRMFormat, allocator: std.mem.Allocator, modifier: u64) !void {
        try self.modifiers.append(allocator, modifier);
    }
};

const testing = core.testing;

// Tests
test "GLFormat - initialization" {
    const format: GLFormat = .{};
    try testing.expectEqual(@as(u32, 0), format.drm_format);
    try testing.expectEqual(@as(u64, 0), format.modifier);
    try testing.expectEqual(false, format.external);
}

test "DRMFormat - initialization and modifiers" {
    var format = DRMFormat.init(testing.allocator);
    defer format.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), format.drm_format);
    try testing.expectEqual(@as(usize, 0), format.modifiers.items.len);

    try format.addModifier(testing.allocator, 123);
    try format.addModifier(testing.allocator, 456);

    try testing.expectEqual(@as(usize, 2), format.modifiers.items.len);
    try testing.expectEqual(@as(u64, 123), format.modifiers.items[0]);
    try testing.expectEqual(@as(u64, 456), format.modifiers.items[1]);
}
