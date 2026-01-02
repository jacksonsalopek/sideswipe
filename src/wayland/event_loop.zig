const std = @import("std");
const c = @import("c.zig").c;

pub const EventLoop = struct {
    handle: *c.wl_event_loop,
    owned: bool,

    pub const Error = error{
        CreateFailed,
        AddFailed,
        DispatchFailed,
    };

    /// Creates a standalone event loop (not associated with a display).
    /// Caller must call deinit() when done.
    pub fn create() Error!EventLoop {
        const handle = c.wl_event_loop_create() orelse return error.CreateFailed;
        return EventLoop{ .handle = handle, .owned = true };
    }

    /// Wraps an existing event loop (e.g., from a display).
    /// Does not take ownership - caller must not call deinit().
    pub fn wrap(handle: *c.wl_event_loop) EventLoop {
        return EventLoop{ .handle = handle, .owned = false };
    }

    /// Destroys the event loop if owned.
    pub fn deinit(self: *EventLoop) void {
        if (self.owned) {
            c.wl_event_loop_destroy(self.handle);
        }
    }

    /// Gets the file descriptor for the event loop.
    /// Can be used with epoll/select for integration with other event systems.
    pub fn getFd(self: *EventLoop) i32 {
        return c.wl_event_loop_get_fd(self.handle);
    }

    /// Dispatches events with a timeout in milliseconds.
    /// Returns the number of events dispatched, or error.
    /// Use timeout = 0 for non-blocking, -1 for infinite wait.
    pub fn dispatch(self: *EventLoop, timeout_ms: i32) Error!i32 {
        const result = c.wl_event_loop_dispatch(self.handle, timeout_ms);
        if (result < 0) return error.DispatchFailed;
        return result;
    }

    /// Dispatches only idle callbacks (does not wait for events).
    pub fn dispatchIdle(self: *EventLoop) void {
        c.wl_event_loop_dispatch_idle(self.handle);
    }

    /// Adds a file descriptor event source.
    pub fn addFd(
        self: *EventLoop,
        fd: i32,
        mask: u32,
        callback: *const fn (i32, u32, ?*anyopaque) callconv(.C) i32,
        data: ?*anyopaque,
    ) Error!*c.wl_event_source {
        return c.wl_event_loop_add_fd(self.handle, fd, mask, callback, data) orelse error.AddFailed;
    }

    /// Adds a timer event source.
    pub fn addTimer(
        self: *EventLoop,
        callback: *const fn (?*anyopaque) callconv(.C) i32,
        data: ?*anyopaque,
    ) Error!*c.wl_event_source {
        return c.wl_event_loop_add_timer(self.handle, callback, data) orelse error.AddFailed;
    }

    /// Adds a signal event source.
    pub fn addSignal(
        self: *EventLoop,
        signal_number: i32,
        callback: *const fn (i32, ?*anyopaque) callconv(.C) i32,
        data: ?*anyopaque,
    ) Error!*c.wl_event_source {
        return c.wl_event_loop_add_signal(self.handle, signal_number, callback, data) orelse error.AddFailed;
    }
};

pub const EventSource = struct {
    handle: *c.wl_event_source,

    pub const Error = error{
        UpdateFailed,
        RemoveFailed,
    };

    pub fn wrap(handle: *c.wl_event_source) EventSource {
        return EventSource{ .handle = handle };
    }

    /// Updates the event mask for a file descriptor source.
    pub fn updateFd(self: *EventSource, mask: u32) Error!void {
        if (c.wl_event_source_fd_update(self.handle, mask) < 0) {
            return error.UpdateFailed;
        }
    }

    /// Updates the timer delay in milliseconds.
    pub fn updateTimer(self: *EventSource, ms_delay: i32) Error!void {
        if (c.wl_event_source_timer_update(self.handle, ms_delay) < 0) {
            return error.UpdateFailed;
        }
    }

    /// Removes and destroys the event source.
    pub fn remove(self: *EventSource) Error!void {
        if (c.wl_event_source_remove(self.handle) < 0) {
            return error.RemoveFailed;
        }
    }

    /// Marks the event source for checking.
    pub fn check(self: *EventSource) void {
        c.wl_event_source_check(self.handle);
    }
};

// Event mask flags for file descriptor sources
pub const WL_EVENT_READABLE = c.WL_EVENT_READABLE;
pub const WL_EVENT_WRITABLE = c.WL_EVENT_WRITABLE;
pub const WL_EVENT_HANGUP = c.WL_EVENT_HANGUP;
pub const WL_EVENT_ERROR = c.WL_EVENT_ERROR;

const testing = @import("core").testing;

test "EventLoop: create and destroy" {
    var loop = try EventLoop.create();
    defer loop.deinit();

    const fd = loop.getFd();
    try testing.expect(fd >= 0);
}

test "EventLoop: dispatch with timeout" {
    var loop = try EventLoop.create();
    defer loop.deinit();

    // Non-blocking dispatch with no events should return 0
    const result = try loop.dispatch(0);
    try testing.expectEqual(@as(i32, 0), result);
}
