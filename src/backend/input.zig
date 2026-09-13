const std = @import("std");
const core = @import("core");
const string = @import("core.string").string;
const libinput = @import("libinput.zig");

/// Per-device capability bitset (I1). Multi-capability devices such as
/// touchpads report several bits; translators are chosen per capability,
/// never from a single device class.
pub const Capabilities = packed struct(u8) {
    keyboard: bool = false,
    pointer: bool = false,
    touch: bool = false,
    tablet_tool: bool = false,
    tablet_pad: bool = false,
    gesture: bool = false,
    switch_device: bool = false,
    _reserved: bool = false,

    pub fn none() Capabilities {
        return .{};
    }

    pub fn all() Capabilities {
        return .{
            .keyboard = true,
            .pointer = true,
            .touch = true,
            .tablet_tool = true,
            .tablet_pad = true,
            .gesture = true,
            .switch_device = true,
        };
    }

    pub fn fromLibinput(device: *libinput.Device) Capabilities {
        return .{
            .keyboard = libinput.hasCapability(device, .keyboard),
            .pointer = libinput.hasCapability(device, .pointer),
            .touch = libinput.hasCapability(device, .touch),
            .tablet_tool = libinput.hasCapability(device, .tablet_tool),
            .tablet_pad = libinput.hasCapability(device, .tablet_pad),
            .gesture = libinput.hasCapability(device, .gesture),
            .switch_device = libinput.hasCapability(device, .switch_device),
        };
    }

    pub fn has(self: Capabilities, capability: libinput.DeviceCapability) bool {
        return switch (capability) {
            .keyboard => self.keyboard,
            .pointer => self.pointer,
            .touch => self.touch,
            .tablet_tool => self.tablet_tool,
            .tablet_pad => self.tablet_pad,
            .gesture => self.gesture,
            .switch_device => self.switch_device,
        };
    }

    pub fn count(self: Capabilities) u32 {
        return @popCount(@as(u8, @bitCast(self)));
    }

    pub fn isEmpty(self: Capabilities) bool {
        return @as(u8, @bitCast(self)) == 0;
    }
};

pub const Device = struct {
    name: string,
    sysname: string,
    vendor: u32,
    product: u32,
    capabilities: Capabilities = .{},
    has_side_button: bool = false,
    has_extra_button: bool = false,
    enabled: bool = true,

    libinput_device: *libinput.Device,
    owns_reference: bool = false,
    allocator: std.mem.Allocator,

    pub fn fromLibinput(allocator: std.mem.Allocator, device: *libinput.Device) !*Device {
        const dev = try allocator.create(Device);
        errdefer allocator.destroy(dev);

        const name = libinput.c.libinput_device_get_name(device);
        const sysname = libinput.c.libinput_device_get_sysname(device);
        const name_copy = try allocator.dupe(u8, std.mem.span(name));
        errdefer allocator.free(name_copy);
        const sysname_copy = try allocator.dupe(u8, std.mem.span(sysname));
        errdefer allocator.free(sysname_copy);

        const capabilities = Capabilities.fromLibinput(device);
        dev.* = .{
            .name = name_copy,
            .sysname = sysname_copy,
            .vendor = @intCast(libinput.c.libinput_device_get_id_vendor(device)),
            .product = @intCast(libinput.c.libinput_device_get_id_product(device)),
            .capabilities = capabilities,
            .has_side_button = libinput.c.libinput_device_pointer_has_button(device, 0x113) > 0,
            .has_extra_button = libinput.c.libinput_device_pointer_has_button(device, 0x114) > 0,
            .libinput_device = device,
            .owns_reference = true,
            .allocator = allocator,
        };

        // Keep device alive by adding a reference
        _ = libinput.c.libinput_device_ref(device);

        return dev;
    }

    pub fn deinit(self: *Device) void {
        if (self.owns_reference) _ = libinput.c.libinput_device_unref(self.libinput_device);
        self.allocator.free(self.name);
        self.allocator.free(self.sysname);
        self.allocator.destroy(self);
    }
};

pub const Event = union(enum) {
    keyboard_key: KeyboardKeyEvent,
    pointer_motion: PointerMotionEvent,
    pointer_motion_absolute: PointerMotionAbsoluteEvent,
    pointer_button: PointerButtonEvent,
    pointer_axis: PointerAxisEvent,
    gesture_swipe_begin: GestureSwipe,
    gesture_swipe_update: GestureSwipe,
    gesture_swipe_end: GestureSwipe,
    gesture_pinch_begin: GesturePinch,
    gesture_pinch_update: GesturePinch,
    gesture_pinch_end: GesturePinch,
    gesture_hold_begin: GestureHold,
    gesture_hold_end: GestureHold,
    touch_down: Touch,
    touch_up: TouchUp,
    touch_motion: Touch,
    touch_frame: TouchFrame,
    touch_cancel: TouchUp,
    tablet_tool_axis: TabletToolAxis,
    tablet_tool_proximity: TabletToolProximity,
    tablet_tool_tip: TabletToolTip,
    tablet_tool_button: TabletToolButton,
    tablet_pad_button: TabletPadButton,
    tablet_pad_ring: TabletPadRing,
    tablet_pad_strip: TabletPadStrip,
    switch_toggle: Switch,
    device_added: DeviceEvent,
    device_removed: DeviceEvent,

    pub const KeyboardKeyEvent = struct {
        device: *Device,
        time_usec: u64,
        key: u32,
        state: libinput.KeyState,
    };

    pub const PointerMotionEvent = struct {
        device: *Device,
        time_usec: u64,
        delta_x: f64,
        delta_y: f64,
        unaccel_delta_x: f64,
        unaccel_delta_y: f64,
    };

    pub const PointerMotionAbsoluteEvent = struct {
        device: *Device,
        time_usec: u64,
        x: f64,
        y: f64,
    };

    pub const PointerButtonEvent = struct {
        device: *Device,
        time_usec: u64,
        button: u32,
        state: libinput.ButtonState,
    };

    pub const PointerAxisEvent = struct {
        device: *Device,
        time_usec: u64,
        axis: libinput.PointerAxis,
        value: f64,
        value_discrete: i32,
        source: libinput.PointerAxisSource,
    };

    pub const DeviceEvent = struct {
        device: *Device,
    };

    pub const GestureSwipe = struct {
        device: *Device,
        time_usec: u64,
        fingers: u32,
        delta_x: f64,
        delta_y: f64,
        cancelled: bool,
    };

    pub const GesturePinch = struct {
        device: *Device,
        time_usec: u64,
        fingers: u32,
        delta_x: f64,
        delta_y: f64,
        scale: f64,
        rotation: f64,
        cancelled: bool,
    };

    pub const GestureHold = struct {
        device: *Device,
        time_usec: u64,
        fingers: u32,
        cancelled: bool,
    };

    pub const Touch = struct {
        device: *Device,
        time_usec: u64,
        slot: i32,
        /// Normalized 0..1 surface coordinates.
        x: f64,
        y: f64,
    };

    pub const TouchUp = struct {
        device: *Device,
        time_usec: u64,
        slot: i32,
    };

    pub const TouchFrame = struct {
        device: *Device,
        time_usec: u64,
    };

    pub const TabletToolAxis = struct {
        device: *Device,
        time_usec: u64,
        /// Normalized 0..1 coordinates.
        x: f64,
        y: f64,
        pressure: f64,
        tilt_x: f64,
        tilt_y: f64,
        rotation: f64,
        distance: f64,
    };

    pub const TabletToolProximity = struct {
        device: *Device,
        time_usec: u64,
        x: f64,
        y: f64,
        state: libinput.TabletToolProximityState,
    };

    pub const TabletToolTip = struct {
        device: *Device,
        time_usec: u64,
        x: f64,
        y: f64,
        state: libinput.TabletToolTipState,
    };

    pub const TabletToolButton = struct {
        device: *Device,
        time_usec: u64,
        button: u32,
        state: libinput.ButtonState,
        seat_button_count: u32,
    };

    pub const TabletPadButton = struct {
        device: *Device,
        time_usec: u64,
        button: u32,
        state: libinput.ButtonState,
    };

    pub const TabletPadRing = struct {
        device: *Device,
        time_usec: u64,
        ring: u32,
        position: f64,
        source: libinput.TabletPadRingSource,
    };

    pub const TabletPadStrip = struct {
        device: *Device,
        time_usec: u64,
        strip: u32,
        position: f64,
        source: libinput.TabletPadStripSource,
    };

    pub const Switch = struct {
        device: *Device,
        time_usec: u64,
        switch_kind: libinput.Switch,
        state: libinput.SwitchState,
    };
};

