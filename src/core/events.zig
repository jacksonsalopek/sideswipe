const std = @import("std");

/// Handle to a registered listener. When destroyed, the listener is automatically disconnected.
pub const Listener = struct {
    id: usize,
    signal: *anyopaque,
    disconnect_fn: *const fn (signal: *anyopaque, id: usize) void,

    pub fn deinit(self: *Listener) void {
        self.disconnect_fn(self.signal, self.id);
    }
};

/// A signal that can have multiple listeners
pub fn Signal(comptime Args: type) type {
    return struct {
        const Self = @This();

        pub const Callback = if (Args == void)
            *const fn (userdata: ?*anyopaque) void
        else
            *const fn (args: Args, userdata: ?*anyopaque) void;

        const ListenerEntry = struct {
            id: usize,
            callback: Callback,
            userdata: ?*anyopaque,
            active: bool = true,
        };

        listeners: std.ArrayList(ListenerEntry),
        static_listeners: std.ArrayList(ListenerEntry),
        allocator: std.mem.Allocator,
        next_id: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .listeners = .{},
                .static_listeners = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.listeners.deinit(self.allocator);
            self.static_listeners.deinit(self.allocator);
        }

        /// Connect a listener that can be disconnected. Returns a handle that auto-disconnects on deinit.
        pub fn listen(self: *Self, callback: Callback, userdata: ?*anyopaque) !Listener {
            const id = self.next_id;
            self.next_id += 1;

            try self.listeners.append(self.allocator, .{
                .id = id,
                .callback = callback,
                .userdata = userdata,
            });

            return .{
                .id = id,
                .signal = self,
                .disconnect_fn = disconnectById,
            };
        }

        /// Connect a static listener that lives for the lifetime of the signal
        pub fn listenStatic(self: *Self, callback: Callback, userdata: ?*anyopaque) !void {
            const id = self.next_id;
            self.next_id += 1;

            try self.static_listeners.append(self.allocator, .{
                .id = id,
                .callback = callback,
                .userdata = userdata,
            });
        }

        fn disconnectById(signal: *anyopaque, id: usize) void {
            const self: *Self = @ptrCast(@alignCast(signal));
            var i: usize = 0;
            while (i < self.listeners.items.len) {
                if (self.listeners.items[i].id == id) {
                    self.listeners.items[i].active = false;
                    break;
                }
                i += 1;
            }
        }

        /// Emit the signal to all listeners
        pub fn emit(self: *Self, args: if (Args == void) void else Args) void {
            // Clean up inactive listeners first
            var i: usize = 0;
            while (i < self.listeners.items.len) {
                if (!self.listeners.items[i].active) {
                    _ = self.listeners.orderedRemove(i);
                } else {
                    i += 1;
                }
            }

            if (self.listeners.items.len == 0 and self.static_listeners.items.len == 0)
                return;

            // Call regular listeners (copy in case they modify the list)
            if (self.listeners.items.len > 0) {
                const listeners = self.allocator.dupe(ListenerEntry, self.listeners.items) catch return;
                defer self.allocator.free(listeners);

                for (listeners) |listener| {
                    if (!listener.active) continue;

                    if (Args == void) {
                        listener.callback(listener.userdata);
                    } else {
                        listener.callback(args, listener.userdata);
                    }
                }
            }

            // Call static listeners
            for (self.static_listeners.items) |listener| {
                if (!listener.active) continue;

                if (Args == void) {
                    listener.callback(listener.userdata);
                } else {
                    listener.callback(args, listener.userdata);
                }
            }
        }

        /// Clear all non-static listeners
        pub fn clear(self: *Self) void {
            self.listeners.clearRetainingCapacity();
        }
    };
}

test "Signal with listener handle" {
    const TestData = struct { value: i32 };

    var signal = Signal(TestData).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;

        fn callback(data: TestData, userdata: ?*anyopaque) void {
            _ = userdata;
            count += data.value;
        }
    };

    var listener = try signal.listen(State.callback, null);

    signal.emit(.{ .value = 10 });
    try std.testing.expectEqual(@as(i32, 10), State.count);

    // Disconnect by destroying the handle
    listener.deinit();

    signal.emit(.{ .value = 10 });
    try std.testing.expectEqual(@as(i32, 10), State.count); // Should not increment
}

test "Signal void" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;

        fn callback(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;
        }
    };

    var listener = try signal.listen(State.callback, null);
    defer listener.deinit();

    signal.emit({});
    signal.emit({});

    try std.testing.expectEqual(@as(i32, 2), State.count);
}

test "Signal multiple listeners with handles" {
    const TestData = struct { value: i32 };

    var signal = Signal(TestData).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count1: i32 = 0;
        var count2: i32 = 0;

        fn callback1(data: TestData, userdata: ?*anyopaque) void {
            _ = userdata;
            count1 += data.value;
        }

        fn callback2(data: TestData, userdata: ?*anyopaque) void {
            _ = userdata;
            count2 += data.value;
        }
    };

    var listener1 = try signal.listen(State.callback1, null);
    defer listener1.deinit();

    var listener2 = try signal.listen(State.callback2, null);
    defer listener2.deinit();

    signal.emit(.{ .value = 10 });

    try std.testing.expectEqual(@as(i32, 10), State.count1);
    try std.testing.expectEqual(@as(i32, 10), State.count2);
}

test "Signal static listeners" {
    const TestData = struct { value: i32 };

    var signal = Signal(TestData).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;

        fn callback(data: TestData, userdata: ?*anyopaque) void {
            _ = userdata;
            count += data.value;
        }
    };

    try signal.listenStatic(State.callback, null);
    signal.emit(.{ .value = 5 });

    try std.testing.expectEqual(@as(i32, 5), State.count);

    // Static listeners can't be disconnected
    signal.clear();
    signal.emit(.{ .value = 5 });

    try std.testing.expectEqual(@as(i32, 10), State.count);
}
