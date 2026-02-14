//! wl_compositor protocol implementation
//! Handles surface and region creation

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;

// wl_compositor interface version we support
const WL_COMPOSITOR_VERSION = 6;

/// User data attached to wl_compositor resources
const CompositorData = struct {
    compositor: *Compositor,
};

/// User data attached to wl_surface resources
pub const SurfaceData = struct {
    surface: *Surface,
};

/// User data attached to wl_region resources
const RegionData = struct {
    // Region implementation would go here
    dummy: u32 = 0,
};

// wl_compositor request handlers

fn compositorCreateSurface(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;

    const data: *CompositorData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;
    const surface = comp.createSurface() catch {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Create wl_surface resource
    const surface_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_surface_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        comp.destroySurface(surface);
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Attach surface data
    const surface_data = comp.allocator.create(SurfaceData) catch {
        comp.destroySurface(surface);
        c.wl_resource_destroy(surface_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    surface_data.* = .{ .surface = surface };
    surface.setResource(surface_resource);

    c.wl_resource_set_implementation(
        surface_resource,
        @ptrCast(&surface_implementation),
        surface_data,
        surfaceDestroy,
    );
}

fn compositorCreateRegion(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;

    const data: *CompositorData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;

    // Create wl_region resource
    const region_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_region_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Attach region data (stub for now)
    const region_data = comp.allocator.create(RegionData) catch {
        c.wl_resource_destroy(region_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    region_data.* = .{};

    c.wl_resource_set_implementation(
        region_resource,
        @ptrCast(&region_implementation),
        region_data,
        regionDestroy,
    );
}

var compositor_implementation = [_]?*const anyopaque{
    @ptrCast(&compositorCreateSurface),
    @ptrCast(&compositorCreateRegion),
};

// wl_surface request handlers

fn surfaceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const surface = data.surface;
    const comp = surface.compositor;
    const allocator = comp.allocator;

    comp.destroySurface(surface);
    allocator.destroy(data);
}

fn surfaceDestroyRequest(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn surfaceAttach(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    buffer_resource: ?*c.wl_resource,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = client;

    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.surface.attach(buffer_resource, x, y);
}

fn surfaceDamage(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;

    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.surface.damage(x, y, width, height) catch {
        c.wl_resource_post_no_memory(resource);
    };
}

fn surfaceFrame(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    callback_id: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = callback_id;

    // Frame callback implementation would go here
    // For now, just stub it out
}

fn surfaceSetOpaqueRegion(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    region: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = region;
    // Opaque region implementation stub
}

fn surfaceSetInputRegion(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    region: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = region;
    // Input region implementation stub
}

fn surfaceCommit(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;

    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.surface.commit();
}

fn surfaceSetBufferTransform(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    transform: i32,
) callconv(.c) void {
    _ = client;

    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.surface.setTransform(@intCast(transform));
}

fn surfaceSetBufferScale(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    scale: i32,
) callconv(.c) void {
    _ = client;

    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.surface.setScale(scale);
}

fn surfaceDamageBuffer(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;

    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.surface.damageBuffer(x, y, width, height) catch {
        c.wl_resource_post_no_memory(resource);
    };
}

fn surfaceOffset(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = x;
    _ = y;
    // Surface offset implementation stub (Wayland 1.21+)
}

var surface_implementation = [_]?*const anyopaque{
    @ptrCast(&surfaceDestroyRequest),
    @ptrCast(&surfaceAttach),
    @ptrCast(&surfaceDamage),
    @ptrCast(&surfaceFrame),
    @ptrCast(&surfaceSetOpaqueRegion),
    @ptrCast(&surfaceSetInputRegion),
    @ptrCast(&surfaceCommit),
    @ptrCast(&surfaceSetBufferTransform),
    @ptrCast(&surfaceSetBufferScale),
    @ptrCast(&surfaceDamageBuffer),
    @ptrCast(&surfaceOffset),
};

// wl_region request handlers (stub)

fn regionDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *RegionData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    // Get allocator from somewhere (for now, use c allocator)
    std.heap.c_allocator.destroy(data);
}

fn regionDestroyRequest(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn regionAdd(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    // Region add implementation stub
}

fn regionSubtract(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    // Region subtract implementation stub
}

var region_implementation = [_]?*const anyopaque{
    @ptrCast(&regionDestroyRequest),
    @ptrCast(&regionAdd),
    @ptrCast(&regionSubtract),
};

// Global bind handler

fn compositorBind(
    client: ?*c.wl_client,
    data: ?*anyopaque,
    version: u32,
    id: u32,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(data));

    const resource = c.wl_resource_create(
        client,
        &c.wl_compositor_interface,
        @intCast(@min(version, WL_COMPOSITOR_VERSION)),
        id,
    ) orelse {
        c.wl_client_post_no_memory(client);
        return;
    };

    const compositor_data = compositor.allocator.create(CompositorData) catch {
        c.wl_resource_destroy(resource);
        c.wl_client_post_no_memory(client);
        return;
    };
    compositor_data.* = .{ .compositor = compositor };

    c.wl_resource_set_implementation(
        resource,
        @ptrCast(&compositor_implementation),
        compositor_data,
        compositorResourceDestroy,
    );
}

fn compositorResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *CompositorData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.compositor.allocator.destroy(data);
}

/// Registers the wl_compositor global
pub fn register(compositor: *Compositor) !void {
    const global = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wl_compositor_interface,
        WL_COMPOSITOR_VERSION,
        compositor,
        compositorBind,
    );
    _ = global; // Global is owned by display, no need to track
}
