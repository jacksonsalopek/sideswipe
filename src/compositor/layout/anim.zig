//! Spring interpolation for tile resize. One configure uses the final size.

const std = @import("std");
const testing = @import("core").testing;
const strip = @import("strip.zig");

const stiffness: f32 = 180;
const damping: f32 = 24;
const settle_position: f32 = 0.5;
const settle_velocity: f32 = 8;

pub const Vec = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const Scale = struct {
    x: f32,
    y: f32,
};

pub const State = struct {
    current: Vec = .{},
    velocity: Vec = .{},
    target: Vec = .{},
    configured: strip.Size = .{ .width = 0, .height = 0 },
    seeded: bool = false,

    pub fn display(self: State) strip.Geometry {
        return .{
            .x = @intFromFloat(@round(self.current.x)),
            .y = @intFromFloat(@round(self.current.y)),
            .width = @max(1, @as(i32, @intFromFloat(@round(self.current.width)))),
            .height = @max(1, @as(i32, @intFromFloat(@round(self.current.height)))),
        };
    }

    pub fn targetGeometry(self: State) strip.Geometry {
        return .{
            .x = @intFromFloat(@round(self.target.x)),
            .y = @intFromFloat(@round(self.target.y)),
            .width = @max(1, @as(i32, @intFromFloat(@round(self.target.width)))),
            .height = @max(1, @as(i32, @intFromFloat(@round(self.target.height)))),
        };
    }
};

/// Starts or retargets a spring. First assignment snaps so map is immediate.
pub fn retarget(state: *State, target: strip.Geometry) void {
    const next = vecFrom(target);
    state.target = next;
    if (!state.seeded) {
        snap(state, next);
        return;
    }
    if (nearlyEqual(state.current, next)) snap(state, next);
}

/// Advances the spring. `dt` is seconds. Returns true while still moving.
pub fn tick(state: *State, dt: f32) bool {
    if (!state.seeded) return false;
    const step = std.math.clamp(dt, 0, 1.0 / 30.0);
    integrate(&state.current.x, &state.velocity.x, state.target.x, step);
    integrate(&state.current.y, &state.velocity.y, state.target.y, step);
    integrate(&state.current.width, &state.velocity.width, state.target.width, step);
    integrate(&state.current.height, &state.velocity.height, state.target.height, step);
    if (!settled(state.*)) return true;
    snap(state, state.target);
    return false;
}

/// Snaps when the committed buffer matches the target / newly configured size.
pub fn earlySwap(state: *State, committed: strip.Size) bool {
    const target = state.targetGeometry();
    if (!matchesFinal(committed, .{ .width = target.width, .height = target.height })) return false;
    snap(state, state.target);
    return true;
}

/// Scale last committed buffer into the animated destination.
pub fn bufferScale(committed: strip.Size, destination: strip.Geometry) Scale {
    const width = @max(1, committed.width);
    const height = @max(1, committed.height);
    return .{
        .x = @as(f32, @floatFromInt(destination.width)) / @as(f32, @floatFromInt(width)),
        .y = @as(f32, @floatFromInt(destination.height)) / @as(f32, @floatFromInt(height)),
    };
}

pub fn matchesFinal(committed: strip.Size, configured: strip.Size) bool {
    return committed.width == configured.width and committed.height == configured.height;
}

fn vecFrom(geometry: strip.Geometry) Vec {
    return .{
        .x = @floatFromInt(geometry.x),
        .y = @floatFromInt(geometry.y),
        .width = @floatFromInt(geometry.width),
        .height = @floatFromInt(geometry.height),
    };
}

fn snap(state: *State, target: Vec) void {
    state.current = target;
    state.target = target;
    state.velocity = .{};
    state.seeded = true;
}

fn integrate(position: *f32, velocity: *f32, target: f32, dt: f32) void {
    const force = (target - position.*) * stiffness - velocity.* * damping;
    velocity.* += force * dt;
    position.* += velocity.* * dt;
}

fn settled(state: State) bool {
    return near(state.current.x, state.target.x, state.velocity.x) and
        near(state.current.y, state.target.y, state.velocity.y) and
        near(state.current.width, state.target.width, state.velocity.width) and
        near(state.current.height, state.target.height, state.velocity.height);
}

fn near(position: f32, target: f32, velocity: f32) bool {
    return @abs(target - position) < settle_position and @abs(velocity) < settle_velocity;
}

fn nearlyEqual(a: Vec, b: Vec) bool {
    return @abs(a.x - b.x) < settle_position and
        @abs(a.y - b.y) < settle_position and
        @abs(a.width - b.width) < settle_position and
        @abs(a.height - b.height) < settle_position;
}

test "anim first retarget snaps to the final geometry" {
    var state: State = .{};
    retarget(&state, .{ .x = 10, .y = 20, .width = 400, .height = 300 });
    try testing.expectEqual(strip.Geometry{
        .x = 10,
        .y = 20,
        .width = 400,
        .height = 300,
    }, state.display());
    try testing.expect(!tick(&state, 1.0 / 60.0));
}

test "anim spring approaches a new size then settles" {
    var state: State = .{};
    retarget(&state, .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    retarget(&state, .{ .x = 0, .y = 0, .width = 200, .height = 80 });
    try testing.expect(tick(&state, 1.0 / 60.0));
    try testing.expect(state.display().width > 100);
    try testing.expect(state.display().width < 200);

    var remaining: usize = 0;
    while (tick(&state, 1.0 / 60.0)) {
        remaining += 1;
        try testing.expect(remaining < 240);
    }
    try testing.expectEqual(@as(i32, 200), state.display().width);
    try testing.expectEqual(@as(i32, 80), state.display().height);
}

test "anim early-swap jumps when the committed buffer matches the target" {
    var state: State = .{};
    retarget(&state, .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    retarget(&state, .{ .x = 0, .y = 0, .width = 300, .height = 200 });
    state.configured = .{ .width = 100, .height = 100 };
    try testing.expect(tick(&state, 1.0 / 60.0));
    try testing.expect(!earlySwap(&state, .{ .width = 100, .height = 100 }));
    try testing.expect(earlySwap(&state, .{ .width = 300, .height = 200 }));
    try testing.expectEqual(@as(i32, 300), state.display().width);
    try testing.expect(!earlySwap(&state, .{ .width = 299, .height = 200 }));
}

test "anim buffer scale stretches the last committed size" {
    const scale = bufferScale(
        .{ .width = 100, .height = 50 },
        .{ .x = 0, .y = 0, .width = 200, .height = 25 },
    );
    try testing.expectEqual(@as(f32, 2), scale.x);
    try testing.expectEqual(@as(f32, 0.5), scale.y);
}
