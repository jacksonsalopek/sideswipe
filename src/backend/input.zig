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
            libinput.c.libinput_device_unref(self.libinput_device);
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
                .events = std.ArrayList(Event).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *EventQueue) void {
            self.events.deinit();
        }

        pub fn push(self: *EventQueue, event: Event) !void {
            try self.events.append(event);
        }

        pub fn pop(self: *EventQueue) ?Event {
            if (self.events.items.len == 0) return null;
            return self.events.orderedRemove(0);
        }

        pub fn drain(self: *EventQueue) []const Event {
            defer self.events.clearRetainingCapacity();
            return self.events.items;
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
