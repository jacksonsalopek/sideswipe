//! Session management inspired by aquamarine
//! Handles libseat, libinput, and udev integration for managing input devices and DRM cards

const std = @import("std");
const string = @import("core.string").string;
const posix = std.posix;
const core = @import("core");
const cli = @import("core.cli");
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
pub const KeyboardModifiersEvent = ipc.signals.KeyboardModifiersEvent;
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

/// True for primary DRM card nodes that belong to this session seat.
pub fn isSessionKmsNode(devnode: string, id_seat: ?string, session_seat: string) bool {
    if (!isCardNodeName(std.fs.path.basename(devnode))) return false;
    if (session_seat.len == 0) return true;
    return std.mem.eql(u8, id_seat orelse "seat0", session_seat);
}

/// Numeric id from DRM_CONNECTOR / CONNECTOR / sysattr, else sysname (`card0-DP-1`).
pub fn parseUdevConnectorId(sysname: ?string, drm_connector: ?string, sysattr: ?string) u32 {
    if (parseNumericConnectorId(drm_connector)) |id| return id;
    if (parseNumericConnectorId(sysattr)) |id| return id;
    return parseConnectorIdFromSysname(sysname orelse "") orelse 0;
}

/// Trailing type-id from a DRM connector sysname such as `card0-HDMI-A-1`.
pub fn parseConnectorIdFromSysname(sysname: string) ?u32 {
    if (!std.mem.startsWith(u8, sysname, "card")) return null;
    const rest = sysname["card".len..];
    const card_dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    const card_digits = rest[0..card_dash];
    if (card_digits.len == 0 or !allAsciiDigits(card_digits)) return null;
    const suffix = rest[card_dash + 1 ..];
    const type_dash = std.mem.lastIndexOfScalar(u8, suffix, '-') orelse return null;
    const type_part = suffix[0..type_dash];
    const id_part = suffix[type_dash + 1 ..];
    if (type_part.len == 0) return null;
    return parseNumericConnectorId(id_part);
}

pub fn parseNumericConnectorId(text: ?string) ?u32 {
    const value = text orelse return null;
    if (value.len == 0 or !allAsciiDigits(value)) return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}

fn udevOptionalSpan(ptr: [*c]const u8) ?string {
    if (ptr == null) return null;
    const text = std.mem.span(ptr);
    if (text.len == 0) return null;
    return text;
}

fn udevChangeConnectorId(device: *udev_device) u32 {
    return parseUdevConnectorId(
        udevOptionalSpan(c.udev_device_get_sysname(device)),
        udevConnectorProperty(device),
        udevOptionalSpan(c.udev_device_get_sysattr_value(device, "id")),
    );
}

fn udevConnectorProperty(device: *udev_device) ?string {
    if (udevOptionalSpan(c.udev_device_get_property_value(device, "DRM_CONNECTOR"))) |value| return value;
    return udevOptionalSpan(c.udev_device_get_property_value(device, "CONNECTOR"));
}

fn isCardNodeName(name: string) bool {
    if (!std.mem.startsWith(u8, name, "card")) return false;
    const digits = name["card".len..];
    if (digits.len == 0) return false;
    return allAsciiDigits(digits);
}

fn allAsciiDigits(text: string) bool {
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn udevSeatProperty(device: *udev_device) ?string {
    const value = c.udev_device_get_property_value(device, "ID_SEAT") orelse return null;
    return std.mem.span(value);
}

fn shouldDispatchSeatAfterOpen(has_handle: bool) bool {
    return has_handle;
}

// Callback functions for C libraries

/// Libseat seat enable/disable callback
fn libseatHandleEnable(seat: ?*libseat, user_data: ?*anyopaque) callconv(.c) void {
    _ = seat;
    const session: *Type = @ptrCast(@alignCast(user_data orelse return));
    session.handleSeatEnable();
}

fn libseatHandleDisable(seat: ?*libseat, user_data: ?*anyopaque) callconv(.c) void {
    const session: *Type = @ptrCast(@alignCast(user_data orelse return));
    session.handleSeatDisable();
    const handle = seat orelse return;
    _ = c.libseat_disable_seat(handle);
}

/// Libinput open_restricted callback
fn libinputOpenRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    const session: *Type = @ptrCast(@alignCast(user_data orelse return -1));
    const handle = session.libseat_handle orelse return -1;

    var device_id: c_int = undefined;
    const fd = c.libseat_open_device(handle, path, &device_id);
    if (fd < 0) return fd;

    applySeatOpenFlags(fd, flags);

    session.trackSeatDevice(fd, device_id) catch {
        _ = c.libseat_close_device(handle, device_id);
        return -1;
    };
    return fd;
}

/// Map libinput open(2) flags to the posix bits we apply after libseat_open_device.
fn seatOpenFlags(flags: c_int) posix.O {
    const incoming: posix.O = @bitCast(@as(u32, @bitCast(flags)));
    return .{
        .CLOEXEC = incoming.CLOEXEC,
        .NONBLOCK = incoming.NONBLOCK,
    };
}

fn applySeatOpenFlags(fd: c_int, flags: c_int) void {
    const wanted = seatOpenFlags(flags);
    applyCloexecIfRequested(fd, wanted.CLOEXEC);
    applyNonblockIfRequested(fd, wanted.NONBLOCK);
}

fn applyCloexecIfRequested(fd: c_int, enable: bool) void {
    if (!enable) return;
    const current = fcntlBits(fd, posix.F.GETFD, 0) orelse return;
    _ = fcntlBits(fd, posix.F.SETFD, current | posix.FD_CLOEXEC);
}

