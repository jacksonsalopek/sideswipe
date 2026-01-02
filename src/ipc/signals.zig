//! Signal definitions for backend events and IPC communication
//! These signals bridge backend implementations to the compositor core

const std = @import("std");
const core = @import("core");
const Signal = core.events.Signal;
const backend = @import("backend");
const BackendType = backend.backend.Type;
const math = @import("core.math");
const Vector2D = math.Vector2D;

/// Keyboard key event data
pub const KeyboardKeyEvent = struct {
    time_msec: u32,
    key: u32,
    state: KeyState,
    output: ?*anyopaque = null, // Optional output context

    pub const KeyState = enum(u32) {
        released = 0,
        pressed = 1,
    };
};

/// Keyboard modifiers event data
pub const KeyboardModifiersEvent = struct {
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
    output: ?*anyopaque = null,
};

/// Pointer motion event data (relative)
pub const PointerMotionEvent = struct {
    time_msec: u32,
    delta_x: f64,
    delta_y: f64,
    output: ?*anyopaque = null,
};

/// Pointer motion event data (absolute)
pub const PointerMotionAbsoluteEvent = struct {
    time_msec: u32,
    x: f64,
    y: f64,
    output: ?*anyopaque = null,
};

/// Pointer button event data
pub const PointerButtonEvent = struct {
    time_msec: u32,
    button: u32,
    state: ButtonState,
    serial: u32 = 0,
    output: ?*anyopaque = null,

    pub const ButtonState = enum(u32) {
        released = 0,
        pressed = 1,
    };
};

/// Pointer axis event data (scroll)
pub const PointerAxisEvent = struct {
    time_msec: u32,
    source: AxisSource,
    orientation: AxisOrientation,
    delta: f64,
    delta_discrete: i32,
    output: ?*anyopaque = null,

    pub const AxisSource = enum(u32) {
        wheel = 0,
        finger = 1,
        continuous = 2,
        wheel_tilt = 3,
    };

    pub const AxisOrientation = enum(u32) {
        vertical = 0,
        horizontal = 1,
    };
};

/// Pointer enter event (focus)
pub const PointerEnterEvent = struct {
    surface_x: f64,
    surface_y: f64,
    serial: u32,
    output: ?*anyopaque = null,
};

/// Pointer leave event (unfocus)
pub const PointerLeaveEvent = struct {
    serial: u32,
    output: ?*anyopaque = null,
};

/// Frame event for render timing
pub const FrameEvent = struct {
    time_msec: u32,
    output: ?*anyopaque,
};

/// Output configure event (resize, etc.)
pub const OutputConfigureEvent = struct {
    width: i32,
    height: i32,
    output: *anyopaque,
};

/// Output close event
pub const OutputCloseEvent = struct {
    output: *anyopaque,
};

/// Output ready event (initialized)
pub const OutputReadyEvent = struct {
    output: *anyopaque,
};

/// Backend ready event
pub const BackendReadyEvent = struct {
    backend_type: BackendType,
};

