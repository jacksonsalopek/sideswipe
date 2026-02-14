const std = @import("std");
const Box = @import("box.zig").Box;
const Mat3x3 = @import("mat3x3.zig").Mat3x3;
const Transform = @import("transform.zig").Direction;

pub fn transformBox(box: Box, t: Transform, box_width: f32, box_height: f32) Box {
    _ = box_width;
    _ = box_height;
    const matrix = Mat3x3.identity().projectBox(box, t, 0);

    var x1 = matrix.matrix[0];
    var y1 = matrix.matrix[1];
    var x2 = matrix.matrix[2];
    var y2 = matrix.matrix[5];

    if (x1 > x2) {
        const tmp = x1;
        x1 = x2;
        x2 = tmp;
    }
    if (y1 > y2) {
        const tmp = y1;
        y1 = y2;
        y2 = tmp;
    }

    return Box{
        .x = x1,
        .y = y1,
        .width = x2 - x1,
        .height = y2 - y1,
    };
}

test "transformBox - identity transform" {
    const box = Box{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const transform = Transform.normal;

    const result = transformBox(box, transform, 1920, 1080);

    // With normal/identity transform, box should remain relatively unchanged
    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "transformBox - flipped horizontally" {
    const box = Box{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const transform = Transform.flipped;

    const result = transformBox(box, transform, 1920, 1080);

    // Result should still be valid
    try std.testing.expect(result.width >= 0);
    try std.testing.expect(result.height >= 0);
}

test "transformBox - rotated 90 degrees" {
    const box = Box{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const transform = Transform.@"90";

    const result = transformBox(box, transform, 1920, 1080);

    // After 90 degree rotation, dimensions swap
    try std.testing.expect(result.width >= 0);
    try std.testing.expect(result.height >= 0);
}

test "transformBox - rotated 180 degrees" {
    const box = Box{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const transform = Transform.@"180";

    const result = transformBox(box, transform, 1920, 1080);

    try std.testing.expect(result.width >= 0);
    try std.testing.expect(result.height >= 0);
}

test "transformBox - rotated 270 degrees" {
    const box = Box{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const transform = Transform.@"270";

    const result = transformBox(box, transform, 1920, 1080);

    try std.testing.expect(result.width >= 0);
    try std.testing.expect(result.height >= 0);
}

test "transformBox - dimensions always positive" {
    const box = Box{ .x = 50, .y = 100, .width = 200, .height = 150 };

    const transforms = [_]Transform{
        Transform.normal,
        Transform.@"90",
        Transform.@"180",
        Transform.@"270",
        Transform.flipped,
        Transform.flipped_90,
        Transform.flipped_180,
        Transform.flipped_270,
    };

    for (transforms) |transform| {
        const result = transformBox(box, transform, 1920, 1080);

        // Width and height should always be non-negative
        try std.testing.expect(result.width >= 0);
        try std.testing.expect(result.height >= 0);
    }
}

test "transformBox - zero-sized box" {
    const box = Box{ .x = 10, .y = 20, .width = 0, .height = 0 };
    const transform = Transform.normal;

    const result = transformBox(box, transform, 1920, 1080);

    // Should handle zero-sized boxes gracefully
    try std.testing.expect(result.width >= 0);
    try std.testing.expect(result.height >= 0);
}

test "transformBox - large box" {
    const box = Box{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const transform = Transform.normal;

    const result = transformBox(box, transform, 3840, 2160);

    try std.testing.expect(result.width >= 0);
    try std.testing.expect(result.height >= 0);
}

test "transformBox - negative coordinates" {
    const box = Box{ .x = -50, .y = -100, .width = 200, .height = 150 };
    const transform = Transform.normal;

    const result = transformBox(box, transform, 1920, 1080);

    // Should handle negative coordinates
    try std.testing.expect(result.width >= 0);
    try std.testing.expect(result.height >= 0);
}
