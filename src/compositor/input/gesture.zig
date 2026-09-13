//! Device-independent gesture recognition and mouse translation.

const std = @import("std");
const testing = @import("core").testing;

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const Primitive = union(enum) {
    hold: TimedPoint,
    flick: TimedDirection,
    drag: Drag,
    hover: TimedPoint,
    release: Timestamp,
    back: Timestamp,
    forward: Timestamp,
    zoom: Zoom,

    pub const Timestamp = struct {
        time_usec: u64,
    };

    pub const TimedPoint = struct {
        time_usec: u64,
        point: Point,
    };

    pub const TimedDirection = struct {
        time_usec: u64,
        direction: Direction,
    };

    pub const Drag = struct {
        time_usec: u64,
        direction: Direction,
        progress: f64,
    };

    pub const Zoom = struct {
        time_usec: u64,
        delta: f64,
    };

    /// Maps a 0.2 pinch Δscale onto one 120-unit column-width step.
    pub const pinch_zoom_units: f64 = 600;
};

pub const Config = struct {
    dead_zone: f64 = 6,
    axis_lock_distance: f64 = 12,
    cone_degrees: f64 = 30,
    hold_usec: u64 = 250_000,
    flick_usec: u64 = 300_000,
    drag_extent: f64 = 240,
};

pub const State = enum {
    idle,
    tracking,
    holding,
    dragging,
};

pub const Recognizer = struct {
    config: Config = .{},
    state: State = .idle,
    origin: Point = .{ .x = 0, .y = 0 },
    current: Point = .{ .x = 0, .y = 0 },
    started_usec: u64 = 0,
    direction: ?Direction = null,

    pub fn begin(self: *Recognizer, time_usec: u64, point: Point) !void {
        if (self.state != .idle) return error.SequenceInProgress;
        try validatePoint(point);
        self.state = .tracking;
        self.origin = point;
        self.current = point;
        self.started_usec = time_usec;
        self.direction = null;
    }

    pub fn motion(self: *Recognizer, time_usec: u64, point: Point) !?Primitive {
        if (self.state == .idle) return error.NoSequence;
        try validatePoint(point);
        self.current = point;
        if (self.state == .holding)
            return .{ .hover = .{ .time_usec = time_usec, .point = point } };
        if (self.direction == null) self.tryLockDirection();
        const direction = self.direction orelse return null;
        if (elapsed(self.started_usec, time_usec) <= self.config.flick_usec) return null;
        self.state = .dragging;
        return .{ .drag = .{
            .time_usec = time_usec,
            .direction = direction,
            .progress = self.progress(direction),
        } };
    }

    pub fn tick(self: *Recognizer, time_usec: u64) !?Primitive {
        if (self.state == .idle) return null;
        if (self.state != .tracking) return null;
        if (distance(self.origin, self.current) > self.config.dead_zone) {
            const direction = self.direction orelse return null;
            if (elapsed(self.started_usec, time_usec) <= self.config.flick_usec) return null;
            self.state = .dragging;
            return .{ .drag = .{
                .time_usec = time_usec,
                .direction = direction,
                .progress = self.progress(direction),
            } };
        }
        if (elapsed(self.started_usec, time_usec) < self.config.hold_usec) return null;
        self.state = .holding;
        return .{ .hold = .{ .time_usec = time_usec, .point = self.origin } };
    }

    pub fn finish(self: *Recognizer, time_usec: u64) !Finish {
        if (self.state == .idle) return error.NoSequence;
        const result = self.finishResult(time_usec);
        self.reset();
        return result;
    }

    pub fn cancel(self: *Recognizer) void {
        self.reset();
    }

    pub fn active(self: *const Recognizer) bool {
        return self.state != .idle;
    }

    fn finishResult(self: *const Recognizer, time_usec: u64) Finish {
        if (self.state == .holding or self.state == .dragging) {
            return .{ .recognized = .{ .release = .{ .time_usec = time_usec } } };
        }
        const duration = elapsed(self.started_usec, time_usec);
        if (duration > self.config.flick_usec) return .unrecognized;
        if (distance(self.origin, self.current) <= self.config.dead_zone) return .unrecognized;
        const direction = self.direction orelse
            coneDirection(self.delta(), self.config.cone_degrees) orelse
            return .unrecognized;
        return .{ .recognized = .{ .flick = .{
            .time_usec = time_usec,
            .direction = direction,
        } } };
    }

    fn tryLockDirection(self: *Recognizer) void {
        const displacement = self.delta();
        if (std.math.hypot(displacement.x, displacement.y) < self.config.axis_lock_distance) return;
        self.direction = coneDirection(displacement, self.config.cone_degrees);
    }

    fn delta(self: *const Recognizer) Point {
        return .{
            .x = self.current.x - self.origin.x,
            .y = self.current.y - self.origin.y,
        };
    }

    fn progress(self: *const Recognizer, direction: Direction) f64 {
        const displacement = self.delta();
        const amount = switch (direction) {
            .left => -displacement.x,
            .right => displacement.x,
            .up => -displacement.y,
            .down => displacement.y,
        };
        return std.math.clamp(amount / self.config.drag_extent, 0, 1);
    }

    fn reset(self: *Recognizer) void {
        self.state = .idle;
        self.direction = null;
    }
};

