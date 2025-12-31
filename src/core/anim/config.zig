const std = @import("std");
const BezierCurve = @import("bezier.zig").BezierCurve;

pub const AnimationStyle = enum {
    linear,
    ease_in_sine,
    ease_out_sine,
    ease_in_out_sine,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_in_quart,
    ease_out_quart,
    ease_in_out_quart,
    ease_in_quint,
    ease_out_quint,
    ease_in_out_quint,
    ease_in_expo,
    ease_out_expo,
    ease_in_out_expo,
    ease_in_circ,
    ease_out_circ,
    ease_in_out_circ,
    ease_in_back,
    ease_out_back,
    ease_in_out_back,
};

pub const AnimationConfig = struct {
    enabled: bool = true,
    style: AnimationStyle = .linear,
    curve: ?BezierCurve = null,

    pub fn init() AnimationConfig {
        return .{};
    }

    pub fn setStyle(self: *AnimationConfig, style: AnimationStyle) void {
        self.style = style;
        self.curve = null;
    }

    pub fn setBezier(self: *AnimationConfig, x0: f32, y0: f32, x1: f32, y1: f32) void {
        self.curve = BezierCurve.init(x0, y0, x1, y1);
        self.style = .linear;
    }

    pub fn getPercent(self: AnimationConfig, percent: f32) f32 {
        if (!self.enabled)
            return 1.0;

        if (self.curve) |curve| {
            return curve.getYForPoint(percent);
        }

        return switch (self.style) {
            .linear => percent,
            .ease_in_sine => 1.0 - @cos((percent * std.math.pi) / 2.0),
            .ease_out_sine => @sin((percent * std.math.pi) / 2.0),
            .ease_in_out_sine => -(@cos(std.math.pi * percent) - 1.0) / 2.0,
            .ease_in_quad => percent * percent,
            .ease_out_quad => 1.0 - (1.0 - percent) * (1.0 - percent),
            .ease_in_out_quad => if (percent < 0.5)
                2.0 * percent * percent
            else
                1.0 - std.math.pow(f32, -2.0 * percent + 2.0, 2.0) / 2.0,
            .ease_in_cubic => percent * percent * percent,
            .ease_out_cubic => 1.0 - std.math.pow(f32, 1.0 - percent, 3.0),
            .ease_in_out_cubic => if (percent < 0.5)
                4.0 * percent * percent * percent
            else
                1.0 - std.math.pow(f32, -2.0 * percent + 2.0, 3.0) / 2.0,
            .ease_in_quart => percent * percent * percent * percent,
            .ease_out_quart => 1.0 - std.math.pow(f32, 1.0 - percent, 4.0),
            .ease_in_out_quart => if (percent < 0.5)
                8.0 * percent * percent * percent * percent
            else
                1.0 - std.math.pow(f32, -2.0 * percent + 2.0, 4.0) / 2.0,
            .ease_in_quint => percent * percent * percent * percent * percent,
            .ease_out_quint => 1.0 - std.math.pow(f32, 1.0 - percent, 5.0),
            .ease_in_out_quint => if (percent < 0.5)
                16.0 * percent * percent * percent * percent * percent
            else
                1.0 - std.math.pow(f32, -2.0 * percent + 2.0, 5.0) / 2.0,
            .ease_in_expo => if (percent == 0.0) 0.0 else std.math.pow(f32, 2.0, 10.0 * percent - 10.0),
            .ease_out_expo => if (percent == 1.0) 1.0 else 1.0 - std.math.pow(f32, 2.0, -10.0 * percent),
            .ease_in_out_expo => if (percent == 0.0)
                0.0
            else if (percent == 1.0)
                1.0
            else if (percent < 0.5)
                std.math.pow(f32, 2.0, 20.0 * percent - 10.0) / 2.0
            else
                (2.0 - std.math.pow(f32, 2.0, -20.0 * percent + 10.0)) / 2.0,
            .ease_in_circ => 1.0 - @sqrt(1.0 - std.math.pow(f32, percent, 2.0)),
            .ease_out_circ => @sqrt(1.0 - std.math.pow(f32, percent - 1.0, 2.0)),
            .ease_in_out_circ => if (percent < 0.5)
                (1.0 - @sqrt(1.0 - std.math.pow(f32, 2.0 * percent, 2.0))) / 2.0
            else
                (@sqrt(1.0 - std.math.pow(f32, -2.0 * percent + 2.0, 2.0)) + 1.0) / 2.0,
            .ease_in_back => blk: {
                const c1: f32 = 1.70158;
                const c3: f32 = c1 + 1.0;
                break :blk c3 * percent * percent * percent - c1 * percent * percent;
            },
            .ease_out_back => blk: {
                const c1: f32 = 1.70158;
                const c3: f32 = c1 + 1.0;
                break :blk 1.0 + c3 * std.math.pow(f32, percent - 1.0, 3.0) + c1 * std.math.pow(f32, percent - 1.0, 2.0);
            },
            .ease_in_out_back => blk: {
                const c1: f32 = 1.70158;
                const c2: f32 = c1 * 1.525;
                break :blk if (percent < 0.5)
                    (std.math.pow(f32, 2.0 * percent, 2.0) * ((c2 + 1.0) * 2.0 * percent - c2)) / 2.0
                else
                    (std.math.pow(f32, 2.0 * percent - 2.0, 2.0) * ((c2 + 1.0) * (percent * 2.0 - 2.0) + c2) + 2.0) / 2.0;
            },
        };
    }
};

