const std = @import("std");
const math = @import("core.math");
const BezierCurve = @import("bezier.zig").BezierCurve;
const AnimationConfig = @import("config.zig").AnimationConfig;
const Vector2D = math.Vector2D;

pub const AnimationData = struct {
    started: bool = false,
    paused: bool = false,
    finished: bool = true,
    started_time: i64 = 0,
    duration: i64 = 0,
    config: AnimationConfig,

    pub fn init(config: AnimationConfig) AnimationData {
        return .{
            .config = config,
        };
    }
};

pub fn AnimatedVariable(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const CallbackFn = *const fn (self: *Self) void;

        goal: T,
        value: T,
        animation_data: AnimationData,

        // Callbacks
        callback_on_begin: ?CallbackFn = null,
        callback_on_update: ?CallbackFn = null,
        callback_on_end: ?CallbackFn = null,
        callback_on_end_one_time: bool = false,

        // Manager tracking for lifecycle safety
        // We store a pointer to the manager's alive flag
        manager_alive_ptr: ?*const bool = null,

        pub fn init(initial: T, config: AnimationConfig) Self {
            return .{
                .goal = initial,
                .value = initial,
                .animation_data = AnimationData.init(config),
            };
        }

        /// Check if the animation manager is still alive
        /// Returns true if no manager is set (standalone mode) or if manager is alive
        pub fn isAnimationManagerAlive(self: *const Self) bool {
            if (self.manager_alive_ptr) |alive_ptr| {
                return alive_ptr.*;
            }
            return true; // No manager, standalone mode
        }

        /// Check if the animation manager has been destroyed
        pub fn isAnimationManagerDead(self: *const Self) bool {
            return !self.isAnimationManagerAlive();
        }

        pub fn setValueAndWarp(self: *Self, v: T) void {
            self.goal = v;
            self.value = v;
            self.animation_data.started = false;
            self.animation_data.finished = true;

            // Call update callback for warp
            if (self.callback_on_update) |callback| {
                callback(self);
            }

            // Call end callback
            self.callEndCallback();
        }

        pub fn setValue(self: *Self, v: T) void {
            // If manager is dead, just warp
            if (!self.isAnimationManagerAlive()) {
                self.setValueAndWarp(v);
                return;
            }

            if (self.animation_data.config.enabled) {
                self.goal = v;
                if (!self.animation_data.started) {
                    self.animation_data.started = true;
                    self.animation_data.paused = false;
                    self.animation_data.finished = false;
                    self.animation_data.started_time = std.time.milliTimestamp();

                    // Call begin callback
                    if (self.callback_on_begin) |callback| {
                        callback(self);
                    }
                }
            } else {
                self.setValueAndWarp(v);
            }
        }

        pub fn tick(self: *Self) void {
            if (self.animation_data.finished or self.animation_data.paused or !self.animation_data.started)
                return;

            const current_time = std.time.milliTimestamp();
            const elapsed = current_time - self.animation_data.started_time;

            if (elapsed >= self.animation_data.duration) {
                self.value = self.goal;
                self.animation_data.finished = true;
                self.animation_data.started = false;

                // Call end callback
                self.callEndCallback();
                return;
            }

            const percent: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.animation_data.duration));
            const eased_percent = self.animation_data.config.getPercent(percent);

            self.value = interpolate(self.value, self.goal, eased_percent);

            // Call update callback
            if (self.callback_on_update) |callback| {
                callback(self);
            }
        }

        pub fn isBeingAnimated(self: *const Self) bool {
            return self.animation_data.started and !self.animation_data.finished;
        }

        pub fn leftToAnimate(self: *const Self) i64 {
            if (!self.isBeingAnimated())
                return 0;

            const current_time = std.time.milliTimestamp();
            const elapsed = current_time - self.animation_data.started_time;
            const remaining = self.animation_data.duration - elapsed;

            return @max(0, remaining);
        }

        pub fn setPaused(self: *Self, paused: bool) void {
            self.animation_data.paused = paused;
        }

        pub fn setConfig(self: *Self, config: AnimationConfig) void {
            self.animation_data.config = config;
        }

        pub fn setDuration(self: *Self, duration_ms: i64) void {
            self.animation_data.duration = duration_ms;
        }

        /// Set callback to be called when animation begins
        pub fn setCallbackOnBegin(self: *Self, callback: ?CallbackFn) void {
            self.callback_on_begin = callback;
        }

        /// Set callback to be called on every animation update
        pub fn setUpdateCallback(self: *Self, callback: ?CallbackFn) void {
            self.callback_on_update = callback;
        }

        /// Set callback to be called when animation ends
        /// If one_time is true, the callback is removed after first call
        pub fn setCallbackOnEnd(self: *Self, callback: ?CallbackFn, one_time: bool) void {
            self.callback_on_end = callback;
            self.callback_on_end_one_time = one_time;

            // If setting a callback and animation is already finished, call it immediately
            if (callback != null and self.animation_data.finished) {
                self.callEndCallback();
            }
        }

        /// Reset all callbacks
        pub fn resetAllCallbacks(self: *Self) void {
            self.callback_on_begin = null;
            self.callback_on_update = null;
            self.callback_on_end = null;
            self.callback_on_end_one_time = false;
        }

        /// Warp to goal value, optionally calling the end callback
        pub fn warp(self: *Self, call_end_callback: bool) void {
            self.value = self.goal;
            self.animation_data.started = false;
            self.animation_data.finished = true;

            if (call_end_callback) {
                self.callEndCallback();
            }
        }

        /// Get the current progress percentage
        pub fn getPercent(self: *const Self) f32 {
            if (!self.animation_data.started or self.animation_data.finished) {
                return 1.0;
            }

            const current_time = std.time.milliTimestamp();
            const elapsed = current_time - self.animation_data.started_time;

            if (elapsed >= self.animation_data.duration) {
                return 1.0;
            }

            return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.animation_data.duration));
        }

        /// Get the current curve value (eased percentage)
        pub fn getCurveValue(self: *const Self) f32 {
            const percent = self.getPercent();
            return self.animation_data.config.getPercent(percent);
        }

        /// Internal helper to call end callback
        fn callEndCallback(self: *Self) void {
            if (self.callback_on_end) |callback| {
                callback(self);

                // Clear callback if it's one-time
                if (self.callback_on_end_one_time) {
                    self.callback_on_end = null;
                }
            }
        }

        fn interpolate(from: T, to: T, percent: f32) T {
            return switch (@typeInfo(T)) {
                .float => from + (to - from) * percent,
                .int => @intFromFloat(@as(f64, @floatFromInt(from)) + @as(f64, @floatFromInt(to - from)) * percent),
                .@"struct" => |info| blk: {
                    // Check if it's Vector2D
                    if (T == Vector2D) {
                        break :blk Vector2D.init(
                            from.x + (to.x - from.x) * percent,
                            from.y + (to.y - from.y) * percent,
                        );
                    }

                    // Generic struct interpolation
                    var result = from;
                    inline for (info.fields) |field| {
                        const from_field = @field(from, field.name);
                        const to_field = @field(to, field.name);
                        @field(result, field.name) = interpolate(from_field, to_field, percent);
                    }
                    break :blk result;
                },
                else => @compileError("AnimatedVariable does not support type " ++ @typeName(T)),
            };
        }
    };
}