pub const Finish = union(enum) {
    recognized: Primitive,
    unrecognized,
};

pub const Button = struct {
    pub const side: u32 = 0x113;
    pub const extra: u32 = 0x114;
    pub const forward: u32 = 0x115;
    pub const back: u32 = 0x116;
    pub const middle: u32 = 0x112;
};

pub const ButtonState = enum {
    released,
    pressed,
};

pub const ButtonEvent = struct {
    time_usec: u64,
    button: u32,
    state: ButtonState,
    point: Point,
};

pub const Translation = struct {
    consumed: bool = false,
    claimed: bool = false,
    primitive: ?Primitive = null,
    completion: ?Primitive = null,
    replay_press: ?ButtonEvent = null,
    replay_release: ?ButtonEvent = null,
};

pub const MouseConfig = struct {
    shell_button: u32 = Button.middle,
    gesture: Config = .{},
};

pub const Mouse = struct {
    config: MouseConfig = .{},
    recognizer: Recognizer = .{},
    deferred_press: ?ButtonEvent = null,
    back_pair: Pair = .idle,
    forward_pair: Pair = .idle,

    const Pair = enum {
        idle,
        client,
        shell,
    };

    pub fn init(config: MouseConfig) Mouse {
        return .{
            .config = config,
            .recognizer = .{ .config = config.gesture },
        };
    }

    /// Compiled default is `BTN_MIDDLE` hold (250 ms / 6 px).
    pub fn defaultShellButton() u32 {
        return Button.middle;
    }

    /// Device capabilities do not override the compiled default. `BTN_SIDE` and
    /// `BTN_EXTRA` are explicit `MouseConfig.shell_button` overrides only.
    pub fn resolveShellButton(_: bool, _: bool) u32 {
        return defaultShellButton();
    }

    pub fn button(
        self: *Mouse,
        time_usec: u64,
        point: Point,
        button_code: u32,
        state: ButtonState,
    ) !Translation {
        if (button_code == Button.back)
            return self.navigationButton(time_usec, state, .back, &self.back_pair);
        if (button_code == Button.forward)
            return self.navigationButton(time_usec, state, .forward, &self.forward_pair);
        if (button_code != self.config.shell_button) return .{};
        if (state == .pressed) return self.press(time_usec, point, button_code);
        return self.release(time_usec, point, button_code);
    }

    pub fn motion(self: *Mouse, time_usec: u64, point: Point) !Translation {
        if (!self.recognizer.active()) return .{};
        const primitive = try self.recognizer.motion(time_usec, point);
        return .{
            .consumed = true,
            .claimed = primitive != null,
            .primitive = primitive,
        };
    }

    pub fn tick(self: *Mouse, time_usec: u64) !Translation {
        if (!self.recognizer.active()) return .{};
        const primitive = try self.recognizer.tick(time_usec);
        return .{
            .consumed = true,
            .claimed = primitive != null,
            .primitive = primitive,
        };
    }

    pub fn axis(
        self: *const Mouse,
        time_usec: u64,
        control: bool,
        over_tile_gap: bool,
        value: f64,
        discrete: i32,
    ) Translation {
        if (!control) return .{};
        if (!self.recognizer.active() and !over_tile_gap) return .{};
        const units = axisV120(value, discrete);
        if (units == 0) return .{};
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .zoom = .{ .time_usec = time_usec, .delta = @floatFromInt(units) } },
        };
    }

    fn press(self: *Mouse, time_usec: u64, point: Point, button_code: u32) !Translation {
        if (self.recognizer.active()) return error.SequenceInProgress;
        try self.recognizer.begin(time_usec, point);
        self.deferred_press = .{
            .time_usec = time_usec,
            .button = button_code,
            .state = .pressed,
            .point = point,
        };
        return .{ .consumed = true };
    }

    fn release(self: *Mouse, time_usec: u64, point: Point, button_code: u32) !Translation {
        if (!self.recognizer.active()) return .{};
        try validatePoint(point);
        const release_motion = if (self.recognizer.state == .tracking or
            self.recognizer.state == .holding)
            try self.recognizer.motion(time_usec, point)
        else
            null;
        self.recognizer.current = point;
        const finish = try self.recognizer.finish(time_usec);
        const deferred = self.deferred_press;
        self.deferred_press = null;
        return switch (finish) {
            .recognized => |primitive| .{
                .consumed = true,
                .claimed = true,
                .primitive = release_motion orelse primitive,
                .completion = if (release_motion != null) primitive else null,
            },
            .unrecognized => .{
                .consumed = true,
                .replay_press = deferred,
                .replay_release = .{
                    .time_usec = time_usec,
                    .button = button_code,
                    .state = .released,
                    .point = point,
                },
            },
        };
    }

    fn navigationButton(
        self: *Mouse,
        time_usec: u64,
        state: ButtonState,
        comptime tag: std.meta.Tag(Primitive),
        pair: *Pair,
    ) Translation {
        if (state == .released) {
            const consumed = pair.* == .shell;
            pair.* = .idle;
            return .{ .consumed = consumed, .claimed = consumed };
        }
        if (pair.* != .idle) return .{ .consumed = pair.* == .shell };
        if (self.recognizer.active()) {
            pair.* = .client;
            return .{};
        }
        pair.* = .shell;
        return navigation(time_usec, tag);
    }
};

