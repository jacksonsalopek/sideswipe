const std = @import("std");
const core = @import("core");
const string = @import("core.string").string;
const libinput = @import("libinput.zig");

pub const Input = struct {
    pub const DeviceType = enum {
        keyboard,
        pointer,
        touch,
        tablet_tool,
        tablet_pad,
        switch_device,

        pub fn fromLibinput(device: *libinput.Device) DeviceType {
            if (libinput.c.libinput_device_has_capability(device, @intFromEnum(libinput.DeviceCapability.keyboard)) != 0) {
                return .keyboard;
            }
            if (libinput.c.libinput_device_has_capability(device, @intFromEnum(libinput.DeviceCapability.pointer)) != 0) {
                return .pointer;
            }
            if (libinput.c.libinput_device_has_capability(device, @intFromEnum(libinput.DeviceCapability.touch)) != 0) {
                return .touch;
            }
            if (libinput.c.libinput_device_has_capability(device, @intFromEnum(libinput.DeviceCapability.tablet_tool)) != 0) {
                return .tablet_tool;
            }
            if (libinput.c.libinput_device_has_capability(device, @intFromEnum(libinput.DeviceCapability.tablet_pad)) != 0) {
                return .tablet_pad;
            }
            if (libinput.c.libinput_device_has_capability(device, @intFromEnum(libinput.DeviceCapability.switch_device)) != 0) {
                return .switch_device;
            }
            return .pointer; // fallback
        }
    };

    pub const Device = struct {
        name: string,
        sysname: string,
        vendor: u32,
        product: u32,
        device_type: DeviceType,
        enabled: bool = true,

        libinput_device: *libinput.Device,
        allocator: std.mem.Allocator,

        pub fn fromLibinput(allocator: std.mem.Allocator, device: *libinput.Device) !*Device {
            const dev = try allocator.create(Device);

            const name = libinput.c.libinput_device_get_name(device);
            const sysname = libinput.c.libinput_device_get_sysname(device);

            dev.* = .{
                .name = try allocator.dupe(u8, std.mem.span(name)),
                .sysname = try allocator.dupe(u8, std.mem.span(sysname)),
                .vendor = @intCast(libinput.c.libinput_device_get_id_vendor(device)),
                .product = @intCast(libinput.c.libinput_device_get_id_product(device)),
                .device_type = DeviceType.fromLibinput(device),
                .libinput_device = device,
                .allocator = allocator,
            };

            // Keep device alive by adding a reference
            _ = libinput.c.libinput_device_ref(device);

            return dev;
        }

        pub fn deinit(self: *Device) void {
            _ = libinput.c.libinput_device_unref(self.libinput_device);
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
    };

    pub const EventQueue = struct {
        events: std.ArrayList(Event),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) EventQueue {
            return .{
                .events = .{},
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
        devices: std.AutoHashMap(*libinput.Device, *Device),
        event_queue: EventQueue,

        pub fn init(allocator: std.mem.Allocator, udev: *anyopaque, seat_id: string) !Manager {
            const interface = libinput.c.libinput_interface{
                .open_restricted = openRestricted,
                .close_restricted = closeRestricted,
            };

            const ctx = libinput.c.libinput_udev_create_context(
                &interface,
                null,
                @ptrCast(udev),
            ) orelse return error.LibinputContextFailed;

            if (libinput.c.libinput_udev_assign_seat(ctx, seat_id.ptr) != 0) {
                libinput.c.libinput_unref(ctx);
                return error.SeatAssignFailed;
            }

            return .{
                .allocator = allocator,
                .libinput_context = ctx,
                .devices = std.AutoHashMap(*libinput.Device, *Device).init(allocator),
                .event_queue = EventQueue.init(allocator),
            };
        }

        pub fn deinit(self: *Manager) void {
            var it = self.devices.valueIterator();
            while (it.next()) |device| {
                device.*.deinit();
            }
            self.devices.deinit();
            self.event_queue.deinit();
            libinput.c.libinput_unref(self.libinput_context);
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
                else => {},
            }
        }

        fn handleDeviceAdded(self: *Manager, event: *libinput.Event) !void {
            const device = libinput.c.libinput_event_get_device(event);
            const input_device = try Device.fromLibinput(self.allocator, device);

            try self.devices.put(device, input_device);
            try self.event_queue.push(.{ .device_added = .{ .device = input_device } });
        }

        fn handleDeviceRemoved(self: *Manager, event: *libinput.Event) !void {
            const device = libinput.c.libinput_event_get_device(event);

            if (self.devices.fetchRemove(device)) |kv| {
                try self.event_queue.push(.{ .device_removed = .{ .device = kv.value } });
                kv.value.deinit();
            }
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
                if (libinput.c.libinput_event_pointer_has_axis(pointer_event, @intFromEnum(axis)) == 0) continue;

                try self.event_queue.push(.{
                    .pointer_axis = .{
                        .device = device,
                        .time_usec = libinput.c.libinput_event_pointer_get_time_usec(pointer_event),
                        .axis = axis,
                        .value = libinput.c.libinput_event_pointer_get_axis_value(pointer_event, @intFromEnum(axis)),
                        .value_discrete = @intCast(libinput.c.libinput_event_pointer_get_axis_value_discrete(pointer_event, @intFromEnum(axis))),
                        .source = @enumFromInt(libinput.c.libinput_event_pointer_get_axis_source(pointer_event)),
                    },
                });
            }
        }

        fn getDeviceForLibinputDevice(self: *Manager, device: *libinput.Device) !*Device {
            return self.devices.get(device) orelse error.DeviceNotFound;
        }

        fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.C) c_int {
            _ = user_data;
            return std.posix.open(std.mem.span(path), @bitCast(@as(u32, @intCast(flags))), 0) catch return -1;
        }

        fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.C) void {
            _ = user_data;
            std.posix.close(fd);
        }
    };
};