pub const EventQueue = struct {
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EventQueue {
        return .{
            .events = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.events.deinit(self.allocator);
    }

    pub fn push(self: *EventQueue, event: Event) !void {
        try self.events.append(self.allocator, event);
    }

    pub fn len(self: *const EventQueue) usize {
        return self.events.items.len;
    }

    pub fn pop(self: *EventQueue) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn drain(self: *EventQueue) []const Event {
        defer self.events.clearRetainingCapacity();
        return self.events.items;
    }

    pub fn clear(self: *EventQueue) void {
        self.events.clearRetainingCapacity();
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    libinput_context: *libinput.Context,
    owns_context: bool = true,
    devices: std.AutoHashMap(*libinput.Device, *Device),
    retired_devices: std.ArrayList(*Device),
    event_queue: EventQueue,

    pub const ContextFactory = *const fn (
        *const libinput.c.libinput_interface,
        ?*anyopaque,
        *anyopaque,
    ) ?*libinput.Context;

    pub fn init(allocator: std.mem.Allocator, udev: *anyopaque, seat_id: string) !Manager {
        return initWithFactory(allocator, udev, seat_id, createContext);
    }

    pub fn initWithFactory(
        allocator: std.mem.Allocator,
        udev: *anyopaque,
        seat_id: string,
        factory: ContextFactory,
    ) !Manager {
        const interface = libinput.c.libinput_interface{
            .open_restricted = openRestricted,
            .close_restricted = closeRestricted,
        };

        const ctx = factory(
            &interface,
            null,
            udev,
        ) orelse return error.LibinputContextFailed;

        const seat_id_z = try allocator.dupeZ(u8, seat_id);
        defer allocator.free(seat_id_z);
        if (libinput.c.libinput_udev_assign_seat(ctx, seat_id_z.ptr) != 0) {
            _ = libinput.c.libinput_unref(ctx);
            return error.SeatAssignFailed;
        }

        return .{
            .allocator = allocator,
            .libinput_context = ctx,
            .devices = std.AutoHashMap(*libinput.Device, *Device).init(allocator),
            .retired_devices = .empty,
            .event_queue = EventQueue.init(allocator),
        };
    }

    pub fn fromContext(allocator: std.mem.Allocator, context: *libinput.Context) Manager {
        return .{
            .allocator = allocator,
            .libinput_context = context,
            .owns_context = false,
            .devices = std.AutoHashMap(*libinput.Device, *Device).init(allocator),
            .retired_devices = .empty,
            .event_queue = EventQueue.init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        var it = self.devices.valueIterator();
        while (it.next()) |device| {
            device.*.deinit();
        }
        for (self.retired_devices.items) |device| device.deinit();
        self.retired_devices.deinit(self.allocator);
        self.devices.deinit();
        self.event_queue.deinit();
        if (self.owns_context) _ = libinput.c.libinput_unref(self.libinput_context);
    }

    pub fn getFd(self: *Manager) c_int {
        return libinput.c.libinput_get_fd(self.libinput_context);
    }

    pub fn processEvents(self: *Manager) !void {
        _ = libinput.c.libinput_dispatch(self.libinput_context);

        while (libinput.c.libinput_get_event(self.libinput_context)) |event| {
            defer libinput.c.libinput_event_destroy(event);
            try self.handleLibinputEvent(event);
        }
    }

    fn handleLibinputEvent(self: *Manager, event: *libinput.Event) !void {
        const event_type: libinput.EventType = @enumFromInt(libinput.c.libinput_event_get_type(event));

        switch (event_type) {
            .device_added => try self.handleDeviceAdded(event),
            .device_removed => try self.handleDeviceRemoved(event),
            .keyboard_key => try self.handleKeyboardKey(event),
            .pointer_motion => try self.handlePointerMotion(event),
            .pointer_motion_absolute => try self.handlePointerMotionAbsolute(event),
            .pointer_button => try self.handlePointerButton(event),
            .pointer_axis => try self.handlePointerAxis(event),
            .gesture_swipe_begin => try self.pushGestureSwipe(event, .gesture_swipe_begin),
            .gesture_swipe_update => try self.pushGestureSwipe(event, .gesture_swipe_update),
            .gesture_swipe_end => try self.pushGestureSwipe(event, .gesture_swipe_end),
            .gesture_pinch_begin => try self.pushGesturePinch(event, .gesture_pinch_begin),
            .gesture_pinch_update => try self.pushGesturePinch(event, .gesture_pinch_update),
            .gesture_pinch_end => try self.pushGesturePinch(event, .gesture_pinch_end),
            .gesture_hold_begin => try self.pushGestureHold(event, .gesture_hold_begin),
            .gesture_hold_end => try self.pushGestureHold(event, .gesture_hold_end),
            .touch_down => try self.handleTouchDown(event),
            .touch_up => try self.handleTouchUp(event),
            .touch_motion => try self.handleTouchMotion(event),
            .touch_frame => try self.handleTouchFrame(event),
            .touch_cancel => try self.handleTouchCancel(event),
            .tablet_tool_axis => try self.handleTabletToolAxis(event),
            .tablet_tool_proximity => try self.handleTabletToolProximity(event),
            .tablet_tool_tip => try self.handleTabletToolTip(event),
            .tablet_tool_button => try self.handleTabletToolButton(event),
            .tablet_pad_button => try self.handleTabletPadButton(event),
            .tablet_pad_ring => try self.handleTabletPadRing(event),
            .tablet_pad_strip => try self.handleTabletPadStrip(event),
            .switch_toggle => try self.handleSwitchToggle(event),
            .none => {},
            else => {},
        }
    }

    fn handleDeviceAdded(self: *Manager, event: *libinput.Event) !void {
        const device = libinput.c.libinput_event_get_device(event) orelse return;
        if (self.devices.contains(device)) return;
        try self.devices.ensureUnusedCapacity(1);
        try self.event_queue.events.ensureUnusedCapacity(self.allocator, 1);
        const input_device = try Device.fromLibinput(self.allocator, device);
        self.devices.putAssumeCapacity(device, input_device);
        self.event_queue.events.appendAssumeCapacity(.{ .device_added = .{ .device = input_device } });
    }

    fn handleDeviceRemoved(self: *Manager, event: *libinput.Event) !void {
        const device = libinput.c.libinput_event_get_device(event) orelse return;
        const input_device = self.devices.get(device) orelse return;
        try self.retired_devices.ensureUnusedCapacity(self.allocator, 1);
        try self.event_queue.events.ensureUnusedCapacity(self.allocator, 1);
        _ = self.devices.remove(device);
        self.retired_devices.appendAssumeCapacity(input_device);
        self.event_queue.events.appendAssumeCapacity(.{
            .device_removed = .{ .device = input_device },
        });
    }

    fn handleKeyboardKey(self: *Manager, event: *libinput.Event) !void {
        const key_event = libinput.c.libinput_event_get_keyboard_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));

        try self.event_queue.push(.{
            .keyboard_key = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_keyboard_get_time_usec(key_event),
                .key = libinput.c.libinput_event_keyboard_get_key(key_event),
                .state = @enumFromInt(libinput.c.libinput_event_keyboard_get_key_state(key_event)),
            },
        });
    }

    fn handlePointerMotion(self: *Manager, event: *libinput.Event) !void {
        const pointer_event = libinput.c.libinput_event_get_pointer_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));

        try self.event_queue.push(.{
            .pointer_motion = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_pointer_get_time_usec(pointer_event),
                .delta_x = libinput.c.libinput_event_pointer_get_dx(pointer_event),
                .delta_y = libinput.c.libinput_event_pointer_get_dy(pointer_event),
                .unaccel_delta_x = libinput.c.libinput_event_pointer_get_dx_unaccelerated(pointer_event),
                .unaccel_delta_y = libinput.c.libinput_event_pointer_get_dy_unaccelerated(pointer_event),
            },
        });
    }

    fn handlePointerMotionAbsolute(self: *Manager, event: *libinput.Event) !void {
        const pointer_event = libinput.c.libinput_event_get_pointer_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));

        try self.event_queue.push(.{
            .pointer_motion_absolute = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_pointer_get_time_usec(pointer_event),
                .x = libinput.c.libinput_event_pointer_get_absolute_x_transformed(pointer_event, 1),
                .y = libinput.c.libinput_event_pointer_get_absolute_y_transformed(pointer_event, 1),
            },
        });
    }

    fn handlePointerButton(self: *Manager, event: *libinput.Event) !void {
        const pointer_event = libinput.c.libinput_event_get_pointer_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));

        try self.event_queue.push(.{
            .pointer_button = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_pointer_get_time_usec(pointer_event),
                .button = libinput.c.libinput_event_pointer_get_button(pointer_event),
                .state = @enumFromInt(libinput.c.libinput_event_pointer_get_button_state(pointer_event)),
            },
        });
    }

    fn handlePointerAxis(self: *Manager, event: *libinput.Event) !void {
        const pointer_event = libinput.c.libinput_event_get_pointer_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));

        const axes = [_]libinput.PointerAxis{ .scroll_vertical, .scroll_horizontal };
        for (axes) |axis| {
            const raw_axis: libinput.c.enum_libinput_pointer_axis = @intCast(@intFromEnum(axis));
            if (libinput.c.libinput_event_pointer_has_axis(pointer_event, raw_axis) == 0) continue;

            try self.event_queue.push(.{
                .pointer_axis = .{
                    .device = device,
                    .time_usec = libinput.c.libinput_event_pointer_get_time_usec(pointer_event),
                    .axis = axis,
                    .value = libinput.c.libinput_event_pointer_get_axis_value(pointer_event, raw_axis),
                    .value_discrete = @intFromFloat(libinput.c.libinput_event_pointer_get_axis_value_discrete(pointer_event, raw_axis)),
                    .source = @enumFromInt(libinput.c.libinput_event_pointer_get_axis_source(pointer_event)),
                },
            });
        }
    }

    fn pushGestureSwipe(self: *Manager, event: *libinput.Event, tag: std.meta.Tag(Event)) !void {
        const gesture = libinput.c.libinput_event_get_gesture_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        const payload = Event.GestureSwipe{
            .device = device,
            .time_usec = libinput.c.libinput_event_gesture_get_time_usec(gesture),
            .fingers = @intCast(libinput.c.libinput_event_gesture_get_finger_count(gesture)),
            .delta_x = libinput.c.libinput_event_gesture_get_dx(gesture),
            .delta_y = libinput.c.libinput_event_gesture_get_dy(gesture),
            .cancelled = libinput.c.libinput_event_gesture_get_cancelled(gesture) != 0,
        };
        switch (tag) {
            .gesture_swipe_begin => try self.event_queue.push(.{ .gesture_swipe_begin = payload }),
            .gesture_swipe_update => try self.event_queue.push(.{ .gesture_swipe_update = payload }),
            .gesture_swipe_end => try self.event_queue.push(.{ .gesture_swipe_end = payload }),
            else => unreachable,
        }
    }

    fn pushGesturePinch(self: *Manager, event: *libinput.Event, tag: std.meta.Tag(Event)) !void {
        const gesture = libinput.c.libinput_event_get_gesture_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        const payload = Event.GesturePinch{
            .device = device,
            .time_usec = libinput.c.libinput_event_gesture_get_time_usec(gesture),
            .fingers = @intCast(libinput.c.libinput_event_gesture_get_finger_count(gesture)),
            .delta_x = libinput.c.libinput_event_gesture_get_dx(gesture),
            .delta_y = libinput.c.libinput_event_gesture_get_dy(gesture),
            .scale = libinput.c.libinput_event_gesture_get_scale(gesture),
            .rotation = libinput.c.libinput_event_gesture_get_angle_delta(gesture),
            .cancelled = libinput.c.libinput_event_gesture_get_cancelled(gesture) != 0,
        };
        switch (tag) {
            .gesture_pinch_begin => try self.event_queue.push(.{ .gesture_pinch_begin = payload }),
            .gesture_pinch_update => try self.event_queue.push(.{ .gesture_pinch_update = payload }),
            .gesture_pinch_end => try self.event_queue.push(.{ .gesture_pinch_end = payload }),
            else => unreachable,
        }
    }

    fn pushGestureHold(self: *Manager, event: *libinput.Event, tag: std.meta.Tag(Event)) !void {
        const gesture = libinput.c.libinput_event_get_gesture_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        const payload = Event.GestureHold{
            .device = device,
            .time_usec = libinput.c.libinput_event_gesture_get_time_usec(gesture),
            .fingers = @intCast(libinput.c.libinput_event_gesture_get_finger_count(gesture)),
            .cancelled = libinput.c.libinput_event_gesture_get_cancelled(gesture) != 0,
        };
        switch (tag) {
            .gesture_hold_begin => try self.event_queue.push(.{ .gesture_hold_begin = payload }),
            .gesture_hold_end => try self.event_queue.push(.{ .gesture_hold_end = payload }),
            else => unreachable,
        }
    }

    fn touchPayload(self: *Manager, event: *libinput.Event) !Event.Touch {
        const touch = libinput.c.libinput_event_get_touch_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        return .{
            .device = device,
            .time_usec = libinput.c.libinput_event_touch_get_time_usec(touch),
            .slot = libinput.c.libinput_event_touch_get_seat_slot(touch),
            .x = libinput.c.libinput_event_touch_get_x_transformed(touch, 1),
            .y = libinput.c.libinput_event_touch_get_y_transformed(touch, 1),
        };
    }

    fn handleTouchDown(self: *Manager, event: *libinput.Event) !void {
        try self.event_queue.push(.{ .touch_down = try self.touchPayload(event) });
    }

    fn handleTouchMotion(self: *Manager, event: *libinput.Event) !void {
        try self.event_queue.push(.{ .touch_motion = try self.touchPayload(event) });
    }

    fn touchSlotPayload(self: *Manager, event: *libinput.Event) !Event.TouchUp {
        const touch = libinput.c.libinput_event_get_touch_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        return .{
            .device = device,
            .time_usec = libinput.c.libinput_event_touch_get_time_usec(touch),
            .slot = libinput.c.libinput_event_touch_get_seat_slot(touch),
        };
    }

    fn handleTouchUp(self: *Manager, event: *libinput.Event) !void {
        try self.event_queue.push(.{ .touch_up = try self.touchSlotPayload(event) });
    }

    fn handleTouchCancel(self: *Manager, event: *libinput.Event) !void {
        try self.event_queue.push(.{ .touch_cancel = try self.touchSlotPayload(event) });
    }

    fn handleTouchFrame(self: *Manager, event: *libinput.Event) !void {
        const touch = libinput.c.libinput_event_get_touch_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .touch_frame = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_touch_get_time_usec(touch),
            },
        });
    }

    fn handleTabletToolAxis(self: *Manager, event: *libinput.Event) !void {
        const tool = libinput.c.libinput_event_get_tablet_tool_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .tablet_tool_axis = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_tablet_tool_get_time_usec(tool),
                .x = libinput.c.libinput_event_tablet_tool_get_x_transformed(tool, 1),
                .y = libinput.c.libinput_event_tablet_tool_get_y_transformed(tool, 1),
                .pressure = libinput.c.libinput_event_tablet_tool_get_pressure(tool),
                .tilt_x = libinput.c.libinput_event_tablet_tool_get_tilt_x(tool),
                .tilt_y = libinput.c.libinput_event_tablet_tool_get_tilt_y(tool),
                .rotation = libinput.c.libinput_event_tablet_tool_get_rotation(tool),
                .distance = libinput.c.libinput_event_tablet_tool_get_distance(tool),
            },
        });
    }

    fn handleTabletToolProximity(self: *Manager, event: *libinput.Event) !void {
        const tool = libinput.c.libinput_event_get_tablet_tool_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .tablet_tool_proximity = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_tablet_tool_get_time_usec(tool),
                .x = libinput.c.libinput_event_tablet_tool_get_x_transformed(tool, 1),
                .y = libinput.c.libinput_event_tablet_tool_get_y_transformed(tool, 1),
                .state = @enumFromInt(libinput.c.libinput_event_tablet_tool_get_proximity_state(tool)),
            },
        });
    }

    fn handleTabletToolTip(self: *Manager, event: *libinput.Event) !void {
        const tool = libinput.c.libinput_event_get_tablet_tool_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .tablet_tool_tip = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_tablet_tool_get_time_usec(tool),
                .x = libinput.c.libinput_event_tablet_tool_get_x_transformed(tool, 1),
                .y = libinput.c.libinput_event_tablet_tool_get_y_transformed(tool, 1),
                .state = @enumFromInt(libinput.c.libinput_event_tablet_tool_get_tip_state(tool)),
            },
        });
    }

    fn handleTabletToolButton(self: *Manager, event: *libinput.Event) !void {
        const tool = libinput.c.libinput_event_get_tablet_tool_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .tablet_tool_button = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_tablet_tool_get_time_usec(tool),
                .button = libinput.c.libinput_event_tablet_tool_get_button(tool),
                .state = @enumFromInt(libinput.c.libinput_event_tablet_tool_get_button_state(tool)),
                .seat_button_count = libinput.c.libinput_event_tablet_tool_get_seat_button_count(tool),
            },
        });
    }

    fn handleTabletPadButton(self: *Manager, event: *libinput.Event) !void {
        const pad = libinput.c.libinput_event_get_tablet_pad_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .tablet_pad_button = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_tablet_pad_get_time_usec(pad),
                .button = libinput.c.libinput_event_tablet_pad_get_button_number(pad),
                .state = @enumFromInt(libinput.c.libinput_event_tablet_pad_get_button_state(pad)),
            },
        });
    }

    fn handleTabletPadRing(self: *Manager, event: *libinput.Event) !void {
        const pad = libinput.c.libinput_event_get_tablet_pad_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .tablet_pad_ring = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_tablet_pad_get_time_usec(pad),
                .ring = libinput.c.libinput_event_tablet_pad_get_ring_number(pad),
                .position = libinput.c.libinput_event_tablet_pad_get_ring_position(pad),
                .source = @enumFromInt(libinput.c.libinput_event_tablet_pad_get_ring_source(pad)),
            },
        });
    }

    fn handleTabletPadStrip(self: *Manager, event: *libinput.Event) !void {
        const pad = libinput.c.libinput_event_get_tablet_pad_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .tablet_pad_strip = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_tablet_pad_get_time_usec(pad),
                .strip = libinput.c.libinput_event_tablet_pad_get_strip_number(pad),
                .position = libinput.c.libinput_event_tablet_pad_get_strip_position(pad),
                .source = @enumFromInt(libinput.c.libinput_event_tablet_pad_get_strip_source(pad)),
            },
        });
    }

    fn handleSwitchToggle(self: *Manager, event: *libinput.Event) !void {
        const switch_event = libinput.c.libinput_event_get_switch_event(event);
        const device = try self.getDeviceForLibinputDevice(libinput.c.libinput_event_get_device(event));
        try self.event_queue.push(.{
            .switch_toggle = .{
                .device = device,
                .time_usec = libinput.c.libinput_event_switch_get_time_usec(switch_event),
                .switch_kind = @enumFromInt(libinput.c.libinput_event_switch_get_switch(switch_event)),
                .state = @enumFromInt(libinput.c.libinput_event_switch_get_switch_state(switch_event)),
            },
        });
    }

    fn getDeviceForLibinputDevice(self: *Manager, optional_device: ?*libinput.Device) !*Device {
        const device = optional_device orelse return error.DeviceNotFound;
        return self.devices.get(device) orelse error.DeviceNotFound;
    }

    pub fn finishDispatch(self: *Manager) void {
        if (self.event_queue.len() != 0) return;
        for (self.retired_devices.items) |device| device.deinit();
        self.retired_devices.clearRetainingCapacity();
    }

    fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
        _ = user_data;
        return core.unix.open(std.mem.span(path), @bitCast(@as(u32, @intCast(flags))), 0) catch return -1;
    }

    fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
        _ = user_data;
        core.unix.close(fd);
    }

    fn createContext(
        interface: *const libinput.c.libinput_interface,
        userdata: ?*anyopaque,
        udev: *anyopaque,
    ) ?*libinput.Context {
        return libinput.c.libinput_udev_create_context(interface, userdata, @ptrCast(udev));
    }
};