const v120_per_notch: i32 = 120;
const wheel_degrees_per_notch: f64 = 15;

/// Wheel v120: discrete notches, else degrees (~15°), else already-v120 values.
pub fn axisV120(value: f64, discrete: i32) i32 {
    if (discrete != 0) return discrete * v120_per_notch;
    if (!std.math.isFinite(value) or value == 0) return 0;
    if (@abs(value) >= @as(f64, @floatFromInt(v120_per_notch)))
        return @intFromFloat(@trunc(value));
    return @as(i32, @intFromFloat(@trunc(value / wheel_degrees_per_notch))) * v120_per_notch;
}

fn navigation(time_usec: u64, comptime tag: std.meta.Tag(Primitive)) Translation {
    const primitive: Primitive = switch (tag) {
        .back => .{ .back = .{ .time_usec = time_usec } },
        .forward => .{ .forward = .{ .time_usec = time_usec } },
        else => @compileError("navigation accepts only back and forward"),
    };
    return .{ .consumed = true, .claimed = true, .primitive = primitive };
}

fn elapsed(start: u64, end: u64) u64 {
    return end -% start;
}

fn validatePoint(point: Point) !void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y))
        return error.InvalidCoordinate;
}

fn distance(a: Point, b: Point) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

fn coneDirection(delta: Point, degrees: f64) ?Direction {
    const radians = degrees * std.math.pi / 180;
    const slope = @tan(radians);
    const abs_x = @abs(delta.x);
    const abs_y = @abs(delta.y);
    if (abs_y <= abs_x * slope) return if (delta.x < 0) .left else .right;
    if (abs_x <= abs_y * slope) return if (delta.y < 0) .up else .down;
    return null;
}