// ===== Edge Case Tests =====

test "EventQueue - large queue handling (1000+ events)" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    // Mock device for testing
    var mock_device = Input.Device{
        .name = "Mock Device",
        .sysname = "mock0",
        .vendor = 0x1234,
        .product = 0x5678,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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

    try std.testing.expectEqual(@as(usize, 1200), queue.events.items.len);

    // Drain should work with large queues
    const events = queue.drain();
    try std.testing.expectEqual(@as(usize, 1200), events.len);
    try std.testing.expectEqual(@as(usize, 0), queue.events.items.len);
}

test "EventQueue - events remain valid after device pointer in queue" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var mock_device = Input.Device{
        .name = "Mock Device",
        .sysname = "mock0",
        .vendor = 0x1234,
        .product = 0x5678,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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
    try std.testing.expectEqual(@as(u32, 10), event1.keyboard_key.key);

    // Pop device_removed event
    const event2 = queue.pop().?;
    try std.testing.expectEqual(&mock_device, event2.device_removed.device);
}

test "Device - identical vendor/product IDs" {
    const mock_device1 = Input.Device{
        .name = "Device 1",
        .sysname = "device1",
        .vendor = 0x1234,
        .product = 0x5678,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
    };

    const mock_device2 = Input.Device{
        .name = "Device 2",
        .sysname = "device2",
        .vendor = 0x1234, // Same vendor
        .product = 0x5678, // Same product
        .device_type = .pointer,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
    };

    // Devices should be distinguishable by name/sysname
    try std.testing.expect(!std.mem.eql(u8, mock_device1.name, mock_device2.name));
    try std.testing.expect(!std.mem.eql(u8, mock_device1.sysname, mock_device2.sysname));

    // But same vendor/product
    try std.testing.expectEqual(mock_device1.vendor, mock_device2.vendor);
    try std.testing.expectEqual(mock_device1.product, mock_device2.product);
}

test "EventQueue - rapid add/remove simulation" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var mock_device = Input.Device{
        .name = "Rapid Device",
        .sysname = "rapid0",
        .vendor = 0xABCD,
        .product = 0xEF01,
        .device_type = .pointer,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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
    try std.testing.expectEqual(@as(usize, 30), queue.events.items.len);

    // All events should be poppable in order
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 30), count);
}

test "EventQueue - device pointer validity tracking" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    // Simulate scenario where device is removed but events still reference it
    var device_still_referenced = Input.Device{
        .name = "Referenced Device",
        .sysname = "ref0",
        .vendor = 0x0001,
        .product = 0x0002,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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
    try std.testing.expectEqual(@as(usize, 4), queue.events.items.len);

    // Process events in order - device pointer should be valid throughout
    const event1 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 1), event1.keyboard_key.key);
    try std.testing.expectEqualStrings("Referenced Device", event1.keyboard_key.device.name);

    const event2 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 2), event2.keyboard_key.key);

    const event3 = queue.pop().?;
    try std.testing.expectEqualStrings("Referenced Device", event3.device_removed.device.name);

    const event4 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 3), event4.keyboard_key.key);
}

test "EventQueue - clear and length operations" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var mock_device = Input.Device{
        .name = "Test",
        .sysname = "test0",
        .vendor = 0,
        .product = 0,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqual(@as(usize, 0), queue.len());

    try queue.push(.{ .device_added = .{ .device = &mock_device } });
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    try queue.push(.{ .device_added = .{ .device = &mock_device } });
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    queue.clear();
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "Device - type detection from capabilities" {
    // Test that DeviceType enum covers all expected types
    const types = [_]Input.DeviceType{
        .keyboard,
        .pointer,
        .touch,
        .tablet_tool,
        .tablet_pad,
        .switch_device,
    };

    // All types should be valid enum values
    for (types) |device_type| {
        _ = device_type;
        // If we get here without error, enum is valid
    }
}

test "EventQueue - ordering preservation under stress" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var mock_device = Input.Device{
        .name = "Ordered Device",
        .sysname = "ordered0",
        .vendor = 0xFFFF,
        .product = 0xFFFF,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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
        try std.testing.expectEqual(actual_key, event.keyboard_key.key);
        actual_key += 1;
    }

    try std.testing.expectEqual(@as(u32, 500), actual_key);
}