fn applyNonblockIfRequested(fd: c_int, enable: bool) void {
    if (!enable) return;
    const current = fcntlBits(fd, posix.F.GETFL, 0) orelse return;
    const bit = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    _ = fcntlBits(fd, posix.F.SETFL, current | bit);
}

fn fcntlBits(fd: c_int, command: c_int, arg: usize) ?usize {
    const result = posix.system.fcntl(fd, command, arg);
    if (posix.errno(result) != .SUCCESS) return null;
    return @intCast(result);
}

/// Libinput close_restricted callback
fn libinputCloseRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const session: *Type = @ptrCast(@alignCast(user_data orelse return));
    const handle = session.libseat_handle orelse return;
    const device_id = session.untrackSeatDevice(fd) orelse return;
    _ = c.libseat_close_device(handle, device_id);
}

/// Device (represents a DRM device opened through libseat)
pub const Device = struct {
    fd: i32 = -1,
    device_id: i32 = -1,
    dev: std.posix.dev_t = 0,
    path: string,
    render_node_fd: i32 = -1,
    claimed: bool = false,
    allocator: std.mem.Allocator,
    session: ?*Type = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sess: *Type, path: string) !*Self {
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
        self.closeSeatFd();
        if (self.fd >= 0) {
            core.unix.close(self.fd);
            self.fd = -1;
        }
        if (self.render_node_fd >= 0) {
            core.unix.close(self.render_node_fd);
            self.render_node_fd = -1;
        }
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn closeSeatFd(self: *Self) void {
        const sess = self.session orelse return;
        const handle = sess.libseat_handle orelse return;
        if (self.device_id < 0) return;
        _ = c.libseat_close_device(handle, self.device_id);
        self.device_id = -1;
        self.fd = -1;
    }

    /// Check if device supports KMS (Kernel Mode Setting)
    pub fn supportsKms(self: *Self) bool {
        if (self.fd < 0) return false;

        const version = c.drmGetVersion(self.fd);
        if (version == null) return false;
        defer c.drmFreeVersion(version);

        const resources = c.drmModeGetResources(self.fd);
        if (resources == null) return false;
        defer c.drmModeFreeResources(resources);

        return resources.*.count_connectors > 0 and resources.*.count_crtcs > 0;
    }

    /// Open a DRM node through libseat.
    pub fn open(allocator: std.mem.Allocator, sess: *Type, path: string) !*Self {
        const handle = sess.libseat_handle orelse return error.NoSeat;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var device_id: c_int = undefined;
        const fd = c.libseat_open_device(handle, path_z.ptr, &device_id);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = c.libseat_close_device(handle, device_id);

        const self = try Self.init(allocator, sess, path);
        self.fd = fd;
        self.device_id = device_id;
        return self;
    }

    /// Open this device if it's a KMS device
    pub fn openIfKms(allocator: std.mem.Allocator, sess: *Type, path: string) !?*Self {
        for (sess.kms_devices.items) |existing| {
            if (std.mem.eql(u8, existing.path, path)) return existing;
        }

        const device = Self.open(allocator, sess, path) catch return null;
        if (!device.supportsKms()) {
            device.deinit();
            return null;
        }
        errdefer device.deinit();
        try sess.kms_devices.append(sess.allocator, device);
        return device;
    }
};

/// Libinput device wrapper
pub const LibinputDevice = struct {
    device: *libinput_device,
    session: ?*Type = null,
    name: string,
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
            .tablet_tools = std.ArrayList(*input.ITabletTool).empty,
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
    path: string,
};