/// Signal manager holding all backend event signals
pub const Manager = struct {
    allocator: std.mem.Allocator,

    // Keyboard signals
    keyboard_key: Signal(KeyboardKeyEvent),
    keyboard_modifiers: Signal(KeyboardModifiersEvent),

    // Pointer signals
    pointer_motion: Signal(PointerMotionEvent),
    pointer_motion_absolute: Signal(PointerMotionAbsoluteEvent),
    pointer_button: Signal(PointerButtonEvent),
    pointer_axis: Signal(PointerAxisEvent),
    pointer_enter: Signal(PointerEnterEvent),
    pointer_leave: Signal(PointerLeaveEvent),

    // Frame/render signals
    frame: Signal(FrameEvent),

    // Output signals
    output_configure: Signal(OutputConfigureEvent),
    output_close: Signal(OutputCloseEvent),
    output_ready: Signal(OutputReadyEvent),

    // Backend signals
    backend_ready: Signal(BackendReadyEvent),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .keyboard_key = Signal(KeyboardKeyEvent).init(allocator),
            .keyboard_modifiers = Signal(KeyboardModifiersEvent).init(allocator),
            .pointer_motion = Signal(PointerMotionEvent).init(allocator),
            .pointer_motion_absolute = Signal(PointerMotionAbsoluteEvent).init(allocator),
            .pointer_button = Signal(PointerButtonEvent).init(allocator),
            .pointer_axis = Signal(PointerAxisEvent).init(allocator),
            .pointer_enter = Signal(PointerEnterEvent).init(allocator),
            .pointer_leave = Signal(PointerLeaveEvent).init(allocator),
            .frame = Signal(FrameEvent).init(allocator),
            .output_configure = Signal(OutputConfigureEvent).init(allocator),
            .output_close = Signal(OutputCloseEvent).init(allocator),
            .output_ready = Signal(OutputReadyEvent).init(allocator),
            .backend_ready = Signal(BackendReadyEvent).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.keyboard_key.deinit();
        self.keyboard_modifiers.deinit();
        self.pointer_motion.deinit();
        self.pointer_motion_absolute.deinit();
        self.pointer_button.deinit();
        self.pointer_axis.deinit();
        self.pointer_enter.deinit();
        self.pointer_leave.deinit();
        self.frame.deinit();
        self.output_configure.deinit();
        self.output_close.deinit();
        self.output_ready.deinit();
        self.backend_ready.deinit();
    }

    /// Clear all non-static listeners
    pub fn clearAll(self: *Self) void {
        self.keyboard_key.clear();
        self.keyboard_modifiers.clear();
        self.pointer_motion.clear();
        self.pointer_motion_absolute.clear();
        self.pointer_button.clear();
        self.pointer_axis.clear();
        self.pointer_enter.clear();
        self.pointer_leave.clear();
        self.frame.clear();
        self.output_configure.clear();
        self.output_close.clear();
        self.output_ready.clear();
        self.backend_ready.clear();
    }
};

// Tests
test "Manager - initialization and cleanup" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    // Verify all signals are initialized
    try testing.expect(manager.keyboard_key.listeners.items.len == 0);
    try testing.expect(manager.pointer_motion.listeners.items.len == 0);
    try testing.expect(manager.frame.listeners.items.len == 0);
}

test "KeyboardKeyEvent - signal emission" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var last_key: u32 = 0;
        var count: i32 = 0;

        fn callback(event: KeyboardKeyEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            last_key = event.key;
            count += 1;
        }
    };
    State.last_key = 0;
    State.count = 0;

    var listener = try manager.keyboard_key.listen(State.callback, null);
    defer listener.deinit();

    manager.keyboard_key.emit(.{
        .time_msec = 1000,
        .key = 42,
        .state = .pressed,
    });

    try testing.expectEqual(@as(u32, 42), State.last_key);
    try testing.expectEqual(@as(i32, 1), State.count);
}

test "PointerMotionEvent - signal emission" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var delta_x: f64 = 0;
        var delta_y: f64 = 0;

        fn callback(event: PointerMotionEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            delta_x = event.delta_x;
            delta_y = event.delta_y;
        }
    };
    State.delta_x = 0;
    State.delta_y = 0;

    var listener = try manager.pointer_motion.listen(State.callback, null);
    defer listener.deinit();

    manager.pointer_motion.emit(.{
        .time_msec = 2000,
        .delta_x = 10.5,
        .delta_y = -5.2,
    });

    try testing.expectEqual(@as(f64, 10.5), State.delta_x);
    try testing.expectEqual(@as(f64, -5.2), State.delta_y);
}

test "FrameEvent - signal emission" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var time: u32 = 0;
        var count: i32 = 0;

        fn callback(event: FrameEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            time = event.time_msec;
            count += 1;
        }
    };
    State.time = 0;
    State.count = 0;

    var listener = try manager.frame.listen(State.callback, null);
    defer listener.deinit();

    // Simulate multiple frames
    manager.frame.emit(.{ .time_msec = 16, .output = null });
    manager.frame.emit(.{ .time_msec = 32, .output = null });
    manager.frame.emit(.{ .time_msec = 48, .output = null });

    try testing.expectEqual(@as(u32, 48), State.time);
    try testing.expectEqual(@as(i32, 3), State.count);
}