test "recognizer emits hold at timeout within dead zone" {
    var recognizer = Recognizer{};
    try recognizer.begin(1_000, .{ .x = 20, .y = 30 });
    try testing.expectNull(try recognizer.tick(250_999));
    const primitive = (try recognizer.tick(251_000)).?;
    try testing.expectEqual(@as(u64, 251_000), primitive.hold.time_usec);
    try testing.expectEqual(Point{ .x = 20, .y = 30 }, primitive.hold.point);
}

test "recognizer locks cardinal axis at twelve pixels" {
    var recognizer = Recognizer{};
    try recognizer.begin(0, .{ .x = 0, .y = 0 });
    try testing.expectNull(try recognizer.motion(1, .{ .x = 11.9, .y = 0 }));
    try testing.expectNull(try recognizer.motion(2, .{ .x = 12, .y = 2 }));
    try testing.expectEqual(@as(?Direction, .right), recognizer.direction);
    try testing.expectNull(try recognizer.motion(3, .{ .x = 13, .y = 100 }));
    try testing.expectEqual(@as(?Direction, .right), recognizer.direction);
}

test "recognizer rejects motion outside thirty degree cones" {
    var recognizer = Recognizer{};
    try recognizer.begin(0, .{ .x = 0, .y = 0 });
    try testing.expectNull(try recognizer.motion(1, .{ .x = 12, .y = 12 }));
    try testing.expectEqual(State.tracking, recognizer.state);
}

test "recognizer keeps a locked axis through flick finish" {
    var recognizer = Recognizer{};
    try recognizer.begin(0, .{ .x = 0, .y = 0 });
    try testing.expectNull(try recognizer.motion(1, .{ .x = 12, .y = 1 }));
    try testing.expectEqual(@as(?Direction, .right), recognizer.direction);
    try testing.expectNull(try recognizer.motion(2, .{ .x = 13, .y = 100 }));
    const flick = try recognizer.finish(100_000);
    try testing.expectEqual(Direction.right, flick.recognized.flick.direction);
}

test "recognizer flick threshold and timeout are inclusive" {
    var fast = Recognizer{};
    try fast.begin(0, .{ .x = 0, .y = 0 });
    _ = try fast.motion(10, .{ .x = -7, .y = 0 });
    const flick = try fast.finish(300_000);
    try testing.expectEqual(Direction.left, flick.recognized.flick.direction);

    var slow = Recognizer{};
    try slow.begin(0, .{ .x = 0, .y = 0 });
    _ = try slow.motion(10, .{ .x = -7, .y = 0 });
    try testing.expectEqual(Finish.unrecognized, try slow.finish(300_001));
}

test "recognizer reports progress and release for sustained drag" {
    var recognizer = Recognizer{};
    try recognizer.begin(0, .{ .x = 100, .y = 100 });
    try testing.expectNull(try recognizer.motion(20, .{ .x = 40, .y = 102 }));
    const drag = (try recognizer.motion(300_001, .{ .x = 40, .y = 102 })).?;
    try testing.expectApproxEqAbs(@as(f64, 0.25), drag.drag.progress, 0.0001);
    const finish = try recognizer.finish(400_000);
    try testing.expectEqual(@as(u64, 400_000), finish.recognized.release.time_usec);
}

test "recognizer validates state time and coordinates" {
    var recognizer = Recognizer{};
    try testing.expectError(error.NoSequence, recognizer.motion(0, .{ .x = 0, .y = 0 }));
    try testing.expectError(error.InvalidCoordinate, recognizer.begin(0, .{ .x = std.math.nan(f64), .y = 0 }));
    try recognizer.begin(10, .{ .x = 0, .y = 0 });
    try testing.expectError(error.SequenceInProgress, recognizer.begin(11, .{ .x = 0, .y = 0 }));
    try testing.expectNull(try recognizer.motion(9, .{ .x = 1, .y = 1 }));
}