test "AnimationConfig - init" {
    const config = AnimationConfig.init();
    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(AnimationStyle.linear, config.style);
    try std.testing.expect(config.curve == null);
}

test "AnimationConfig - linear style" {
    const config = AnimationConfig.init();

    try std.testing.expectEqual(@as(f32, 0.0), config.getPercent(0.0));
    try std.testing.expectEqual(@as(f32, 0.25), config.getPercent(0.25));
    try std.testing.expectEqual(@as(f32, 0.5), config.getPercent(0.5));
    try std.testing.expectEqual(@as(f32, 0.75), config.getPercent(0.75));
    try std.testing.expectEqual(@as(f32, 1.0), config.getPercent(1.0));
}

test "AnimationConfig - disabled" {
    var config = AnimationConfig.init();
    config.enabled = false;

    // When disabled, should always return 1.0
    try std.testing.expectEqual(@as(f32, 1.0), config.getPercent(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), config.getPercent(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), config.getPercent(1.0));
}

test "AnimationConfig - setStyle" {
    var config = AnimationConfig.init();
    config.curve = BezierCurve.init(0.5, 0.5, 0.5, 0.5);

    config.setStyle(.ease_in_quad);
    try std.testing.expectEqual(AnimationStyle.ease_in_quad, config.style);
    try std.testing.expect(config.curve == null);
}

test "AnimationConfig - setBezier" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_sine);

    config.setBezier(0.42, 0, 1, 1);
    try std.testing.expect(config.curve != null);
    try std.testing.expectEqual(AnimationStyle.linear, config.style);
}

test "AnimationConfig - ease_in_quad" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_quad);

    const half = config.getPercent(0.5);
    // Quadratic ease-in: 0.5^2 = 0.25
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), half, 0.001);
}

test "AnimationConfig - ease_out_quad" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_out_quad);

    const half = config.getPercent(0.5);
    // Ease-out should be faster than linear at 0.5
    try std.testing.expect(half > 0.5);
}

test "AnimationConfig - ease_in_out_sine" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_out_sine);

    const half = config.getPercent(0.5);
    // Should be around 0.5 (symmetric)
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), half, 0.1);

    // Start should be slow
    const quarter = config.getPercent(0.25);
    try std.testing.expect(quarter < 0.25);
}

test "AnimationConfig - ease_in_cubic" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_cubic);

    const half = config.getPercent(0.5);
    // Cubic: 0.5^3 = 0.125
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), half, 0.001);
}

test "AnimationConfig - ease_out_cubic" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_out_cubic);

    const half = config.getPercent(0.5);
    // Should be faster than linear
    try std.testing.expect(half > 0.5);
}

test "AnimationConfig - ease_in_expo" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_expo);

    // At 0, should be 0
    try std.testing.expectEqual(@as(f32, 0.0), config.getPercent(0.0));

    // Should start very slow
    const small = config.getPercent(0.1);
    try std.testing.expect(small < 0.01);
}

test "AnimationConfig - ease_out_expo" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_out_expo);

    // At 1, should be 1
    try std.testing.expectEqual(@as(f32, 1.0), config.getPercent(1.0));

    // Should start fast
    const small = config.getPercent(0.1);
    try std.testing.expect(small > 0.1);
}

test "AnimationConfig - ease_in_circ" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_circ);

    const half = config.getPercent(0.5);
    // Circular ease-in should be slower than linear at start
    try std.testing.expect(half < 0.5);
}

test "AnimationConfig - ease_out_circ" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_out_circ);

    const half = config.getPercent(0.5);
    // Circular ease-out should be faster than linear
    try std.testing.expect(half > 0.5);
}

test "AnimationConfig - ease_in_back" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_in_back);

    // Back easing can go slightly negative before moving forward
    _ = config.getPercent(0.1);
    const result = config.getPercent(1.0);

    // Should end at 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.01);
}

test "AnimationConfig - ease_out_back" {
    var config = AnimationConfig.init();
    config.setStyle(.ease_out_back);

    const result = config.getPercent(1.0);
    // Should end at 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.01);
}

test "AnimationConfig - custom bezier curve" {
    var config = AnimationConfig.init();
    config.setBezier(0.42, 0, 1, 1);

    const half = config.getPercent(0.5);
    // Should use the bezier curve
    try std.testing.expect(half >= 0.0 and half <= 1.0);
}

test "AnimationConfig - boundary values for all styles" {
    const styles = [_]AnimationStyle{
        .linear,            .ease_in_sine,  .ease_out_sine,
        .ease_in_out_sine,  .ease_in_quad,  .ease_out_quad,
        .ease_in_out_quad,  .ease_in_cubic, .ease_out_cubic,
        .ease_in_out_cubic, .ease_in_quart, .ease_out_quart,
        .ease_in_out_quart, .ease_in_quint, .ease_out_quint,
        .ease_in_out_quint, .ease_in_expo,  .ease_out_expo,
        .ease_in_out_expo,  .ease_in_circ,  .ease_out_circ,
        .ease_in_out_circ,  .ease_in_back,  .ease_out_back,
        .ease_in_out_back,
    };

    for (styles) |style| {
        var config = AnimationConfig.init();
        config.setStyle(style);

        const start = config.getPercent(0.0);
        const end = config.getPercent(1.0);

        // All curves should start at 0 and end at 1
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), start, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), end, 0.01);
    }
}
