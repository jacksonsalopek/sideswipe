//! XDG shell protocol implementation
//! Handles desktop windows (xdg_toplevel), popups, and positioning

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const wl_compositor_protocol = @import("compositor.zig");

// XDG shell version we support
const XDG_WM_BASE_VERSION = 5;

/// XDG surface state
pub const XdgSurface = struct {
    surface: *Surface,
    resource: ?*c.wl_resource = null,
    toplevel: ?*XdgToplevel = null,
    configured: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, surface: *Surface) !*XdgSurface {
        const self = try allocator.create(XdgSurface);
        self.* = .{
            .surface = surface,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *XdgSurface) void {
        if (self.toplevel) |toplevel| {
            toplevel.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn sendConfigure(self: *XdgSurface, serial: u32) void {
        if (self.resource) |resource| {
            c.xdg_surface_send_configure(resource, serial);
        }
        self.configured = true;
    }
};

/// XDG toplevel (desktop window) state
pub const XdgToplevel = struct {
    xdg_surface: *XdgSurface,
    resource: ?*c.wl_resource = null,
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, xdg_surface: *XdgSurface) !*XdgToplevel {
        const self = try allocator.create(XdgToplevel);
        self.* = .{
            .xdg_surface = xdg_surface,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *XdgToplevel) void {
        if (self.title) |title| {
            self.allocator.free(title);
        }
        if (self.app_id) |app_id| {
            self.allocator.free(app_id);
        }
        self.allocator.destroy(self);
    }

    pub fn sendConfigure(self: *XdgToplevel, width: i32, height: i32) void {
        if (self.resource) |resource| {
            // Create state array (empty for now)
            var state = c.wl_array{
                .size = 0,
                .alloc = 0,
                .data = null,
            };
            c.xdg_toplevel_send_configure(resource, width, height, &state);
        }
    }

    pub fn sendClose(self: *XdgToplevel) void {
        if (self.resource) |resource| {
            c.xdg_toplevel_send_close(resource);
        }
    }
};

// User data structures

const XdgWmBaseData = struct {
    compositor: *Compositor,
};

const XdgSurfaceData = struct {
    xdg_surface: *XdgSurface,
};

const XdgToplevelData = struct {
    toplevel: *XdgToplevel,
};

// xdg_wm_base handlers

fn xdgWmBaseDestroy(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn xdgWmBaseCreatePositioner(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = id;
    // Positioner stub - not needed for basic toplevel windows
}

fn xdgWmBaseGetXdgSurface(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;

    const data: *XdgWmBaseData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    // Get surface from wl_surface resource
    const surface_data: *wl_compositor_protocol.SurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(surface_resource),
    ));
    const surface = surface_data.surface;

    const comp = data.compositor;

    // Create xdg_surface
    const xdg_surface = XdgSurface.init(comp.allocator, surface) catch {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Set surface role
    surface.setRole(.xdg_toplevel, xdg_surface) catch {
        xdg_surface.deinit();
        c.wl_resource_post_error(
            resource,
            c.XDG_WM_BASE_ERROR_ROLE,
            "surface already has a role",
        );
        return;
    };

    // Create xdg_surface resource
    const xdg_surface_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.xdg_surface_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        xdg_surface.deinit();
        c.wl_resource_post_no_memory(resource);
        return;
    };

    xdg_surface.resource = xdg_surface_resource;

    const xdg_surface_data = comp.allocator.create(XdgSurfaceData) catch {
        xdg_surface.deinit();
        c.wl_resource_destroy(xdg_surface_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    xdg_surface_data.* = .{ .xdg_surface = xdg_surface };

    c.wl_resource_set_implementation(
        xdg_surface_resource,
        @ptrCast(&xdg_surface_implementation),
        xdg_surface_data,
        xdgSurfaceResourceDestroy,
    );
}

fn xdgWmBasePong(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    serial: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = serial;
    // Pong handling (ping/pong for detecting unresponsive clients)
}

var xdg_wm_base_implementation = [_]?*const anyopaque{
    @ptrCast(&xdgWmBaseDestroy),
    @ptrCast(&xdgWmBaseCreatePositioner),
    @ptrCast(&xdgWmBaseGetXdgSurface),
    @ptrCast(&xdgWmBasePong),
};

// xdg_surface handlers

fn xdgSurfaceResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *XdgSurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const xdg_surface = data.xdg_surface;
    const allocator = xdg_surface.allocator;

    xdg_surface.deinit();
    allocator.destroy(data);
}

fn xdgSurfaceDestroy(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn xdgSurfaceGetToplevel(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;

    const data: *XdgSurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const xdg_surface = data.xdg_surface;
    const allocator = xdg_surface.allocator;

    // Create toplevel
    const toplevel = XdgToplevel.init(allocator, xdg_surface) catch {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    xdg_surface.toplevel = toplevel;

    // Create toplevel resource
    const toplevel_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.xdg_toplevel_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        toplevel.deinit();
        xdg_surface.toplevel = null;
        c.wl_resource_post_no_memory(resource);
        return;
    };

    toplevel.resource = toplevel_resource;

    const toplevel_data = allocator.create(XdgToplevelData) catch {
        toplevel.deinit();
        xdg_surface.toplevel = null;
        c.wl_resource_destroy(toplevel_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    toplevel_data.* = .{ .toplevel = toplevel };

    c.wl_resource_set_implementation(
        toplevel_resource,
        @ptrCast(&xdg_toplevel_implementation),
        toplevel_data,
        xdgToplevelResourceDestroy,
    );

    // Send initial configure
    toplevel.sendConfigure(0, 0);
    const serial = xdg_surface.surface.compositor.nextSerial();
    xdg_surface.sendConfigure(serial);
}

fn xdgSurfaceGetPopup(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    parent: ?*c.wl_resource,
    positioner: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = id;
    _ = parent;
    _ = positioner;
    // Popup stub - not implemented yet
}

fn xdgSurfaceSetWindowGeometry(
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
    // Window geometry stub
}

fn xdgSurfaceAckConfigure(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    serial: u32,
) callconv(.c) void {
    _ = client;
    _ = serial;

    const data: *XdgSurfaceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    data.xdg_surface.configured = true;
}

var xdg_surface_implementation = [_]?*const anyopaque{
    @ptrCast(&xdgSurfaceDestroy),
    @ptrCast(&xdgSurfaceGetToplevel),
    @ptrCast(&xdgSurfaceGetPopup),
    @ptrCast(&xdgSurfaceSetWindowGeometry),
    @ptrCast(&xdgSurfaceAckConfigure),
};

// xdg_toplevel handlers

fn xdgToplevelResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *XdgToplevelData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const allocator = data.toplevel.allocator;
    allocator.destroy(data);
    // Note: XdgToplevel is owned by XdgSurface, don't destroy it here
}

fn xdgToplevelDestroy(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn xdgToplevelSetParent(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    parent: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = parent;
    // Parent relationship stub
}

fn xdgToplevelSetTitle(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    title: [*:0]const u8,
) callconv(.c) void {
    _ = client;

    const data: *XdgToplevelData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const toplevel = data.toplevel;

    // Free old title
    if (toplevel.title) |old_title| {
        toplevel.allocator.free(old_title);
    }

    // Copy new title
    const title_slice = std.mem.span(title);
    toplevel.title = toplevel.allocator.dupe(u8, title_slice) catch null;
}

fn xdgToplevelSetAppId(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    app_id: [*:0]const u8,
) callconv(.c) void {
    _ = client;

    const data: *XdgToplevelData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const toplevel = data.toplevel;

    // Free old app_id
    if (toplevel.app_id) |old_app_id| {
        toplevel.allocator.free(old_app_id);
    }

    // Copy new app_id
    const app_id_slice = std.mem.span(app_id);
    toplevel.app_id = toplevel.allocator.dupe(u8, app_id_slice) catch null;
}

fn xdgToplevelShowWindowMenu(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    seat: ?*c.wl_resource,
    serial: u32,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = seat;
    _ = serial;
    _ = x;
    _ = y;
    // Window menu stub
}

fn xdgToplevelMove(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    seat: ?*c.wl_resource,
    serial: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = seat;
    _ = serial;
    // Move stub
}

fn xdgToplevelResize(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    seat: ?*c.wl_resource,
    serial: u32,
    edges: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = seat;
    _ = serial;
    _ = edges;
    // Resize stub
}

fn xdgToplevelSetMaxSize(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = width;
    _ = height;
    // Max size stub
}

fn xdgToplevelSetMinSize(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = width;
    _ = height;
    // Min size stub
}

fn xdgToplevelSetMaximized(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    // Maximize stub
}

fn xdgToplevelUnsetMaximized(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    // Unmaximize stub
}

fn xdgToplevelSetFullscreen(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    output: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = output;
    // Fullscreen stub
}

fn xdgToplevelUnsetFullscreen(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    // Unfullscreen stub
}

fn xdgToplevelSetMinimized(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = resource;
    // Minimize stub
}

var xdg_toplevel_implementation = [_]?*const anyopaque{
    @ptrCast(&xdgToplevelDestroy),
    @ptrCast(&xdgToplevelSetParent),
    @ptrCast(&xdgToplevelSetTitle),
    @ptrCast(&xdgToplevelSetAppId),
    @ptrCast(&xdgToplevelShowWindowMenu),
    @ptrCast(&xdgToplevelMove),
    @ptrCast(&xdgToplevelResize),
    @ptrCast(&xdgToplevelSetMaxSize),
    @ptrCast(&xdgToplevelSetMinSize),
    @ptrCast(&xdgToplevelSetMaximized),
    @ptrCast(&xdgToplevelUnsetMaximized),
    @ptrCast(&xdgToplevelSetFullscreen),
    @ptrCast(&xdgToplevelUnsetFullscreen),
    @ptrCast(&xdgToplevelSetMinimized),
};

// Global bind handler

fn xdgWmBaseBind(
    client: ?*c.wl_client,
    data: ?*anyopaque,
    version: u32,
    id: u32,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(data));

    const resource = c.wl_resource_create(
        client,
        &c.xdg_wm_base_interface,
        @intCast(@min(version, XDG_WM_BASE_VERSION)),
        id,
    ) orelse {
        c.wl_client_post_no_memory(client);
        return;
    };

    const wm_base_data = compositor.allocator.create(XdgWmBaseData) catch {
        c.wl_resource_destroy(resource);
        c.wl_client_post_no_memory(client);
        return;
    };
    wm_base_data.* = .{ .compositor = compositor };

    c.wl_resource_set_implementation(
        resource,
        @ptrCast(&xdg_wm_base_implementation),
        wm_base_data,
        xdgWmBaseResourceDestroy,
    );
}

fn xdgWmBaseResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *XdgWmBaseData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.compositor.allocator.destroy(data);
}

/// Registers the xdg_wm_base global
pub fn register(compositor: *Compositor) !void {
    const global = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.xdg_wm_base_interface,
        XDG_WM_BASE_VERSION,
        compositor,
        xdgWmBaseBind,
    );
    _ = global; // Global is owned by display
}