test "AnimatedVariable f32" {
    var config = AnimationConfig.init();
    config.setStyle(.linear);

    var animated = AnimatedVariable(f32).init(0.0, config);
    animated.setDuration(100);

    try std.testing.expectEqual(@as(f32, 0.0), animated.value);

    animated.setValue(100.0);
    try std.testing.expect(animated.isBeingAnimated());

    // Simulate time passing
    animated.animation_data.started_time = std.time.milliTimestamp() - 50;
    animated.tick();

    // Should be around 50% (linear interpolation)
    try std.testing.expect(animated.value > 40.0 and animated.value < 60.0);

    // Finish animation
    animated.animation_data.started_time = std.time.milliTimestamp() - 100;
    animated.tick();

    try std.testing.expectEqual(@as(f32, 100.0), animated.value);
    try std.testing.expect(!animated.isBeingAnimated());
}

test "AnimatedVariable warp" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);

    animated.setValue(100.0);
    try std.testing.expect(animated.isBeingAnimated());

    animated.setValueAndWarp(50.0);
    try std.testing.expectEqual(@as(f32, 50.0), animated.value);
    try std.testing.expect(!animated.isBeingAnimated());
}

test "AnimatedVariable Vector2D" {
    var config = AnimationConfig.init();
    config.setStyle(.linear);

    var animated = AnimatedVariable(Vector2D).init(Vector2D.init(0, 0), config);
    animated.setDuration(100);

    animated.setValue(Vector2D.init(100, 100));

    animated.animation_data.started_time = std.time.milliTimestamp() - 50;
    animated.tick();

    try std.testing.expect(animated.value.x > 40.0 and animated.value.x < 60.0);
    try std.testing.expect(animated.value.y > 40.0 and animated.value.y < 60.0);
}

test "AnimatedVariable disabled animation" {
    var config = AnimationConfig.init();
    config.enabled = false;

    var animated = AnimatedVariable(f32).init(0.0, config);

    animated.setValue(100.0);
    try std.testing.expectEqual(@as(f32, 100.0), animated.value);
    try std.testing.expect(!animated.isBeingAnimated());
}

test "AnimatedVariable callbacks - onBegin" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);
    animated.setDuration(100);

    var begin_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn onBegin(anim: *AnimatedVariable(f32)) void {
            _ = anim;
            counter.* += 1;
        }
    };
    Ctx.counter = &begin_count;

    animated.setCallbackOnBegin(Ctx.onBegin);

    animated.setValue(100.0);
    try std.testing.expectEqual(@as(u32, 1), begin_count);

    // Setting again while animating shouldn't call begin again
    animated.setValue(200.0);
    try std.testing.expectEqual(@as(u32, 1), begin_count);
}