/// Type manages seat, input, and device access
pub const Type = struct {
    allocator: std.mem.Allocator,
    active: bool = true,
    vt: u32 = 0, // 0 means unsupported
    seat_name: [:0]const u8,

    // KMS devices (DRM cards)
    kms_devices: std.ArrayList(*Device),
    seat_fds: std.ArrayList(SeatFd),

    // Libinput devices
    libinput_devices: std.ArrayList(*LibinputDevice),

    // External library handles
    udev_handle: ?*udev = null,
    udev_monitor: ?*udev_monitor = null,
    libseat_handle: ?*libseat = null,
    libinput_handle: ?*libinput = null,
    input_manager: ?input.Manager = null,

    // Event signals
    signal_ready: Signal(void),
    signal_device_change: Signal(ChangeEvent),
    signal_keyboard_key: Signal(KeyboardKeyEvent),
    signal_keyboard_modifiers: Signal(KeyboardModifiersEvent),
    signal_pointer_motion: Signal(PointerMotionEvent),
    signal_pointer_motion_absolute: Signal(PointerMotionAbsoluteEvent),
    signal_pointer_button: Signal(PointerButtonEvent),
    signal_pointer_axis: Signal(PointerAxisEvent),
    signal_touch_down: Signal(TouchDownEvent),
    signal_touch_up: Signal(TouchUpEvent),
    signal_touch_motion: Signal(TouchMotionEvent),
    signal_touch_cancel: Signal(TouchCancelEvent),
    signal_input_event: Signal(input.Event),
    signal_seat_disable: Signal(void),
    signal_seat_enable: Signal(void),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .seat_name = "", // Will be set during initialization
            .kms_devices = std.ArrayList(*Device).empty,
            .seat_fds = std.ArrayList(SeatFd).empty,
            .libinput_devices = std.ArrayList(*LibinputDevice).empty,
            .signal_ready = Signal(void).init(allocator),
            .signal_device_change = Signal(ChangeEvent).init(allocator),
            .signal_keyboard_key = Signal(KeyboardKeyEvent).init(allocator),
            .signal_keyboard_modifiers = Signal(KeyboardModifiersEvent).init(allocator),
            .signal_pointer_motion = Signal(PointerMotionEvent).init(allocator),
            .signal_pointer_motion_absolute = Signal(PointerMotionAbsoluteEvent).init(allocator),
            .signal_pointer_button = Signal(PointerButtonEvent).init(allocator),
            .signal_pointer_axis = Signal(PointerAxisEvent).init(allocator),
            .signal_touch_down = Signal(TouchDownEvent).init(allocator),
            .signal_touch_up = Signal(TouchUpEvent).init(allocator),
            .signal_touch_motion = Signal(TouchMotionEvent).init(allocator),
            .signal_touch_cancel = Signal(TouchCancelEvent).init(allocator),
            .signal_input_event = Signal(input.Event).init(allocator),
            .signal_seat_disable = Signal(void).init(allocator),
            .signal_seat_enable = Signal(void).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up signals
        self.signal_ready.deinit();
        self.signal_device_change.deinit();
        self.signal_keyboard_key.deinit();
        self.signal_keyboard_modifiers.deinit();
        self.signal_pointer_motion.deinit();
        self.signal_pointer_motion_absolute.deinit();
        self.signal_pointer_button.deinit();
        self.signal_pointer_axis.deinit();
        self.signal_touch_down.deinit();
        self.signal_touch_up.deinit();
        self.signal_touch_motion.deinit();
        self.signal_touch_cancel.deinit();
        self.signal_input_event.deinit();
        self.signal_seat_disable.deinit();
        self.signal_seat_enable.deinit();

        if (self.input_manager) |*manager| manager.deinit();
        self.input_manager = null;

        // Clean up libinput devices
        for (self.libinput_devices.items) |device| {
            device.deinit();
        }
        self.libinput_devices.deinit(self.allocator);

        // Clean up session devices
        for (self.kms_devices.items) |device| {
            device.deinit();
        }
        self.kms_devices.deinit(self.allocator);

        // libinput_unref closes devices via close_restricted, which uses seat_fds.
        if (self.libinput_handle) |handle| {
            _ = c.libinput_unref(handle);
            self.libinput_handle = null;
        }
        self.closeRemainingSeatDevices();
        self.seat_fds.deinit(self.allocator);

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
            session.seat_name = try allocator.dupeZ(u8, std.mem.span(ptr));
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

        const seat_name_cstr: [*:0]const u8 = if (session.seat_name.len > 0) session.seat_name.ptr else "seat0";
        if (c.libinput_udev_assign_seat(session.libinput_handle, seat_name_cstr) != 0) {
            return error.LibinputAssignSeatFailed;
        }
        session.input_manager = input.Manager.fromContext(
            allocator,
            @ptrCast(session.libinput_handle.?),
        );

        if (shouldDispatchSeatAfterOpen(session.libseat_handle != null)) {
            session.dispatchLibseatEvents();
        }

        return session;
    }

    /// Get file descriptors that need polling
    pub fn pollFds(self: *Self, allocator: std.mem.Allocator) ![]PollFd {
        var fds = std.ArrayList(PollFd).empty;

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

    /// Remember the libseat device id that belongs to an opened fd.
    fn trackSeatDevice(self: *Self, fd: i32, device_id: i32) !void {
        try self.seat_fds.append(self.allocator, .{ .fd = fd, .device_id = device_id });
    }

    /// Forget an opened fd and return its libseat device id.
    fn untrackSeatDevice(self: *Self, fd: i32) ?i32 {
        for (self.seat_fds.items, 0..) |entry, index| {
            if (entry.fd != fd) continue;
            _ = self.seat_fds.swapRemove(index);
            return entry.device_id;
        }
        return null;
    }

    fn closeRemainingSeatDevices(self: *Self) void {
        const handle = self.libseat_handle orelse {
            self.seat_fds.clearRetainingCapacity();
            return;
        };
        for (self.seat_fds.items) |entry| {
            _ = c.libseat_close_device(handle, entry.device_id);
        }
        self.seat_fds.clearRetainingCapacity();
    }

    /// Called when session is ready
    pub fn onReady(self: *Self) void {
        self.enumerateExistingDrmDevices();

        // Emit ready signal to backend
        cli.log.debug("Session ready - emitting signal", .{});
        self.signal_ready.emit({});
    }

    /// Collect KMS devices for the current seat.
    pub fn collectKmsDevices(self: *Self, allocator: std.mem.Allocator) ![]const *Device {
        const udev_ctx = self.udev_handle orelse return error.UdevNotInitialized;
        const enumerate = c.udev_enumerate_new(udev_ctx) orelse return error.UdevEnumerateFailed;
        defer _ = c.udev_enumerate_unref(enumerate);

        _ = c.udev_enumerate_add_match_subsystem(enumerate, "drm");
        _ = c.udev_enumerate_add_match_sysname(enumerate, "card[0-9]*");
        if (c.udev_enumerate_scan_devices(enumerate) != 0) return error.UdevScanFailed;

        var devices = std.ArrayList(*Device).empty;
        errdefer devices.deinit(allocator);

        var entry = c.udev_enumerate_get_list_entry(enumerate);
        while (entry != null) : (entry = c.udev_list_entry_get_next(entry)) {
            self.collectKmsEntry(allocator, udev_ctx, entry, &devices) catch continue;
        }
        return devices.toOwnedSlice(allocator);
    }

    fn collectKmsEntry(
        self: *Self,
        allocator: std.mem.Allocator,
        udev_ctx: *udev,
        entry: ?*c.struct_udev_list_entry,
        devices: *std.ArrayList(*Device),
    ) !void {
        const syspath = c.udev_list_entry_get_name(entry) orelse return;
        const device = c.udev_device_new_from_syspath(udev_ctx, syspath) orelse return;
        defer _ = c.udev_device_unref(device);

        const devnode = c.udev_device_get_devnode(device) orelse return;
        const path = std.mem.span(devnode);
        if (!isSessionKmsNode(path, udevSeatProperty(device), self.seat_name)) return;

        const opened = Device.openIfKms(allocator, self, path) catch return;
        if (opened) |dev| try devices.append(allocator, dev);
    }

    /// Enumerate existing DRM devices via udev
    fn enumerateExistingDrmDevices(self: *Self) void {
        const udev_ctx = self.udev_handle orelse return;

        const enumerate = c.udev_enumerate_new(udev_ctx) orelse return;
        defer _ = c.udev_enumerate_unref(enumerate);

        _ = c.udev_enumerate_add_match_subsystem(enumerate, "drm");
        _ = c.udev_enumerate_scan_devices(enumerate);

        var entry = c.udev_enumerate_get_list_entry(enumerate);
        while (entry != null) : (entry = c.udev_list_entry_get_next(entry)) {
            self.processSyspathEntry(udev_ctx, entry);
        }
    }

    /// Process a single syspath entry from udev enumeration
    fn processSyspathEntry(self: *Self, udev_ctx: *udev, entry: ?*c.struct_udev_list_entry) void {
        const syspath = c.udev_list_entry_get_name(entry) orelse return;
        const device = c.udev_device_new_from_syspath(udev_ctx, syspath) orelse return;
        defer _ = c.udev_device_unref(device);

        const devnode = c.udev_device_get_devnode(device) orelse return;
        const path = std.mem.span(devnode);
        if (!isSessionKmsNode(path, udevSeatProperty(device), self.seat_name)) return;
        _ = Device.openIfKms(self.allocator, self, path) catch {};
    }

    fn dispatchUdevEvents(self: *Self) void {
        const monitor = self.udev_monitor orelse return;

        while (true) {
            const device = c.udev_monitor_receive_device(monitor) orelse break;
            defer _ = c.udev_device_unref(device);

            const action_ptr = c.udev_device_get_action(device) orelse continue;
            const action = std.mem.span(action_ptr);
            const devnode = udevOptionalSpan(c.udev_device_get_devnode(device));

            if (std.mem.eql(u8, action, "add")) {
                const path = devnode orelse continue;
                self.handleUdevAdd(path);
            } else if (std.mem.eql(u8, action, "remove")) {
                const path = devnode orelse continue;
                self.handleUdevRemove(path);
            } else if (std.mem.eql(u8, action, "change")) {
                self.handleUdevChange(device);
            }
        }
    }

    fn handleUdevAdd(self: *Self, devnode: string) void {
        if (!isSessionKmsNode(devnode, null, self.seat_name)) return;
        _ = Device.openIfKms(self.allocator, self, devnode) catch {};
    }

    fn handleUdevRemove(self: *Self, devnode: string) void {
        const device = self.findKmsDeviceByPath(devnode) orelse return;
        if (device.claimed) return;
        self.releaseKmsDevice(device);
    }

    /// Mark a KMS device as owned by a backend so udev remove will not close it.
    pub fn claimKmsDevice(_: *Self, device: *Device) void {
        device.claimed = true;
    }

    /// Drop a KMS device from the session list and close it.
    pub fn releaseKmsDevice(self: *Self, device: *Device) void {
        self.removeKmsDevice(device);
        device.deinit();
    }

    fn removeKmsDevice(self: *Self, device: *Device) void {
        const index = self.indexOfKmsDevice(device) orelse return;
        _ = self.kms_devices.swapRemove(index);
    }

    fn indexOfKmsDevice(self: *Self, device: *Device) ?usize {
        for (self.kms_devices.items, 0..) |item, index| {
            if (item == device) return index;
        }
        return null;
    }

    fn findKmsDeviceByPath(self: *Self, path: string) ?*Device {
        for (self.kms_devices.items) |device| {
            if (std.mem.eql(u8, device.path, path)) return device;
        }
        return null;
    }

    fn handleSeatDisable(self: *Self) void {
        self.active = false;
        self.signal_seat_disable.emit({});
        self.suspendLibinput();
    }

    fn handleSeatEnable(self: *Self) void {
        self.active = true;
        self.resumeLibinput();
        self.signal_seat_enable.emit({});
    }

    fn suspendLibinput(self: *Self) void {
        const handle = self.libinput_handle orelse return;
        c.libinput_suspend(handle);
    }

    fn resumeLibinput(self: *Self) void {
        const handle = self.libinput_handle orelse return;
        _ = c.libinput_resume(handle);
    }

    fn handleUdevChange(self: *Self, device: *udev_device) void {
        const connector_id = udevChangeConnectorId(device);
        cli.log.debug("Device changed: connector_id={d}", .{connector_id});
        self.signal_device_change.emit(.{
            .event_type = .hotplug,
            .hotplug = .{
                .connector_id = connector_id,
                .prop_id = 0,
            },
        });
    }

    fn dispatchLibinputEvents(self: *Self) void {
        const manager = if (self.input_manager) |*active| active else return;
        manager.processEvents() catch return;
        while (manager.event_queue.pop()) |event| self.emitInputEvent(event);
        manager.finishDispatch();
    }

    fn emitInputEvent(self: *Self, event: input.Event) void {
        self.signal_input_event.emit(event);
        switch (event) {
            .keyboard_key => |value| self.signal_keyboard_key.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .key = value.key,
                .state = @enumFromInt(@intFromEnum(value.state)),
            }),
            .pointer_motion => |value| self.signal_pointer_motion.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .delta_x = value.delta_x,
                .delta_y = value.delta_y,
            }),
            .pointer_motion_absolute => |value| self.signal_pointer_motion_absolute.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .x = value.x,
                .y = value.y,
            }),
            .pointer_button => |value| self.signal_pointer_button.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .button = value.button,
                .state = @enumFromInt(@intFromEnum(value.state)),
            }),
            .touch_down => |value| self.signal_touch_down.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .touch_id = value.slot,
                .x = value.x,
                .y = value.y,
            }),
            .touch_up => |value| self.signal_touch_up.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .touch_id = value.slot,
            }),
            .touch_motion => |value| self.signal_touch_motion.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .touch_id = value.slot,
                .x = value.x,
                .y = value.y,
            }),
            .touch_cancel => |value| self.signal_touch_cancel.emit(.{
                .time_msec = @truncate(value.time_usec / std.time.us_per_ms),
                .touch_id = value.slot,
            }),
            else => {},
        }
    }

    fn dispatchLibseatEvents(self: *Self) void {
        const handle = self.libseat_handle orelse return;
        if (c.libseat_get_fd(handle) < 0) return;
        _ = c.libseat_dispatch(handle, 0);
    }

    fn handleLibinputEvent(self: *Self, event: *libinput_event) void {
        const event_type = c.libinput_event_get_type(event);

        switch (event_type) {
            c.LIBINPUT_EVENT_DEVICE_ADDED => self.handleDeviceAdded(event),
            c.LIBINPUT_EVENT_DEVICE_REMOVED => self.handleDeviceRemoved(event),
            c.LIBINPUT_EVENT_KEYBOARD_KEY => self.handleKeyboardKey(event),
            c.LIBINPUT_EVENT_POINTER_MOTION => self.handlePointerMotion(event),
            c.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE => self.handlePointerMotionAbsolute(event),
            c.LIBINPUT_EVENT_POINTER_BUTTON => self.handlePointerButton(event),
            c.LIBINPUT_EVENT_POINTER_AXIS => self.handlePointerAxis(event),
            c.LIBINPUT_EVENT_TOUCH_DOWN => self.handleTouchDown(event),
            c.LIBINPUT_EVENT_TOUCH_UP => self.handleTouchUp(event),
            c.LIBINPUT_EVENT_TOUCH_MOTION => self.handleTouchMotion(event),
            c.LIBINPUT_EVENT_TOUCH_CANCEL => self.handleTouchCancel(event),
            c.LIBINPUT_EVENT_TOUCH_FRAME => {
                // Touch frame - marks end of logical touch event group
                // Currently no signal for this, could be added if needed
                cli.log.debug("Touch frame event", .{});
            },
            c.LIBINPUT_EVENT_SWITCH_TOGGLE => {
                // Switch event (e.g., lid switch)
                cli.log.debug("Switch toggle event", .{});
                // TODO: Implement switch event signal if needed
            },
            c.LIBINPUT_EVENT_TABLET_TOOL_AXIS, c.LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY, c.LIBINPUT_EVENT_TABLET_TOOL_TIP, c.LIBINPUT_EVENT_TABLET_TOOL_BUTTON => {
                // Tablet tool events
                cli.log.debug("Tablet tool event: type={d}", .{event_type});
                // TODO: Implement tablet event signals if needed
            },
            c.LIBINPUT_EVENT_TABLET_PAD_BUTTON, c.LIBINPUT_EVENT_TABLET_PAD_RING, c.LIBINPUT_EVENT_TABLET_PAD_STRIP => {
                // Tablet pad events
                cli.log.debug("Tablet pad event: type={d}", .{event_type});
                // TODO: Implement tablet pad event signals if needed
            },
            c.LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN, c.LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE, c.LIBINPUT_EVENT_GESTURE_SWIPE_END, c.LIBINPUT_EVENT_GESTURE_PINCH_BEGIN, c.LIBINPUT_EVENT_GESTURE_PINCH_UPDATE, c.LIBINPUT_EVENT_GESTURE_PINCH_END, c.LIBINPUT_EVENT_GESTURE_HOLD_BEGIN, c.LIBINPUT_EVENT_GESTURE_HOLD_END => {
                // Gesture events
                cli.log.debug("Gesture event: type={d}", .{event_type});
                // TODO: Implement gesture event signals if needed
            },
            else => {
                // Unknown event type
                cli.log.debug("Unhandled libinput event type: {d}", .{event_type});
            },
        }
    }

    fn handleDeviceAdded(self: *Self, event: *libinput_event) void {
        const device_ptr = c.libinput_event_get_device(event);
        const dev = LibinputDevice.init(self.allocator, device_ptr, self) catch return;
        dev.initDevices() catch {
            dev.deinit();
            return;
        };
        self.libinput_devices.append(self.allocator, dev) catch {
            dev.deinit();
            return;
        };
    }

    fn handleDeviceRemoved(self: *Self, event: *libinput_event) void {
        const device_ptr = c.libinput_event_get_device(event);
        for (self.libinput_devices.items, 0..) |dev, i| {
            if (dev.device == device_ptr) {
                _ = self.libinput_devices.swapRemove(i);
                dev.deinit();
                break;
            }
        }
    }

    fn handleKeyboardKey(self: *Self, event: *libinput_event) void {
        const kbd_event = c.libinput_event_get_keyboard_event(event) orelse return;

        const time_msec = c.libinput_event_keyboard_get_time(kbd_event);
        const key = c.libinput_event_keyboard_get_key(kbd_event);
        const key_state = c.libinput_event_keyboard_get_key_state(kbd_event);

        const state: KeyboardKeyEvent.KeyState = if (key_state == c.LIBINPUT_KEY_STATE_PRESSED)
            .pressed
        else
            .released;

        cli.log.debug("Keyboard event: key={d} state={s} time={d}", .{ key, @tagName(state), time_msec });

        self.signal_keyboard_key.emit(.{
            .time_msec = time_msec,
            .key = key,
            .state = state,
        });
    }

    fn handlePointerMotion(self: *Self, event: *libinput_event) void {
        const ptr_event = c.libinput_event_get_pointer_event(event) orelse return;

        const time_msec = c.libinput_event_pointer_get_time(ptr_event);
        const dx = c.libinput_event_pointer_get_dx(ptr_event);
        const dy = c.libinput_event_pointer_get_dy(ptr_event);

        cli.log.debug("Pointer motion: dx={d:.2} dy={d:.2}", .{ dx, dy });

        self.signal_pointer_motion.emit(.{
            .time_msec = time_msec,
            .delta_x = dx,
            .delta_y = dy,
        });
    }

    fn handlePointerMotionAbsolute(self: *Self, event: *libinput_event) void {
        const ptr_event = c.libinput_event_get_pointer_event(event) orelse return;

        const time_msec = c.libinput_event_pointer_get_time(ptr_event);
        const x = c.libinput_event_pointer_get_absolute_x(ptr_event);
        const y = c.libinput_event_pointer_get_absolute_y(ptr_event);

        cli.log.debug("Pointer motion absolute: x={d:.2} y={d:.2}", .{ x, y });

        self.signal_pointer_motion_absolute.emit(.{
            .time_msec = time_msec,
            .x = x,
            .y = y,
        });
    }

    fn handlePointerButton(self: *Self, event: *libinput_event) void {
        const ptr_event = c.libinput_event_get_pointer_event(event) orelse return;

        const time_msec = c.libinput_event_pointer_get_time(ptr_event);
        const button = c.libinput_event_pointer_get_button(ptr_event);
        const button_state = c.libinput_event_pointer_get_button_state(ptr_event);

        const state: PointerButtonEvent.ButtonState = if (button_state == c.LIBINPUT_BUTTON_STATE_PRESSED)
            .pressed
        else
            .released;

        cli.log.debug("Pointer button: button={d} state={s}", .{ button, @tagName(state) });

        self.signal_pointer_button.emit(.{
            .time_msec = time_msec,
            .button = button,
            .state = state,
            .serial = 0,
        });
    }

    fn handlePointerAxis(self: *Self, event: *libinput_event) void {
        const ptr_event = c.libinput_event_get_pointer_event(event) orelse return;

        const time_msec = c.libinput_event_pointer_get_time(ptr_event);

        if (c.libinput_event_pointer_has_axis(ptr_event, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL) != 0) {
            self.emitPointerAxis(ptr_event, time_msec, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, .vertical);
        }

        if (c.libinput_event_pointer_has_axis(ptr_event, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL) != 0) {
            self.emitPointerAxis(ptr_event, time_msec, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL, .horizontal);
        }
    }

    fn emitPointerAxis(self: *Self, ptr_event: *c.struct_libinput_event_pointer, time_msec: u32, axis: u32, orientation: PointerAxisEvent.Orientation) void {
        const delta = c.libinput_event_pointer_get_axis_value(ptr_event, axis);
        const discrete = c.libinput_event_pointer_get_axis_value_discrete(ptr_event, axis);
        const axis_source = c.libinput_event_pointer_get_axis_source(ptr_event);

        const source: PointerAxisEvent.AxisSource = switch (axis_source) {
            c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL => .wheel,
            c.LIBINPUT_POINTER_AXIS_SOURCE_FINGER => .finger,
            c.LIBINPUT_POINTER_AXIS_SOURCE_CONTINUOUS => .continuous,
            c.LIBINPUT_POINTER_AXIS_SOURCE_WHEEL_TILT => .wheel_tilt,
            else => .wheel,
        };

        cli.log.debug("Pointer axis {s}: delta={d:.2} source={s}", .{ @tagName(orientation), delta, @tagName(source) });

        self.signal_pointer_axis.emit(.{
            .time_msec = time_msec,
            .source = source,
            .orientation = orientation,
            .delta = delta,
            .delta_discrete = @intFromFloat(discrete),
        });
    }

    fn handleTouchDown(self: *Self, event: *libinput_event) void {
        const touch_event = c.libinput_event_get_touch_event(event) orelse return;

        const time_msec = c.libinput_event_touch_get_time(touch_event);
        const slot = c.libinput_event_touch_get_seat_slot(touch_event);
        const x = c.libinput_event_touch_get_x(touch_event);
        const y = c.libinput_event_touch_get_y(touch_event);

        cli.log.debug("Touch down: slot={d} x={d:.2} y={d:.2}", .{ slot, x, y });

        self.signal_touch_down.emit(.{
            .time_msec = time_msec,
            .touch_id = slot,
            .x = x,
            .y = y,
        });
    }

    fn handleTouchUp(self: *Self, event: *libinput_event) void {
        const touch_event = c.libinput_event_get_touch_event(event) orelse return;

        const time_msec = c.libinput_event_touch_get_time(touch_event);
        const slot = c.libinput_event_touch_get_seat_slot(touch_event);

        cli.log.debug("Touch up: slot={d}", .{slot});

        self.signal_touch_up.emit(.{
            .time_msec = time_msec,
            .touch_id = slot,
        });
    }

    fn handleTouchMotion(self: *Self, event: *libinput_event) void {
        const touch_event = c.libinput_event_get_touch_event(event) orelse return;

        const time_msec = c.libinput_event_touch_get_time(touch_event);
        const slot = c.libinput_event_touch_get_seat_slot(touch_event);
        const x = c.libinput_event_touch_get_x(touch_event);
        const y = c.libinput_event_touch_get_y(touch_event);

        cli.log.debug("Touch motion: slot={d} x={d:.2} y={d:.2}", .{ slot, x, y });

        self.signal_touch_motion.emit(.{
            .time_msec = time_msec,
            .touch_id = slot,
            .x = x,
            .y = y,
        });
    }

    fn handleTouchCancel(self: *Self, event: *libinput_event) void {
        const touch_event = c.libinput_event_get_touch_event(event) orelse return;

        const time_msec = c.libinput_event_touch_get_time(touch_event);
        const slot = c.libinput_event_touch_get_seat_slot(touch_event);

        cli.log.debug("Touch cancel: slot={d}", .{slot});

        self.signal_touch_cancel.emit(.{
            .time_msec = time_msec,
            .touch_id = slot,
        });
    }
};

