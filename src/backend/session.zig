//! Session management inspired by aquamarine
//! Handles libseat, libinput, and udev integration for managing input devices and DRM cards

const std = @import("std");
const posix = std.posix;
const input = @import("input.zig");

const c = @cImport({
    @cInclude("libudev.h");
    @cInclude("libseat.h");
    @cInclude("libinput.h");
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
        _ = self;
        // TODO: Implement DRM capability checking
        return false;
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

        self.* = .{
            .device = device,
            .session = sess,
            .name = "", // TODO: Get device name from libinput
            .allocator = allocator,
            .tablet_tools = std.ArrayList(*input.ITabletTool){},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.tablet_tools.deinit(self.allocator);
        // TODO: Cleanup device interfaces
        self.allocator.destroy(self);
    }

    /// Initialize device capabilities (keyboard, mouse, etc.)
    pub fn initDevices(self: *Self) void {
        _ = self;
        // TODO: Query libinput device capabilities and create appropriate interfaces
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

    // Backend reference
    backend: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, backend: ?*anyopaque) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .seat_name = "", // Will be set during initialization
            .session_devices = std.ArrayList(*Device){},
            .libinput_devices = std.ArrayList(*LibinputDevice){},
            .backend = backend,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
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

        self.allocator.destroy(self);
    }

    /// Attempt to create a session for the given backend
    pub fn attempt(allocator: std.mem.Allocator, backend: ?*anyopaque) !*Self {
        const session = try Self.init(allocator, backend);
        errdefer session.deinit();

        // TODO: Initialize libseat
        // TODO: Initialize udev
        // TODO: Initialize libinput

        return session;
    }

    /// Get file descriptors that need polling
    pub fn pollFds(self: *Self) ![]PollFd {
        _ = self;
        // TODO: Return fds for libseat, udev, and libinput
        return &[_]PollFd{};
    }

    /// Dispatch pending events asynchronously
    pub fn dispatchPendingEventsAsync(self: *Self) void {
        _ = self;
        // TODO: Dispatch udev events
        // TODO: Dispatch libinput events
        // TODO: Dispatch libseat events
    }

    /// Switch to a different virtual terminal
    pub fn switchVt(self: *Self, vt: u32) bool {
        _ = self;
        _ = vt;
        // TODO: Implement VT switching via libseat
        return false;
    }

    /// Called when session is ready
    pub fn onReady(self: *Self) void {
        _ = self;
        // TODO: Emit ready signals, enumerate devices
    }

    fn dispatchUdevEvents(self: *Self) void {
        _ = self;
        // TODO: Handle udev hotplug events
    }

    fn dispatchLibinputEvents(self: *Self) void {
        _ = self;
        // TODO: Process libinput events
    }

    fn dispatchLibseatEvents(self: *Self) void {
        _ = self;
        // TODO: Handle libseat seat enable/disable
    }

    fn handleLibinputEvent(self: *Self, event: *libinput_event) void {
        _ = self;
        _ = event;
        // TODO: Route libinput events to appropriate handlers
    }
};

/// Poll file descriptor wrapper
pub const PollFd = struct {
    fd: i32,
    events: i16,
    revents: i16 = 0,
};

// Tests
test "Session - initialization" {
    const testing = std.testing;

    var sess = try Type.init(testing.allocator, null);
    defer sess.deinit();

    try testing.expect(sess.active == true);
    try testing.expectEqual(@as(u32, 0), sess.vt);
    try testing.expectEqual(@as(usize, 0), sess.session_devices.items.len);
    try testing.expectEqual(@as(usize, 0), sess.libinput_devices.items.len);
}

test "Device - basic initialization" {
    const testing = std.testing;

    var sess = try Type.init(testing.allocator, null);
    defer sess.deinit();

    var device = try Device.init(testing.allocator, sess, "/dev/dri/card0");
    defer device.deinit();

    try testing.expectEqualStrings("/dev/dri/card0", device.path);
    try testing.expectEqual(@as(i32, -1), device.fd);
    try testing.expectEqual(@as(i32, -1), device.render_node_fd);
}

test "Session - switch VT returns false when not implemented" {
    const testing = std.testing;

    var sess = try Type.init(testing.allocator, null);
    defer sess.deinit();

    const result = sess.switchVt(2);
    try testing.expectEqual(false, result);
}