test "Manager - multiple listeners on same signal" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var count1: i32 = 0;
        var count2: i32 = 0;

        fn callback1(event: PointerButtonEvent, userdata: ?*anyopaque) void {
            _ = event;
            _ = userdata;
            count1 += 1;
        }

        fn callback2(event: PointerButtonEvent, userdata: ?*anyopaque) void {
            _ = event;
            _ = userdata;
            count2 += 1;
        }
    };
    State.count1 = 0;
    State.count2 = 0;

    var listener1 = try manager.pointer_button.listen(State.callback1, null);
    defer listener1.deinit();

    var listener2 = try manager.pointer_button.listen(State.callback2, null);
    defer listener2.deinit();

    manager.pointer_button.emit(.{
        .time_msec = 1000,
        .button = 272,
        .state = .pressed,
    });

    try testing.expectEqual(@as(i32, 1), State.count1);
    try testing.expectEqual(@as(i32, 1), State.count2);
}

test "Manager - clearAll removes listeners" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var count: i32 = 0;

        fn callback(event: KeyboardKeyEvent, userdata: ?*anyopaque) void {
            _ = event;
            _ = userdata;
            count += 1;
        }
    };
    State.count = 0;

    _ = try manager.keyboard_key.listen(State.callback, null);

    manager.keyboard_key.emit(.{
        .time_msec = 1000,
        .key = 10,
        .state = .pressed,
    });

    try testing.expectEqual(@as(i32, 1), State.count);

    manager.clearAll();

    manager.keyboard_key.emit(.{
        .time_msec = 2000,
        .key = 20,
        .state = .pressed,
    });

    // Count should still be 1 (listener was cleared)
    try testing.expectEqual(@as(i32, 1), State.count);
}

test "OutputConfigureEvent - signal emission" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var width: i32 = 0;
        var height: i32 = 0;

        fn callback(event: OutputConfigureEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            width = event.width;
            height = event.height;
        }
    };
    State.width = 0;
    State.height = 0;

    var listener = try manager.output_configure.listen(State.callback, null);
    defer listener.deinit();

    var dummy_output: u32 = 0;
    manager.output_configure.emit(.{
        .width = 1920,
        .height = 1080,
        .output = &dummy_output,
    });

    try testing.expectEqual(@as(i32, 1920), State.width);
    try testing.expectEqual(@as(i32, 1080), State.height);
}

test "PointerAxisEvent - all sources and orientations" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var last_source: PointerAxisEvent.AxisSource = .wheel;
        var last_orientation: PointerAxisEvent.AxisOrientation = .vertical;

        fn callback(event: PointerAxisEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            last_source = event.source;
            last_orientation = event.orientation;
        }
    };

    var listener = try manager.pointer_axis.listen(State.callback, null);
    defer listener.deinit();

    // Test different sources
    manager.pointer_axis.emit(.{
        .time_msec = 1000,
        .source = .finger,
        .orientation = .horizontal,
        .delta = 10.0,
        .delta_discrete = 1,
    });

    try testing.expectEqual(PointerAxisEvent.AxisSource.finger, State.last_source);
    try testing.expectEqual(PointerAxisEvent.AxisOrientation.horizontal, State.last_orientation);
}

test "BackendReadyEvent - signal emission" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const State = struct {
        var backend_type: BackendType = .null;

        fn callback(event: BackendReadyEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            backend_type = event.backend_type;
        }
    };
    State.backend_type = .null;

    var listener = try manager.backend_ready.listen(State.callback, null);
    defer listener.deinit();

    manager.backend_ready.emit(.{ .backend_type = .wayland });

    try testing.expectEqual(BackendType.wayland, State.backend_type);
}