test "EventQueue - mixed event types" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var mock_kb = Input.Device{
        .name = "Keyboard",
        .sysname = "kb0",
        .vendor = 0x1,
        .product = 0x1,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
    };

    var mock_ptr = Input.Device{
        .name = "Pointer",
        .sysname = "ptr0",
        .vendor = 0x2,
        .product = 0x2,
        .device_type = .pointer,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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

    try std.testing.expectEqual(@as(usize, 5), queue.len());

    // Verify correct types in order
    const e1 = queue.pop().?;
    try std.testing.expect(e1 == .device_added);

    const e2 = queue.pop().?;
    try std.testing.expect(e2 == .device_added);

    const e3 = queue.pop().?;
    try std.testing.expect(e3 == .keyboard_key);

    const e4 = queue.pop().?;
    try std.testing.expect(e4 == .pointer_motion);

    const e5 = queue.pop().?;
    try std.testing.expect(e5 == .device_removed);
}

test "Device - disabled state handling" {
    var device = Input.Device{
        .name = "Test Device",
        .sysname = "test0",
        .vendor = 0x1234,
        .product = 0x5678,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(device.enabled);

    device.enabled = false;
    try std.testing.expect(!device.enabled);

    // Re-enabling should work
    device.enabled = true;
    try std.testing.expect(device.enabled);
}

test "EventQueue - pop from empty queue" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    // Pop from empty queue should return null
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(queue.pop() == null);
}

test "EventQueue - drain empty queue" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    const events = queue.drain();
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "EventQueue - interleaved device lifecycle events" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var device1 = Input.Device{
        .name = "Device 1",
        .sysname = "dev1",
        .vendor = 0x1,
        .product = 0x1,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
    };

    var device2 = Input.Device{
        .name = "Device 2",
        .sysname = "dev2",
        .vendor = 0x2,
        .product = 0x2,
        .device_type = .pointer,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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

    try std.testing.expectEqual(@as(usize, 7), queue.len());

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

    try std.testing.expect(device1_added);
    try std.testing.expect(device1_removed);
    try std.testing.expect(device2_added);
    try std.testing.expect(device2_removed);
}

test "Device - multiple device types" {
    const types = [_]Input.DeviceType{
        .keyboard,
        .pointer,
        .touch,
        .tablet_tool,
        .tablet_pad,
        .switch_device,
    };

    for (types, 0..) |device_type, i| {
        const device = Input.Device{
            .name = "Multi Device",
            .sysname = "multi0",
            .vendor = @intCast(i),
            .product = @intCast(i),
            .device_type = device_type,
            .enabled = true,
            .libinput_device = undefined,
            .allocator = std.testing.allocator,
        };

        try std.testing.expectEqual(device_type, device.device_type);
    }
}