/// Poll file descriptor wrapper
pub const PollFd = struct {
    fd: i32,
    events: i16,
    revents: i16 = 0,
};

/// Mapping from an opened fd to its libseat device id
const SeatFd = struct {
    fd: i32,
    device_id: i32,
};

const testing = core.testing;

// Tests
test "Session - initialization" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    try testing.expect(sess.active);
    try testing.expectEqual(@as(u32, 0), sess.vt);
    try testing.expectEqual(@as(usize, 0), sess.kms_devices.items.len);
    try testing.expectEqual(@as(usize, 0), sess.libinput_devices.items.len);
}

test "Session - seat device tracking uses libseat ids not fds" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    try sess.trackSeatDevice(13, 2);
    try sess.trackSeatDevice(14, 3);
    try testing.expectEqual(@as(?i32, 2), sess.untrackSeatDevice(13));
    try testing.expectEqual(@as(?i32, 3), sess.untrackSeatDevice(14));
    try testing.expectEqual(@as(?i32, null), sess.untrackSeatDevice(13));
    try testing.expectEqual(@as(usize, 0), sess.seat_fds.items.len);
}

test "Session - deinit with leftover seat fds is safe" {
    var sess = try Type.init(testing.allocator);
    try sess.trackSeatDevice(13, 2);
    sess.deinit();
}

