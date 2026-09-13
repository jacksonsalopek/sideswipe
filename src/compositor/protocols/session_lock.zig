//! ext_session_lock_v1: blank outputs and drop client input until unlock.

const wayland = @import("wayland");
const c = wayland.c;
const Compositor = @import("../compositor.zig").Compositor;
const SurfaceData = @import("compositor.zig").SurfaceData;
const session = @import("../lock.zig");

const Manager = struct {
    compositor: *Compositor,
};

const Lock = struct {
    compositor: *Compositor,
    machine: *session.Machine,
    resource: *c.wl_resource,
    object: session.Object = .{},
    surfaces: u32 = 0,
};

fn managerDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn managerLock(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const manager_resource = resource orelse return;
    const manager = userdata(Manager, manager_resource);
    const lock_resource = c.wl_resource_create(
        c.wl_resource_get_client(manager_resource),
        &c.ext_session_lock_v1_interface,
        1,
        id,
    ) orelse return c.wl_resource_post_no_memory(manager_resource);

    const lock = manager.compositor.allocator.create(Lock) catch {
        c.wl_resource_destroy(lock_resource);
        return c.wl_resource_post_no_memory(manager_resource);
    };
    lock.* = .{
        .compositor = manager.compositor,
        .machine = &manager.compositor.session_lock,
        .resource = lock_resource,
    };
    c.wl_resource_set_implementation(lock_resource, @ptrCast(&lock_impl), lock, destroyLock);

    lock.object.claim(lock.machine) catch {
        c.ext_session_lock_v1_send_finished(lock_resource);
        return;
    };
    applySession(manager.compositor, true);
    lock.object.confirm(lock.machine);
    c.ext_session_lock_v1_send_locked(lock_resource);
}

fn lockDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const lock = userdata(Lock, resource orelse return);
    lock.object.destroy(lock.machine) catch {
        c.wl_resource_post_error(
            resource,
            c.EXT_SESSION_LOCK_V1_ERROR_INVALID_DESTROY,
            "session is locked",
        );
        return;
    };
    c.wl_resource_destroy(resource);
}

fn lockUnlock(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const lock = userdata(Lock, resource orelse return);
    lock.object.unlock(lock.machine) catch {
        c.wl_resource_post_error(
            resource,
            c.EXT_SESSION_LOCK_V1_ERROR_INVALID_UNLOCK,
            "locked event was never sent",
        );
        return;
    };
    applySession(lock.compositor, false);
    c.wl_resource_destroy(resource);
}

fn lockGetSurface(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
    _: ?*c.wl_resource,
) callconv(.c) void {
    const lock = userdata(Lock, resource orelse return);
    const surface = userdata(SurfaceData, surface_resource orelse return).surface;
    if (surface.role != .none) {
        c.wl_resource_post_error(resource, c.EXT_SESSION_LOCK_V1_ERROR_ROLE, "surface already has a role");
        return;
    }
    const created = c.wl_resource_create(
        c.wl_resource_get_client(resource.?),
        &c.ext_session_lock_surface_v1_interface,
        1,
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    surface.role = .session_lock;
    lock.surfaces += 1;
    const size = lock.compositor.viewportSize();
    surface.scene_geometry = .{
        .x = 0,
        .y = 0,
        .width = @max(size.width, 1),
        .height = @max(size.height, 1),
    };
    lock.compositor.seat.activate(surface);
    c.wl_resource_set_implementation(created, @ptrCast(&surface_impl), surface, null);
    const serial = lock.compositor.nextSerial();
    c.ext_session_lock_surface_v1_send_configure(
        created,
        serial,
        @intCast(@max(size.width, 1)),
        @intCast(@max(size.height, 1)),
    );
}

fn surfaceDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn surfaceAck(_: ?*c.wl_client, _: ?*c.wl_resource, _: u32) callconv(.c) void {}

fn destroyManager(resource: ?*c.wl_resource) callconv(.c) void {
    const manager = userdata(Manager, resource orelse return);
    manager.compositor.allocator.destroy(manager);
}

fn destroyLock(resource: ?*c.wl_resource) callconv(.c) void {
    const lock = userdata(Lock, resource orelse return);
    lock.object.resourceGone(lock.machine);
    lock.compositor.allocator.destroy(lock);
}

fn applySession(compositor: *Compositor, locked: bool) void {
    compositor.seat.session_locked = locked;
    if (locked) compositor.seat.dropUnlockedFocus();
    for (compositor.outputs.items) |output| {
        output.blanked = locked;
        output.scheduleFrame();
    }
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&managerDestroy),
    @ptrCast(&managerLock),
};

var lock_impl = [_]?*const anyopaque{
    @ptrCast(&lockDestroy),
    @ptrCast(&lockGetSurface),
    @ptrCast(&lockUnlock),
};

var surface_impl = [_]?*const anyopaque{
    @ptrCast(&surfaceDestroy),
    @ptrCast(&surfaceAck),
};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, _: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(client, &c.ext_session_lock_manager_v1_interface, 1, id) orelse
        return c.wl_client_post_no_memory(client);
    const manager = compositor.allocator.create(Manager) catch {
        c.wl_resource_destroy(resource);
        return c.wl_client_post_no_memory(client);
    };
    manager.* = .{ .compositor = compositor };
    c.wl_resource_set_implementation(resource, @ptrCast(&manager_impl), manager, destroyManager);
}

pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.ext_session_lock_manager_v1_interface,
        1,
        compositor,
        bind,
    );
}

fn userdata(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}