// ===== Edge Case Tests =====
const testing = core.testing;

test "EventQueue - large queue handling (1000+ events)" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    // Mock device for testing
    var mock_device = Device{
        .name = "Mock Device",
        .sysname = "mock0",
        .vendor = 0x1234,
        .product = 0x5678,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Add 1000+ events
    var i: usize = 0;
    while (i < 1200) : (i += 1) {
        try queue.push(.{
            .keyboard_key = .{
                .device = &mock_device,
                .time_usec = @intCast(i * 1000),
                .key = @intCast(i % 256),
                .state = if (i % 2 == 0) .pressed else .released,
            },
        });
    }

    try testing.expectEqual(@as(usize, 1200), queue.events.items.len);

    // Drain should work with large queues
    const events = queue.drain();
    try testing.expectEqual(@as(usize, 1200), events.len);
    try testing.expectEqual(@as(usize, 0), queue.events.items.len);
}

test "EventQueue - events remain valid after device pointer in queue" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_device = Device{
        .name = "Mock Device",
        .sysname = "mock0",
        .vendor = 0x1234,
        .product = 0x5678,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Add events with device pointer
    try queue.push(.{
        .keyboard_key = .{
            .device = &mock_device,
            .time_usec = 1000,
            .key = 10,
            .state = .pressed,
        },
    });

    try queue.push(.{
        .device_removed = .{
            .device = &mock_device,
        },
    });

    // Pop first event - device pointer should still be accessible
    const event1 = queue.pop().?;
    try testing.expectEqual(@as(u32, 10), event1.keyboard_key.key);

    // Pop device_removed event
    const event2 = queue.pop().?;
    try testing.expectEqual(&mock_device, event2.device_removed.device);
}

