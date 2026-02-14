pub const box = @import("box.zig");
pub const mat3 = @import("mat3.zig");
pub const mat3x3 = @import("mat3x3.zig");
pub const region = @import("region.zig");
pub const transform = @import("transform.zig");
pub const transforms = @import("transforms.zig");
pub const vector2d = @import("vector2d.zig");

// Re-export clean type names
pub const Vec2 = vector2d.Vec2;
pub const Box = box.Box;
pub const Region = region.Region;
pub const Mat3x3 = mat3x3.Mat3x3;
pub const Mat3f32 = mat3.Mat3f32;
pub const Mat3f64 = mat3.Mat3f64;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("vector2d.zig");
    _ = @import("box.zig");
    _ = @import("region.zig");
    _ = @import("mat3.zig");
    _ = @import("mat3x3.zig");
    _ = @import("transforms.zig");
}
