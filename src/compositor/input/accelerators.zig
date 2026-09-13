//! Fixed I8 accelerators. Bindings are not configurable in v1.

const std = @import("std");
const testing = @import("core").testing;
const gesture = @import("gesture.zig");

pub const xkb_left: u32 = 0xff51;
pub const xkb_up: u32 = 0xff52;
pub const xkb_right: u32 = 0xff53;
pub const xkb_down: u32 = 0xff54;
pub const xkb_escape: u32 = 0xff1b;
pub const xkb_space: u32 = 0x0020;

pub const Action = enum {
    previous_column,
    next_column,
    switcher,
    shade,
    ring,
    back,
};

pub const Result = struct {
    action: Action,
    primitive: gesture.Primitive,
    stub: bool = false,
    focus_visible: bool = false,
};

/// Maps Super+arrows/space and Escape. Other modifiers suppress Super chords.
pub fn resolve(super: bool, extra_mod: bool, pressed: bool, keysym: u32, time_usec: u64) ?Result {
    if (!pressed) return null;
    if (keysym == xkb_escape) return back(time_usec);
    if (!super or extra_mod) return null;
    return switch (keysym) {
        xkb_left => column(.previous_column, .left, time_usec),
        xkb_right => column(.next_column, .right, time_usec),
        xkb_up => stub(.switcher, .up, time_usec),
        xkb_down => stub(.shade, .down, time_usec),
        xkb_space => .{
            .action = .ring,
            .primitive = .{ .hold = .{ .time_usec = time_usec, .point = .{} } },
            .focus_visible = true,
        },
        else => null,
    };
}

fn column(action: Action, direction: gesture.Direction, time_usec: u64) Result {
    return .{
        .action = action,
        .primitive = .{ .flick = .{ .time_usec = time_usec, .direction = direction } },
    };
}

fn stub(action: Action, direction: gesture.Direction, time_usec: u64) Result {
    return .{
        .action = action,
        .primitive = .{ .drag = .{
            .time_usec = time_usec,
            .direction = direction,
            .progress = 1,
        } },
        .stub = true,
    };
}

fn back(time_usec: u64) Result {
    return .{
        .action = .back,
        .primitive = .{ .back = .{ .time_usec = time_usec } },
    };
}

test "super arrows space and escape map to I8" {
    const left = resolve(true, false, true, xkb_left, 10).?;
    try testing.expectEqual(Action.previous_column, left.action);
    try testing.expectEqual(gesture.Direction.left, left.primitive.flick.direction);

    const right = resolve(true, false, true, xkb_right, 11).?;
    try testing.expectEqual(Action.next_column, right.action);
    try testing.expectEqual(gesture.Direction.right, right.primitive.flick.direction);

    const up = resolve(true, false, true, xkb_up, 12).?;
    try testing.expectEqual(Action.switcher, up.action);
    try testing.expect(up.stub);

    const down = resolve(true, false, true, xkb_down, 13).?;
    try testing.expectEqual(Action.shade, down.action);
    try testing.expect(down.stub);

    const ring = resolve(true, false, true, xkb_space, 14).?;
    try testing.expectEqual(Action.ring, ring.action);
    try testing.expect(ring.focus_visible);

    const escape = resolve(false, false, true, xkb_escape, 15).?;
    try testing.expectEqual(Action.back, escape.action);
}

test "super chords ignore extra modifiers and key releases" {
    try testing.expectNull(resolve(true, true, true, xkb_left, 1));
    try testing.expectNull(resolve(false, false, true, xkb_left, 1));
    try testing.expectNull(resolve(true, false, false, xkb_left, 1));
    try testing.expectNull(resolve(true, false, true, 'a', 1));
}
