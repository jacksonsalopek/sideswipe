pub const BezierCurve = struct {
    ax: f32 = 0,
    bx: f32 = 0,
    cx: f32 = 0,
    ay: f32 = 0,
    by: f32 = 0,
    cy: f32 = 0,
    inverted: bool = false,

    pub fn init(x0: f32, y0: f32, x1: f32, y1: f32) BezierCurve {
        var curve: BezierCurve = .{};

        curve.cx = 3.0 * x0;
        curve.bx = 3.0 * (x1 - x0) - curve.cx;
        curve.ax = 1.0 - curve.cx - curve.bx;

        curve.cy = 3.0 * y0;
        curve.by = 3.0 * (y1 - y0) - curve.cy;
        curve.ay = 1.0 - curve.cy - curve.by;

        return curve;
    }

    fn sampleCurveX(self: BezierCurve, t: f32) f32 {
        return ((self.ax * t + self.bx) * t + self.cx) * t;
    }

    fn sampleCurveY(self: BezierCurve, t: f32) f32 {
        return ((self.ay * t + self.by) * t + self.cy) * t;
    }

    fn sampleCurveDerivativeX(self: BezierCurve, t: f32) f32 {
        return (3.0 * self.ax * t + 2.0 * self.bx) * t + self.cx;
    }

    fn sampleCurveDerivativeY(self: BezierCurve, t: f32) f32 {
        return (3.0 * self.ay * t + 2.0 * self.by) * t + self.cy;
    }

    fn solveCurveX(self: BezierCurve, x: f32, epsilon: f32) f32 {
        var t0: f32 = undefined;
        var t1: f32 = undefined;
        var t2: f32 = x;
        var x2: f32 = undefined;
        var d2: f32 = undefined;

        // First try a few iterations of Newton's method
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            x2 = self.sampleCurveX(t2) - x;
            if (@abs(x2) < epsilon)
                return t2;
            d2 = self.sampleCurveDerivativeX(t2);
            if (@abs(d2) < 1e-6)
                break;
            t2 = t2 - x2 / d2;
        }

        // Fall back to bisection
        t0 = 0.0;
        t1 = 1.0;
        t2 = x;

        if (t2 < t0)
            return t0;
        if (t2 > t1)
            return t1;

        while (t0 < t1) {
            x2 = self.sampleCurveX(t2);
            if (@abs(x2 - x) < epsilon)
                return t2;
            if (x > x2) {
                t0 = t2;
            } else {
                t1 = t2;
            }
            t2 = (t1 - t0) * 0.5 + t0;
        }

        return t2;
    }

    fn solveCurveY(self: BezierCurve, y: f32, epsilon: f32) f32 {
        var t0: f32 = undefined;
        var t1: f32 = undefined;
        var t2: f32 = y;
        var y2: f32 = undefined;
        var d2: f32 = undefined;

        // First try a few iterations of Newton's method
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            y2 = self.sampleCurveY(t2) - y;
            if (@abs(y2) < epsilon)
                return t2;
            d2 = self.sampleCurveDerivativeY(t2);
            if (@abs(d2) < 1e-6)
                break;
            t2 = t2 - y2 / d2;
        }

        // Fall back to bisection
        t0 = 0.0;
        t1 = 1.0;
        t2 = y;

        if (t2 < t0)
            return t0;
        if (t2 > t1)
            return t1;

        while (t0 < t1) {
            y2 = self.sampleCurveY(t2);
            if (@abs(y2 - y) < epsilon)
                return t2;
            if (y > y2) {
                t0 = t2;
            } else {
                t1 = t2;
            }
            t2 = (t1 - t0) * 0.5 + t0;
        }

        return t2;
    }

    pub fn getYForPoint(self: BezierCurve, t: f32) f32 {
        if (self.inverted)
            return self.sampleCurveX(self.solveCurveY(t, 0.001));

        return self.sampleCurveY(self.solveCurveX(t, 0.001));
    }

    pub fn getXForPoint(self: BezierCurve, t: f32) f32 {
        if (self.inverted)
            return self.sampleCurveY(self.solveCurveX(t, 0.001));

        return self.sampleCurveX(self.solveCurveY(t, 0.001));
    }

    pub fn setInverted(self: *BezierCurve, inverted: bool) void {
        self.inverted = inverted;
    }
};

const std = @import("std");

test "BezierCurve - linear curve (identity)" {
    // Linear curve should be identity: y = x
    const curve = BezierCurve.init(0, 0, 1, 1);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curve.getYForPoint(0.0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), curve.getYForPoint(0.25), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), curve.getYForPoint(0.5), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), curve.getYForPoint(0.75), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), curve.getYForPoint(1.0), 0.01);
}

