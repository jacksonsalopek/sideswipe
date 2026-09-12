//! wl_compositor protocol implementation
//! Handles surface and region creation

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const FrameCallback = @import("../surface.zig").FrameCallback;
const InputRect = @import("../surface.zig").InputRect;

// wl_compositor interface version we support
const WL_COMPOSITOR_VERSION = 6;

// User data structures
// Note: All user data structs are allocated/freed with compositor.allocator

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
    compositor: *Compositor,
    rectangles: std.ArrayList(InputRect) = .empty,

    fn deinit(self: *RegionData) void {
        self.rectangles.deinit(self.compositor.allocator);
        self.compositor.allocator.destroy(self);
    }

    fn add(self: *RegionData, rectangle: InputRect) !void {
        if (rectangle.width <= 0 or rectangle.height <= 0) return;
        try self.rectangles.append(self.compositor.allocator, rectangle);
    }

    fn subtract(self: *RegionData, removed: InputRect) !void {
        if (removed.width <= 0 or removed.height <= 0) return;
        var replacement = std.ArrayList(InputRect).empty;
        errdefer replacement.deinit(self.compositor.allocator);
        for (self.rectangles.items) |rectangle| {
            try appendDifference(
                self.compositor.allocator,
                &replacement,
                rectangle,
                removed,
            );
        }
        self.rectangles.deinit(self.compositor.allocator);
        self.rectangles = replacement;
    }
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

    comp.logger.debug("Created surface {d}", .{surface.id});

    // Create wl_surface resource
    const surface_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_surface_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        comp.destroySurface(surface, "creation failed: no memory for wl_surface resource");
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Attach surface data
    const surface_data = comp.allocator.create(SurfaceData) catch {
        comp.destroySurface(surface, "creation failed: no memory for surface data");
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

    const region_data = comp.allocator.create(RegionData) catch {
        c.wl_resource_destroy(region_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    region_data.* = .{ .compositor = comp };

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

    comp.destroySurface(surface, "client destroyed wl_surface");
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

    const surface = data.surface;
    if (buffer_resource != null) {
        surface.compositor.logger.debug("Surface {d} attached buffer", .{surface.id});
    }

    surface.attach(buffer_resource, x, y) catch {
        c.wl_resource_post_no_memory(resource);
    };
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
    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const surface = data.surface;
    const comp = surface.compositor;

    // Create wl_callback resource
    const callback_resource = c.wl_resource_create(
        client,
        &c.wl_callback_interface,
        1,
        callback_id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Create callback data
    const callback = comp.allocator.create(FrameCallback) catch {
        c.wl_resource_destroy(callback_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    callback.* = .{ .resource = callback_resource };

    // Add to surface's pending frame callbacks
    surface.frame(callback) catch {
        comp.allocator.destroy(callback);
        c.wl_resource_destroy(callback_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };

    comp.logger.trace("Surface {d} registered frame callback", .{surface.id});
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
    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    if (region == null) {
        data.surface.setInputRegion(null) catch c.wl_resource_post_no_memory(resource);
        return;
    }
    const region_data: *RegionData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(region),
    ));
    data.surface.setInputRegion(region_data.rectangles.items) catch
        c.wl_resource_post_no_memory(resource);
}

fn surfaceCommit(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;

    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const surface = data.surface;
    if (surface.pending.buffer.buffer != null) {
        surface.compositor.logger.debug("Surface {d} committed", .{surface.id});
    }

    surface.validatePendingState() catch |err| {
        postCommitValidationError(surface, resource orelse return, err);
        return;
    };
    surface.commit();
}

fn postCommitValidationError(
    surface: *Surface,
    resource: *c.wl_resource,
    err: Surface.CommitValidationError,
) void {
    switch (err) {
        error.InvalidScale => c.wl_resource_post_error(
            resource,
            c.WL_SURFACE_ERROR_INVALID_SCALE,
            "buffer scale must be positive",
        ),
        error.InvalidSize => c.wl_resource_post_error(
            resource,
            c.WL_SURFACE_ERROR_INVALID_SIZE,
            "buffer dimensions must be divisible by buffer scale",
        ),
        error.ViewportBadSize => c.wl_resource_post_error(
            surface.viewport_resource orelse resource,
            c.WP_VIEWPORT_ERROR_BAD_SIZE,
            "fractional viewport source size requires a destination",
        ),
        error.ViewportOutOfBuffer => c.wl_resource_post_error(
            surface.viewport_resource orelse resource,
            c.WP_VIEWPORT_ERROR_OUT_OF_BUFFER,
            "viewport source rectangle exceeds the buffer",
        ),
    }
}

fn surfaceSetBufferTransform(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    transform: i32,
) callconv(.c) void {
    _ = client;

    if (!validBufferTransform(transform)) {
        c.wl_resource_post_error(
            resource,
            c.WL_SURFACE_ERROR_INVALID_TRANSFORM,
            "invalid buffer transform",
        );
        return;
    }
    const data: *SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.surface.setTransform(@intCast(transform));
}

fn validBufferTransform(transform: i32) bool {
    return transform >= c.WL_OUTPUT_TRANSFORM_NORMAL and
        transform <= c.WL_OUTPUT_TRANSFORM_FLIPPED_270;
}

fn surfaceSetBufferScale(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    scale: i32,
) callconv(.c) void {
    _ = client;

    if (scale <= 0) {
        c.wl_resource_post_error(
            resource,
            c.WL_SURFACE_ERROR_INVALID_SCALE,
            "buffer scale must be positive",
        );
        return;
    }

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

// wl_region request handlers

fn regionDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *RegionData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.deinit();
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
    const data: *RegionData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.add(.{ .x = x, .y = y, .width = width, .height = height }) catch
        c.wl_resource_post_no_memory(resource);
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
    const data: *RegionData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.subtract(.{ .x = x, .y = y, .width = width, .height = height }) catch
        c.wl_resource_post_no_memory(resource);
}

fn appendDifference(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(InputRect),
    rectangle: InputRect,
    removed: InputRect,
) !void {
    const left = @max(rectangle.x, removed.x);
    const top = @max(rectangle.y, removed.y);
    const right = @min(rectangle.x + rectangle.width, removed.x + removed.width);
    const bottom = @min(rectangle.y + rectangle.height, removed.y + removed.height);
    if (left >= right or top >= bottom) {
        try result.append(allocator, rectangle);
        return;
    }
    try appendNonEmpty(result, allocator, .{
        .x = rectangle.x,
        .y = rectangle.y,
        .width = rectangle.width,
        .height = top - rectangle.y,
    });
    try appendNonEmpty(result, allocator, .{
        .x = rectangle.x,
        .y = bottom,
        .width = rectangle.width,
        .height = rectangle.y + rectangle.height - bottom,
    });
    try appendNonEmpty(result, allocator, .{
        .x = rectangle.x,
        .y = top,
        .width = left - rectangle.x,
        .height = bottom - top,
    });
    try appendNonEmpty(result, allocator, .{
        .x = right,
        .y = top,
        .width = rectangle.x + rectangle.width - right,
        .height = bottom - top,
    });
}

fn appendNonEmpty(
    result: *std.ArrayList(InputRect),
    allocator: std.mem.Allocator,
    rectangle: InputRect,
) !void {
    if (rectangle.width <= 0 or rectangle.height <= 0) return;
    try result.append(allocator, rectangle);
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

    compositor.logger.debug("Client bound to wl_compositor (version {d})", .{version});

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

const testing = @import("core").testing;

test "wl_surface buffer transform accepts only protocol enum values" {
    try testing.expect(validBufferTransform(c.WL_OUTPUT_TRANSFORM_NORMAL));
    try testing.expect(validBufferTransform(c.WL_OUTPUT_TRANSFORM_FLIPPED_270));
    try testing.expectFalse(validBufferTransform(-1));
    try testing.expectFalse(validBufferTransform(c.WL_OUTPUT_TRANSFORM_FLIPPED_270 + 1));
}

test "wl_region add and subtract preserve union geometry" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const region = try testing.allocator.create(RegionData);
    region.* = .{ .compositor = fixture.compositor };
    defer region.deinit();

    try region.add(.{ .x = 0, .y = 0, .width = 100, .height = 80 });
    try region.add(.{ .x = 200, .y = 200, .width = 10, .height = 10 });
    try region.subtract(.{ .x = 20, .y = 10, .width = 60, .height = 50 });

    try testing.expectEqual(@as(usize, 5), region.rectangles.items.len);
    var found_disjoint = false;
    for (region.rectangles.items) |rectangle| {
        if (rectangle.x == 200 and rectangle.y == 200 and
            rectangle.width == 10 and rectangle.height == 10)
            found_disjoint = true;
    }
    try testing.expect(found_disjoint);
}

test "wl_surface input region copies assignment and commits atomically" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    defer @import("core").unix.close(fds[1]);
    const client = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse
        return error.ClientCreateFailed;
    defer c.wl_client_destroy(client);

    const surface_resource = c.wl_resource_create(client, &c.wl_surface_interface, 1, 1) orelse
        return error.ResourceCreateFailed;
    const surface_data = try testing.allocator.create(SurfaceData);
    surface_data.* = .{ .surface = surface };
    surface.setResource(surface_resource);
    c.wl_resource_set_implementation(
        surface_resource,
        @ptrCast(&surface_implementation),
        surface_data,
        surfaceDestroy,
    );

    const region_resource = c.wl_resource_create(client, &c.wl_region_interface, 1, 2) orelse
        return error.ResourceCreateFailed;
    const region_data = try testing.allocator.create(RegionData);
    region_data.* = .{ .compositor = fixture.compositor };
    c.wl_resource_set_implementation(
        region_resource,
        @ptrCast(&region_implementation),
        region_data,
        regionDestroy,
    );
    regionAdd(null, region_resource, 10, 20, 30, 40);
    surfaceSetInputRegion(null, surface_resource, region_resource);
    c.wl_resource_destroy(region_resource);

    try testing.expect(surface.acceptsInput(0, 0));
    surfaceCommit(null, surface_resource);
    try testing.expectFalse(surface.acceptsInput(0, 0));
    try testing.expect(surface.acceptsInput(15, 25));

    surfaceSetInputRegion(null, surface_resource, null);
    try testing.expectFalse(surface.acceptsInput(0, 0));
    surfaceCommit(null, surface_resource);
    try testing.expect(surface.acceptsInput(0, 0));
}
