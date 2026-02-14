//! wl_output protocol implementation
//! Provides display information to clients (geometry, modes, scale)

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("../compositor.zig").Compositor;

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

    // Send initial output configuration
    sendOutputInfo(resource, @intCast(version));
}

fn outputResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *OutputData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.compositor.allocator.destroy(data);
}

/// Sends output configuration to the client
fn sendOutputInfo(resource: ?*c.wl_resource, version: u32) void {
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

    // Send mode (resolution and refresh rate)
    // flags, width, height, refresh (in mHz)
    c.wl_output_send_mode(
        resource,
        c.WL_OUTPUT_MODE_CURRENT | c.WL_OUTPUT_MODE_PREFERRED,
        1920, // width
        1080, // height
        60000, // 60Hz in mHz
    );

    // Send scale (version 2+)
    if (version >= 2) {
        c.wl_output_send_scale(resource, 1);
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