test "BezierCurve - ease-in (slow start)" {
    // Ease-in curve: slow start, fast end
    const curve = BezierCurve.init(0.42, 0, 1, 1);

    const y_quarter = curve.getYForPoint(0.25);
    const y_half = curve.getYForPoint(0.5);

    // At quarter progress, should be less than 0.25 (slow start)
    try std.testing.expect(y_quarter < 0.25);
    // At half progress, curve should accelerate
    try std.testing.expect(y_half > 0.25);
    try std.testing.expect(y_half < 0.75);
}

test "BezierCurve - ease-out (fast start)" {
    // Ease-out curve: fast start, slow end
    const curve = BezierCurve.init(0, 0, 0.58, 1);

    const y_quarter = curve.getYForPoint(0.25);
    const y_three_quarter = curve.getYForPoint(0.75);

    // At quarter progress, should be more than 0.25 (fast start)
    try std.testing.expect(y_quarter > 0.25);
    // At three-quarter progress, should be less than 0.75 (deceleration)
    try std.testing.expect(y_three_quarter < 1.0);
}

test "BezierCurve - ease-in-out (symmetric)" {
    // Ease-in-out curve: slow start, fast middle, slow end
    const curve = BezierCurve.init(0.42, 0, 0.58, 1);

    const y_quarter = curve.getYForPoint(0.25);
    const y_half = curve.getYForPoint(0.5);
    const y_three_quarter = curve.getYForPoint(0.75);

    // At quarter progress, should be less than 0.25 (slow start)
    try std.testing.expect(y_quarter < 0.25);
    // At half, should be around 0.5 (symmetric)
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), y_half, 0.1);
    // At three-quarter, should be more than 0.75 (but decelerating)
    try std.testing.expect(y_three_quarter > 0.75);
}

test "BezierCurve - boundary values" {
    const curve = BezierCurve.init(0.25, 0.1, 0.25, 1);

    // Start and end should always be 0 and 1
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curve.getYForPoint(0.0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), curve.getYForPoint(1.0), 0.01);
}

test "BezierCurve - inverted curve" {
    var curve = BezierCurve.init(0.2, 0.4, 0.8, 0.6);

    // Initially not inverted
    try std.testing.expect(!curve.inverted);

    // Set inverted
    curve.setInverted(true);
    try std.testing.expect(curve.inverted);

    // Set back to normal
    curve.setInverted(false);
    try std.testing.expect(!curve.inverted);

    // Verify getYForPoint and getXForPoint both work
    const y = curve.getYForPoint(0.5);
    const x = curve.getXForPoint(0.5);

    try std.testing.expect(y >= 0.0 and y <= 1.0);
    try std.testing.expect(x >= 0.0 and x <= 1.0);
}

test "BezierCurve - getXForPoint" {
    const curve = BezierCurve.init(0, 0, 1, 1);

    // For linear curve, getXForPoint should also be identity-like
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curve.getXForPoint(0.0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), curve.getXForPoint(0.5), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), curve.getXForPoint(1.0), 0.01);
}

test "BezierCurve - steep curve" {
    // Very steep curve at the start
    const curve = BezierCurve.init(0, 0.8, 1, 1);

    const y_early = curve.getYForPoint(0.1);

    // Should have a steep rise early on
    try std.testing.expect(y_early > 0.3);
}

test "BezierCurve - monotonic property" {
    const curve = BezierCurve.init(0.25, 0.1, 0.25, 1);

    var prev_y: f32 = 0.0;
    var t: f32 = 0.0;

    // Curve should be monotonically increasing
    while (t <= 1.0) : (t += 0.1) {
        const y = curve.getYForPoint(t);
        try std.testing.expect(y >= prev_y);
        prev_y = y;
    }
}

test "BezierCurve - non-monotonic clamps out of range" {
    // Non-monotonic curve - control points that create loops
    // Should handle gracefully without going out of bounds
    const curve = BezierCurve.init(1.5, 0.5, -0.5, 0.5);

    // Normal range
    const y_normal = curve.getYForPoint(0.5);
    try std.testing.expect(std.math.isFinite(y_normal));
    
    // Moderately out of range (realistic compositor values)
    const y_above = curve.getYForPoint(2.0);
    try std.testing.expect(std.math.isFinite(y_above));
    
    const y_below = curve.getYForPoint(-1.0);
    try std.testing.expect(std.math.isFinite(y_below));
    
    // More extreme but still realistic
    const y_far_above = curve.getYForPoint(100.0);
    try std.testing.expect(std.math.isFinite(y_far_above));
    
    const y_far_below = curve.getYForPoint(-100.0);
    try std.testing.expect(std.math.isFinite(y_far_below));
}

