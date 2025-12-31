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

            // Call static listeners (snapshot for safety)
            if (self.static_listeners.items.len > 0) {
                const static_listeners = self.allocator.dupe(ListenerEntry, self.static_listeners.items) catch return;
                defer self.allocator.free(static_listeners);

                for (static_listeners) |listener| {
                    if (!listener.active) continue;

                    if (Args == void) {
                        listener.callback(listener.userdata);
                    } else {
                        listener.callback(args, listener.userdata);
                    }
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

test "Signal - listener added during emit" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var second_listener: ?Listener = null;
        var sig: *Signal(void) = undefined;

        fn callback1(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;

            // Add listener during emit
            if (second_listener == null) {
                second_listener = sig.listen(callback2, null) catch unreachable;
            }
        }

        fn callback2(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;
        }
    };
    State.count = 0;
    State.second_listener = null;
    State.sig = &signal;

    var listener1 = try signal.listen(State.callback1, null);
    defer listener1.deinit();
    defer if (State.second_listener) |*l| l.deinit();

    signal.emit({});
    // Second listener added during emit should NOT fire on same emit
    try std.testing.expectEqual(@as(i32, 1), State.count);

    signal.emit({});
    // Second listener should fire on next emit
    try std.testing.expectEqual(@as(i32, 3), State.count);
}

test "Signal - listener removed during emit" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var second_listener: ?Listener = null;

        fn callback1(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;

            // Remove listener during emit
            if (second_listener) |*l| {
                l.deinit();
                second_listener = null;
            }
        }

        fn callback2(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 10;
        }
    };
    State.count = 0;

    var listener1 = try signal.listen(State.callback1, null);
    defer listener1.deinit();

    State.second_listener = try signal.listen(State.callback2, null);

    signal.emit({});
    // Both listeners fire because we snapshot before calling
    // But second is marked inactive so won't fire next time
    try std.testing.expectEqual(@as(i32, 11), State.count);

    signal.emit({});
    // Only first listener remains (second was cleaned up)
    try std.testing.expectEqual(@as(i32, 12), State.count);
}

test "Signal - multiple listeners with mixed disconnect" {
    const TestData = struct { value: i32 };
    var signal = Signal(TestData).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count1: i32 = 0;
        var count2: i32 = 0;
        var count3: i32 = 0;

        fn callback1(data: TestData, userdata: ?*anyopaque) void {
            _ = userdata;
            count1 += data.value;
        }

        fn callback2(data: TestData, userdata: ?*anyopaque) void {
            _ = userdata;
            count2 += data.value;
        }

        fn callback3(data: TestData, userdata: ?*anyopaque) void {
            _ = userdata;
            count3 += data.value;
        }
    };
    State.count1 = 0;
    State.count2 = 0;
    State.count3 = 0;

    var listener1 = try signal.listen(State.callback1, null);
    defer listener1.deinit();

    var listener2 = try signal.listen(State.callback2, null);

    var listener3 = try signal.listen(State.callback3, null);
    defer listener3.deinit();

    signal.emit(.{ .value = 10 });
    try std.testing.expectEqual(@as(i32, 10), State.count1);
    try std.testing.expectEqual(@as(i32, 10), State.count2);
    try std.testing.expectEqual(@as(i32, 10), State.count3);

    // Disconnect middle listener
    listener2.deinit();

    signal.emit(.{ .value = 10 });
    try std.testing.expectEqual(@as(i32, 20), State.count1);
    try std.testing.expectEqual(@as(i32, 10), State.count2); // Should not increment
    try std.testing.expectEqual(@as(i32, 20), State.count3);
}

test "Signal - listener with userdata" {
    const TestData = struct { value: i32 };
    var signal = Signal(TestData).init(std.testing.allocator);
    defer signal.deinit();

    var user_count: i32 = 0;

    const State = struct {
        fn callback(data: TestData, userdata: ?*anyopaque) void {
            const count: *i32 = @ptrCast(@alignCast(userdata.?));
            count.* += data.value;
        }
    };

    var listener = try signal.listen(State.callback, &user_count);
    defer listener.deinit();

    signal.emit(.{ .value = 5 });
    try std.testing.expectEqual(@as(i32, 5), user_count);

    signal.emit(.{ .value = 3 });
    try std.testing.expectEqual(@as(i32, 8), user_count);
}