test "Device - openIfKms without a seat returns null" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    try testing.expectEqual(@as(?*Device, null), try Device.openIfKms(testing.allocator, sess, "/dev/dri/card0"));
}

test "Session - collectKmsDevices without udev fails" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    try testing.expectError(error.UdevNotInitialized, sess.collectKmsDevices(testing.allocator));
}

test "Device - open without a seat fails" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    try testing.expectError(error.NoSeat, Device.open(testing.allocator, sess, "/dev/dri/card0"));
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
    try testing.expectEqual(@as(usize, 0), sess.signal_input_event.listeners.items.len);
}

test "Session - M2 runtime path preserves extended input events and timestamps" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();
    var device = input.Device{
        .name = "runtime",
        .sysname = "event0",
        .vendor = 1,
        .product = 2,
        .capabilities = .{ .gesture = true, .touch = true, .tablet_tool = true, .switch_device = true },
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };
    const State = struct {
        var count: usize = 0;
        var last_time: u64 = 0;

        fn callback(event: input.Event, _: ?*anyopaque) void {
            count += 1;
            last_time = switch (event) {
                .gesture_swipe_update => |value| value.time_usec,
                .touch_frame => |value| value.time_usec,
                .tablet_tool_axis => |value| value.time_usec,
                .switch_toggle => |value| value.time_usec,
                else => last_time,
            };
        }
    };
    State.count = 0;
    State.last_time = 0;
    var listener = try sess.signal_input_event.listen(State.callback, null);
    defer listener.deinit();

    sess.emitInputEvent(.{ .gesture_swipe_update = .{
        .device = &device,
        .time_usec = 101,
        .fingers = 3,
        .delta_x = 12,
        .delta_y = 0,
        .cancelled = false,
    } });
    sess.emitInputEvent(.{ .touch_frame = .{ .device = &device, .time_usec = 102 } });
    sess.emitInputEvent(.{ .tablet_tool_axis = .{
        .device = &device,
        .time_usec = 103,
        .x = 0.5,
        .y = 0.5,
        .pressure = 0.5,
        .tilt_x = 0,
        .tilt_y = 0,
        .rotation = 0,
        .distance = 0,
    } });
    sess.emitInputEvent(.{ .switch_toggle = .{
        .device = &device,
        .time_usec = 104,
        .switch_kind = .lid,
        .state = .on,
    } });
    try testing.expectEqual(@as(usize, 4), State.count);
    try testing.expectEqual(@as(u64, 104), State.last_time);
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