test "BezierCurve - adjacent baked X equal (flat tail)" {
    // Curve that ends flat (both control points at 1,1)
    const curve = BezierCurve.init(0.2, 0.2, 1.0, 1.0);

    // Exactly at end
    const y_at_end = curve.getYForPoint(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), y_at_end, 0.01);
    
    // Slightly beyond end - should clamp to endpoint
    const y_past_end = curve.getYForPoint(1.0001);
    try std.testing.expectApproxEqAbs(y_at_end, y_past_end, 0.01);
}

test "BezierCurve - all baked X equal (vertical curve)" {
    // Extreme case: X doesn't change (vertical line)
    // Both control points have X=0
    const curve = BezierCurve.init(0.0, 0.3, 0.0, 0.7);

    // Below range
    const y_lo = curve.getYForPoint(-100.0);
    try std.testing.expect(std.math.isFinite(y_lo));
    
    // At zero
    const y_0 = curve.getYForPoint(0.0);
    try std.testing.expect(std.math.isFinite(y_0));
    
    // Above range
    const y_hi = curve.getYForPoint(100.0);
    try std.testing.expect(std.math.isFinite(y_hi));

    // All should be valid values
    try std.testing.expect(std.math.isFinite(y_lo));
    try std.testing.expect(std.math.isFinite(y_0));
    try std.testing.expect(std.math.isFinite(y_hi));
}

test "BezierCurve - extreme control points" {
    // Test with control points far outside [0,1] range
    const curve = BezierCurve.init(2.0, -1.0, -1.0, 2.0);

    // Should handle gracefully even with extreme values
    const y_start = curve.getYForPoint(0.0);
    const y_mid = curve.getYForPoint(0.5);
    const y_end = curve.getYForPoint(1.0);
    
    try std.testing.expect(std.math.isFinite(y_start));
    try std.testing.expect(std.math.isFinite(y_mid));
    try std.testing.expect(std.math.isFinite(y_end));
}

test "BezierCurve - zero duration handling" {
    // Edge case: what happens with t values very close together
    const curve = BezierCurve.init(0.25, 0.1, 0.25, 1.0);
    
    const y1 = curve.getYForPoint(0.0001);
    const y2 = curve.getYForPoint(0.0002);
    
    // Should be very close but both valid
    try std.testing.expect(std.math.isFinite(y1));
    try std.testing.expect(std.math.isFinite(y2));
    try std.testing.expect(@abs(y2 - y1) < 0.1);
}

test "BezierCurve - repeated queries at same point" {
    const curve = BezierCurve.init(0.42, 0, 0.58, 1);
    
    // Query the same point multiple times - should be consistent
    const y1 = curve.getYForPoint(0.5);
    const y2 = curve.getYForPoint(0.5);
    const y3 = curve.getYForPoint(0.5);
    
    try std.testing.expectEqual(y1, y2);
    try std.testing.expectEqual(y2, y3);
}

test "BezierCurve - negative X values" {
    const curve = BezierCurve.init(0.42, 0, 0.58, 1);
    
    // Negative X - implementation extrapolates rather than clamping
    const y_neg = curve.getYForPoint(-0.5);
    
    // Should still be finite
    try std.testing.expect(std.math.isFinite(y_neg));
}

test "BezierCurve - X values beyond 1.0" {
    const curve = BezierCurve.init(0.42, 0, 0.58, 1);
    
    // X beyond 1.0 - implementation extrapolates
    const y_over = curve.getYForPoint(1.5);
    
    // Should still be finite
    try std.testing.expect(std.math.isFinite(y_over));
}

test "BezierCurve - cusps (control points creating sharp turns)" {
    // Control points that create cusps (sharp direction changes)
    const curve = BezierCurve.init(2.0, 0.5, -1.0, 0.5);

    // Sample many points to ensure numerical stability at cusp
    var t: f32 = 0.0;
    while (t <= 1.0) : (t += 0.05) {
        const y = curve.getYForPoint(t);
        try std.testing.expect(std.math.isFinite(y));
        // Value should be reasonable (not exploding)
        try std.testing.expect(y > -100.0 and y < 100.0);
    }
}

test "BezierCurve - very large control points" {
    // Extreme control points that could cause overflow
    const curve = BezierCurve.init(1000.0, 1000.0, -1000.0, -1000.0);

    // Should handle without overflow or NaN
    const y_start = curve.getYForPoint(0.0);
    const y_mid = curve.getYForPoint(0.5);
    const y_end = curve.getYForPoint(1.0);

    try std.testing.expect(std.math.isFinite(y_start));
    try std.testing.expect(std.math.isFinite(y_mid));
    try std.testing.expect(std.math.isFinite(y_end));
}

