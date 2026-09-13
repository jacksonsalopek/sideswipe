//! Touchscreen translator (I4): edge swipes, long-press, pinch.

const std = @import("std");
const testing = @import("core").testing;
const gesture = @import("gesture.zig");

pub const Config = struct {
    gesture: gesture.Config = .{
        .hold_usec = 500_000,
        .dead_zone = 10,
    },
    edge_px: f64 = 24,
};

pub const Viewport = struct {
    width: f64 = 1920,
    height: f64 = 1080,
};

const Edge = enum { left, top, bottom };

const Slot = struct {
    id: i32 = 0,
    active: bool = false,
    origin: gesture.Point = .{},
    current: gesture.Point = .{},
    started_usec: u64 = 0,
};

pub const Translator = struct {
    config: Config = .{},
    viewport: Viewport = .{},
    slots: [8]Slot = @splat(.{}),
    edge: ?Edge = null,
    claimed: bool = false,
    hold_emitted: bool = false,
    pinch_base: f64 = 0,
    last_pinch: f64 = 1,

    pub fn down(
        self: *Translator,
        time_usec: u64,
        id: i32,
        point: gesture.Point,
    ) !gesture.Translation {
        try validate(point);
        const slot = self.activate(id, time_usec, point) orelse return error.TooManyTouches;
        if (self.activeCount() == 1) {
            self.edge = edgeAt(self.config, self.viewport, point);
            self.claimed = false;
            self.hold_emitted = false;
            _ = slot;
            return .{};
        }
        if (self.activeCount() == 2) {
            self.pinch_base = self.fingerDistance();
            self.last_pinch = 1;
            self.edge = null;
        }
        return .{};
    }

    pub fn motion(
        self: *Translator,
        time_usec: u64,
        id: i32,
        point: gesture.Point,
    ) !gesture.Translation {
        try validate(point);
        const slot = self.slotById(id) orelse return .{};
        slot.current = point;
        if (self.activeCount() >= 2) return self.pinch(time_usec);
        if (self.edge) |side| return self.edgeMotion(time_usec, side);
        return .{};
    }

    pub fn up(self: *Translator, time_usec: u64, id: i32) !gesture.Translation {
        const slot = self.slotById(id) orelse return .{};
        const origin = slot.origin;
        const current = slot.current;
        const started = slot.started_usec;
        slot.active = false;
        if (self.activeCount() >= 1) {
            if (self.claimed) return .{ .consumed = true, .claimed = true };
            return .{};
        }
        const edge = self.edge;
        const claimed = self.claimed;
        self.reset();
        if (claimed) return finishClaimed(time_usec, started, edge, origin, current);
        return .{};
    }

    pub fn cancel(self: *Translator) void {
        self.reset();
    }

    pub fn tick(self: *Translator, time_usec: u64) ?gesture.Translation {
        if (self.activeCount() != 1 or self.edge != null or self.hold_emitted) return null;
        const slot = self.firstActive() orelse return null;
        if (distance(slot.origin, slot.current) > self.config.gesture.dead_zone) return null;
        if (elapsed(slot.started_usec, time_usec) < self.config.gesture.hold_usec) return null;
        self.hold_emitted = true;
        return .{
            .consumed = false,
            .claimed = true,
            .primitive = .{ .hold = .{ .time_usec = time_usec, .point = slot.origin } },
        };
    }

    fn edgeMotion(self: *Translator, time_usec: u64, side: Edge) gesture.Translation {
        const slot = self.firstActive() orelse return .{};
        const delta = gesture.Point{
            .x = slot.current.x - slot.origin.x,
            .y = slot.current.y - slot.origin.y,
        };
        if (std.math.hypot(delta.x, delta.y) < self.config.gesture.axis_lock_distance) return .{};
        return switch (side) {
            .left => self.claimBack(time_usec),
            .top => self.progress(time_usec, .down, delta.y, delta),
            .bottom => self.bottom(time_usec, delta),
        };
    }

    fn claimBack(self: *Translator, time_usec: u64) gesture.Translation {
        if (self.claimed) return .{ .consumed = true, .claimed = true };
        return self.claim(.{ .back = .{ .time_usec = time_usec } });
    }

    fn bottom(self: *Translator, time_usec: u64, delta: gesture.Point) gesture.Translation {
        const direction = cone(delta, self.config.gesture.cone_degrees) orelse return .{};
        if (direction == .down) return .{};
        return self.progress(time_usec, direction, amount(delta, direction), delta);
    }

    fn progress(
        self: *Translator,
        time_usec: u64,
        direction: gesture.Direction,
        signed: f64,
        _: gesture.Point,
    ) gesture.Translation {
        if (signed <= 0) return .{};
        const value = std.math.clamp(signed / self.config.gesture.drag_extent, 0, 1);
        return self.claim(.{ .drag = .{
            .time_usec = time_usec,
            .direction = direction,
            .progress = value,
        } });
    }

    fn pinch(self: *Translator, time_usec: u64) gesture.Translation {
        if (self.pinch_base <= 0) return .{};
        const scale = self.fingerDistance() / self.pinch_base;
        const delta = (scale - self.last_pinch) * gesture.Primitive.pinch_zoom_units;
        self.last_pinch = scale;
        return self.claim(.{ .zoom = .{ .time_usec = time_usec, .delta = delta } });
    }

    fn claim(self: *Translator, primitive: gesture.Primitive) gesture.Translation {
        self.claimed = true;
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = primitive,
        };
    }

    fn activate(self: *Translator, id: i32, time_usec: u64, point: gesture.Point) ?*Slot {
        if (self.slotById(id)) |existing| {
            existing.origin = point;
            existing.current = point;
            existing.started_usec = time_usec;
            existing.active = true;
            return existing;
        }
        for (&self.slots) |*slot| {
            if (slot.active) continue;
            slot.* = .{
                .id = id,
                .active = true,
                .origin = point,
                .current = point,
                .started_usec = time_usec,
            };
            return slot;
        }
        return null;
    }

    fn slotById(self: *Translator, id: i32) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.active and slot.id == id) return slot;
        }
        return null;
    }

    pub fn centroid(self: *const Translator) gesture.Point {
        var sum = gesture.Point{};
        var count: f64 = 0;
        for (self.slots) |slot| {
            if (!slot.active) continue;
            sum.x += slot.current.x;
            sum.y += slot.current.y;
            count += 1;
        }
        if (count == 0) return sum;
        return .{ .x = sum.x / count, .y = sum.y / count };
    }

    pub fn holdDeadline(self: *const Translator) u64 {
        for (self.slots) |slot| {
            if (slot.active) return slot.started_usec + self.config.gesture.hold_usec;
        }
        return 0;
    }

    fn firstActive(self: *Translator) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.active) return slot;
        }
        return null;
    }

    fn activeCount(self: *const Translator) u32 {
        var count: u32 = 0;
        for (self.slots) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }

    fn fingerDistance(self: *const Translator) f64 {
        var first: ?gesture.Point = null;
        var second: ?gesture.Point = null;
        for (self.slots) |slot| {
            if (!slot.active) continue;
            if (first == null) {
                first = slot.current;
            } else if (second == null) {
                second = slot.current;
            }
        }
        const a = first orelse return 0;
        const b = second orelse return 0;
        return distance(a, b);
    }

    fn reset(self: *Translator) void {
        self.slots = @splat(.{});
        self.edge = null;
        self.claimed = false;
        self.hold_emitted = false;
        self.pinch_base = 0;
        self.last_pinch = 1;
    }
};