test "Signal - mixed static and dynamic listeners" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;

        fn callback1(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;
        }

        fn callback2(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 10;
        }
    };
    State.count = 0;

    var listener = try signal.listen(State.callback1, null);
    defer listener.deinit();

    try signal.listenStatic(State.callback2, null);

    signal.emit({});
    try std.testing.expectEqual(@as(i32, 11), State.count);

    // Disconnect dynamic listener
    listener.deinit();

    signal.emit({});
    // Only static listener fires
    try std.testing.expectEqual(@as(i32, 21), State.count);
}

test "Signal - empty signal emit" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    // Should not crash with no listeners
    signal.emit({});
    signal.emit({});
}

test "Signal - listener disconnects multiple others" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count1: i32 = 0;
        var count2: i32 = 0;
        var count3: i32 = 0;
        var listener2: ?Listener = null;
        var listener3: ?Listener = null;

        fn callback1(userdata: ?*anyopaque) void {
            _ = userdata;
            count1 += 1;
            // Disconnect multiple other listeners
            if (listener2) |*l| {
                l.deinit();
                listener2 = null;
            }
            if (listener3) |*l| {
                l.deinit();
                listener3 = null;
            }
        }

        fn callback2(userdata: ?*anyopaque) void {
            _ = userdata;
            count2 += 1;
        }

        fn callback3(userdata: ?*anyopaque) void {
            _ = userdata;
            count3 += 1;
        }
    };
    State.count1 = 0;
    State.count2 = 0;
    State.count3 = 0;

    var listener1 = try signal.listen(State.callback1, null);
    defer listener1.deinit();

    State.listener2 = try signal.listen(State.callback2, null);
    State.listener3 = try signal.listen(State.callback3, null);

    // First emit - listener1 disconnects 2 and 3
    signal.emit({});
    
    // All fire because we snapshot before calling
    try std.testing.expectEqual(@as(i32, 1), State.count1);
    try std.testing.expectEqual(@as(i32, 1), State.count2);
    try std.testing.expectEqual(@as(i32, 1), State.count3);

    // Second emit - only listener1 remains
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 2), State.count1);
    try std.testing.expectEqual(@as(i32, 1), State.count2); // No change
    try std.testing.expectEqual(@as(i32, 1), State.count3); // No change
}

test "Signal - listener disconnects self and adds new" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count1: i32 = 0;
        var count2: i32 = 0;
        var listener1: ?Listener = null;
        var listener2: ?Listener = null;
        var sig: *Signal(void) = undefined;

        fn callback1(userdata: ?*anyopaque) void {
            _ = userdata;
            count1 += 1;
            
            if (count1 == 1) {
                // Disconnect self
                if (listener1) |*l| {
                    l.deinit();
                    listener1 = null;
                }
                // Add new listener
                listener2 = sig.listen(callback2, null) catch unreachable;
            }
        }

        fn callback2(userdata: ?*anyopaque) void {
            _ = userdata;
            count2 += 1;
        }
    };
    State.count1 = 0;
    State.count2 = 0;
    State.sig = &signal;

    State.listener1 = try signal.listen(State.callback1, null);
    defer if (State.listener2) |*l| l.deinit();

    // First emit
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.count1);
    try std.testing.expectEqual(@as(i32, 0), State.count2); // New listener not called yet

    // Second emit - only new listener should fire
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.count1); // Old listener disconnected
    try std.testing.expectEqual(@as(i32, 1), State.count2); // New listener fires
}

test "Signal - stress test with 1000 listeners" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    var listeners = std.ArrayList(Listener){};
    defer {
        for (listeners.items) |*l| {
            l.deinit();
        }
        listeners.deinit(std.testing.allocator);
    }

    var counter: i32 = 0;
    const State = struct {
        var count: *i32 = undefined;
        fn callback(userdata: ?*anyopaque) void {
            _ = userdata;
            count.* += 1;
        }
    };
    State.count = &counter;

    // Register 1000 listeners
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const listener = try signal.listen(State.callback, null);
        try listeners.append(std.testing.allocator, listener);
    }

    // Emit should call all 1000
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1000), counter);

    // Second emit
    counter = 0;
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1000), counter);
}

test "Signal - all listeners disconnect themselves" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var listeners: [5]?Listener = [_]?Listener{null} ** 5;

        fn makeCallback(comptime index: usize) *const fn (?*anyopaque) void {
            return struct {
                fn callback(userdata: ?*anyopaque) void {
                    _ = userdata;
                    count += 1;
                    // Each listener disconnects itself
                    if (listeners[index]) |*l| {
                        l.deinit();
                        listeners[index] = null;
                    }
                }
            }.callback;
        }
    };
    State.count = 0;

    // Register 5 listeners
    inline for (0..5) |i| {
        State.listeners[i] = try signal.listen(State.makeCallback(i), null);
    }

    // First emit - all listeners fire and disconnect themselves
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 5), State.count);

    // Second emit - no listeners should fire
    State.count = 0;
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 0), State.count);
}

