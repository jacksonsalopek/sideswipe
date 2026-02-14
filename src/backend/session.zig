//! Session management inspired by aquamarine
//! Handles libseat, libinput, and udev integration for managing input devices and DRM cards

const std = @import("std");
const posix = std.posix;
const core = @import("core");
const input = @import("input.zig");
const ipc = @import("ipc");
const Signal = core.events.Signal;

const c = @cImport({
    @cInclude("libudev.h");
    @cInclude("libseat.h");
    @cInclude("libinput.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

// External C library types
pub const udev = c.struct_udev;
pub const udev_monitor = c.struct_udev_monitor;
pub const udev_device = c.struct_udev_device;
pub const libseat = c.struct_libseat;
pub const libinput = c.struct_libinput;
pub const libinput_event = c.struct_libinput_event;
pub const libinput_device = c.struct_libinput_device;
pub const libinput_tablet_tool = c.struct_libinput_tablet_tool;

// Import input event structures from IPC module (no duplication)
pub const KeyboardKeyEvent = ipc.signals.KeyboardKeyEvent;
pub const PointerMotionEvent = ipc.signals.PointerMotionEvent;
pub const PointerMotionAbsoluteEvent = ipc.signals.PointerMotionAbsoluteEvent;
pub const PointerButtonEvent = ipc.signals.PointerButtonEvent;
pub const PointerAxisEvent = ipc.signals.PointerAxisEvent;
pub const TouchDownEvent = ipc.signals.TouchDownEvent;
pub const TouchUpEvent = ipc.signals.TouchUpEvent;
pub const TouchMotionEvent = ipc.signals.TouchMotionEvent;
pub const TouchCancelEvent = ipc.signals.TouchCancelEvent;

/// Session device change event type
pub const ChangeEventType = enum(u32) {
    hotplug = 0,
    lease = 1,
};

/// Session device change event
pub const ChangeEvent = struct {
    event_type: ChangeEventType = .hotplug,
    hotplug: struct {
        connector_id: u32 = 0,
        prop_id: u32 = 0,
    } = .{},
};

// Callback functions for C libraries

/// Libseat seat enable/disable callback
fn libseatHandleEnable(seat: ?*libseat, user_data: ?*anyopaque) callconv(.C) void {
    _ = seat;
    const session: *Type = @ptrCast(@alignCast(user_data orelse return));
    session.active = true;
    session.onReady();
}

fn libseatHandleDisable(seat: ?*libseat, user_data: ?*anyopaque) callconv(.C) void {
    const handle = seat orelse return;
    const session: *Type = @ptrCast(@alignCast(user_data orelse return));
    session.active = false;

    // Disable all devices
    _ = c.libseat_disable_seat(handle);
}

/// Libinput open_restricted callback
fn libinputOpenRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.C) c_int {
    const session: *Type = @ptrCast(@alignCast(user_data orelse return -1));
    const handle = session.libseat_handle orelse return -1;

    var device_id: c_int = undefined;
    const fd = c.libseat_open_device(handle, path, &device_id);

    if (fd < 0) return fd;

    // Store device_id for later closing
    // For now, just return the fd
    _ = flags;
    return fd;
}

/// Libinput close_restricted callback
fn libinputCloseRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.C) void {
    const session: *Type = @ptrCast(@alignCast(user_data orelse return));
    const handle = session.libseat_handle orelse return;

    // Find device_id for this fd and close it
    // For simplicity, just close the fd directly
    _ = c.libseat_close_device(handle, fd);
}

/// Device (represents a DRM device opened through libseat)
pub const Device = struct {
    fd: i32 = -1,
    device_id: i32 = -1,
    dev: std.posix.dev_t = 0,
    path: []const u8,
    render_node_fd: i32 = -1,
    allocator: std.mem.Allocator,
    session: ?*Type = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sess: *Type, path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
            .session = sess,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
        }
        if (self.render_node_fd >= 0) {
            posix.close(self.render_node_fd);
        }
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Check if device supports KMS (Kernel Mode Setting)
    pub fn supportsKms(self: *Self) bool {
        if (self.fd < 0) return false;

        // Check if device has DRM capability
        const version = c.drmGetVersion(self.fd);
        if (version == null) return false;
        defer c.drmFreeVersion(version);

        // Try to get DRM resources to verify KMS support
        const resources = c.drmModeGetResources(self.fd);
        if (resources == null) return false;
        defer c.drmModeFreeResources(resources);

        // Device supports KMS if it has connectors and CRTCs
        return resources.*.count_connectors > 0 and resources.*.count_crtcs > 0;
    }

    /// Open this device if it's a KMS device
    pub fn openIfKms(allocator: std.mem.Allocator, sess: *Type, path: []const u8) !?*Self {
        var device = try Self.init(allocator, sess, path);
        if (!device.supportsKms()) {
            device.deinit();
            return null;
        }
        return device;
    }
};

