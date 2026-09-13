//! Trackpad translator (I3): 3-finger swipe, tap-and-hold, pinch, 2-finger column swipe.
//!
//! I3 is DRM-session-only (libinput gesture events). Nested Wayland has no
//! `zwp_pointer_gestures_v1` client bind; two-finger column switch may arrive
//! as `pointer_axis` and is handled in the seat.

const std = @import("std");
const testing = @import("core").testing;
const gesture = @import("gesture.zig");

pub const Config = struct {
    gesture: gesture.Config = .{},
    tap_usec: u64 = 300_000,
    second_hold_usec: u64 = 300_000,
    tap_prime_usec: u64 = 500_000,
};

const Mode = enum {
    idle,
    swipe,
    pinch,
    primed,
    second_down,
};

pub const Translator = struct {
    config: Config = .{},
    recognizer: gesture.Recognizer = .{},
    mode: Mode = .idle,
    fingers: u32 = 0,
    origin: gesture.Point = .{},
    current: gesture.Point = .{},
    last_scale: f64 = 1,
    primed_usec: u64 = 0,
    second_started_usec: u64 = 0,

    pub fn init(config: Config) Translator {
        var gesture_config = config.gesture;
        gesture_config.hold_usec = std.math.maxInt(u64);
        return .{
            .config = config,
            .recognizer = .{ .config = gesture_config },
        };
    }

    pub fn swipeBegin(self: *Translator, time_usec: u64, fingers: u32) !gesture.Translation {
        if (fingers == 3 and self.mode == .primed) {
            if (elapsed(self.primed_usec, time_usec) > self.config.tap_prime_usec) self.reset();
            if (self.mode == .primed) return self.beginSecond(time_usec, fingers);
        }
        if (self.mode != .idle and self.mode != .primed) return error.SequenceInProgress;
        if (fingers != 2 and fingers != 3) return .{};
        self.mode = .swipe;
        self.fingers = fingers;
        self.origin = .{};
        self.current = .{};
        try self.recognizer.begin(time_usec, self.origin);
        return .{ .consumed = fingers == 3 };
    }

    pub fn swipeUpdate(
        self: *Translator,
        time_usec: u64,
        delta_x: f64,
        delta_y: f64,
    ) !gesture.Translation {
        if (self.mode != .swipe and self.mode != .second_down) return .{};
        try validateDelta(delta_x, delta_y);
        self.current.x += delta_x;
        self.current.y += delta_y;
        if (self.mode == .second_down) return self.secondMotion(time_usec);
        const primitive = try self.recognizer.motion(time_usec, self.current);
        if (self.fingers == 2) return twoFinger(primitive);
        return .{
            .consumed = true,
            .claimed = primitive != null,
            .primitive = primitive,
        };
    }

    pub fn swipeEnd(self: *Translator, time_usec: u64, cancelled: bool) !gesture.Translation {
        if (self.mode == .second_down) return self.finishSecond(time_usec, cancelled);
        if (self.mode != .swipe) return .{};
        if (cancelled) {
            self.reset();
            return .{ .consumed = true };
        }
        const finish = try self.recognizer.finish(time_usec);
        const fingers = self.fingers;
        const duration = elapsed(self.recognizer.started_usec, time_usec);
        const tap = fingers == 3 and duration <= self.config.tap_usec and
            distance(self.origin, self.current) <= self.config.gesture.dead_zone;
        self.reset();
        if (tap) {
            self.mode = .primed;
            self.primed_usec = time_usec;
            return .{ .consumed = true };
        }
        if (fingers == 2) return twoFingerFinish(finish);
        return recognized(finish);
    }

    pub fn pinchBegin(self: *Translator, time_usec: u64, scale: f64) !gesture.Translation {
        _ = time_usec;
        if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidCoordinate;
        if (self.mode != .idle and self.mode != .primed) return error.SequenceInProgress;
        self.mode = .pinch;
        self.last_scale = scale;
        return .{ .consumed = true };
    }

    pub fn pinchUpdate(self: *Translator, time_usec: u64, scale: f64) !gesture.Translation {
        if (self.mode != .pinch) return .{};
        if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidCoordinate;
        const delta = (scale - self.last_scale) * gesture.Primitive.pinch_zoom_units;
        self.last_scale = scale;
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .zoom = .{ .time_usec = time_usec, .delta = delta } },
        };
    }

    pub fn pinchEnd(self: *Translator, time_usec: u64, cancelled: bool) gesture.Translation {
        if (self.mode != .pinch) return .{};
        self.reset();
        if (cancelled) return .{ .consumed = true };
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .release = .{ .time_usec = time_usec } },
        };
    }

    pub fn holdBegin(self: *Translator, time_usec: u64, fingers: u32) !gesture.Translation {
        if (fingers != 3) return .{};
        if (self.mode == .primed) {
            if (elapsed(self.primed_usec, time_usec) > self.config.tap_prime_usec) self.reset();
            if (self.mode == .primed) return self.beginSecond(time_usec, fingers);
        }
        if (self.mode != .idle) return error.SequenceInProgress;
        self.mode = .swipe;
        self.fingers = 3;
        self.origin = .{};
        self.current = .{};
        try self.recognizer.begin(time_usec, self.origin);
        return .{ .consumed = true };
    }

    pub fn holdEnd(self: *Translator, time_usec: u64, cancelled: bool) !gesture.Translation {
        return self.swipeEnd(time_usec, cancelled);
    }

    pub fn tick(self: *Translator, time_usec: u64) !gesture.Translation {
        if (self.mode == .primed) {
            if (elapsed(self.primed_usec, time_usec) > self.config.tap_prime_usec) self.reset();
            return .{};
        }
        if (self.mode == .second_down) return self.secondTick(time_usec);
        if (self.mode != .swipe or self.fingers != 3) return .{};
        const primitive = try self.recognizer.tick(time_usec);
        return .{
            .consumed = true,
            .claimed = primitive != null,
            .primitive = primitive,
        };
    }

    fn beginSecond(self: *Translator, time_usec: u64, fingers: u32) gesture.Translation {
        self.mode = .second_down;
        self.fingers = fingers;
        self.second_started_usec = time_usec;
        self.origin = .{};
        self.current = .{};
        return .{ .consumed = true };
    }

    fn secondMotion(self: *Translator, time_usec: u64) gesture.Translation {
        if (distance(self.origin, self.current) > self.config.gesture.dead_zone) {
            self.reset();
            return .{ .consumed = true };
        }
        return self.secondTick(time_usec);
    }

    fn secondTick(self: *Translator, time_usec: u64) gesture.Translation {
        if (elapsed(self.second_started_usec, time_usec) < self.config.second_hold_usec) {
            return .{ .consumed = true };
        }
        self.reset();
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .hold = .{ .time_usec = time_usec, .point = self.origin } },
        };
    }

    fn finishSecond(self: *Translator, time_usec: u64, cancelled: bool) gesture.Translation {
        const held = elapsed(self.second_started_usec, time_usec) >= self.config.second_hold_usec;
        self.reset();
        if (cancelled or !held) return .{ .consumed = true };
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .hold = .{ .time_usec = time_usec, .point = .{} } },
        };
    }

    fn reset(self: *Translator) void {
        self.recognizer.cancel();
        self.mode = .idle;
        self.fingers = 0;
        self.last_scale = 1;
    }
};

