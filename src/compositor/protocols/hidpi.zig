//! wp_viewporter and wp_fractional_scale_v1.

const wayland = @import("wayland");
const c = wayland.c;
const testing = @import("core").testing;

const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const SurfaceData = @import("compositor.zig").SurfaceData;
const scale = @import("../scale.zig");

const VERSION = 1;

const ManagerData = struct {
    compositor: *Compositor,
};

fn surfaceFromResource(resource: ?*c.wl_resource) *Surface {
    const data: *SurfaceData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    return data.surface;
}

fn managerDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn fractionalGet(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    const surface = surfaceFromResource(surface_resource);
    if (surface.fractional_scale_resource != null) {
        c.wl_resource_post_error(resource, c.WP_FRACTIONAL_SCALE_MANAGER_V1_ERROR_FRACTIONAL_SCALE_EXISTS, "fractional scale already exists");
        return;
    }
    const fractional = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wp_fractional_scale_v1_interface,
        VERSION,
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };
    surface.fractional_scale_resource = fractional;
    c.wl_resource_set_implementation(fractional, @ptrCast(&fractional_implementation), surface, fractionalResourceDestroy);
    sendPreferred(surface, surface.compositor.preferredScale());
}

pub fn sendPreferred(surface: *Surface, preferred: f32) void {
    const resource = surface.fractional_scale_resource orelse return;
    c.wp_fractional_scale_v1_send_preferred_scale(resource, scale.protocolValue(preferred));
}

fn fractionalDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn fractionalResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    surface.fractional_scale_resource = null;
}

var fractional_manager_implementation = [_]?*const anyopaque{
    @ptrCast(&managerDestroy),
    @ptrCast(&fractionalGet),
};

var fractional_implementation = [_]?*const anyopaque{
    @ptrCast(&fractionalDestroy),
};

fn viewporterGet(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    const surface = surfaceFromResource(surface_resource);
    if (surface.viewport_resource != null) {
        c.wl_resource_post_error(resource, c.WP_VIEWPORTER_ERROR_VIEWPORT_EXISTS, "viewport already exists");
        return;
    }
    const viewport = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wp_viewport_interface,
        VERSION,
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };
    surface.viewport_resource = viewport;
    c.wl_resource_set_implementation(viewport, @ptrCast(&viewport_implementation), surface, viewportResourceDestroy);
}

fn viewportDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn viewportSetSource(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    if (x == -256 and y == -256 and width == -256 and height == -256) {
        surface.setViewportSource(null);
        return;
    }
    if (!validViewportSource(x, y, width, height)) {
        c.wl_resource_post_error(resource, c.WP_VIEWPORT_ERROR_BAD_VALUE, "viewport source must be non-negative with positive size");
        return;
    }
    surface.setViewportSource(.{ .x = x, .y = y, .width = width, .height = height });
}

fn validViewportSource(x: i32, y: i32, width: i32, height: i32) bool {
    return x >= 0 and y >= 0 and width > 0 and height > 0;
}

fn viewportSetDestination(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    width: i32,
    height: i32,
) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    if (width == -1 and height == -1) {
        surface.setViewportDestination(null);
        return;
    }
    if (width <= 0 or height <= 0) {
        c.wl_resource_post_error(resource, c.WP_VIEWPORT_ERROR_BAD_VALUE, "viewport destination must have positive size");
        return;
    }
    surface.setViewportDestination(.{ .width = width, .height = height });
}

fn viewportResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const surface: *Surface = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    surface.viewport_resource = null;
    surface.setViewportSource(null);
    surface.setViewportDestination(null);
}

var viewporter_implementation = [_]?*const anyopaque{
    @ptrCast(&managerDestroy),
    @ptrCast(&viewporterGet),
};

var viewport_implementation = [_]?*const anyopaque{
    @ptrCast(&viewportDestroy),
    @ptrCast(&viewportSetSource),
    @ptrCast(&viewportSetDestination),
};

fn bindManager(
    interface: *const c.wl_interface,
    implementation: *const anyopaque,
    client: ?*c.wl_client,
    data: ?*anyopaque,
    version: u32,
    id: u32,
) void {
    const compositor: *Compositor = @ptrCast(@alignCast(data));
    const resource = c.wl_resource_create(client, interface, @intCast(@min(version, VERSION)), id) orelse {
        c.wl_client_post_no_memory(client);
        return;
    };
    c.wl_resource_set_implementation(resource, implementation, compositor, null);
}

fn fractionalBind(client: ?*c.wl_client, data: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    bindManager(&c.wp_fractional_scale_manager_v1_interface, @ptrCast(&fractional_manager_implementation), client, data, version, id);
}

fn viewporterBind(client: ?*c.wl_client, data: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    bindManager(&c.wp_viewporter_interface, @ptrCast(&viewporter_implementation), client, data, version, id);
}

pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(compositor.server.getDisplay(), &c.wp_viewporter_interface, VERSION, compositor, viewporterBind);
    _ = try wayland.Global.create(compositor.server.getDisplay(), &c.wp_fractional_scale_manager_v1_interface, VERSION, compositor, fractionalBind);
}

test "sendPreferred is a no-op without a fractional scale object" {
    var surface: Surface = undefined;
    surface.fractional_scale_resource = null;
    sendPreferred(&surface, 1.5);
}

test "viewport source rejects negative coordinates and extents" {
    try testing.expect(validViewportSource(0, 0, 256, 256));
    try testing.expectFalse(validViewportSource(-1, 0, 256, 256));
    try testing.expectFalse(validViewportSource(0, -1, 256, 256));
    try testing.expectFalse(validViewportSource(0, 0, 0, 256));
    try testing.expectFalse(validViewportSource(0, 0, 256, -1));
}