test "parseConnectorIdFromSysname - success and failure" {
    try testing.expectEqual(@as(?u32, 1), parseConnectorIdFromSysname("card0-DP-1"));
    try testing.expectEqual(@as(?u32, 1), parseConnectorIdFromSysname("card0-HDMI-A-1"));
    try testing.expectEqual(@as(?u32, 2), parseConnectorIdFromSysname("card1-eDP-2"));
    try testing.expectEqual(@as(?u32, 1), parseConnectorIdFromSysname("card10-DVI-D-1"));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname(""));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname("card0"));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname("card0-"));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname("DP-1"));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname("renderD128"));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname("card0-DP-"));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname("card-DP-1"));
    try testing.expectEqual(@as(?u32, null), parseConnectorIdFromSysname("cardX-DP-1"));
}

test "parseUdevConnectorId - prefers DRM_CONNECTOR then sysattr then sysname" {
    try testing.expectEqual(@as(u32, 42), parseUdevConnectorId("card0-DP-1", "42", "7"));
    try testing.expectEqual(@as(u32, 7), parseUdevConnectorId("card0-DP-1", null, "7"));
    try testing.expectEqual(@as(u32, 1), parseUdevConnectorId("card0-DP-1", "not-a-number", null));
    try testing.expectEqual(@as(u32, 0), parseUdevConnectorId(null, null, null));
    try testing.expectEqual(@as(u32, 0), parseUdevConnectorId("card0", "", "x"));
    try testing.expectEqual(@as(?u32, null), parseNumericConnectorId(""));
    try testing.expectEqual(@as(?u32, 0), parseNumericConnectorId("0"));
}