fn finishClaimed(
    time_usec: u64,
    started_usec: u64,
    edge: ?Edge,
    origin: gesture.Point,
    current: gesture.Point,
) gesture.Translation {
    if (edge == .left) {
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .release = .{ .time_usec = time_usec } },
        };
    }
    const delta = gesture.Point{ .x = current.x - origin.x, .y = current.y - origin.y };
    const direction = cone(delta, 30) orelse {
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .release = .{ .time_usec = time_usec } },
        };
    };
    if (elapsed(started_usec, time_usec) <= 300_000 and std.math.hypot(delta.x, delta.y) > 6) {
        return .{
            .consumed = true,
            .claimed = true,
            .primitive = .{ .flick = .{ .time_usec = time_usec, .direction = direction } },
        };
    }
    return .{
        .consumed = true,
        .claimed = true,
        .primitive = .{ .release = .{ .time_usec = time_usec } },
    };
}

fn edgeAt(config: Config, viewport: Viewport, point: gesture.Point) ?Edge {
    if (point.x <= config.edge_px) return .left;
    if (point.y <= config.edge_px) return .top;
    if (point.y >= viewport.height - config.edge_px) return .bottom;
    return null;
}

fn cone(delta: gesture.Point, degrees: f64) ?gesture.Direction {
    const radians = degrees * std.math.pi / 180;
    const slope = @tan(radians);
    const abs_x = @abs(delta.x);
    const abs_y = @abs(delta.y);
    if (abs_y <= abs_x * slope) return if (delta.x < 0) .left else .right;
    if (abs_x <= abs_y * slope) return if (delta.y < 0) .up else .down;
    return null;
}