test "Device - identical vendor/product IDs" {
    const mock_device1 = Device{
        .name = "Device 1",
        .sysname = "device1",
        .vendor = 0x1234,
        .product = 0x5678,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    const mock_device2 = Device{
        .name = "Device 2",
        .sysname = "device2",
        .vendor = 0x1234, // Same vendor
        .product = 0x5678, // Same product
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Devices should be distinguishable by name/sysname
    try testing.expectNotEqual(mock_device1.name, mock_device2.name);
    try testing.expectNotEqual(mock_device1.sysname, mock_device2.sysname);

    // But same vendor/product
    try testing.expectEqual(mock_device1.vendor, mock_device2.vendor);
    try testing.expectEqual(mock_device1.product, mock_device2.product);
}

test "EventQueue - rapid add/remove simulation" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_device = Device{
        .name = "Rapid Device",
        .sysname = "rapid0",
        .vendor = 0xABCD,
        .product = 0xEF01,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Simulate rapid add/remove cycles
    var cycle: usize = 0;
    while (cycle < 10) : (cycle += 1) {
        // Add device
        try queue.push(.{
            .device_added = .{ .device = &mock_device },
        });

        // Some events
        try queue.push(.{
            .pointer_motion = .{
                .device = &mock_device,
                .time_usec = @intCast(cycle * 1000),
                .delta_x = 1.0,
                .delta_y = 1.0,
                .unaccel_delta_x = 1.0,
                .unaccel_delta_y = 1.0,
            },
        });

        // Remove device
        try queue.push(.{
            .device_removed = .{ .device = &mock_device },
        });
    }

    // Should have 30 events (3 per cycle * 10 cycles)
    try testing.expectEqual(@as(usize, 30), queue.events.items.len);

    // All events should be poppable in order
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 30), count);
}