fn twoFinger(primitive: ?gesture.Primitive) gesture.Translation {
    const drag = primitive orelse return .{};
    if (drag != .drag) return .{};
    if (drag.drag.direction != .left and drag.drag.direction != .right) return .{};
    return .{ .consumed = true, .claimed = true, .primitive = drag };
}

fn twoFingerFinish(finish: gesture.Finish) gesture.Translation {
    return switch (finish) {
        .recognized => |primitive| switch (primitive) {
            .flick => |flick| finishHorizontal(flick.direction, primitive),
            .drag => |drag| finishHorizontal(drag.direction, primitive),
            else => .{},
        },
        .unrecognized => .{},
    };
}

fn finishHorizontal(direction: gesture.Direction, primitive: gesture.Primitive) gesture.Translation {
    if (direction != .left and direction != .right) return .{};
    return .{ .consumed = true, .claimed = true, .primitive = primitive };
}

fn recognized(finish: gesture.Finish) gesture.Translation {
    return switch (finish) {
        .recognized => |primitive| .{
            .consumed = true,
            .claimed = true,
            .primitive = primitive,
        },
        .unrecognized => .{ .consumed = true },
    };
}

fn elapsed(start: u64, end: u64) u64 {
    return end -% start;
}

fn distance(a: gesture.Point, b: gesture.Point) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

fn validateDelta(dx: f64, dy: f64) !void {
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return error.InvalidCoordinate;
}