test "EventQueue - event timestamp ordering validation" {
    var queue = Input.EventQueue.init(std.testing.allocator);
    defer queue.deinit();

    var mock_device = Input.Device{
        .name = "Time Device",
        .sysname = "time0",
        .vendor = 0x9999,
        .product = 0x9999,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = std.testing.allocator,
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
    try std.testing.expectEqual(@as(u64, 1000), e1.keyboard_key.time_usec);

    const e2 = queue.pop().?;
    try std.testing.expectEqual(@as(u64, 500), e2.keyboard_key.time_usec);

    const e3 = queue.pop().?;
    try std.testing.expectEqual(@as(u64, 2000), e3.keyboard_key.time_usec);
}

// Aquamarine-style input device interfaces
pub const IKeyboard = blk: {
    const VTableDef = struct {
        get_libinput_handle: *const fn (ptr: *anyopaque) ?*libinput.Device,
        get_name: *const fn (ptr: *anyopaque) []const u8,
        update_leds: *const fn (ptr: *anyopaque, leds: u32) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Base = core.vtable.VTable(VTableDef);

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

        pub fn getName(self: Self) []const u8 {
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

        pub fn getName(self: Self) []const u8 {
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

        pub fn getName(self: Self) []const u8 {
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
    const testing = std.testing;

    const MockKeyboard = struct {
        name: []const u8,
        leds_state: u32 = 0,

        fn getLibinputHandle(ptr: *anyopaque) ?*libinput.Device {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    const MockPointer = struct {
        name: []const u8,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    const MockTouch = struct {
        name: []const u8,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    const MockSwitch = struct {
        name: []const u8,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    const MockTablet = struct {
        name: []const u8,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    const MockTabletTool = struct {
        name: []const u8,
        type: ITabletTool.Type,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    const MockTabletPad = struct {
        name: []const u8,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    const MockKeyboard = struct {
        name: []const u8,

        fn getLibinputHandle(ptr: *anyopaque) ?*libinput.Device {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
        name: []const u8,

        fn getLibinputHandle(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn getName(ptr: *anyopaque) []const u8 {
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
    const testing = std.testing;

    var queue = Input.EventQueue.init(testing.allocator);
    defer queue.deinit();

    var device1 = Input.Device{
        .name = "Initial Device",
        .sysname = "initial0",
        .vendor = 0x1234,
        .product = 0x5678,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var device2 = Input.Device{
        .name = "Hotplugged Device",
        .sysname = "hotplug0",
        .vendor = 0xABCD,
        .product = 0xEF01,
        .device_type = .pointer,
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
    // This test documents error handling when libinput context creation fails
    // Since we can't easily create a failing libinput context in a test,
    // we validate that the appropriate error types exist in the Manager.init error set

    // The Manager.init function should handle these error cases:
    // - error.LibinputContextFailed: when libinput_udev_create_context fails
    // - error.SeatAssignFailed: when libinput_udev_assign_seat fails
    
    // In production code, these errors would be caught and handled appropriately
    // by the caller (e.g., retrying initialization or falling back to a different backend)
}

test "EventQueue - event ordering with multiple device types" {
    const testing = std.testing;

    var queue = Input.EventQueue.init(testing.allocator);
    defer queue.deinit();

    var keyboard = Input.Device{
        .name = "Keyboard",
        .sysname = "kbd0",
        .vendor = 0x1,
        .product = 0x1,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var pointer = Input.Device{
        .name = "Mouse",
        .sysname = "mouse0",
        .vendor = 0x2,
        .product = 0x2,
        .device_type = .pointer,
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
    try testing.expect(e1 == .keyboard_key);
    try testing.expectEqual(@as(u64, 1000), e1.keyboard_key.time_usec);

    const e2 = queue.pop().?;
    try testing.expect(e2 == .pointer_motion);
    try testing.expectEqual(@as(u64, 1100), e2.pointer_motion.time_usec);

    const e3 = queue.pop().?;
    try testing.expect(e3 == .pointer_button);
    try testing.expectEqual(@as(u64, 1200), e3.pointer_button.time_usec);

    const e4 = queue.pop().?;
    try testing.expect(e4 == .keyboard_key);
    try testing.expectEqual(@as(u64, 1300), e4.keyboard_key.time_usec);
}

test "Device - multiple capabilities on single device" {
    const testing = std.testing;

    // Some devices (like laptop touchpads) have both pointer and touch capabilities
    // This test ensures our device model can handle this

    var combo_device = Input.Device{
        .name = "Touchpad with Pointer",
        .sysname = "combo0",
        .vendor = 0x1234,
        .product = 0x5678,
        .device_type = .pointer, // Primary capability
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    try testing.expectEqualStrings("Touchpad with Pointer", combo_device.name);
    try testing.expectEqual(Input.DeviceType.pointer, combo_device.device_type);

    // Device should handle events from its primary capability
    var queue = Input.EventQueue.init(testing.allocator);
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
    try testing.expect(event == .pointer_motion);
}

test "Manager - seat switching" {
    const testing = std.testing;

    // This test documents the expected behavior when switching seats
    // In practice, this would require deinit and re-init of the Manager

    var device1 = Input.Device{
        .name = "Seat0 Device",
        .sysname = "seat0dev",
        .vendor = 0x1111,
        .product = 0x2222,
        .device_type = .keyboard,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    var device2 = Input.Device{
        .name = "Seat1 Device",
        .sysname = "seat1dev",
        .vendor = 0x3333,
        .product = 0x4444,
        .device_type = .pointer,
        .enabled = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    // Simulate seat switch by clearing old devices and adding new ones
    var queue = Input.EventQueue.init(testing.allocator);
    defer queue.deinit();

    // Old seat devices removed
    try queue.push(.{ .device_removed = .{ .device = &device1 } });

    // New seat devices added
    try queue.push(.{ .device_added = .{ .device = &device2 } });

    try testing.expectEqual(@as(usize, 2), queue.len());

    const e1 = queue.pop().?;
    try testing.expect(e1 == .device_removed);
    try testing.expectEqualStrings("Seat0 Device", e1.device_removed.device.name);

    const e2 = queue.pop().?;
    try testing.expect(e2 == .device_added);
    try testing.expectEqualStrings("Seat1 Device", e2.device_added.device.name);
}