/// Libinput device wrapper
pub const LibinputDevice = struct {
    device: *libinput_device,
    session: ?*Type = null,
    name: []const u8,
    allocator: std.mem.Allocator,

    // Input device interfaces (optional, depending on capabilities)
    keyboard: ?*input.IKeyboard = null,
    mouse: ?*input.IPointer = null,
    touch: ?*input.ITouch = null,
    switch_device: ?*input.ISwitch = null,
    tablet: ?*input.ITablet = null,
    tablet_pad: ?*input.ITabletPad = null,
    tablet_tools: std.ArrayList(*input.ITabletTool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, device: *libinput_device, sess: *Type) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Get device name from libinput
        const name_ptr = c.libinput_device_get_name(device);
        const name = if (name_ptr) |ptr|
            try allocator.dupe(u8, std.mem.span(ptr))
        else
            try allocator.dupe(u8, "unknown");

        self.* = .{
            .device = device,
            .session = sess,
            .name = name,
            .allocator = allocator,
            .tablet_tools = std.ArrayList(*input.ITabletTool){},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Cleanup tablet tools
        for (self.tablet_tools.items) |tool| {
            tool.deinit();
        }
        self.tablet_tools.deinit(self.allocator);

        // Cleanup device interfaces
        if (self.keyboard) |kb| kb.deinit();
        if (self.mouse) |ms| ms.deinit();
        if (self.touch) |tc| tc.deinit();
        if (self.switch_device) |sw| sw.deinit();
        if (self.tablet) |tb| tb.deinit();
        if (self.tablet_pad) |tp| tp.deinit();

        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Initialize device capabilities (keyboard, mouse, etc.)
    pub fn initDevices(self: *Self) !void {
        // Query libinput device capabilities and create appropriate interfaces
        if (c.libinput_device_has_capability(self.device, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0) {
            self.keyboard = try input.IKeyboard.init(self.allocator);
        }

        if (c.libinput_device_has_capability(self.device, c.LIBINPUT_DEVICE_CAP_POINTER) != 0) {
            self.mouse = try input.IPointer.init(self.allocator);
        }

        if (c.libinput_device_has_capability(self.device, c.LIBINPUT_DEVICE_CAP_TOUCH) != 0) {
            self.touch = try input.ITouch.init(self.allocator);
        }

        if (c.libinput_device_has_capability(self.device, c.LIBINPUT_DEVICE_CAP_SWITCH) != 0) {
            self.switch_device = try input.ISwitch.init(self.allocator);
        }

        if (c.libinput_device_has_capability(self.device, c.LIBINPUT_DEVICE_CAP_TABLET_TOOL) != 0) {
            self.tablet = try input.ITablet.init(self.allocator);
        }

        if (c.libinput_device_has_capability(self.device, c.LIBINPUT_DEVICE_CAP_TABLET_PAD) != 0) {
            self.tablet_pad = try input.ITabletPad.init(self.allocator);
        }
    }
};

/// DRM card add event
pub const AddDrmCardEvent = struct {
    path: []const u8,
};

/// Type manages seat, input, and device access
pub const Type = struct {
    allocator: std.mem.Allocator,
    active: bool = true,
    vt: u32 = 0, // 0 means unsupported
    seat_name: []const u8,

    // Session devices (DRM cards)
    session_devices: std.ArrayList(*Device),

    // Libinput devices
    libinput_devices: std.ArrayList(*LibinputDevice),

    // External library handles
    udev_handle: ?*udev = null,
    udev_monitor: ?*udev_monitor = null,
    libseat_handle: ?*libseat = null,
    libinput_handle: ?*libinput = null,

    // Event signals
    signal_ready: Signal(void),
    signal_device_change: Signal(ChangeEvent),
    signal_keyboard_key: Signal(KeyboardKeyEvent),
    signal_pointer_motion: Signal(PointerMotionEvent),
    signal_pointer_motion_absolute: Signal(PointerMotionAbsoluteEvent),
    signal_pointer_button: Signal(PointerButtonEvent),
    signal_pointer_axis: Signal(PointerAxisEvent),
    signal_touch_down: Signal(TouchDownEvent),
    signal_touch_up: Signal(TouchUpEvent),
    signal_touch_motion: Signal(TouchMotionEvent),
    signal_touch_cancel: Signal(TouchCancelEvent),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .seat_name = "", // Will be set during initialization
            .session_devices = std.ArrayList(*Device){},
            .libinput_devices = std.ArrayList(*LibinputDevice){},
            .signal_ready = Signal(void).init(allocator),
            .signal_device_change = Signal(ChangeEvent).init(allocator),
            .signal_keyboard_key = Signal(KeyboardKeyEvent).init(allocator),
            .signal_pointer_motion = Signal(PointerMotionEvent).init(allocator),
            .signal_pointer_motion_absolute = Signal(PointerMotionAbsoluteEvent).init(allocator),
            .signal_pointer_button = Signal(PointerButtonEvent).init(allocator),
            .signal_pointer_axis = Signal(PointerAxisEvent).init(allocator),
            .signal_touch_down = Signal(TouchDownEvent).init(allocator),
            .signal_touch_up = Signal(TouchUpEvent).init(allocator),
            .signal_touch_motion = Signal(TouchMotionEvent).init(allocator),
            .signal_touch_cancel = Signal(TouchCancelEvent).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up signals
        self.signal_ready.deinit();
        self.signal_device_change.deinit();
        self.signal_keyboard_key.deinit();
        self.signal_pointer_motion.deinit();
        self.signal_pointer_motion_absolute.deinit();
        self.signal_pointer_button.deinit();
        self.signal_pointer_axis.deinit();
        self.signal_touch_down.deinit();
        self.signal_touch_up.deinit();
        self.signal_touch_motion.deinit();
        self.signal_touch_cancel.deinit();

        // Clean up libinput devices
        for (self.libinput_devices.items) |device| {
            device.deinit();
        }
        self.libinput_devices.deinit(self.allocator);

        // Clean up session devices
        for (self.session_devices.items) |device| {
            device.deinit();
        }
        self.session_devices.deinit(self.allocator);

        // Clean up external library handles
        if (self.libinput_handle) |handle| {
            _ = c.libinput_unref(handle);
        }
        if (self.libseat_handle) |handle| {
            _ = c.libseat_close_seat(handle);
        }
        if (self.udev_monitor) |monitor| {
            _ = c.udev_monitor_unref(monitor);
        }
        if (self.udev_handle) |handle| {
            _ = c.udev_unref(handle);
        }

        if (self.seat_name.len > 0) {
            self.allocator.free(self.seat_name);
        }

        self.allocator.destroy(self);
    }

    /// Attempt to create a session for the given backend
    pub fn attempt(allocator: std.mem.Allocator) !*Self {
        const session = try Self.init(allocator);
        errdefer session.deinit();

        // Initialize libseat
        const libseat_listener = c.libseat_seat_listener{
            .enable_seat = libseatHandleEnable,
            .disable_seat = libseatHandleDisable,
        };

        session.libseat_handle = c.libseat_open_seat(&libseat_listener, session);
        if (session.libseat_handle == null) {
            return error.LibseatInitFailed;
        }

        // Get seat name
        const seat_name_ptr = c.libseat_seat_name(session.libseat_handle);
        if (seat_name_ptr) |ptr| {
            session.seat_name = try allocator.dupe(u8, std.mem.span(ptr));
        }

        // Initialize udev
        session.udev_handle = c.udev_new();
        if (session.udev_handle == null) {
            return error.UdevInitFailed;
        }

        // Setup udev monitor for DRM devices
        session.udev_monitor = c.udev_monitor_new_from_netlink(session.udev_handle, "udev");
        if (session.udev_monitor == null) {
            return error.UdevMonitorInitFailed;
        }

        _ = c.udev_monitor_filter_add_match_subsystem_devtype(session.udev_monitor, "drm", null);
        _ = c.udev_monitor_enable_receiving(session.udev_monitor);

        // Initialize libinput
        const libinput_interface = c.libinput_interface{
            .open_restricted = libinputOpenRestricted,
            .close_restricted = libinputCloseRestricted,
        };

        session.libinput_handle = c.libinput_udev_create_context(&libinput_interface, session, session.udev_handle);
        if (session.libinput_handle == null) {
            return error.LibinputInitFailed;
        }

        const seat_name_cstr = if (session.seat_name.len > 0) session.seat_name.ptr else "seat0";
        if (c.libinput_udev_assign_seat(session.libinput_handle, seat_name_cstr) != 0) {
            return error.LibinputAssignSeatFailed;
        }

        return session;
    }

    /// Get file descriptors that need polling
    pub fn pollFds(self: *Self, allocator: std.mem.Allocator) ![]PollFd {
        var fds = std.ArrayList(PollFd){};

        // Add libseat fd
        if (self.libseat_handle) |handle| {
            const fd = c.libseat_get_fd(handle);
            if (fd >= 0) {
                try fds.append(allocator, .{ .fd = fd, .events = posix.POLL.IN });
            }
        }

        // Add udev monitor fd
        if (self.udev_monitor) |monitor| {
            const fd = c.udev_monitor_get_fd(monitor);
            if (fd >= 0) {
                try fds.append(allocator, .{ .fd = fd, .events = posix.POLL.IN });
            }
        }

        // Add libinput fd
        if (self.libinput_handle) |handle| {
            const fd = c.libinput_get_fd(handle);
            if (fd >= 0) {
                try fds.append(allocator, .{ .fd = fd, .events = posix.POLL.IN });
            }
        }

        return fds.toOwnedSlice(allocator);
    }

    /// Dispatch pending events asynchronously
    pub fn dispatchPendingEventsAsync(self: *Self) void {
        self.dispatchLibseatEvents();
        self.dispatchUdevEvents();
        self.dispatchLibinputEvents();
    }

    /// Switch to a different virtual terminal
    pub fn switchVt(self: *Self, vt: u32) bool {
        const handle = self.libseat_handle orelse return false;
        return c.libseat_switch_session(handle, @intCast(vt)) == 0;
    }

    /// Called when session is ready
    pub fn onReady(self: *Self) void {
        // Enumerate existing DRM devices
        if (self.udev_handle) |udev_ctx| {
            const enumerate = c.udev_enumerate_new(udev_ctx);
            if (enumerate) |enum_ctx| {
                defer _ = c.udev_enumerate_unref(enum_ctx);

                _ = c.udev_enumerate_add_match_subsystem(enum_ctx, "drm");
                _ = c.udev_enumerate_scan_devices(enum_ctx);

                var entry = c.udev_enumerate_get_list_entry(enum_ctx);
                while (entry != null) : (entry = c.udev_list_entry_get_next(entry)) {
                    const syspath = c.udev_list_entry_get_name(entry);
                    if (syspath) |path| {
                        const device = c.udev_device_new_from_syspath(udev_ctx, path);
                        if (device) |dev| {
                            defer _ = c.udev_device_unref(dev);

                            const devnode = c.udev_device_get_devnode(dev);
                            if (devnode) |node| {
                                const devnode_str = std.mem.span(node);
                                _ = Device.openIfKms(self.allocator, self, devnode_str) catch continue;
                            }
                        }
                    }
                }
            }
        }

        // Emit ready signal to backend
        std.log.debug("Session ready - emitting signal", .{});
        self.signal_ready.emit({});
    }

    fn dispatchUdevEvents(self: *Self) void {
        const monitor = self.udev_monitor orelse return;

        while (true) {
            const device = c.udev_monitor_receive_device(monitor) orelse break;
            defer _ = c.udev_device_unref(device);

            const action_ptr = c.udev_device_get_action(device);
            const devnode_ptr = c.udev_device_get_devnode(device);

            if (action_ptr == null or devnode_ptr == null) continue;

            const action = std.mem.span(action_ptr);
            const devnode = std.mem.span(devnode_ptr);

            if (std.mem.eql(u8, action, "add")) {
                // Device added - try to open as DRM card
                _ = Device.openIfKms(self.allocator, self, devnode) catch continue;
            } else if (std.mem.eql(u8, action, "remove")) {
                // Device removed - find and close it
                for (self.session_devices.items, 0..) |dev, i| {
                    if (std.mem.eql(u8, dev.path, devnode)) {
                        _ = self.session_devices.swapRemove(i);
                        dev.deinit();
                        break;
                    }
                }
            } else if (std.mem.eql(u8, action, "change")) {
                // Device changed - emit hotplug event
                core.cli.log.debug("Device changed: {s}", .{devnode});
                const change_event = ChangeEvent{
                    .event_type = .hotplug,
                    .hotplug = .{
                        .connector_id = 0, // Would need to parse from udev properties
                        .prop_id = 0,
                    },
                };
                self.signal_device_change.emit(change_event);
            }
        }
    }

    fn dispatchLibinputEvents(self: *Self) void {
        const handle = self.libinput_handle orelse return;

        _ = c.libinput_dispatch(handle);

        while (c.libinput_get_event(handle)) |event| {
            defer _ = c.libinput_event_destroy(event);
            self.handleLibinputEvent(event);
        }
    }

    fn dispatchLibseatEvents(self: *Self) void {
        const handle = self.libseat_handle orelse return;
        _ = c.libseat_dispatch(handle, 0);
    }

    fn handleLibinputEvent(self: *Self, event: *libinput_event) void {
        const event_type = c.libinput_event_get_type(event);
        const device_ptr = c.libinput_event_get_device(event);

        switch (event_type) {
            c.LIBINPUT_EVENT_DEVICE_ADDED => {
                // New device detected
                const dev = LibinputDevice.init(self.allocator, device_ptr, self) catch return;
                dev.initDevices() catch {
                    dev.deinit();
                    return;
                };
                self.libinput_devices.append(self.allocator, dev) catch {
                    dev.deinit();
                    return;
                };
            },
            c.LIBINPUT_EVENT_DEVICE_REMOVED => {
                // Device removed - find and remove it
                for (self.libinput_devices.items, 0..) |dev, i| {
                    if (dev.device == device_ptr) {
                        _ = self.libinput_devices.swapRemove(i);
                        dev.deinit();
                        break;
                    }
                }
            },
            c.LIBINPUT_EVENT_KEYBOARD_KEY => {
                // Keyboard event - route to keyboard interface
                const kbd_event = c.libinput_event_get_keyboard_event(event);
                if (kbd_event) |ke| {
                    const time_msec = c.libinput_event_keyboard_get_time(ke);
                    const key = c.libinput_event_keyboard_get_key(ke);
                    const key_state = c.libinput_event_keyboard_get_key_state(ke);

                    const state: KeyboardKeyEvent.KeyState = if (key_state == c.LIBINPUT_KEY_STATE_PRESSED)
                        .pressed
                    else
                        .released;

                    core.cli.log.debug("Keyboard event: key={d} state={s} time={d}", .{ key, @tagName(state), time_msec });

                    self.signal_keyboard_key.emit(.{
                        .time_msec = time_msec,
                        .key = key,
                        .state = state,
                    });
                }
            },
            c.LIBINPUT_EVENT_POINTER_MOTION => {
                // Relative pointer motion
                const ptr_event = c.libinput_event_get_pointer_event(event);
                if (ptr_event) |pe| {
                    const time_msec = c.libinput_event_pointer_get_time(pe);
                    const dx = c.libinput_event_pointer_get_dx(pe);
                    const dy = c.libinput_event_pointer_get_dy(pe);

                    core.cli.log.debug("Pointer motion: dx={d:.2} dy={d:.2}", .{ dx, dy });

                    self.signal_pointer_motion.emit(.{
                        .time_msec = time_msec,
                        .delta_x = dx,
                        .delta_y = dy,
                    });
                }
            },
            c.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE => {
                // Absolute pointer motion
                const ptr_event = c.libinput_event_get_pointer_event(event);
                if (ptr_event) |pe| {
                    const time_msec = c.libinput_event_pointer_get_time(pe);
                    const x = c.libinput_event_pointer_get_absolute_x(pe);
                    const y = c.libinput_event_pointer_get_absolute_y(pe);

                    core.cli.log.debug("Pointer motion absolute: x={d:.2} y={d:.2}", .{ x, y });

                    self.signal_pointer_motion_absolute.emit(.{
                        .time_msec = time_msec,
                        .x = x,
                        .y = y,
                    });
                }
            },
            c.LIBINPUT_EVENT_POINTER_BUTTON => {
                // Pointer button
                const ptr_event = c.libinput_event_get_pointer_event(event);
                if (ptr_event) |pe| {
                    const time_msec = c.libinput_event_pointer_get_time(pe);
                    const button = c.libinput_event_pointer_get_button(pe);
                    const button_state = c.libinput_event_pointer_get_button_state(pe);

                    const state: PointerButtonEvent.ButtonState = if (button_state == c.LIBINPUT_BUTTON_STATE_PRESSED)
                        .pressed
                    else
                        .released;

                    core.cli.log.debug("Pointer button: button={d} state={s}", .{ button, @tagName(state) });

                    self.signal_pointer_button.emit(.{
                        .time_msec = time_msec,
                        .button = button,
                        .state = state,
                        .serial = 0,
                    });
                }
            },
            c.LIBINPUT_EVENT_POINTER_AXIS => {
                // Pointer axis (scroll)
                const ptr_event = c.libinput_event_get_pointer_event(event);
                if (ptr_event) |pe| {
                    const time_msec = c.libinput_event_pointer_get_time(pe);

                    // Check which axis has a value
                    if (c.libinput_event_pointer_has_axis(pe, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL) != 0) {
                        const delta = c.libinput_event_pointer_get_axis_value(pe, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL);
                        const axis_source = c.libinput_event_pointer_get_axis_source(pe);

                        const source: PointerAxisEvent.AxisSource = switch (axis_source) {
                            c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL => .wheel,
                            c.LIBINPUT_POINTER_AXIS_SOURCE_FINGER => .finger,
                            c.LIBINPUT_POINTER_AXIS_SOURCE_CONTINUOUS => .continuous,
                            c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL_TILT => .wheel_tilt,
                            else => .wheel,
                        };

                        core.cli.log.debug("Pointer axis vertical: delta={d:.2} source={s}", .{ delta, @tagName(source) });

                        self.signal_pointer_axis.emit(.{
                            .time_msec = time_msec,
                            .source = source,
                            .orientation = .vertical,
                            .delta = delta,
                            .delta_discrete = 0, // Could be extracted from libinput if needed
                        });
                    }

                    if (c.libinput_event_pointer_has_axis(pe, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL) != 0) {
                        const delta = c.libinput_event_pointer_get_axis_value(pe, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL);
                        const axis_source = c.libinput_event_pointer_get_axis_source(pe);

                        const source: PointerAxisEvent.AxisSource = switch (axis_source) {
                            c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL => .wheel,
                            c.LIBINPUT_POINTER_AXIS_SOURCE_FINGER => .finger,
                            c.LIBINPUT_POINTER_AXIS_SOURCE_CONTINUOUS => .continuous,
                            c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL_TILT => .wheel_tilt,
                            else => .wheel,
                        };

                        core.cli.log.debug("Pointer axis horizontal: delta={d:.2} source={s}", .{ delta, @tagName(source) });

                        self.signal_pointer_axis.emit(.{
                            .time_msec = time_msec,
                            .source = source,
                            .orientation = .horizontal,
                            .delta = delta,
                            .delta_discrete = 0,
                        });
                    }
                }
            },
            c.LIBINPUT_EVENT_TOUCH_DOWN => {
                // Touch down
                const touch_event = c.libinput_event_get_touch_event(event);
                if (touch_event) |te| {
                    const time_msec = c.libinput_event_touch_get_time(te);
                    const slot = c.libinput_event_touch_get_seat_slot(te);
                    const x = c.libinput_event_touch_get_x(te);
                    const y = c.libinput_event_touch_get_y(te);

                    core.cli.log.debug("Touch down: slot={d} x={d:.2} y={d:.2}", .{ slot, x, y });

                    self.signal_touch_down.emit(.{
                        .time_msec = time_msec,
                        .touch_id = slot,
                        .x = x,
                        .y = y,
                    });
                }
            },
            c.LIBINPUT_EVENT_TOUCH_UP => {
                // Touch up
                const touch_event = c.libinput_event_get_touch_event(event);
                if (touch_event) |te| {
                    const time_msec = c.libinput_event_touch_get_time(te);
                    const slot = c.libinput_event_touch_get_seat_slot(te);

                    core.cli.log.debug("Touch up: slot={d}", .{slot});

                    self.signal_touch_up.emit(.{
                        .time_msec = time_msec,
                        .touch_id = slot,
                    });
                }
            },
            c.LIBINPUT_EVENT_TOUCH_MOTION => {
                // Touch motion
                const touch_event = c.libinput_event_get_touch_event(event);
                if (touch_event) |te| {
                    const time_msec = c.libinput_event_touch_get_time(te);
                    const slot = c.libinput_event_touch_get_seat_slot(te);
                    const x = c.libinput_event_touch_get_x(te);
                    const y = c.libinput_event_touch_get_y(te);

                    core.cli.log.debug("Touch motion: slot={d} x={d:.2} y={d:.2}", .{ slot, x, y });

                    self.signal_touch_motion.emit(.{
                        .time_msec = time_msec,
                        .touch_id = slot,
                        .x = x,
                        .y = y,
                    });
                }
            },
            c.LIBINPUT_EVENT_TOUCH_CANCEL => {
                // Touch cancel
                const touch_event = c.libinput_event_get_touch_event(event);
                if (touch_event) |te| {
                    const time_msec = c.libinput_event_touch_get_time(te);
                    const slot = c.libinput_event_touch_get_seat_slot(te);

                    core.cli.log.debug("Touch cancel: slot={d}", .{slot});

                    self.signal_touch_cancel.emit(.{
                        .time_msec = time_msec,
                        .touch_id = slot,
                    });
                }
            },
            c.LIBINPUT_EVENT_TOUCH_FRAME => {
                // Touch frame - marks end of logical touch event group
                // Currently no signal for this, could be added if needed
                core.cli.log.debug("Touch frame event", .{});
            },
            c.LIBINPUT_EVENT_SWITCH_TOGGLE => {
                // Switch event (e.g., lid switch)
                core.cli.log.debug("Switch toggle event", .{});
                // TODO: Implement switch event signal if needed
            },
            c.LIBINPUT_EVENT_TABLET_TOOL_AXIS, c.LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY, c.LIBINPUT_EVENT_TABLET_TOOL_TIP, c.LIBINPUT_EVENT_TABLET_TOOL_BUTTON => {
                // Tablet tool events
                core.cli.log.debug("Tablet tool event: type={d}", .{event_type});
                // TODO: Implement tablet event signals if needed
            },
            c.LIBINPUT_EVENT_TABLET_PAD_BUTTON, c.LIBINPUT_EVENT_TABLET_PAD_RING, c.LIBINPUT_EVENT_TABLET_PAD_STRIP => {
                // Tablet pad events
                core.cli.log.debug("Tablet pad event: type={d}", .{event_type});
                // TODO: Implement tablet pad event signals if needed
            },
            c.LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN, c.LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE, c.LIBINPUT_EVENT_GESTURE_SWIPE_END, c.LIBINPUT_EVENT_GESTURE_PINCH_BEGIN, c.LIBINPUT_EVENT_GESTURE_PINCH_UPDATE, c.LIBINPUT_EVENT_GESTURE_PINCH_END, c.LIBINPUT_EVENT_GESTURE_HOLD_BEGIN, c.LIBINPUT_EVENT_GESTURE_HOLD_END => {
                // Gesture events
                core.cli.log.debug("Gesture event: type={d}", .{event_type});
                // TODO: Implement gesture event signals if needed
            },
            else => {
                // Unknown event type
                core.cli.log.debug("Unhandled libinput event type: {d}", .{event_type});
            },
        }
    }
};

/// Poll file descriptor wrapper
pub const PollFd = struct {
    fd: i32,
    events: i16,
    revents: i16 = 0,
};

const testing = core.testing;

// Tests
test "Session - initialization" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    try testing.expect(sess.active);
    try testing.expectEqual(@as(u32, 0), sess.vt);
    try testing.expectEqual(@as(usize, 0), sess.session_devices.items.len);
    try testing.expectEqual(@as(usize, 0), sess.libinput_devices.items.len);
}