test "AnimatedVariable callbacks - onUpdate" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);
    animated.setDuration(100);

    var update_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn onUpdate(anim: *AnimatedVariable(f32)) void {
            _ = anim;
            counter.* += 1;
        }
    };
    Ctx.counter = &update_count;

    animated.setUpdateCallback(Ctx.onUpdate);

    animated.setValue(100.0);
    animated.animation_data.started_time = std.time.milliTimestamp() - 50;

    animated.tick();
    try std.testing.expectEqual(@as(u32, 1), update_count);

    animated.tick();
    try std.testing.expectEqual(@as(u32, 2), update_count);
}

test "AnimatedVariable callbacks - onEnd" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);
    animated.setDuration(100);

    var end_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn onEnd(anim: *AnimatedVariable(f32)) void {
            _ = anim;
            counter.* += 1;
        }
    };
    Ctx.counter = &end_count;

    animated.setCallbackOnEnd(Ctx.onEnd, false);

    // Setting callback on finished animation should call it immediately
    try std.testing.expectEqual(@as(u32, 1), end_count);

    animated.setValue(100.0);
    animated.animation_data.started_time = std.time.milliTimestamp() - 100;
    animated.tick();

    try std.testing.expectEqual(@as(u32, 2), end_count);
}

test "AnimatedVariable callbacks - onEnd one-time" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);
    animated.setDuration(100);

    var end_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn onEnd(anim: *AnimatedVariable(f32)) void {
            _ = anim;
            counter.* += 1;
        }
    };
    Ctx.counter = &end_count;

    animated.setCallbackOnEnd(Ctx.onEnd, true);

    // First call when setting on finished animation
    try std.testing.expectEqual(@as(u32, 1), end_count);

    // Callback should be cleared after first call
    try std.testing.expect(animated.callback_on_end == null);

    // Warp shouldn't trigger it again
    animated.setValueAndWarp(50.0);
    try std.testing.expectEqual(@as(u32, 1), end_count);
}

test "AnimatedVariable callbacks - resetAllCallbacks" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);

    var dummy_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn callback(anim: *AnimatedVariable(f32)) void {
            _ = anim;
            counter.* += 1;
        }
    };
    Ctx.counter = &dummy_count;

    animated.setCallbackOnBegin(Ctx.callback);
    animated.setUpdateCallback(Ctx.callback);
    animated.setCallbackOnEnd(Ctx.callback, false);

    try std.testing.expect(animated.callback_on_begin != null);
    try std.testing.expect(animated.callback_on_update != null);
    try std.testing.expect(animated.callback_on_end != null);

    animated.resetAllCallbacks();

    try std.testing.expect(animated.callback_on_begin == null);
    try std.testing.expect(animated.callback_on_update == null);
    try std.testing.expect(animated.callback_on_end == null);
}

test "AnimatedVariable callbacks - warp with callback control" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);

    var end_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn onEnd(anim: *AnimatedVariable(f32)) void {
            _ = anim;
            counter.* += 1;
        }
    };
    Ctx.counter = &end_count;

    // Clear the initial callback call
    animated.setCallbackOnEnd(Ctx.onEnd, false);
    end_count = 0;

    animated.setValue(100.0);

    // Warp without callback
    animated.warp(false);
    try std.testing.expectEqual(@as(u32, 0), end_count);

    animated.setValue(200.0);

    // Warp with callback
    animated.warp(true);
    try std.testing.expectEqual(@as(u32, 1), end_count);
}

test "AnimatedVariable - getPercent and getCurveValue" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_quad);

    var animated = AnimatedVariable(f32).init(0.0, config);
    animated.setDuration(100);

    // Initially not animating, should be 100%
    try std.testing.expectEqual(@as(f32, 1.0), animated.getPercent());
    try std.testing.expectEqual(@as(f32, 1.0), animated.getCurveValue());

    animated.setValue(100.0);
    animated.animation_data.started_time = std.time.milliTimestamp() - 50;

    // Should be at 50% progress
    const percent = animated.getPercent();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), percent, 0.1);

    // Curve value should be eased (quad: 0.5^2 = 0.25)
    const curve = animated.getCurveValue();
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), curve, 0.1);

    // Finish animation
    animated.warp(false);
    try std.testing.expectEqual(@as(f32, 1.0), animated.getPercent());
    try std.testing.expectEqual(@as(f32, 1.0), animated.getCurveValue());
}

test "AnimatedVariable - setValueAndWarp calls update callback" {
    const config = AnimationConfig.init();
    var animated = AnimatedVariable(f32).init(0.0, config);

    var update_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn onUpdate(anim: *AnimatedVariable(f32)) void {
            _ = anim;
            counter.* += 1;
        }
    };
    Ctx.counter = &update_count;

    animated.setUpdateCallback(Ctx.onUpdate);

    animated.setValueAndWarp(42.0);
    try std.testing.expectEqual(@as(u32, 1), update_count);
    try std.testing.expectEqual(@as(f32, 42.0), animated.value);
}