test "EventQueue - device pointer validity tracking" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    // Simulate scenario where device is removed but events still reference it
    var device_still_referenced = Device{
        .name = "Referenced Device",
        .sysname = "ref0",
        .vendor = 0x0001,
        .product = 0x0002,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Add multiple events before device removal
    try queue.push(.{
        .keyboard_key = .{
            .device = &device_still_referenced,
            .time_usec = 1000,
            .key = 1,
            .state = .pressed,
        },
    });

    try queue.push(.{
        .keyboard_key = .{
            .device = &device_still_referenced,
            .time_usec = 2000,
            .key = 2,
            .state = .pressed,
        },
    });

    try queue.push(.{
        .device_removed = .{
            .device = &device_still_referenced,
        },
    });

    // Events after removal
    try queue.push(.{
        .keyboard_key = .{
            .device = &device_still_referenced,
            .time_usec = 3000,
            .key = 3,
            .state = .pressed,
        },
    });

    // All events should be retrievable
    try testing.expectEqual(@as(usize, 4), queue.events.items.len);

    // Process events in order - device pointer should be valid throughout
    const event1 = queue.pop().?;
    try testing.expectEqual(@as(u32, 1), event1.keyboard_key.key);
    try testing.expectEqualStrings("Referenced Device", event1.keyboard_key.device.name);

    const event2 = queue.pop().?;
    try testing.expectEqual(@as(u32, 2), event2.keyboard_key.key);

    const event3 = queue.pop().?;
    try testing.expectEqualStrings("Referenced Device", event3.device_removed.device.name);

    const event4 = queue.pop().?;
    try testing.expectEqual(@as(u32, 3), event4.keyboard_key.key);
}

test "EventQueue - clear and length operations" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_device = Device{
        .name = "Test",
        .sysname = "test0",
        .vendor = 0,
        .product = 0,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(usize, 0), queue.len());

    try queue.push(.{ .device_added = .{ .device = &mock_device } });
    try testing.expectEqual(@as(usize, 1), queue.len());

    try queue.push(.{ .device_added = .{ .device = &mock_device } });
    try testing.expectEqual(@as(usize, 2), queue.len());

    queue.clear();
    try testing.expectEqual(@as(usize, 0), queue.len());
}

test "EventQueue - ordering preservation under stress" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_device = Device{
        .name = "Ordered Device",
        .sysname = "ordered0",
        .vendor = 0xFFFF,
        .product = 0xFFFF,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Add events with sequential keys to verify ordering
    var expected_key: u32 = 0;
    while (expected_key < 500) : (expected_key += 1) {
        try queue.push(.{
            .keyboard_key = .{
                .device = &mock_device,
                .time_usec = @intCast(expected_key * 100),
                .key = expected_key,
                .state = .pressed,
            },
        });
    }

    // Pop all and verify order is preserved
    var actual_key: u32 = 0;
    while (queue.pop()) |event| {
        try testing.expectEqual(actual_key, event.keyboard_key.key);
        actual_key += 1;
    }

    try testing.expectEqual(@as(u32, 500), actual_key);
}