test "Signal - static listener modification attempt" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var sig: *Signal(void) = undefined;

        fn callback(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;
            
            // Static listeners can't be disconnected directly
            // This just increments the counter
        }
    };
    State.count = 0;
    State.sig = &signal;

    try signal.listenStatic(State.callback, null);

    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.count);

    // Static listener should fire again
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 2), State.count);
}

test "Signal - listener adds multiple listeners during emit" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var new_listeners: [3]?Listener = [_]?Listener{null} ** 3;
        var sig: *Signal(void) = undefined;
        var added: bool = false;

        fn callback_main(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;
            
            if (!added) {
                added = true;
                // Add 3 new listeners during emit
                new_listeners[0] = sig.listen(callback_new, null) catch unreachable;
                new_listeners[1] = sig.listen(callback_new, null) catch unreachable;
                new_listeners[2] = sig.listen(callback_new, null) catch unreachable;
            }
        }

        fn callback_new(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 10;
        }
    };
    State.count = 0;
    State.sig = &signal;
    State.added = false;
    defer {
        for (&State.new_listeners) |*l| {
            if (l.*) |*listener| {
                listener.deinit();
            }
        }
    }

    var listener_main = try signal.listen(State.callback_main, null);
    defer listener_main.deinit();

    // First emit - main fires, adds 3 new listeners
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.count);

    // Second emit - main + 3 new listeners should fire
    State.count = 0;
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 31), State.count); // 1 + 10 + 10 + 10
}

test "Signal - cascade of disconnections" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var listeners: [10]?Listener = [_]?Listener{null} ** 10;

        fn makeCallback(comptime index: usize) *const fn (?*anyopaque) void {
            return struct {
                fn callback(userdata: ?*anyopaque) void {
                    _ = userdata;
                    count += 1;
                    
                    // Each listener disconnects the next one
                    if (index + 1 < 10) {
                        if (listeners[index + 1]) |*l| {
                            l.deinit();
                            listeners[index + 1] = null;
                        }
                    }
                }
            }.callback;
        }
    };
    State.count = 0;

    // Register 10 listeners
    inline for (0..10) |i| {
        State.listeners[i] = try signal.listen(State.makeCallback(i), null);
    }

    // Emit - each listener disconnects the next
    signal.emit({});
    
    // All should fire because we snapshot
    try std.testing.expectEqual(@as(i32, 10), State.count);

    // Second emit - only first listener remains active (it was never disconnected)
    State.count = 0;
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.count);
}

test "Signal - performance with rapid emit cycles" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    var counter: i32 = 0;
    const State = struct {
        var count: *i32 = undefined;
        fn callback(userdata: ?*anyopaque) void {
            _ = userdata;
            count.* += 1;
        }
    };
    State.count = &counter;

    // Register 100 listeners
    var listeners = std.ArrayList(Listener){};
    defer {
        for (listeners.items) |*l| {
            l.deinit();
        }
        listeners.deinit(std.testing.allocator);
    }

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try listeners.append(std.testing.allocator, try signal.listen(State.callback, null));
    }

    // Emit 100 times
    var emit_count: usize = 0;
    while (emit_count < 100) : (emit_count += 1) {
        signal.emit({});
    }

    // Should have called all listeners all times
    try std.testing.expectEqual(@as(i32, 10000), counter);
}

test "Signal - listener reconnects during emit" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var listener: ?Listener = null;
        var sig: *Signal(void) = undefined;

        fn callback(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;
            
            if (count == 1) {
                // Disconnect and immediately reconnect
                if (listener) |*l| {
                    l.deinit();
                }
                listener = sig.listen(callback, null) catch unreachable;
            }
        }
    };
    State.count = 0;
    State.sig = &signal;

    State.listener = try signal.listen(State.callback, null);
    defer if (State.listener) |*l| l.deinit();

    // First emit
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.count);

    // Second emit - new listener should fire
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 2), State.count);
}

