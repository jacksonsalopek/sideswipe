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

        goal: T,
        value: T,
        animation_data: AnimationData,

        pub fn init(initial: T, config: AnimationConfig) Self {
            return .{
                .goal = initial,
                .value = initial,
                .animation_data = AnimationData.init(config),
            };
        }

        pub fn setValueAndWarp(self: *Self, v: T) void {
            self.goal = v;
            self.value = v;
            self.animation_data.started = false;
            self.animation_data.finished = true;
        }

        pub fn setValue(self: *Self, v: T) void {
            if (self.animation_data.config.enabled) {
                self.goal = v;
                if (!self.animation_data.started) {
                    self.animation_data.started = true;
                    self.animation_data.paused = false;
                    self.animation_data.finished = false;
                    self.animation_data.started_time = std.time.milliTimestamp();
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
                return;
            }

            const percent: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.animation_data.duration));
            const eased_percent = self.animation_data.config.getPercent(percent);

            self.value = interpolate(self.value, self.goal, eased_percent);
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
