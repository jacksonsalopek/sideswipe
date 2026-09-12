const std = @import("std");

pub const c = @cImport({
    @cInclude("libinput.h");
});

// Core types
pub const Context = c.struct_libinput;
pub const Device = c.struct_libinput_device;
pub const Event = c.struct_libinput_event;

// Event-specific types
pub const EventKeyboard = c.struct_libinput_event_keyboard;
pub const EventPointer = c.struct_libinput_event_pointer;
pub const EventTouch = c.struct_libinput_event_touch;
pub const EventTabletTool = c.struct_libinput_event_tablet_tool;
pub const EventTabletPad = c.struct_libinput_event_tablet_pad;
pub const EventGesture = c.struct_libinput_event_gesture;
pub const EventSwitch = c.struct_libinput_event_switch;

// Tablet-specific types
pub const TabletTool = c.struct_libinput_tablet_tool;
pub const TabletPadModeGroup = c.struct_libinput_tablet_pad_mode_group;

pub const EventType = enum(c_int) {
    none = c.LIBINPUT_EVENT_NONE,
    device_added = c.LIBINPUT_EVENT_DEVICE_ADDED,
    device_removed = c.LIBINPUT_EVENT_DEVICE_REMOVED,
    keyboard_key = c.LIBINPUT_EVENT_KEYBOARD_KEY,
    pointer_motion = c.LIBINPUT_EVENT_POINTER_MOTION,
    pointer_motion_absolute = c.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE,
    pointer_button = c.LIBINPUT_EVENT_POINTER_BUTTON,
    pointer_axis = c.LIBINPUT_EVENT_POINTER_AXIS,
    touch_down = c.LIBINPUT_EVENT_TOUCH_DOWN,
    touch_up = c.LIBINPUT_EVENT_TOUCH_UP,
    touch_motion = c.LIBINPUT_EVENT_TOUCH_MOTION,
    touch_cancel = c.LIBINPUT_EVENT_TOUCH_CANCEL,
    touch_frame = c.LIBINPUT_EVENT_TOUCH_FRAME,
    tablet_tool_axis = c.LIBINPUT_EVENT_TABLET_TOOL_AXIS,
    tablet_tool_proximity = c.LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY,
    tablet_tool_tip = c.LIBINPUT_EVENT_TABLET_TOOL_TIP,
    tablet_tool_button = c.LIBINPUT_EVENT_TABLET_TOOL_BUTTON,
    tablet_pad_button = c.LIBINPUT_EVENT_TABLET_PAD_BUTTON,
    tablet_pad_ring = c.LIBINPUT_EVENT_TABLET_PAD_RING,
    tablet_pad_strip = c.LIBINPUT_EVENT_TABLET_PAD_STRIP,
    gesture_swipe_begin = c.LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN,
    gesture_swipe_update = c.LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE,
    gesture_swipe_end = c.LIBINPUT_EVENT_GESTURE_SWIPE_END,
    gesture_pinch_begin = c.LIBINPUT_EVENT_GESTURE_PINCH_BEGIN,
    gesture_pinch_update = c.LIBINPUT_EVENT_GESTURE_PINCH_UPDATE,
    gesture_pinch_end = c.LIBINPUT_EVENT_GESTURE_PINCH_END,
    gesture_hold_begin = c.LIBINPUT_EVENT_GESTURE_HOLD_BEGIN,
    gesture_hold_end = c.LIBINPUT_EVENT_GESTURE_HOLD_END,
    switch_toggle = c.LIBINPUT_EVENT_SWITCH_TOGGLE,
    _,
};

pub const DeviceCapability = enum(c_int) {
    keyboard = c.LIBINPUT_DEVICE_CAP_KEYBOARD,
    pointer = c.LIBINPUT_DEVICE_CAP_POINTER,
    touch = c.LIBINPUT_DEVICE_CAP_TOUCH,
    tablet_tool = c.LIBINPUT_DEVICE_CAP_TABLET_TOOL,
    tablet_pad = c.LIBINPUT_DEVICE_CAP_TABLET_PAD,
    gesture = c.LIBINPUT_DEVICE_CAP_GESTURE,
    switch_device = c.LIBINPUT_DEVICE_CAP_SWITCH,
};

pub const KeyState = enum(c_int) {
    released = c.LIBINPUT_KEY_STATE_RELEASED,
    pressed = c.LIBINPUT_KEY_STATE_PRESSED,
};

pub const ButtonState = enum(c_int) {
    released = c.LIBINPUT_BUTTON_STATE_RELEASED,
    pressed = c.LIBINPUT_BUTTON_STATE_PRESSED,
};

pub const PointerAxis = enum(c_int) {
    scroll_vertical = c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL,
    scroll_horizontal = c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL,
};

pub const PointerAxisSource = enum(c_int) {
    wheel = c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL,
    finger = c.LIBINPUT_POINTER_AXIS_SOURCE_FINGER,
    continuous = c.LIBINPUT_POINTER_AXIS_SOURCE_CONTINUOUS,
    wheel_tilt = c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL_TILT,
};

pub const SwitchState = enum(c_int) {
    off = c.LIBINPUT_SWITCH_STATE_OFF,
    on = c.LIBINPUT_SWITCH_STATE_ON,
};

pub const Switch = enum(c_int) {
    lid = c.LIBINPUT_SWITCH_LID,
    tablet_mode = c.LIBINPUT_SWITCH_TABLET_MODE,
};

pub const TabletToolProximityState = enum(c_int) {
    out = c.LIBINPUT_TABLET_TOOL_PROXIMITY_STATE_OUT,
    in = c.LIBINPUT_TABLET_TOOL_PROXIMITY_STATE_IN,
};

pub const TabletToolTipState = enum(c_int) {
    up = c.LIBINPUT_TABLET_TOOL_TIP_UP,
    down = c.LIBINPUT_TABLET_TOOL_TIP_DOWN,
};

pub const TabletPadRingSource = enum(c_int) {
    unknown = c.LIBINPUT_TABLET_PAD_RING_SOURCE_UNKNOWN,
    finger = c.LIBINPUT_TABLET_PAD_RING_SOURCE_FINGER,
};

pub const TabletPadStripSource = enum(c_int) {
    unknown = c.LIBINPUT_TABLET_PAD_STRIP_SOURCE_UNKNOWN,
    finger = c.LIBINPUT_TABLET_PAD_STRIP_SOURCE_FINGER,
};

/// Queries a single device capability bit.
pub fn hasCapability(device: *Device, capability: DeviceCapability) bool {
    const raw: c.enum_libinput_device_capability = @intCast(@intFromEnum(capability));
    return c.libinput_device_has_capability(device, raw) != 0;
}

const testing = std.testing;

test "hasCapability - signature accepts all capabilities" {
    // Compile-time check that every DeviceCapability maps to a libinput constant.
    const caps = [_]DeviceCapability{ .keyboard, .pointer, .touch, .tablet_tool, .tablet_pad, .gesture, .switch_device };
    for (caps) |cap| {
        _ = @intFromEnum(cap);
    }
}

test "tablet enums - distinct states" {
    try testing.expect(TabletToolProximityState.out != TabletToolProximityState.in);
    try testing.expect(TabletToolTipState.up != TabletToolTipState.down);
    try testing.expect(TabletPadRingSource.unknown != TabletPadRingSource.finger);
    try testing.expect(TabletPadStripSource.unknown != TabletPadStripSource.finger);
}

test "unknown event tags remain representable" {
    const event_type: EventType = @enumFromInt(0x7fff);
    const handled = switch (event_type) {
        .none => true,
        else => false,
    };
    try testing.expect(!handled);
}
