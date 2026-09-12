//! wl_output protocol implementation
//! Provides display information to clients (geometry, modes, scale)

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("../compositor.zig").Compositor;
const scale = @import("../scale.zig");

// wl_output interface version we support
const WL_OUTPUT_VERSION = 4;

// User data structures
// Note: All user data structs are allocated/freed with compositor.allocator

/// User data attached to wl_output resources
const OutputData = struct {
    compositor: *Compositor,
};

// wl_output has no requests, only events sent to clients

// Global bind handler

fn outputBind(
    client: ?*c.wl_client,
    data: ?*anyopaque,
    version: u32,
    id: u32,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(data));

    compositor.logger.debug("Client bound to wl_output (version {d})", .{version});

    const resource = c.wl_resource_create(
        client,
        &c.wl_output_interface,
        @intCast(@min(version, WL_OUTPUT_VERSION)),
        id,
    ) orelse {
        c.wl_client_post_no_memory(client);
        return;
    };

    const output_data = compositor.allocator.create(OutputData) catch {
        c.wl_resource_destroy(resource);
        c.wl_client_post_no_memory(client);
        return;
    };
    output_data.* = .{ .compositor = compositor };

    c.wl_resource_set_implementation(
        resource,
        null, // No request handlers for wl_output
        output_data,
        outputResourceDestroy,
    );

    attach(compositor, resource);
    sendOutputInfo(resource, @intCast(version), compositor);
}

fn outputResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *OutputData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    detach(data.compositor, resource);
    data.compositor.allocator.destroy(data);
}

fn attach(compositor: *Compositor, resource: *c.wl_resource) void {
    compositor.output_binds.append(compositor.allocator, resource) catch {};
}

fn detach(compositor: *Compositor, resource: ?*c.wl_resource) void {
    const target = resource orelse return;
    for (compositor.output_binds.items, 0..) |bound, index| {
        if (bound != target) continue;
        _ = compositor.output_binds.swapRemove(index);
        return;
    }
}

pub fn broadcast(compositor: *Compositor) void {
    for (compositor.output_binds.items) |resource| {
        sendOutputInfo(resource, @intCast(c.wl_resource_get_version(resource)), compositor);
    }
}

const Mode = struct {
    width: i32,
    height: i32,
    scale: f32,
};

fn advertisedMode(compositor: *Compositor) Mode {
    const fractional_scale = compositor.preferredScale();
    if (compositor.outputs.items.len == 0) {
        return physicalMode(1920, 1080, fractional_scale);
    }
    const output = compositor.outputs.items[0];
    return physicalMode(output.logical_width, output.logical_height, output.fractional_scale);
}

fn physicalMode(logical_width: i32, logical_height: i32, fractional_scale: f32) Mode {
    return .{
        .width = @intFromFloat(@round(@as(f32, @floatFromInt(@max(logical_width, 1))) * fractional_scale)),
        .height = @intFromFloat(@round(@as(f32, @floatFromInt(@max(logical_height, 1))) * fractional_scale)),
        .scale = fractional_scale,
    };
}

/// Sends output configuration to the client
fn sendOutputInfo(resource: ?*c.wl_resource, version: u32, compositor: *Compositor) void {
    const mode = advertisedMode(compositor);
    const fractional_scale = mode.scale;
    // Send geometry (position and physical size)
    // x, y, physical_width_mm, physical_height_mm, subpixel, make, model, transform
    c.wl_output_send_geometry(
        resource,
        0, // x position
        0, // y position
        340, // ~14" physical width in mm (example)
        190, // ~14" physical height in mm (example)
        c.WL_OUTPUT_SUBPIXEL_UNKNOWN,
        "Sideswipe",
        "Virtual-1",
        c.WL_OUTPUT_TRANSFORM_NORMAL,
    );

    c.wl_output_send_mode(
        resource,
        c.WL_OUTPUT_MODE_CURRENT | c.WL_OUTPUT_MODE_PREFERRED,
        mode.width,
        mode.height,
        60000,
    );

    // Send scale (version 2+)
    if (version >= 2) {
        c.wl_output_send_scale(resource, scale.legacy(fractional_scale));
    }

    // Send name (version 4+)
    if (version >= 4) {
        c.wl_output_send_name(resource, "Virtual-1");
        c.wl_output_send_description(resource, "Sideswipe virtual output");
    }

    // Send done event (version 2+)
    if (version >= 2) {
        c.wl_output_send_done(resource);
    }
}

/// Registers the wl_output global
pub fn register(compositor: *Compositor) !void {
    const global = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wl_output_interface,
        WL_OUTPUT_VERSION,
        compositor,
        outputBind,
    );
    _ = global; // Global is owned by display, no need to track
}

const testing = @import("core").testing;

test "physicalMode scales logical size to buffer pixels" {
    const mode = physicalMode(1280, 800, 1.5);
    try testing.expectEqual(@as(i32, 1920), mode.width);
    try testing.expectEqual(@as(i32, 1200), mode.height);
    try testing.expectEqual(@as(f32, 1.5), mode.scale);
}