test "mouse defaults to middle hold and ignores side extra capability" {
    try testing.expectEqual(Button.middle, Mouse.defaultShellButton());
    try testing.expectEqual(Button.middle, Mouse.init(.{}).config.shell_button);
    try testing.expectEqual(@as(u64, 250_000), Mouse.init(.{}).config.gesture.hold_usec);
    try testing.expectEqual(@as(f64, 6), Mouse.init(.{}).config.gesture.dead_zone);
    try testing.expectEqual(Button.middle, Mouse.resolveShellButton(true, true));
    try testing.expectEqual(Button.middle, Mouse.resolveShellButton(true, false));
    try testing.expectEqual(Button.middle, Mouse.resolveShellButton(false, true));
    try testing.expectEqual(Button.middle, Mouse.resolveShellButton(false, false));
    try testing.expectEqual(Button.middle, Mouse.init(.{ .shell_button = Button.middle }).config.shell_button);
}

test "mouse honors an explicit hold duration override" {
    var mouse = Mouse.init(.{ .gesture = .{ .hold_usec = 400_000 } });
    _ = try mouse.button(0, .{}, Button.middle, .pressed);
    try testing.expectNull((try mouse.tick(250_000)).primitive);
    const hold = (try mouse.tick(400_000)).primitive.?;
    try testing.expectEqual(std.meta.Tag(Primitive).hold, std.meta.activeTag(hold));
}

test "mouse side and extra are explicit overrides only" {
    var side = Mouse.init(.{ .shell_button = Button.side });
    const side_press = try side.button(10, .{ .x = 1, .y = 2 }, Button.side, .pressed);
    try testing.expect(side_press.consumed);
    try testing.expectFalse((try side.button(11, .{}, Button.middle, .pressed)).consumed);

    var extra = Mouse.init(.{ .shell_button = Button.extra });
    const extra_press = try extra.button(10, .{ .x = 1, .y = 2 }, Button.extra, .pressed);
    try testing.expect(extra_press.consumed);
    try testing.expectNull(extra_press.replay_press);
    const extra_release = try extra.button(20, .{ .x = 1, .y = 2 }, Button.extra, .released);
    try testing.expectEqual(@as(u64, 10), extra_release.replay_press.?.time_usec);
}

test "mouse defers and replays click with original timestamp" {
    var mouse = Mouse.init(.{});
    const press = try mouse.button(123, .{ .x = 5, .y = 7 }, Button.middle, .pressed);
    try testing.expect(press.consumed);
    try testing.expectNull(press.replay_press);
    const release = try mouse.button(200, .{ .x = 7, .y = 7 }, Button.middle, .released);
    try testing.expectEqual(@as(u64, 123), release.replay_press.?.time_usec);
    try testing.expectEqual(ButtonState.pressed, release.replay_press.?.state);
    try testing.expectEqual(@as(u64, 200), release.replay_release.?.time_usec);
}

test "mouse consumes shell drag without replay" {
    var mouse = Mouse.init(.{});
    _ = try mouse.button(0, .{ .x = 0, .y = 0 }, Button.middle, .pressed);
    try testing.expectNull((try mouse.motion(10, .{ .x = 20, .y = 1 })).primitive);
    const drag = try mouse.motion(300_001, .{ .x = 20, .y = 1 });
    try testing.expectEqual(Direction.right, drag.primitive.?.drag.direction);
    const release = try mouse.button(20, .{ .x = 30, .y = 1 }, Button.middle, .released);
    try testing.expectNull(release.replay_press);
    try testing.expectEqual(std.meta.Tag(Primitive).release, std.meta.activeTag(release.primitive.?));
}

test "mouse slow move release completes drag without click replay" {
    var mouse = Mouse.init(.{});
    _ = try mouse.button(0, .{}, Button.middle, .pressed);
    try testing.expectNull((try mouse.motion(10, .{ .x = 20, .y = 0 })).primitive);

    const release = try mouse.button(400_000, .{ .x = 120, .y = 0 }, Button.middle, .released);
    try testing.expectEqual(Direction.right, release.primitive.?.drag.direction);
    try testing.expectEqual(
        std.meta.Tag(Primitive).release,
        std.meta.activeTag(release.completion.?),
    );
    try testing.expectNull(release.replay_press);
    try testing.expectNull(release.replay_release);
}