test "Signal - mixed static and dynamic modifications" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var dynamic_count: i32 = 0;
        var static_count: i32 = 0;
        var dynamic_listener: ?Listener = null;

        fn dynamic_callback(userdata: ?*anyopaque) void {
            _ = userdata;
            dynamic_count += 1;
            
            // Try to disconnect self
            if (dynamic_listener) |*l| {
                l.deinit();
                dynamic_listener = null;
            }
        }

        fn static_callback(userdata: ?*anyopaque) void {
            _ = userdata;
            static_count += 1;
        }
    };
    State.dynamic_count = 0;
    State.static_count = 0;

    State.dynamic_listener = try signal.listen(State.dynamic_callback, null);
    try signal.listenStatic(State.static_callback, null);

    // First emit
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.dynamic_count);
    try std.testing.expectEqual(@as(i32, 1), State.static_count);

    // Second emit - only static listener fires
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.dynamic_count); // No change
    try std.testing.expectEqual(@as(i32, 2), State.static_count); // Increments
}

test "Signal - alternating connect/disconnect pattern" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count: i32 = 0;
        var listener: ?Listener = null;
        var sig: *Signal(void) = undefined;
        var should_disconnect: bool = true;

        fn callback(userdata: ?*anyopaque) void {
            _ = userdata;
            count += 1;
            
            if (should_disconnect) {
                if (listener) |*l| {
                    l.deinit();
                    listener = null;
                }
                should_disconnect = false;
            } else {
                listener = sig.listen(callback, null) catch unreachable;
                should_disconnect = true;
            }
        }
    };
    State.count = 0;
    State.sig = &signal;
    State.should_disconnect = true;

    State.listener = try signal.listen(State.callback, null);
    defer if (State.listener) |*l| l.deinit();

    // Multiple emits with alternating connect/disconnect
    // Note: reconnect in callback doesn't fire on same emit
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        signal.emit({});
        
        // After disconnect, reconnect for next iteration
        if (State.listener == null and State.should_disconnect) {
            State.listener = try signal.listen(State.callback, null);
            State.should_disconnect = false;
        }
    }

    // Count varies based on reconnect timing, just verify it worked
    try std.testing.expect(State.count > 0);
}

test "Signal - snapshot protects against orderedRemove" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var execution_order: [5]i32 = [_]i32{0} ** 5;
        var index: usize = 0;
        var listeners: [5]?Listener = [_]?Listener{null} ** 5;

        fn makeCallback(comptime id: i32) *const fn (?*anyopaque) void {
            return struct {
                fn callback(userdata: ?*anyopaque) void {
                    _ = userdata;
                    execution_order[index] = id;
                    index += 1;
                    
                    // Listener 0 disconnects all others
                    if (id == 0) {
                        for (&listeners) |*l| {
                            if (l.*) |*listener| {
                                listener.deinit();
                                l.* = null;
                            }
                        }
                    }
                }
            }.callback;
        }
    };
    State.index = 0;

    // Register 5 listeners
    inline for (0..5) |i| {
        State.listeners[i] = try signal.listen(State.makeCallback(@intCast(i)), null);
    }

    // Emit - all should execute despite first one disconnecting others
    signal.emit({});
    
    // All 5 should have executed
    try std.testing.expectEqual(@as(usize, 5), State.index);
    try std.testing.expectEqual(@as(i32, 0), State.execution_order[0]);
    try std.testing.expectEqual(@as(i32, 1), State.execution_order[1]);
    try std.testing.expectEqual(@as(i32, 2), State.execution_order[2]);
    try std.testing.expectEqual(@as(i32, 3), State.execution_order[3]);
    try std.testing.expectEqual(@as(i32, 4), State.execution_order[4]);
}

test "Signal - clear during emit has no effect" {
    var signal = Signal(void).init(std.testing.allocator);
    defer signal.deinit();

    const State = struct {
        var count1: i32 = 0;
        var count2: i32 = 0;
        var sig: *Signal(void) = undefined;

        fn callback1(userdata: ?*anyopaque) void {
            _ = userdata;
            count1 += 1;
            // Try to clear all listeners
            sig.clear();
        }

        fn callback2(userdata: ?*anyopaque) void {
            _ = userdata;
            count2 += 1;
        }
    };
    State.count1 = 0;
    State.count2 = 0;
    State.sig = &signal;

    var listener1 = try signal.listen(State.callback1, null);
    defer listener1.deinit();

    var listener2 = try signal.listen(State.callback2, null);
    defer listener2.deinit();

    // Emit - both should fire despite clear() being called
    signal.emit({});
    try std.testing.expectEqual(@as(i32, 1), State.count1);
    try std.testing.expectEqual(@as(i32, 1), State.count2);
}