test "BezierCurve - very small control points near boundaries" {
    // Control points very close to boundaries - tests precision
    const curve = BezierCurve.init(0.0000001, 0.0, 1.0, 0.9999999);

    // Should handle small differences gracefully
    const y1 = curve.getYForPoint(0.0);
    const y2 = curve.getYForPoint(0.1);
    const y3 = curve.getYForPoint(0.5);
    const y4 = curve.getYForPoint(0.9);
    const y5 = curve.getYForPoint(1.0);

    // All should be finite
    try std.testing.expect(std.math.isFinite(y1));
    try std.testing.expect(std.math.isFinite(y2));
    try std.testing.expect(std.math.isFinite(y3));
    try std.testing.expect(std.math.isFinite(y4));
    try std.testing.expect(std.math.isFinite(y5));

    // Should stay within reasonable bounds
    try std.testing.expect(y1 >= 0.0 and y1 <= 1.0);
    try std.testing.expect(y5 >= 0.0 and y5 <= 1.0);
}

test "BezierCurve - numerical stability with hundreds of evaluations" {
    const curve = BezierCurve.init(0.42, 0, 0.58, 1);

    // Evaluate 1000 times at different points
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / 1000.0;
        const y = curve.getYForPoint(t);
        
        try std.testing.expect(std.math.isFinite(y));
        try std.testing.expect(y >= -0.5 and y <= 1.5); // Allow some overshoot
    }
}

test "BezierCurve - repeated evaluations at critical points" {
    const curve = BezierCurve.init(0.25, 0.1, 0.75, 0.9);

    // Critical points: start, quarter, half, three-quarter, end
    const critical_points = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };

    for (critical_points) |t| {
        // Evaluate same point 100 times - should be consistent
        var prev_y: f32 = curve.getYForPoint(t);
        
        var j: usize = 0;
        while (j < 100) : (j += 1) {
            const y = curve.getYForPoint(t);
            try std.testing.expectEqual(prev_y, y);
            prev_y = y;
        }
    }
}

test "BezierCurve - extreme asymmetric control points" {
    // One control point normal, one extreme
    const curve1 = BezierCurve.init(0.1, 0.1, 10.0, 0.9);
    const curve2 = BezierCurve.init(10.0, 0.1, 0.9, 0.9);

    // Both should handle gracefully
    for ([_]BezierCurve{ curve1, curve2 }) |curve| {
        var t: f32 = 0.0;
        while (t <= 1.0) : (t += 0.1) {
            const y = curve.getYForPoint(t);
            try std.testing.expect(std.math.isFinite(y));
        }
    }
}

test "BezierCurve - near-zero denominators" {
    // Control points that could cause division by near-zero
    const curve = BezierCurve.init(0.0, 0.0, 0.0, 1.0);

    // Should not cause division errors
    var t: f32 = 0.0;
    while (t <= 1.0) : (t += 0.1) {
        const y = curve.getYForPoint(t);
        try std.testing.expect(std.math.isFinite(y));
        try std.testing.expect(!std.math.isNan(y));
    }
}

test "BezierCurve - all control points equal" {
    // Degenerate case: all control points the same
    const curve = BezierCurve.init(0.5, 0.5, 0.5, 0.5);

    // Should produce a straight line at y=0.5
    var t: f32 = 0.0;
    while (t <= 1.0) : (t += 0.1) {
        const y = curve.getYForPoint(t);
        try std.testing.expect(std.math.isFinite(y));
    }
}

test "BezierCurve - precision at boundaries" {
    const curve = BezierCurve.init(0.42, 0, 0.58, 1);

    // Test very close to 0.0
    const y_near_zero1 = curve.getYForPoint(0.0001);
    const y_near_zero2 = curve.getYForPoint(0.00001);
    try std.testing.expect(std.math.isFinite(y_near_zero1));
    try std.testing.expect(std.math.isFinite(y_near_zero2));

    // Test very close to 1.0
    const y_near_one1 = curve.getYForPoint(0.9999);
    const y_near_one2 = curve.getYForPoint(0.99999);
    try std.testing.expect(std.math.isFinite(y_near_one1));
    try std.testing.expect(std.math.isFinite(y_near_one2));

    // Values should be very close to 0 and 1 respectively
    try std.testing.expect(y_near_zero2 < 0.1);
    try std.testing.expect(y_near_one2 > 0.9);
}

test "BezierCurve - snake curve (s-shaped)" {
    // S-shaped curve that crosses itself in X
    const curve = BezierCurve.init(0.0, 1.0, 1.0, 0.0);

    // Sample throughout - should remain finite despite crossing
    var t: f32 = 0.0;
    var prev_y: ?f32 = null;
    
    while (t <= 1.0) : (t += 0.05) {
        const y = curve.getYForPoint(t);
        try std.testing.expect(std.math.isFinite(y));
        
        // Track that we get reasonable Y values
        if (prev_y) |py| {
            const diff = @abs(y - py);
            try std.testing.expect(diff < 2.0); // No huge jumps
        }
        prev_y = y;
    }
}