test "three-finger swipe becomes a right flick" {
    var pad = Translator.init(.{});
    _ = try pad.swipeBegin(0, 3);
    _ = try pad.swipeUpdate(10, 20, 0);
    const end = try pad.swipeEnd(100_000, false);
    try testing.expectEqual(gesture.Direction.right, end.primitive.?.flick.direction);
    try testing.expect(end.claimed);
}

test "three-finger sustained swipe reports drag progress" {
    var pad = Translator.init(.{});
    _ = try pad.swipeBegin(0, 3);
    try testing.expectNull((try pad.swipeUpdate(10, 60, 0)).primitive);
    const drag = try pad.swipeUpdate(300_001, 0, 0);
    try testing.expectEqual(gesture.Direction.right, drag.primitive.?.drag.direction);
    try testing.expectApproxEqAbs(@as(f64, 0.25), drag.primitive.?.drag.progress, 0.0001);
}

test "two-finger horizontal swipe is a column drag" {
    var pad = Translator.init(.{});
    _ = try pad.swipeBegin(0, 2);
    _ = try pad.swipeUpdate(10, -60, 1);
    const drag = try pad.swipeUpdate(300_001, 0, 0);
    try testing.expectEqual(gesture.Direction.left, drag.primitive.?.drag.direction);
    try testing.expect(drag.consumed);
}

test "two-finger vertical swipe is not claimed" {
    var pad = Translator.init(.{});
    _ = try pad.swipeBegin(0, 2);
    _ = try pad.swipeUpdate(10, 0, -60);
    const drag = try pad.swipeUpdate(300_001, 0, 0);
    try testing.expectNull(drag.primitive);
    try testing.expectFalse(drag.consumed);
    const end = try pad.swipeEnd(300_002, false);
    try testing.expectFalse(end.claimed);
}

test "pinch emits continuous zoom deltas" {
    var pad = Translator.init(.{});
    _ = try pad.pinchBegin(0, 1);
    const first = try pad.pinchUpdate(10, 1.2);
    try testing.expectApproxEqAbs(@as(f64, 120), first.primitive.?.zoom.delta, 0.0001);
    const second = try pad.pinchUpdate(20, 1.1);
    try testing.expectApproxEqAbs(@as(f64, -60), second.primitive.?.zoom.delta, 0.0001);
    const end = pad.pinchEnd(30, false);
    try testing.expectEqual(std.meta.Tag(gesture.Primitive).release, std.meta.activeTag(end.primitive.?));
}

test "three-finger tap then hold three hundred milliseconds is hold" {
    var pad = Translator.init(.{});
    _ = try pad.holdBegin(0, 3);
    _ = try pad.holdEnd(80_000, false);
    try testing.expectEqual(Mode.primed, pad.mode);
    _ = try pad.holdBegin(100_000, 3);
    try testing.expectNull((try pad.tick(399_999)).primitive);
    const hold = try pad.tick(400_000);
    try testing.expectEqual(std.meta.Tag(gesture.Primitive).hold, std.meta.activeTag(hold.primitive.?));
}

test "first three-finger hold without a prior tap is not a ring hold" {
    var pad = Translator.init(.{});
    _ = try pad.holdBegin(0, 3);
    try testing.expectNull((try pad.tick(300_000)).primitive);
}

test "primed tap expires after five hundred milliseconds" {
    var pad = Translator.init(.{});
    _ = try pad.holdBegin(0, 3);
    _ = try pad.holdEnd(80_000, false);
    try testing.expectEqual(Mode.primed, pad.mode);
    _ = try pad.tick(580_001);
    try testing.expectEqual(Mode.idle, pad.mode);
    _ = try pad.holdBegin(600_000, 3);
    try testing.expectNull((try pad.tick(900_000)).primitive);
}

test "second tap after prime window is not a hold" {
    var pad = Translator.init(.{});
    _ = try pad.holdBegin(0, 3);
    _ = try pad.holdEnd(80_000, false);
    _ = try pad.holdBegin(600_000, 3);
    try testing.expectEqual(Mode.swipe, pad.mode);
    try testing.expectNull((try pad.tick(900_000)).primitive);
}

test "trackpad rejects non-finite motion" {
    var pad = Translator.init(.{});
    _ = try pad.swipeBegin(0, 3);
    try testing.expectError(error.InvalidCoordinate, pad.swipeUpdate(1, std.math.nan(f64), 0));
}