fn amount(delta: gesture.Point, direction: gesture.Direction) f64 {
    return switch (direction) {
        .left => -delta.x,
        .right => delta.x,
        .up => -delta.y,
        .down => delta.y,
    };
}

fn elapsed(start: u64, end: u64) u64 {
    return end -% start;
}

fn distance(a: gesture.Point, b: gesture.Point) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

fn validate(point: gesture.Point) !void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidCoordinate;
}

test "left-edge swipe becomes back and is claimed" {
    var translator = Translator{};
    try testing.expectNull((try translator.down(0, 0, .{ .x = 8, .y = 200 })).primitive);
    const move = try translator.motion(10, 0, .{ .x = 40, .y = 200 });
    try testing.expectEqual(std.meta.Tag(gesture.Primitive).back, std.meta.activeTag(move.primitive.?));
    try testing.expect(move.consumed);
    const again = try translator.motion(20, 0, .{ .x = 80, .y = 200 });
    try testing.expectNull(again.primitive);
    try testing.expect(again.claimed);
}

test "bottom-edge swipe reports upward drag then flick" {
    var translator = Translator{ .viewport = .{ .width = 400, .height = 800 } };
    _ = try translator.down(0, 1, .{ .x = 200, .y = 790 });
    const drag = try translator.motion(20, 1, .{ .x = 200, .y = 740 });
    try testing.expectEqual(gesture.Direction.up, drag.primitive.?.drag.direction);
    const end = try translator.up(80_000, 1);
    try testing.expectEqual(gesture.Direction.up, end.primitive.?.flick.direction);
}

test "top-edge swipe is downward drag" {
    var translator = Translator{};
    _ = try translator.down(0, 0, .{ .x = 100, .y = 10 });
    const drag = try translator.motion(20, 0, .{ .x = 100, .y = 80 });
    try testing.expectEqual(gesture.Direction.down, drag.primitive.?.drag.direction);
}

test "interior long-press is hold and not consumed" {
    var translator = Translator{};
    _ = try translator.down(0, 0, .{ .x = 200, .y = 200 });
    try testing.expectNull(translator.tick(499_999));
    const hold = translator.tick(500_000).?;
    try testing.expectEqual(std.meta.Tag(gesture.Primitive).hold, std.meta.activeTag(hold.primitive.?));
    try testing.expectFalse(hold.consumed);
    try testing.expect(hold.claimed);
}

test "two-finger pinch zooms" {
    var translator = Translator{};
    _ = try translator.down(0, 0, .{ .x = 100, .y = 100 });
    _ = try translator.down(1, 1, .{ .x = 140, .y = 100 });
    const zoom = try translator.motion(2, 1, .{ .x = 180, .y = 100 });
    try testing.expectEqual(std.meta.Tag(gesture.Primitive).zoom, std.meta.activeTag(zoom.primitive.?));
    try testing.expect(zoom.primitive.?.zoom.delta > 0);
}

test "interior motion is not claimed" {
    var translator = Translator{};
    _ = try translator.down(0, 0, .{ .x = 200, .y = 200 });
    const move = try translator.motion(1, 0, .{ .x = 260, .y = 200 });
    try testing.expectFalse(move.consumed);
    try testing.expectNull(move.primitive);
}