test "mouse hold release updates hover before completion" {
    var mouse = Mouse.init(.{});
    _ = try mouse.button(0, .{}, Button.middle, .pressed);
    _ = try mouse.tick(250_000);

    const release = try mouse.button(500_000, .{ .x = 72, .y = 0 }, Button.middle, .released);
    try testing.expectEqual(std.meta.Tag(Primitive).hover, std.meta.activeTag(release.primitive.?));
    try testing.expectEqual(std.meta.Tag(Primitive).release, std.meta.activeTag(release.completion.?));
}

test "mouse classifies quick twelve pixel motion as flick" {
    var mouse = Mouse.init(.{});
    _ = try mouse.button(1_000, .{}, Button.middle, .pressed);
    const motion = try mouse.motion(2_000, .{ .x = 12, .y = 0 });
    try testing.expectNull(motion.primitive);
    try testing.expectFalse(motion.claimed);
    const release = try mouse.button(3_000, .{ .x = 12, .y = 0 }, Button.middle, .released);
    try testing.expectEqual(Direction.right, release.primitive.?.flick.direction);
    try testing.expect(release.claimed);
}

test "mouse navigation button pairs remain coherent across gesture changes" {
    var mouse = Mouse.init(.{});
    const press = try mouse.button(1, .{}, Button.back, .pressed);
    try testing.expect(press.consumed);
    _ = try mouse.button(2, .{}, Button.middle, .pressed);
    const release = try mouse.button(3, .{}, Button.back, .released);
    try testing.expect(release.consumed);

    var client_pair = Mouse.init(.{});
    _ = try client_pair.button(1, .{}, Button.middle, .pressed);
    try testing.expectFalse((try client_pair.button(2, .{}, Button.forward, .pressed)).consumed);
    _ = try client_pair.button(3, .{}, Button.middle, .released);
    try testing.expectFalse((try client_pair.button(4, .{}, Button.forward, .released)).consumed);
}

test "recognizer elapsed arithmetic tolerates timestamp wrap" {
    var recognizer = Recognizer{};
    try recognizer.begin(std.math.maxInt(u64) - 100, .{});
    try testing.expectNull(try recognizer.motion(20, .{ .x = 12, .y = 0 }));
    const finish = try recognizer.finish(30);
    try testing.expectEqual(Direction.right, finish.recognized.flick.direction);
    try testing.expectFalse(recognizer.active());
}

test "mouse back forward and zoom obey gesture guards" {
    var mouse = Mouse.init(.{});
    const back = try mouse.button(1, .{}, Button.back, .pressed);
    try testing.expectEqual(std.meta.Tag(Primitive).back, std.meta.activeTag(back.primitive.?));
    try testing.expect((try mouse.button(2, .{}, Button.back, .released)).consumed);
    const passthrough = mouse.axis(2, true, false, 15, 1);
    try testing.expectFalse(passthrough.consumed);
    const gap_zoom = mouse.axis(3, true, true, -15, 0);
    try testing.expectEqual(@as(f64, -120), gap_zoom.primitive.?.zoom.delta);
    _ = try mouse.button(4, .{}, Button.middle, .pressed);
    const held_zoom = mouse.axis(5, true, false, 15, 1);
    try testing.expect(held_zoom.consumed);
    const crumb = mouse.axis(6, true, false, 7, 0);
    try testing.expectFalse(crumb.consumed);
    const guarded_back = try mouse.button(7, .{}, Button.back, .pressed);
    try testing.expectFalse(guarded_back.consumed);
}

test "axis v120 maps a wheel notch and ignores crumbs" {
    try testing.expectEqual(@as(i32, 120), axisV120(15, 0));
    try testing.expectEqual(@as(i32, 120), axisV120(15, 1));
    try testing.expectEqual(@as(i32, -120), axisV120(-15, 0));
    try testing.expectEqual(@as(i32, 240), axisV120(30, 0));
    try testing.expectEqual(@as(i32, 120), axisV120(120, 0));
    try testing.expectEqual(@as(i32, 0), axisV120(7, 0));
    try testing.expectEqual(@as(i32, 0), axisV120(0, 0));
    try testing.expectEqual(@as(i32, 0), axisV120(std.math.nan(f64), 0));
}
