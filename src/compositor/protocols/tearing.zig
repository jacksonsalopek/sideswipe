//! wp_tearing_control_v1 — async flips only on fullscreen HDR passthrough.

const wayland = @import("wayland");
const c = wayland.c;
const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const SurfaceData = @import("compositor.zig").SurfaceData;

const VERSION = 1;

fn managerDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn getTearing(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    const surface = userdata(SurfaceData, surface_resource orelse return).surface;
    if (surface.tearing_control != null) {
        c.wl_resource_post_error(
            resource,
            c.WP_TEARING_CONTROL_MANAGER_V1_ERROR_TEARING_CONTROL_EXISTS,
            "tearing control already exists",
        );
        return;
    }
    const created = c.wl_resource_create(
        c.wl_resource_get_client(resource orelse return),
        &c.wp_tearing_control_v1_interface,
        VERSION,
        id,
    ) orelse return c.wl_resource_post_no_memory(resource);
    surface.tearing_control = created;
    c.wl_resource_set_implementation(created, @ptrCast(&control_impl), surface, controlDestroy);
}

fn setHint(_: ?*c.wl_client, resource: ?*c.wl_resource, hint: u32) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    surface.tearing_async = hint == c.WP_TEARING_CONTROL_V1_PRESENTATION_HINT_ASYNC;
}

fn controlClientDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn controlDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    surface.tearing_control = null;
    surface.tearing_async = false;
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&managerDestroy),
    @ptrCast(&getTearing),
};

var control_impl = [_]?*const anyopaque{
    @ptrCast(&setHint),
    @ptrCast(&controlClientDestroy),
};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.wp_tearing_control_manager_v1_interface,
        @intCast(@min(version, VERSION)),
        id,
    ) orelse return c.wl_client_post_no_memory(client);
    c.wl_resource_set_implementation(resource, @ptrCast(&manager_impl), compositor, null);
}

pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wp_tearing_control_manager_v1_interface,
        VERSION,
        compositor,
        bind,
    );
}

fn userdata(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}

/// Tearing is honored only for fullscreen HDR passthrough (H6).
pub fn allowAsync(passthrough: bool, tearing_async: bool) bool {
    return passthrough and tearing_async;
}

const testing = @import("core").testing;

test "tearing async is gated on HDR passthrough" {
    try testing.expect(allowAsync(true, true));
    try testing.expectFalse(allowAsync(false, true));
    try testing.expectFalse(allowAsync(true, false));
}