test "Session - isSessionKmsNode accepts card nodes and seat rules" {
    try testing.expect(isSessionKmsNode("/dev/dri/card0", "seat0", "seat0"));
    try testing.expect(isSessionKmsNode("/dev/dri/card12", "seat0", "seat0"));
    try testing.expect(!isSessionKmsNode("/dev/dri/renderD128", "seat0", "seat0"));
    try testing.expect(!isSessionKmsNode("/dev/dri/controlD64", "seat0", "seat0"));
    try testing.expect(!isSessionKmsNode("", "seat0", "seat0"));
    try testing.expect(!isSessionKmsNode("control", "seat0", "seat0"));
    try testing.expect(!isSessionKmsNode("/dev/dri/card0", "seat1", "seat0"));
    try testing.expect(isSessionKmsNode("/dev/dri/card0", null, "seat0"));
    try testing.expect(!isSessionKmsNode("/dev/dri/card0", null, "seat1"));
    try testing.expect(isSessionKmsNode("/dev/dri/card0", "seat1", ""));
    try testing.expect(!isSessionKmsNode("/dev/dri/renderD128", "seat1", ""));
}

test "Session - disable and enable handlers emit signals without enumerating" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    const State = struct {
        var seq: [2]u8 = .{ 0, 0 };
        var n: usize = 0;

        fn onDisable(_: ?*anyopaque) void {
            seq[n] = 1;
            n += 1;
        }

        fn onEnable(_: ?*anyopaque) void {
            seq[n] = 2;
            n += 1;
        }
    };
    State.seq = .{ 0, 0 };
    State.n = 0;

    var disable_listener = try sess.signal_seat_disable.listen(State.onDisable, null);
    defer disable_listener.deinit();
    var enable_listener = try sess.signal_seat_enable.listen(State.onEnable, null);
    defer enable_listener.deinit();

    try testing.expectEqual(@as(usize, 1), sess.signal_seat_disable.listeners.items.len);
    try testing.expectEqual(@as(usize, 1), sess.signal_seat_enable.listeners.items.len);

    libseatHandleDisable(null, @ptrCast(sess));
    try testing.expectFalse(sess.active);
    try testing.expectEqual(@as(usize, 1), State.n);
    try testing.expectEqual(@as(u8, 1), State.seq[0]);
    try testing.expectEqual(@as(usize, 0), sess.kms_devices.items.len);

    libseatHandleEnable(null, @ptrCast(sess));
    try testing.expect(sess.active);
    try testing.expectEqual(@as(usize, 2), State.n);
    try testing.expectEqual(@as(u8, 2), State.seq[1]);
    try testing.expectEqual(@as(usize, 0), sess.kms_devices.items.len);
}