test "Device - basic initialization" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    var device = try Device.init(testing.allocator, sess, "/dev/dri/card0");
    defer device.deinit();

    try testing.expectEqualStrings("/dev/dri/card0", device.path);
    try testing.expectEqual(@as(i32, -1), device.fd);
    try testing.expectEqual(@as(i32, -1), device.render_node_fd);
}

test "Session - switch VT returns false when not implemented" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    const result = sess.switchVt(2);
    try testing.expectFalse(result);
}

test "Session - signals are initialized" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    // Verify all signals are initialized
    try testing.expectEqual(@as(usize, 0), sess.signal_ready.listeners.items.len);
    try testing.expectEqual(@as(usize, 0), sess.signal_keyboard_key.listeners.items.len);
    try testing.expectEqual(@as(usize, 0), sess.signal_pointer_motion.listeners.items.len);
    try testing.expectEqual(@as(usize, 0), sess.signal_touch_down.listeners.items.len);
}

test "Session - keyboard signal emission" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

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

    var listener = try sess.signal_keyboard_key.listen(State.callback, null);
    defer listener.deinit();

    sess.signal_keyboard_key.emit(.{
        .time_msec = 1000,
        .key = 42,
        .state = .pressed,
    });

    try testing.expectEqual(@as(u32, 42), State.last_key);
    try testing.expectEqual(@as(i32, 1), State.count);
}