test "EventQueue - mixed event types" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_kb = Device{
        .name = "Keyboard",
        .sysname = "kb0",
        .vendor = 0x1,
        .product = 0x1,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var mock_ptr = Device{
        .name = "Pointer",
        .sysname = "ptr0",
        .vendor = 0x2,
        .product = 0x2,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Interleave different event types
    try queue.push(.{ .device_added = .{ .device = &mock_kb } });
    try queue.push(.{ .device_added = .{ .device = &mock_ptr } });
    try queue.push(.{
        .keyboard_key = .{
            .device = &mock_kb,
            .time_usec = 1000,
            .key = 10,
            .state = .pressed,
        },
    });
    try queue.push(.{
        .pointer_motion = .{
            .device = &mock_ptr,
            .time_usec = 1500,
            .delta_x = 5.0,
            .delta_y = 3.0,
            .unaccel_delta_x = 5.0,
            .unaccel_delta_y = 3.0,
        },
    });
    try queue.push(.{ .device_removed = .{ .device = &mock_kb } });

    try testing.expectEqual(@as(usize, 5), queue.len());

    // Verify correct types in order
    const e1 = queue.pop().?;
    try testing.expectEqual(.device_added, std.meta.activeTag(e1));

    const e2 = queue.pop().?;
    try testing.expectEqual(.device_added, std.meta.activeTag(e2));

    const e3 = queue.pop().?;
    try testing.expectEqual(.keyboard_key, std.meta.activeTag(e3));

    const e4 = queue.pop().?;
    try testing.expectEqual(.pointer_motion, std.meta.activeTag(e4));

    const e5 = queue.pop().?;
    try testing.expectEqual(.device_removed, std.meta.activeTag(e5));
}

test "Device - disabled state handling" {
    var device = Device{
        .name = "Test Device",
        .sysname = "test0",
        .vendor = 0x1234,
        .product = 0x5678,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    try testing.expect(device.enabled);

    device.enabled = false;
    try testing.expectFalse(device.enabled);

    // Re-enabling should work
    device.enabled = true;
    try testing.expect(device.enabled);
}

test "EventQueue - pop from empty queue" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    // Pop from empty queue should return null
    try testing.expectNull(queue.pop());
    try testing.expectNull(queue.pop());
}

test "EventQueue - drain empty queue" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    const events = queue.drain();
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "EventQueue - interleaved device lifecycle events" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var device1 = Device{
        .name = "Device 1",
        .sysname = "dev1",
        .vendor = 0x1,
        .product = 0x1,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var device2 = Device{
        .name = "Device 2",
        .sysname = "dev2",
        .vendor = 0x2,
        .product = 0x2,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Simulate: device1 added, device2 added, device1 removed, device2 removed
    try queue.push(.{ .device_added = .{ .device = &device1 } });
    try queue.push(.{
        .keyboard_key = .{
            .device = &device1,
            .time_usec = 1000,
            .key = 1,
            .state = .pressed,
        },
    });
    try queue.push(.{ .device_added = .{ .device = &device2 } });
    try queue.push(.{
        .pointer_button = .{
            .device = &device2,
            .time_usec = 2000,
            .button = 272,
            .state = .pressed,
        },
    });
    try queue.push(.{ .device_removed = .{ .device = &device1 } });
    try queue.push(.{
        .pointer_button = .{
            .device = &device2,
            .time_usec = 3000,
            .button = 272,
            .state = .released,
        },
    });
    try queue.push(.{ .device_removed = .{ .device = &device2 } });

    try testing.expectEqual(@as(usize, 7), queue.len());

    // Process all events - should maintain correct device references
    var device1_added = false;
    var device1_removed = false;
    var device2_added = false;
    var device2_removed = false;

    while (queue.pop()) |event| {
        switch (event) {
            .device_added => |e| {
                if (e.device == &device1) device1_added = true;
                if (e.device == &device2) device2_added = true;
            },
            .device_removed => |e| {
                if (e.device == &device1) device1_removed = true;
                if (e.device == &device2) device2_removed = true;
            },
            else => {},
        }
    }

    try testing.expect(device1_added);
    try testing.expect(device1_removed);
    try testing.expect(device2_added);
    try testing.expect(device2_removed);
}

test "EventQueue - event timestamp ordering validation" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_device = Device{
        .name = "Time Device",
        .sysname = "time0",
        .vendor = 0x9999,
        .product = 0x9999,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Add events with specific timestamps
    const timestamps = [_]u64{ 1000, 500, 2000, 1500, 3000 };

    for (timestamps, 0..) |ts, i| {
        try queue.push(.{
            .keyboard_key = .{
                .device = &mock_device,
                .time_usec = ts,
                .key = @intCast(i),
                .state = .pressed,
            },
        });
    }

    // Events should be in insertion order, not timestamp order
    const e1 = queue.pop().?;
    try testing.expectEqual(@as(u64, 1000), e1.keyboard_key.time_usec);

    const e2 = queue.pop().?;
    try testing.expectEqual(@as(u64, 500), e2.keyboard_key.time_usec);

    const e3 = queue.pop().?;
    try testing.expectEqual(@as(u64, 2000), e3.keyboard_key.time_usec);
}

// Aquamarine-style input device interfaces
pub const IKeyboard = blk: {
    const VTableDef = struct {
        get_libinput_handle: *const fn (ptr: *anyopaque) ?*libinput.Device,
        get_name: *const fn (ptr: *anyopaque) string,
        update_leds: *const fn (ptr: *anyopaque, leds: u32) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Base = core.vtable.Interface(VTableDef);

    break :blk struct {
        base: Base,

        pub const VTable = VTableDef;
        const Self = @This();

        pub fn init(ptr: anytype, vtable: *const VTableDef) Self {
            return .{ .base = Base.init(ptr, vtable) };
        }

        pub fn getLibinputHandle(self: Self) ?*libinput.Device {
            return self.base.vtable.get_libinput_handle(self.base.ptr);
        }

        pub fn getName(self: Self) string {
            return self.base.vtable.get_name(self.base.ptr);
        }

        pub fn updateLeds(self: Self, leds: u32) void {
            self.base.vtable.update_leds(self.base.ptr, leds);
        }

        pub fn deinit(self: Self) void {
            self.base.vtable.deinit(self.base.ptr);
        }
    };
};

pub const IPointer = core.vtable.DeviceInterface("IPointer");

pub const ITouch = core.vtable.DeviceInterface("ITouch");

pub const ISwitch = blk: {
    const BaseInterface = core.vtable.DeviceInterface("ISwitch");

    break :blk struct {
        base: BaseInterface,

        pub const Type = enum(u32) {
            unknown = 0,
            lid = 1,
            tablet_mode = 2,
        };

        pub const VTable = BaseInterface.VTable;
        const Self = @This();

        pub fn init(ptr: anytype, vtable: *const VTable) Self {
            return .{ .base = BaseInterface.init(ptr, vtable) };
        }

        pub fn getLibinputHandle(self: Self) ?*anyopaque {
            return self.base.getLibinputHandle();
        }

        pub fn getName(self: Self) string {
            return self.base.getName();
        }

        pub fn deinit(self: Self) void {
            self.base.deinit();
        }
    };
};

pub const ITablet = core.vtable.DeviceInterface("ITablet");

pub const ITabletTool = blk: {
    const BaseInterface = core.vtable.DeviceInterface("ITabletTool");

    break :blk struct {
        base: BaseInterface,

        pub const Type = enum(u32) {
            invalid = 0,
            pen = 1,
            eraser = 2,
            brush = 3,
            pencil = 4,
            airbrush = 5,
            mouse = 6,
            lens = 7,
            totem = 8,
        };

        pub const VTable = BaseInterface.VTable;
        const Self = @This();

        pub fn init(ptr: anytype, vtable: *const VTable) Self {
            return .{ .base = BaseInterface.init(ptr, vtable) };
        }

        pub fn getLibinputHandle(self: Self) ?*anyopaque {
            return self.base.getLibinputHandle();
        }

        pub fn getName(self: Self) string {
            return self.base.getName();
        }

        pub fn deinit(self: Self) void {
            self.base.deinit();
        }
    };
};

pub const ITabletPad = core.vtable.DeviceInterface("ITabletPad");

// Tests for device interfaces
test "IKeyboard - interface creation and methods" {
    const MockKeyboard = struct {
        name: string,
        leds_state: u32 = 0,

        fn getLibinputHandle(ptr: *anyopaque) ?*libinput.Device {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn updateLeds(ptr: *anyopaque, leds: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.leds_state = leds;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IKeyboard.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .update_leds = updateLeds,
            .deinit = deinitFn,
        };
    };

    var mock = MockKeyboard{ .name = "Test Keyboard" };
    const keyboard = IKeyboard.init(&mock, &MockKeyboard.vtable_instance);

    try testing.expectEqualStrings("Test Keyboard", keyboard.getName());
    try testing.expectEqual(@as(u32, 0), mock.leds_state);

    keyboard.updateLeds(5);
    try testing.expectEqual(@as(u32, 5), mock.leds_state);
}

test "IPointer - interface creation" {
    const MockPointer = struct {
        name: string,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IPointer.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .deinit = deinitFn,
        };
    };

    var mock = MockPointer{ .name = "Test Mouse" };
    const pointer = IPointer.init(&mock, &MockPointer.vtable_instance);

    try testing.expectEqualStrings("Test Mouse", pointer.getName());
    try testing.expect(pointer.getLibinputHandle() == null);
}

test "ITouch - interface creation" {
    const MockTouch = struct {
        name: string,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = ITouch.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .deinit = deinitFn,
        };
    };

    var mock = MockTouch{ .name = "Test Touchscreen" };
    const touch = ITouch.init(&mock, &MockTouch.vtable_instance);

    try testing.expectEqualStrings("Test Touchscreen", touch.getName());
}

test "ISwitch - interface with SwitchType enum" {
    const MockSwitch = struct {
        name: string,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = ISwitch.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .deinit = deinitFn,
        };
    };

    var mock = MockSwitch{ .name = "Lid Switch" };
    const switch_dev = ISwitch.init(&mock, &MockSwitch.vtable_instance);

    try testing.expectEqualStrings("Lid Switch", switch_dev.getName());

    // Test SwitchType enum
    try testing.expectEqual(@as(u32, 0), @intFromEnum(ISwitch.Type.unknown));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(ISwitch.Type.lid));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(ISwitch.Type.tablet_mode));
}

test "ITablet - interface creation" {
    const MockTablet = struct {
        name: string,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = ITablet.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .deinit = deinitFn,
        };
    };

    var mock = MockTablet{ .name = "Wacom Tablet" };
    const tablet = ITablet.init(&mock, &MockTablet.vtable_instance);

    try testing.expectEqualStrings("Wacom Tablet", tablet.getName());
}

test "ITabletTool - interface with ToolType enum" {
    const MockTabletTool = struct {
        name: string,
        type: ITabletTool.Type,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = ITabletTool.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .deinit = deinitFn,
        };
    };

    var mock = MockTabletTool{ .name = "Pen", .type = .pen };
    const tool = ITabletTool.init(&mock, &MockTabletTool.vtable_instance);

    try testing.expectEqualStrings("Pen", tool.getName());

    // Test ToolType enum values
    try testing.expectEqual(@as(u32, 0), @intFromEnum(ITabletTool.Type.invalid));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(ITabletTool.Type.pen));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(ITabletTool.Type.eraser));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(ITabletTool.Type.airbrush));
}

test "ITabletPad - interface creation" {
    const MockTabletPad = struct {
        name: string,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = ITabletPad.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .deinit = deinitFn,
        };
    };

    var mock = MockTabletPad{ .name = "Tablet Pad" };
    const pad = ITabletPad.init(&mock, &MockTabletPad.vtable_instance);

    try testing.expectEqualStrings("Tablet Pad", pad.getName());
}