test "Session - claimed devices survive udev remove" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    const claimed = try Device.init(testing.allocator, sess, "/dev/dri/card0");
    try sess.kms_devices.append(sess.allocator, claimed);
    sess.claimKmsDevice(claimed);

    const unclaimed = try Device.init(testing.allocator, sess, "/dev/dri/card1");
    try sess.kms_devices.append(sess.allocator, unclaimed);

    sess.handleUdevRemove("/dev/dri/card0");
    try testing.expectEqual(@as(usize, 2), sess.kms_devices.items.len);
    try testing.expect(claimed.claimed);

    sess.handleUdevRemove("/dev/dri/card1");
    try testing.expectEqual(@as(usize, 1), sess.kms_devices.items.len);
    try testing.expectEqual(claimed, sess.kms_devices.items[0]);
}

test "Session - releaseKmsDevice removes from list and is safe if already gone" {
    var sess = try Type.init(testing.allocator);
    defer sess.deinit();

    const device = try Device.init(testing.allocator, sess, "/dev/dri/card0");
    try sess.kms_devices.append(sess.allocator, device);
    sess.releaseKmsDevice(device);
    try testing.expectEqual(@as(usize, 0), sess.kms_devices.items.len);

    const orphan = try Device.init(testing.allocator, sess, "/dev/dri/card1");
    sess.releaseKmsDevice(orphan);
    try testing.expectEqual(@as(usize, 0), sess.kms_devices.items.len);
}

test "Session - dispatch after open is skipped without a seat handle" {
    try testing.expect(shouldDispatchSeatAfterOpen(true));
    try testing.expect(!shouldDispatchSeatAfterOpen(false));

    var sess = try Type.init(testing.allocator);
    defer sess.deinit();
    sess.dispatchPendingEventsAsync();
}

test "Session - seatOpenFlags maps CLOEXEC and NONBLOCK" {
    const both_bits = @as(u32, @bitCast(posix.O{ .CLOEXEC = true, .NONBLOCK = true }));
    const both = seatOpenFlags(@bitCast(both_bits));
    try testing.expect(both.CLOEXEC);
    try testing.expect(both.NONBLOCK);

    const none = seatOpenFlags(0);
    try testing.expect(!none.CLOEXEC);
    try testing.expect(!none.NONBLOCK);
}