test "Session - pointer motion signal emission" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

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

    var listener = try sess.signal_pointer_motion.listen(State.callback, null);
    defer listener.deinit();

    sess.signal_pointer_motion.emit(.{
        .time_msec = 2000,
        .delta_x = 10.5,
        .delta_y = -5.2,
    });

    try testing.expectEqual(@as(f64, 10.5), State.delta_x);
    try testing.expectEqual(@as(f64, -5.2), State.delta_y);
}

test "Session - touch down signal emission" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    const State = struct {
        var touch_id: i32 = -1;
        var x: f64 = 0;
        var y: f64 = 0;

        fn callback(event: TouchDownEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            touch_id = event.touch_id;
            x = event.x;
            y = event.y;
        }
    };
    State.touch_id = -1;
    State.x = 0;
    State.y = 0;

    var listener = try sess.signal_touch_down.listen(State.callback, null);
    defer listener.deinit();

    sess.signal_touch_down.emit(.{
        .time_msec = 3000,
        .touch_id = 5,
        .x = 123.45,
        .y = 678.90,
    });

    try testing.expectEqual(@as(i32, 5), State.touch_id);
    try testing.expectEqual(@as(f64, 123.45), State.x);
    try testing.expectEqual(@as(f64, 678.90), State.y);
}

test "Session - ready signal emission" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    const State = struct {
        var ready_called: bool = false;

        fn callback(userdata: ?*anyopaque) void {
            _ = userdata;
            ready_called = true;
        }
    };
    State.ready_called = false;

    var listener = try sess.signal_ready.listen(State.callback, null);
    defer listener.deinit();

    sess.signal_ready.emit({});

    try testing.expect(State.ready_called);
}

test "Session - device change signal emission" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    const State = struct {
        var event_type: ChangeEventType = .hotplug;
        var called: bool = false;

        fn callback(event: ChangeEvent, userdata: ?*anyopaque) void {
            _ = userdata;
            event_type = event.event_type;
            called = true;
        }
    };
    State.event_type = .hotplug;
    State.called = false;

    var listener = try sess.signal_device_change.listen(State.callback, null);
    defer listener.deinit();

    sess.signal_device_change.emit(.{
        .event_type = .lease,
        .hotplug = .{},
    });

    try testing.expect(State.called);
    try testing.expectEqual(ChangeEventType.lease, State.event_type);
}