test "Multiple device interfaces - different types" {
    const MockKeyboard = struct {
        name: string,

        fn getLibinputHandle(ptr: *anyopaque) ?*libinput.Device {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn updateLeds(ptr: *anyopaque, leds: u32) void {
            _ = ptr;
            _ = leds;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IKeyboard.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .update_leds = updateLeds,
            .deinit = deinitFn,
        };
    };

    const MockPointer = struct {
        name: string,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) string {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IPointer.VTable{
            .get_libinput_handle = getLibinputHandle,
            .get_name = getName,
            .deinit = deinitFn,
        };
    };

    var mock1 = MockKeyboard{ .name = "Keyboard" };
    var mock2 = MockPointer{ .name = "Mouse" };

    const keyboard = IKeyboard.init(&mock1, &MockKeyboard.vtable_instance);
    const pointer = IPointer.init(&mock2, &MockPointer.vtable_instance);

    try testing.expectEqualStrings("Keyboard", keyboard.getName());
    try testing.expectEqualStrings("Mouse", pointer.getName());
}

test "Manager - device hotplug during event processing" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var device1 = Device{
        .name = "Initial Device",
        .sysname = "initial0",
        .vendor = 0x1234,
        .product = 0x5678,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var device2 = Device{
        .name = "Hotplugged Device",
        .sysname = "hotplug0",
        .vendor = 0xABCD,
        .product = 0xEF01,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Simulate hotplug sequence
    try queue.push(.{ .device_added = .{ .device = &device1 } });
    try queue.push(.{
        .keyboard_key = .{
            .device = &device1,
            .time_usec = 1000,
            .key = 10,
            .state = .pressed,
        },
    });
    try queue.push(.{ .device_added = .{ .device = &device2 } }); // Hotplug during processing
    try queue.push(.{
        .pointer_motion = .{
            .device = &device2,
            .time_usec = 2000,
            .delta_x = 5.0,
            .delta_y = 3.0,
            .unaccel_delta_x = 5.0,
            .unaccel_delta_y = 3.0,
        },
    });
    try queue.push(.{
        .keyboard_key = .{
            .device = &device1,
            .time_usec = 3000,
            .key = 10,
            .state = .released,
        },
    });

    try testing.expectEqual(@as(usize, 5), queue.len());

    // Verify all events are processable
    var event_count: usize = 0;
    while (queue.pop()) |_| {
        event_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), event_count);
}

test "Manager - recover from libinput context failure" {
    const Failure = struct {
        fn create(
            _: *const libinput.c.libinput_interface,
            _: ?*anyopaque,
            _: *anyopaque,
        ) ?*libinput.Context {
            return null;
        }
    };
    var udev_storage: usize = 0;
    try testing.expectError(
        error.LibinputContextFailed,
        Manager.initWithFactory(
            testing.allocator,
            @ptrCast(&udev_storage),
            "seat0",
            Failure.create,
        ),
    );
}

test "EventQueue - event ordering with multiple device types" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var keyboard = Device{
        .name = "Keyboard",
        .sysname = "kbd0",
        .vendor = 0x1,
        .product = 0x1,
        .capabilities = .{ .keyboard = true },
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var pointer = Device{
        .name = "Mouse",
        .sysname = "mouse0",
        .vendor = 0x2,
        .product = 0x2,
        .capabilities = .{ .pointer = true },
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Add events in specific order
    try queue.push(.{
        .keyboard_key = .{
            .device = &keyboard,
            .time_usec = 1000,
            .key = 10,
            .state = .pressed,
        },
    });
    try queue.push(.{
        .pointer_motion = .{
            .device = &pointer,
            .time_usec = 1100,
            .delta_x = 1.0,
            .delta_y = 2.0,
            .unaccel_delta_x = 1.0,
            .unaccel_delta_y = 2.0,
        },
    });
    try queue.push(.{
        .pointer_button = .{
            .device = &pointer,
            .time_usec = 1200,
            .button = 272,
            .state = .pressed,
        },
    });
    try queue.push(.{
        .keyboard_key = .{
            .device = &keyboard,
            .time_usec = 1300,
            .key = 20,
            .state = .pressed,
        },
    });

    try testing.expectEqual(@as(usize, 4), queue.len());

    // Verify order is preserved
    const e1 = queue.pop().?;
    try testing.expectEqual(.keyboard_key, std.meta.activeTag(e1));
    try testing.expectEqual(@as(u64, 1000), e1.keyboard_key.time_usec);

    const e2 = queue.pop().?;
    try testing.expectEqual(.pointer_motion, std.meta.activeTag(e2));
    try testing.expectEqual(@as(u64, 1100), e2.pointer_motion.time_usec);

    const e3 = queue.pop().?;
    try testing.expectEqual(.pointer_button, std.meta.activeTag(e3));
    try testing.expectEqual(@as(u64, 1200), e3.pointer_button.time_usec);

    const e4 = queue.pop().?;
    try testing.expectEqual(.keyboard_key, std.meta.activeTag(e4));
    try testing.expectEqual(@as(u64, 1300), e4.keyboard_key.time_usec);
}

test "Capabilities - bitset semantics" {
    const empty = Capabilities.none();
    try testing.expect(empty.isEmpty());
    try testing.expectEqual(@as(u32, 0), empty.count());
    try testing.expectFalse(empty.has(.keyboard));

    const full = Capabilities.all();
    try testing.expectFalse(full.isEmpty());
    try testing.expectEqual(@as(u32, 7), full.count());
    try testing.expect(full.has(.keyboard));
    try testing.expect(full.has(.pointer));
    try testing.expect(full.has(.touch));
    try testing.expect(full.has(.tablet_tool));
    try testing.expect(full.has(.tablet_pad));
    try testing.expect(full.has(.gesture));
    try testing.expect(full.has(.switch_device));

    const pad: Capabilities = .{ .pointer = true, .touch = true, .gesture = true };
    try testing.expectEqual(@as(u32, 3), pad.count());
    try testing.expect(pad.has(.gesture));
    try testing.expectFalse(pad.has(.keyboard));
}

test "Event - gesture touch tablet switch variants queue correctly" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_device = Device{
        .name = "Combo",
        .sysname = "combo0",
        .vendor = 0x1,
        .product = 0x2,
        .capabilities = .{ .touch = true, .gesture = true },
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    try queue.push(.{ .gesture_swipe_update = .{
        .device = &mock_device,
        .time_usec = 1000,
        .fingers = 3,
        .delta_x = 4.0,
        .delta_y = 0.0,
        .cancelled = false,
    } });
    try queue.push(.{ .gesture_pinch_begin = .{
        .device = &mock_device,
        .time_usec = 1100,
        .fingers = 2,
        .delta_x = 0.0,
        .delta_y = 0.0,
        .scale = 1.0,
        .rotation = 0.0,
        .cancelled = false,
    } });
    try queue.push(.{ .gesture_hold_end = .{
        .device = &mock_device,
        .time_usec = 1200,
        .fingers = 3,
        .cancelled = true,
    } });
    try queue.push(.{ .touch_down = .{
        .device = &mock_device,
        .time_usec = 1300,
        .slot = 0,
        .x = 0.5,
        .y = 0.25,
    } });
    try queue.push(.{ .touch_frame = .{ .device = &mock_device, .time_usec = 1400 } });
    try queue.push(.{ .touch_up = .{ .device = &mock_device, .time_usec = 1500, .slot = 0 } });
    try queue.push(.{ .tablet_tool_axis = .{
        .device = &mock_device,
        .time_usec = 1600,
        .x = 0.1,
        .y = 0.2,
        .pressure = 0.5,
        .tilt_x = 1.0,
        .tilt_y = 2.0,
        .rotation = 3.0,
        .distance = 0.0,
    } });
    try queue.push(.{ .tablet_pad_ring = .{
        .device = &mock_device,
        .time_usec = 1700,
        .ring = 0,
        .position = 0.75,
        .source = .finger,
    } });
    try queue.push(.{ .switch_toggle = .{
        .device = &mock_device,
        .time_usec = 1800,
        .switch_kind = .lid,
        .state = .on,
    } });

    try testing.expectEqual(@as(usize, 9), queue.len());

    const swipe = queue.pop().?;
    try testing.expectEqual(.gesture_swipe_update, std.meta.activeTag(swipe));
    try testing.expectEqual(@as(u32, 3), swipe.gesture_swipe_update.fingers);
    try testing.expectEqual(@as(u64, 1000), swipe.gesture_swipe_update.time_usec);

    const pinch = queue.pop().?;
    try testing.expectEqual(@as(f64, 1.0), pinch.gesture_pinch_begin.scale);

    const hold = queue.pop().?;
    try testing.expect(hold.gesture_hold_end.cancelled);

    const down = queue.pop().?;
    try testing.expectEqual(@as(f64, 0.5), down.touch_down.x);

    const frame = queue.pop().?;
    try testing.expectEqual(.touch_frame, std.meta.activeTag(frame));

    const up = queue.pop().?;
    try testing.expectEqual(@as(i32, 0), up.touch_up.slot);

    const axis = queue.pop().?;
    try testing.expectEqual(@as(f64, 0.5), axis.tablet_tool_axis.pressure);

    const ring = queue.pop().?;
    try testing.expectEqual(libinput.TabletPadRingSource.finger, ring.tablet_pad_ring.source);

    const switch_event = queue.pop().?;
    try testing.expectEqual(libinput.Switch.lid, switch_event.switch_toggle.switch_kind);
    try testing.expectEqual(libinput.SwitchState.on, switch_event.switch_toggle.state);

    try testing.expectNull(queue.pop());
}

test "Event - every variant preserves libinput timestamp" {
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    var mock_device = Device{
        .name = "Timestamped",
        .sysname = "ts0",
        .vendor = 0x1,
        .product = 0x1,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    try queue.push(.{ .gesture_swipe_begin = .{ .device = &mock_device, .time_usec = 42, .fingers = 3, .delta_x = 0, .delta_y = 0, .cancelled = false } });
    try queue.push(.{ .gesture_swipe_end = .{ .device = &mock_device, .time_usec = 43, .fingers = 3, .delta_x = 1, .delta_y = 1, .cancelled = false } });
    try queue.push(.{ .gesture_pinch_update = .{ .device = &mock_device, .time_usec = 44, .fingers = 2, .delta_x = 0, .delta_y = 0, .scale = 1.1, .rotation = 5, .cancelled = false } });
    try queue.push(.{ .gesture_pinch_end = .{ .device = &mock_device, .time_usec = 45, .fingers = 2, .delta_x = 0, .delta_y = 0, .scale = 1.2, .rotation = 6, .cancelled = false } });
    try queue.push(.{ .gesture_hold_begin = .{ .device = &mock_device, .time_usec = 46, .fingers = 4, .cancelled = false } });
    try queue.push(.{ .touch_motion = .{ .device = &mock_device, .time_usec = 47, .slot = 1, .x = 0.9, .y = 0.9 } });
    try queue.push(.{ .touch_cancel = .{ .device = &mock_device, .time_usec = 48, .slot = 1 } });
    try queue.push(.{ .tablet_tool_proximity = .{ .device = &mock_device, .time_usec = 49, .x = 0, .y = 0, .state = .in } });
    try queue.push(.{ .tablet_tool_tip = .{ .device = &mock_device, .time_usec = 50, .x = 0, .y = 0, .state = .down } });
    try queue.push(.{ .tablet_tool_button = .{ .device = &mock_device, .time_usec = 51, .button = 1, .state = .pressed, .seat_button_count = 1 } });
    try queue.push(.{ .tablet_pad_button = .{ .device = &mock_device, .time_usec = 52, .button = 3, .state = .released } });
    try queue.push(.{ .tablet_pad_strip = .{ .device = &mock_device, .time_usec = 53, .strip = 1, .position = 0.1, .source = .unknown } });

    var expected: u64 = 42;
    while (queue.pop()) |event| {
        const ts: u64 = switch (event) {
            .gesture_swipe_begin => |e| e.time_usec,
            .gesture_swipe_update => |e| e.time_usec,
            .gesture_swipe_end => |e| e.time_usec,
            .gesture_pinch_begin => |e| e.time_usec,
            .gesture_pinch_update => |e| e.time_usec,
            .gesture_pinch_end => |e| e.time_usec,
            .gesture_hold_begin => |e| e.time_usec,
            .gesture_hold_end => |e| e.time_usec,
            .touch_down => |e| e.time_usec,
            .touch_up => |e| e.time_usec,
            .touch_motion => |e| e.time_usec,
            .touch_frame => |e| e.time_usec,
            .touch_cancel => |e| e.time_usec,
            .tablet_tool_axis => |e| e.time_usec,
            .tablet_tool_proximity => |e| e.time_usec,
            .tablet_tool_tip => |e| e.time_usec,
            .tablet_tool_button => |e| e.time_usec,
            .tablet_pad_button => |e| e.time_usec,
            .tablet_pad_ring => |e| e.time_usec,
            .tablet_pad_strip => |e| e.time_usec,
            .switch_toggle => |e| e.time_usec,
            else => unreachable,
        };
        try testing.expectEqual(expected, ts);
        expected += 1;
    }
    try testing.expectEqual(@as(u64, 54), expected);
}

test "Device - multiple capabilities on single device" {
    // Some devices (like laptop touchpads) have both pointer and touch capabilities
    // This test ensures our device model can handle this

    var combo_device = Device{
        .name = "Touchpad with Pointer",
        .sysname = "combo0",
        .vendor = 0x1234,
        .product = 0x5678,
        .capabilities = .{ .pointer = true, .touch = true, .gesture = true },
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    try testing.expectEqualStrings("Touchpad with Pointer", combo_device.name);
    try testing.expect(combo_device.capabilities.has(.pointer));
    try testing.expect(combo_device.capabilities.has(.touch));
    try testing.expect(combo_device.capabilities.has(.gesture));

    // Device should handle events from its primary capability
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    try queue.push(.{
        .pointer_motion = .{
            .device = &combo_device,
            .time_usec = 1000,
            .delta_x = 10.0,
            .delta_y = 5.0,
            .unaccel_delta_x = 10.0,
            .unaccel_delta_y = 5.0,
        },
    });

    try testing.expectEqual(@as(usize, 1), queue.len());
    const event = queue.pop().?;
    try testing.expectEqual(.pointer_motion, std.meta.activeTag(event));
}

test "Manager - seat switching" {
    // This test documents the expected behavior when switching seats
    // In practice, this would require deinit and re-init of the Manager

    var device1 = Device{
        .name = "Seat0 Device",
        .sysname = "seat0dev",
        .vendor = 0x1111,
        .product = 0x2222,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var device2 = Device{
        .name = "Seat1 Device",
        .sysname = "seat1dev",
        .vendor = 0x3333,
        .product = 0x4444,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Simulate seat switch by clearing old devices and adding new ones
    var queue = EventQueue.init(testing.allocator);
    defer queue.deinit();

    // Old seat devices removed
    try queue.push(.{ .device_removed = .{ .device = &device1 } });

    // New seat devices added
    try queue.push(.{ .device_added = .{ .device = &device2 } });

    try testing.expectEqual(@as(usize, 2), queue.len());

    const e1 = queue.pop().?;
    try testing.expectEqual(.device_removed, std.meta.activeTag(e1));
    try testing.expectEqualStrings("Seat0 Device", e1.device_removed.device.name);

    const e2 = queue.pop().?;
    try testing.expectEqual(.device_added, std.meta.activeTag(e2));
    try testing.expectEqualStrings("Seat1 Device", e2.device_added.device.name);
}

test "Manager - retired devices are reclaimed after queued events drain" {
    var context_storage: usize = 0;
    const context: *libinput.Context = @ptrCast(@alignCast(&context_storage));
    var manager = Manager.fromContext(testing.allocator, context);
    defer manager.deinit();

    const device = try testing.allocator.create(Device);
    device.* = .{
        .name = try testing.allocator.dupe(u8, "removed"),
        .sysname = try testing.allocator.dupe(u8, "event0"),
        .vendor = 1,
        .product = 2,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };
    try manager.retired_devices.append(testing.allocator, device);
    try manager.event_queue.push(.{ .device_removed = .{ .device = device } });

    manager.finishDispatch();
    try testing.expectEqual(@as(usize, 1), manager.retired_devices.items.len);
    _ = manager.event_queue.pop();
    manager.finishDispatch();
    try testing.expectEqual(@as(usize, 0), manager.retired_devices.items.len);
}
