//! ext_idle_notifier_v1 — idle timeout tracking for OLED dim (R3).

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;
const testing = @import("core").testing;
const Compositor = @import("../compositor.zig").Compositor;

const VERSION = 2;

pub const Transition = enum { idled, resumed };

pub const Watch = struct {
    timeout_msec: u32,
    idle: bool = false,
    last_activity_msec: u64 = 0,

    pub fn note(self: *Watch, now_msec: u64) ?Transition {
        self.last_activity_msec = now_msec;
        if (!self.idle) return null;
        self.idle = false;
        return .resumed;
    }

    pub fn tick(self: *Watch, now_msec: u64) ?Transition {
        if (self.idle) return null;
        if (now_msec -| self.last_activity_msec < self.timeout_msec) return null;
        self.idle = true;
        return .idled;
    }
};

const Notification = struct {
    compositor: *Compositor,
    resource: *c.wl_resource,
    watch: Watch,
};

fn managerDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn getNotification(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    timeout: u32,
    _: ?*c.wl_resource,
) callconv(.c) void {
    createNotification(client, resource, id, timeout);
}

fn getInputNotification(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    timeout: u32,
    _: ?*c.wl_resource,
) callconv(.c) void {
    createNotification(client, resource, id, timeout);
}

fn createNotification(client: ?*c.wl_client, resource: ?*c.wl_resource, id: u32, timeout: u32) void {
    const compositor: *Compositor = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const created = c.wl_resource_create(client, &c.ext_idle_notification_v1_interface, 1, id) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };
    const notification = compositor.allocator.create(Notification) catch {
        c.wl_resource_destroy(created);
        return c.wl_resource_post_no_memory(resource);
    };
    notification.* = .{
        .compositor = compositor,
        .resource = created,
        .watch = .{ .timeout_msec = timeout, .last_activity_msec = compositor.seat.last_activity_msec },
    };
    c.wl_resource_set_implementation(created, @ptrCast(&notification_impl), notification, destroyNotification);
}

fn notificationDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn destroyNotification(resource: ?*c.wl_resource) callconv(.c) void {
    const notification = userdata(Notification, resource orelse return);
    notification.compositor.allocator.destroy(notification);
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&managerDestroy),
    @ptrCast(&getNotification),
    @ptrCast(&getInputNotification),
};

var notification_impl = [_]?*const anyopaque{
    @ptrCast(&notificationDestroy),
};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.ext_idle_notifier_v1_interface,
        @intCast(@min(version, VERSION)),
        id,
    ) orelse return c.wl_client_post_no_memory(client);
    c.wl_resource_set_implementation(resource, @ptrCast(&manager_impl), compositor, null);
}

pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.ext_idle_notifier_v1_interface,
        VERSION,
        compositor,
        bind,
    );
}

fn userdata(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}

test "idle watch idles after timeout and resumes on activity" {
    var watch = Watch{ .timeout_msec = 100, .last_activity_msec = 0 };
    try testing.expectEqual(@as(?Transition, .idled), watch.tick(100));
    try testing.expect(watch.idle);
    try testing.expectEqual(@as(?Transition, .resumed), watch.note(150));
    try testing.expectFalse(watch.idle);
}
