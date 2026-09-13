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
/// Owns the XdgToplevel if one is created
pub const XdgSurface = struct {
    surface: *Surface,
    resource: ?*c.wl_resource = null,
    toplevel: ?*XdgToplevel = null, // Owned by this XdgSurface
    popup: ?*Popup = null,
    pending_window_geometry: ?PopupGeometry = null,
    window_geometry: ?PopupGeometry = null,
    configured: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, surface: *Surface) !*XdgSurface {
        const self = try allocator.create(XdgSurface);
        self.* = .{
            .surface = surface,
            .allocator = allocator,
        };
        surface.commit_handler = applyCommittedGeometry;
        return self;
    }

    pub fn deinit(self: *XdgSurface) void {
        clearXdgSurfaceReferences(self);
        self.destroyRoleResources();
        self.surface.compositor.unmapToplevel(self.surface);
        self.surface.map_handler = null;
        self.surface.commit_handler = null;
        self.surface.role_data = null;
        self.surface.xdg_surface_resource = null;
        self.allocator.destroy(self);
    }

    fn destroyRoleResources(self: *XdgSurface) void {
        if (self.toplevel) |toplevel| {
            if (toplevel.resource) |resource| {
                c.wl_resource_destroy(resource);
            } else {
                self.toplevel = null;
                toplevel.deinit();
            }
        }
        if (self.popup) |popup| {
            if (popup.resource) |resource| {
                c.wl_resource_destroy(resource);
            } else {
                self.popup = null;
                popup.deinit();
            }
        }
    }

    pub fn sendConfigure(self: *XdgSurface, serial: u32) void {
        if (self.resource) |resource| {
            c.xdg_surface_send_configure(resource, serial);
        }
        self.configured = true;
    }
};

fn clearXdgSurfaceReferences(removed: *XdgSurface) void {
    for (removed.surface.compositor.surfaces.items) |surface| {
        if (surface.role != .xdg_toplevel and surface.role != .xdg_popup) continue;
        const candidate: *XdgSurface = @ptrCast(@alignCast(surface.role_data orelse continue));
        if (candidate.popup) |popup| {
            if (popup.parent == removed) popup.parent = null;
        }
    }
}

fn clearToplevelReferences(removed: *XdgToplevel) void {
    for (removed.xdg_surface.surface.compositor.surfaces.items) |surface| {
        if (surface.role != .xdg_toplevel) continue;
        const candidate: *XdgSurface = @ptrCast(@alignCast(surface.role_data orelse continue));
        if (candidate.toplevel) |toplevel| {
            if (toplevel.parent == removed) toplevel.parent = null;
        }
    }
}

pub const PopupGeometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Positioner = struct {
    allocator: std.mem.Allocator,
    size: ?struct { width: i32, height: i32 } = null,
    anchor_rect: ?PopupGeometry = null,
    anchor: u32 = c.XDG_POSITIONER_ANCHOR_NONE,
    gravity: u32 = c.XDG_POSITIONER_GRAVITY_NONE,
    constraint_adjustment: u32 = c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_NONE,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    reactive: bool = false,
    parent_width: i32 = 0,
    parent_height: i32 = 0,
    parent_configure: u32 = 0,
};

pub const Popup = struct {
    allocator: std.mem.Allocator,
    xdg_surface: *XdgSurface,
    parent: ?*XdgSurface,
    resource: ?*c.wl_resource = null,
    geometry: PopupGeometry,
    grabbed: bool = false,

    fn deinit(self: *Popup) void {
        self.allocator.destroy(self);
    }

    pub fn dismiss(self: *Popup) void {
        if (self.resource) |resource| c.xdg_popup_send_popup_done(resource);
        self.grabbed = false;
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
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,
    parent: ?*XdgToplevel = null,
    is_dialog: bool = false,
    modal: bool = false,
    dialog_resource: ?*c.wl_resource = null,
    decoration_resource: ?*c.wl_resource = null,
    client_decoration_mode: ?u32 = null,
    force_ssd: bool = false,
    force_csd: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, xdg_surface: *XdgSurface) !*XdgToplevel {
        const self = try allocator.create(XdgToplevel);
        self.* = .{
            .xdg_surface = xdg_surface,
            .allocator = allocator,
        };
        xdg_surface.surface.close_context = self;
        xdg_surface.surface.close_handler = requestToplevelClose;
        return self;
    }

    pub fn deinit(self: *XdgToplevel) void {
        if (self.xdg_surface.surface.close_context == @as(*anyopaque, @ptrCast(self))) {
            self.xdg_surface.surface.close_context = null;
            self.xdg_surface.surface.close_handler = null;
        }
        self.xdg_surface.surface.compositor.unmapToplevel(self.xdg_surface.surface);
        clearToplevelReferences(self);
        if (self.title) |title| {
            self.allocator.free(title);
        }
        if (self.app_id) |app_id| {
            self.allocator.free(app_id);
        }
        self.allocator.destroy(self);
    }

    pub fn sendConfigure(self: *XdgToplevel, width: i32, height: i32) void {
        const resource = self.resource orelse return;
        var states = c.wl_array{
            .size = 0,
            .alloc = 0,
            .data = null,
        };
        defer c.wl_array_release(&states);
        appendToplevelState(&states, self.maximized, c.XDG_TOPLEVEL_STATE_MAXIMIZED);
        appendToplevelState(&states, self.fullscreen, c.XDG_TOPLEVEL_STATE_FULLSCREEN);
        c.xdg_toplevel_send_configure(resource, width, height, &states);
    }

    pub fn sendClose(self: *XdgToplevel) void {
        if (self.resource) |resource| {
            c.xdg_toplevel_send_close(resource);
        }
    }
};

fn requestToplevelClose(context: *anyopaque) void {
    const toplevel: *XdgToplevel = @ptrCast(@alignCast(context));
    toplevel.sendClose();
}

fn appendToplevelState(states: *c.wl_array, enabled: bool, value: u32) void {
    if (!enabled) return;
    const ptr = c.wl_array_add(states, @sizeOf(u32)) orelse return;
    const slot: *u32 = @ptrCast(@alignCast(ptr));
    slot.* = value;
}

/// Returns the `XdgToplevel` bound to an `xdg_toplevel` resource.
pub fn toplevelFromResource(resource: ?*c.wl_resource) ?*XdgToplevel {
    const item = resource orelse return null;
    const payload: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(item)));
    return payload.toplevel;
}

/// Returns the `XdgToplevel` stored as resource user data (dialog/decoration).
pub fn toplevelFromUserData(resource: ?*c.wl_resource) ?*XdgToplevel {
    const item = resource orelse return null;
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(item)));
}

fn handleToplevelMap(surface: *Surface, mapped: bool) void {
    const xdg_surface: *XdgSurface = @ptrCast(@alignCast(surface.role_data orelse return));
    const toplevel = xdg_surface.toplevel orelse return;
    if (!mapped) {
        surface.compositor.unmapToplevel(surface);
        return;
    }
    surface.compositor.mapToplevelWithHints(surface, toplevel, configureMappedToplevel, hintsOf(toplevel));
}

fn configureMappedToplevel(context: *anyopaque, width: i32, height: i32, serial: u32) void {
    const toplevel: *XdgToplevel = @ptrCast(@alignCast(context));
    toplevel.width = width;
    toplevel.height = height;
    if (toplevel.xdg_surface.surface.compositor.findToplevel(toplevel.xdg_surface.surface)) |entry| {
        syncDecorationOverride(toplevel, entry);
        toplevel.maximized = entry.maximized;
        toplevel.fullscreen = entry.fullscreen;
    }
    toplevel.sendConfigure(width, height);
    @import("xdg_decoration.zig").sendMode(toplevel);
    toplevel.xdg_surface.sendConfigure(serial);
}

fn hintsOf(toplevel: *XdgToplevel) Compositor.ToplevelHints {
    return .{
        .parent = if (toplevel.parent) |parent| parent.xdg_surface.surface else null,
        .is_dialog = toplevel.is_dialog,
        .modal = toplevel.modal,
        .app_id = toplevel.app_id,
        .title = toplevel.title,
        .min_size = .{ .width = toplevel.min_width, .height = toplevel.min_height },
        .max_size = .{ .width = toplevel.max_width, .height = toplevel.max_height },
        .window_geometry = if (toplevel.xdg_surface.window_geometry) |geo|
            .{ .x = geo.x, .y = geo.y, .width = geo.width, .height = geo.height }
        else
            null,
        .maximized = toplevel.maximized,
        .fullscreen = toplevel.fullscreen,
    };
}

fn requestRelayout(toplevel: *XdgToplevel) void {
    toplevel.xdg_surface.surface.compositor.refreshToplevel(
        toplevel.xdg_surface.surface,
        hintsOf(toplevel),
    );
}

fn syncDecorationOverride(toplevel: *XdgToplevel, entry: *Compositor.Toplevel) void {
    if (entry.ssd_override) |forced| {
        toplevel.force_ssd = forced;
        toplevel.force_csd = !forced;
        return;
    }
    toplevel.force_ssd = entry.ssd;
    toplevel.force_csd = false;
}

fn applyCommittedGeometry(surface: *Surface) void {
    const xdg_surface: *XdgSurface = @ptrCast(@alignCast(surface.role_data orelse return));
    if (xdg_surface.pending_window_geometry) |geometry| {
        xdg_surface.pending_window_geometry = null;
        xdg_surface.window_geometry = geometry;
        if (xdg_surface.toplevel) |toplevel| {
            if (surface.mapped) requestRelayout(toplevel);
        }
    }
    if (xdg_surface.popup != null) applyPopupGeometry(xdg_surface.popup.?);
}

// User data structures
// Note: All user data structs are allocated/freed with compositor.allocator

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
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    const data: *XdgWmBaseData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const positioner = data.compositor.allocator.create(Positioner) catch {
        c.wl_resource_post_no_memory(resource);
        return;
    };
    positioner.* = .{ .allocator = data.compositor.allocator };
    const positioner_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.xdg_positioner_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        data.compositor.allocator.destroy(positioner);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    c.wl_resource_set_implementation(positioner_resource, @ptrCast(&xdg_positioner_implementation), positioner, positionerResourceDestroy);
}

fn positionerData(resource: ?*c.wl_resource) *Positioner {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}

fn positionerResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const positioner = positionerData(resource);
    positioner.allocator.destroy(positioner);
}

fn positionerDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn positionerSetSize(_: ?*c.wl_client, resource: ?*c.wl_resource, width: i32, height: i32) callconv(.c) void {
    if (width <= 0 or height <= 0) {
        c.wl_resource_post_error(resource, c.XDG_POSITIONER_ERROR_INVALID_INPUT, "positioner size must be positive");
        return;
    }
    positionerData(resource).size = .{ .width = width, .height = height };
}

fn positionerSetAnchorRect(_: ?*c.wl_client, resource: ?*c.wl_resource, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
    if (width <= 0 or height <= 0) {
        c.wl_resource_post_error(resource, c.XDG_POSITIONER_ERROR_INVALID_INPUT, "anchor rectangle must be positive");
        return;
    }
    positionerData(resource).anchor_rect = .{ .x = x, .y = y, .width = width, .height = height };
}

fn positionerSetAnchor(_: ?*c.wl_client, resource: ?*c.wl_resource, anchor: u32) callconv(.c) void {
    positionerData(resource).anchor = anchor;
}

fn positionerSetGravity(_: ?*c.wl_client, resource: ?*c.wl_resource, gravity: u32) callconv(.c) void {
    positionerData(resource).gravity = gravity;
}

fn positionerSetConstraintAdjustment(_: ?*c.wl_client, resource: ?*c.wl_resource, adjustment: u32) callconv(.c) void {
    positionerData(resource).constraint_adjustment = adjustment;
}

fn positionerSetOffset(_: ?*c.wl_client, resource: ?*c.wl_resource, x: i32, y: i32) callconv(.c) void {
    const positioner = positionerData(resource);
    positioner.offset_x = x;
    positioner.offset_y = y;
}

fn positionerSetReactive(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    positionerData(resource).reactive = true;
}

fn positionerSetParentSize(_: ?*c.wl_client, resource: ?*c.wl_resource, width: i32, height: i32) callconv(.c) void {
    if (width <= 0 or height <= 0) {
        c.wl_resource_post_error(resource, c.XDG_POSITIONER_ERROR_INVALID_INPUT, "parent size must be positive");
        return;
    }
    const positioner = positionerData(resource);
    positioner.parent_width = width;
    positioner.parent_height = height;
}

fn positionerSetParentConfigure(_: ?*c.wl_client, resource: ?*c.wl_resource, serial: u32) callconv(.c) void {
    positionerData(resource).parent_configure = serial;
}

var xdg_positioner_implementation = [_]?*const anyopaque{
    @ptrCast(&positionerDestroy),
    @ptrCast(&positionerSetSize),
    @ptrCast(&positionerSetAnchorRect),
    @ptrCast(&positionerSetAnchor),
    @ptrCast(&positionerSetGravity),
    @ptrCast(&positionerSetConstraintAdjustment),
    @ptrCast(&positionerSetOffset),
    @ptrCast(&positionerSetReactive),
    @ptrCast(&positionerSetParentSize),
    @ptrCast(&positionerSetParentConfigure),
};

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
    if (surface.role != .none or surface.xdg_surface_resource != null) {
        c.wl_resource_post_error(resource, c.XDG_WM_BASE_ERROR_ROLE, "wl_surface already has a role or xdg_surface");
        return;
    }

    comp.logger.debug("Created XDG surface for surface {d}", .{surface.id});

    // Create xdg_surface
    const xdg_surface = XdgSurface.init(comp.allocator, surface) catch {
        c.wl_resource_post_no_memory(resource);
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
    surface.xdg_surface_resource = xdg_surface_resource;

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

    xdg_surface.resource = null;
    xdg_surface.surface.xdg_surface_resource = null;
    xdg_surface.deinit();
    allocator.destroy(data);
}

fn xdgSurfaceDestroy(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    const data: *XdgSurfaceData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    if (data.xdg_surface.toplevel != null or data.xdg_surface.popup != null) {
        c.wl_resource_post_error(
            resource,
            c.XDG_SURFACE_ERROR_DEFUNCT_ROLE_OBJECT,
            "role object must be destroyed before xdg_surface",
        );
        return;
    }
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
    xdg_surface.surface.setRole(.xdg_toplevel, xdg_surface) catch {
        c.wl_resource_post_error(resource, c.XDG_SURFACE_ERROR_ALREADY_CONSTRUCTED, "xdg surface already has a role");
        return;
    };

    xdg_surface.surface.compositor.logger.info("Created XDG toplevel window for surface {d}", .{xdg_surface.surface.id});

    // Create toplevel
    const toplevel = XdgToplevel.init(allocator, xdg_surface) catch {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    xdg_surface.toplevel = toplevel;
    xdg_surface.surface.map_handler = handleToplevelMap;

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

    const viewport = xdg_surface.surface.compositor.viewportSize();
    toplevel.width = viewport.width;
    toplevel.height = viewport.height;
    toplevel.sendConfigure(viewport.width, viewport.height);
    const serial = xdg_surface.surface.compositor.nextSerial();
    xdg_surface.sendConfigure(serial);
    xdg_surface.surface.compositor.logger.debug(
        "Configured toplevel window {d}x{d}",
        .{ viewport.width, viewport.height },
    );
}

fn xdgSurfaceGetPopup(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    parent: ?*c.wl_resource,
    positioner: ?*c.wl_resource,
) callconv(.c) void {
    const data: *XdgSurfaceData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    const parent_resource = parent orelse {
        c.wl_resource_post_error(resource, c.XDG_WM_BASE_ERROR_INVALID_POPUP_PARENT, "popup requires a parent");
        return;
    };
    const parent_data: *XdgSurfaceData = @ptrCast(@alignCast(c.wl_resource_get_user_data(parent_resource)));
    const spec = positionerData(positioner);
    if (spec.size == null or spec.anchor_rect == null) {
        c.wl_resource_post_error(positioner, c.XDG_POSITIONER_ERROR_INVALID_INPUT, "positioner is incomplete");
        return;
    }
    data.xdg_surface.surface.setRole(.xdg_popup, data.xdg_surface) catch {
        c.wl_resource_post_error(resource, c.XDG_SURFACE_ERROR_ALREADY_CONSTRUCTED, "xdg surface already has a role");
        return;
    };

    const popup = data.xdg_surface.allocator.create(Popup) catch {
        c.wl_resource_post_no_memory(resource);
        return;
    };
    popup.* = .{
        .allocator = data.xdg_surface.allocator,
        .xdg_surface = data.xdg_surface,
        .parent = parent_data.xdg_surface,
        .geometry = constrainPositioner(spec.*, .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }),
    };
    const popup_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.xdg_popup_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        popup.deinit();
        c.wl_resource_post_no_memory(resource);
        return;
    };
    popup.resource = popup_resource;
    data.xdg_surface.popup = popup;
    c.wl_resource_set_implementation(popup_resource, @ptrCast(&xdg_popup_implementation), popup, popupResourceDestroy);
    sendPopupConfigure(popup);
}

fn popupDestroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn popupGrab(_: ?*c.wl_client, resource: ?*c.wl_resource, _: ?*c.wl_resource, _: u32) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    popup.grabbed = true;
    popup.xdg_surface.surface.compositor.seat.setPopupGrab(resource.?);
}

fn popupReposition(_: ?*c.wl_client, resource: ?*c.wl_resource, positioner: ?*c.wl_resource, token: u32) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    popup.geometry = constrainPositioner(positionerData(positioner).*, .{ .x = 0, .y = 0, .width = 1920, .height = 1080 });
    sendPopupConfigure(popup);
    c.xdg_popup_send_repositioned(resource, token);
}

fn popupResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    popup.xdg_surface.surface.compositor.seat.clearPopupGrab(resource.?);
    popup.resource = null;
    if (popup.xdg_surface.popup == popup) popup.xdg_surface.popup = null;
    popup.deinit();
}

fn sendPopupConfigure(popup: *Popup) void {
    applyPopupGeometry(popup);
    const resource = popup.resource orelse return;
    const geometry = popup.geometry;
    c.xdg_popup_send_configure(resource, geometry.x, geometry.y, geometry.width, geometry.height);
    popup.xdg_surface.sendConfigure(popup.xdg_surface.surface.compositor.nextSerial());
}

fn applyPopupGeometry(popup: *Popup) void {
    const geometry = popup.geometry;
    const parent_surface = if (popup.parent) |parent| parent.surface else null;
    const parent_x = if (parent_surface) |surface|
        if (surface.scene_geometry) |parent_geometry| parent_geometry.x else 0
    else
        0;
    const parent_y = if (parent_surface) |surface|
        if (surface.scene_geometry) |parent_geometry| parent_geometry.y else 0
    else
        0;
    const content = popup.xdg_surface.window_geometry orelse geometry;
    popup.xdg_surface.surface.scene_geometry = .{
        .x = parent_x + geometry.x + content.x,
        .y = parent_y + geometry.y + content.y,
        .width = content.width,
        .height = content.height,
    };
}

var xdg_popup_implementation = [_]?*const anyopaque{
    @ptrCast(&popupDestroy),
    @ptrCast(&popupGrab),
    @ptrCast(&popupReposition),
};

fn xdgSurfaceSetWindowGeometry(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;
    if (width <= 0 or height <= 0) {
        c.wl_resource_post_error(resource, c.XDG_SURFACE_ERROR_INVALID_SIZE, "window geometry must have positive size");
        return;
    }
    const data: *XdgSurfaceData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    data.xdg_surface.pending_window_geometry = .{ .x = x, .y = y, .width = width, .height = height };
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

    const toplevel = data.toplevel;
    const allocator = toplevel.allocator;
    toplevel.resource = null;
    if (toplevel.xdg_surface.toplevel == toplevel) toplevel.xdg_surface.toplevel = null;
    toplevel.deinit();
    allocator.destroy(data);
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
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    if (parent) |parent_resource| {
        const parent_data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(parent_resource)));
        data.toplevel.parent = parent_data.toplevel;
    } else {
        data.toplevel.parent = null;
    }
    requestRelayout(data.toplevel);
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

    if (toplevel.title) |t| {
        toplevel.xdg_surface.surface.compositor.logger.info("Toplevel window title: {s}", .{t});
    }
    requestRelayout(toplevel);
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

    if (toplevel.app_id) |a| {
        toplevel.xdg_surface.surface.compositor.logger.info("Toplevel window app_id: {s}", .{a});
    }
    requestRelayout(toplevel);
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
    // W8: client show_window_menu is a no-op (no grab, no error, no menu).
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
    // W8: client move is a no-op (no grab, no error, no action).
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
    // W8: client resize is a no-op (no grab, no error, no action).
}

fn xdgToplevelSetMaxSize(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;
    if (width < 0 or height < 0) return;
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    data.toplevel.max_width = width;
    data.toplevel.max_height = height;
    requestRelayout(data.toplevel);
}

fn xdgToplevelSetMinSize(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = client;
    if (width < 0 or height < 0) return;
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    data.toplevel.min_width = width;
    data.toplevel.min_height = height;
    requestRelayout(data.toplevel);
}

fn xdgToplevelSetMaximized(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    data.toplevel.maximized = true;
    requestRelayout(data.toplevel);
}

fn xdgToplevelUnsetMaximized(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    data.toplevel.maximized = false;
    requestRelayout(data.toplevel);
}

fn xdgToplevelSetFullscreen(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    output: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = output;
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    data.toplevel.fullscreen = true;
    requestRelayout(data.toplevel);
}

fn xdgToplevelUnsetFullscreen(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    data.toplevel.fullscreen = false;
    requestRelayout(data.toplevel);
}

fn xdgToplevelSetMinimized(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    const data: *XdgToplevelData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    // W8: minimized is acknowledged with a configure that omits minimized.
    data.toplevel.sendConfigure(data.toplevel.width, data.toplevel.height);
    data.toplevel.xdg_surface.sendConfigure(data.toplevel.xdg_surface.surface.compositor.nextSerial());
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

    compositor.logger.debug("Client bound to xdg_wm_base (version {d})", .{version});

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

pub fn constrainPositioner(positioner: Positioner, bounds: PopupGeometry) PopupGeometry {
    const size = positioner.size orelse return .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const anchor_rect = positioner.anchor_rect orelse return .{ .x = 0, .y = 0, .width = size.width, .height = size.height };
    const anchor = anchorPoint(anchor_rect, positioner.anchor);
    var geometry = gravityGeometry(anchor, size.width, size.height, positioner.gravity);
    geometry.x += positioner.offset_x;
    geometry.y += positioner.offset_y;

    geometry = constrainAxis(geometry, bounds, positioner.constraint_adjustment, true, anchor.x);
    geometry = constrainAxis(geometry, bounds, positioner.constraint_adjustment, false, anchor.y);
    return geometry;
}

const Point = struct { x: i32, y: i32 };

fn anchorPoint(rect: PopupGeometry, anchor: u32) Point {
    const center_x = rect.x + @divTrunc(rect.width, 2);
    const center_y = rect.y + @divTrunc(rect.height, 2);
    const x = switch (anchor) {
        c.XDG_POSITIONER_ANCHOR_LEFT, c.XDG_POSITIONER_ANCHOR_TOP_LEFT, c.XDG_POSITIONER_ANCHOR_BOTTOM_LEFT => rect.x,
        c.XDG_POSITIONER_ANCHOR_RIGHT, c.XDG_POSITIONER_ANCHOR_TOP_RIGHT, c.XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT => rect.x + rect.width,
        else => center_x,
    };
    const y = switch (anchor) {
        c.XDG_POSITIONER_ANCHOR_TOP, c.XDG_POSITIONER_ANCHOR_TOP_LEFT, c.XDG_POSITIONER_ANCHOR_TOP_RIGHT => rect.y,
        c.XDG_POSITIONER_ANCHOR_BOTTOM, c.XDG_POSITIONER_ANCHOR_BOTTOM_LEFT, c.XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT => rect.y + rect.height,
        else => center_y,
    };
    return .{ .x = x, .y = y };
}

fn gravityGeometry(anchor: Point, width: i32, height: i32, gravity: u32) PopupGeometry {
    const x = switch (gravity) {
        c.XDG_POSITIONER_GRAVITY_RIGHT, c.XDG_POSITIONER_GRAVITY_TOP_RIGHT, c.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT => anchor.x,
        c.XDG_POSITIONER_GRAVITY_LEFT, c.XDG_POSITIONER_GRAVITY_TOP_LEFT, c.XDG_POSITIONER_GRAVITY_BOTTOM_LEFT => anchor.x - width,
        else => anchor.x - @divTrunc(width, 2),
    };
    const y = switch (gravity) {
        c.XDG_POSITIONER_GRAVITY_BOTTOM, c.XDG_POSITIONER_GRAVITY_BOTTOM_LEFT, c.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT => anchor.y,
        c.XDG_POSITIONER_GRAVITY_TOP, c.XDG_POSITIONER_GRAVITY_TOP_LEFT, c.XDG_POSITIONER_GRAVITY_TOP_RIGHT => anchor.y - height,
        else => anchor.y - @divTrunc(height, 2),
    };
    return .{ .x = x, .y = y, .width = width, .height = height };
}

fn constrainAxis(geometry: PopupGeometry, bounds: PopupGeometry, adjustment: u32, horizontal: bool, anchor: i32) PopupGeometry {
    var result = geometry;
    const slide_flag: u32 = if (horizontal) c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X else c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y;
    const flip_flag: u32 = if (horizontal) c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X else c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y;
    const resize_flag: u32 = if (horizontal) c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_X else c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_Y;
    if (!overflows(result, bounds, horizontal)) return result;
    if ((adjustment & slide_flag) != 0) {
        slideAxis(&result, bounds, horizontal);
        if (!overflows(result, bounds, horizontal)) return result;
    }
    if ((adjustment & flip_flag) != 0) {
        flipAxis(&result, anchor, horizontal);
        if (!overflows(result, bounds, horizontal)) return result;
    }
    if ((adjustment & resize_flag) != 0) resizeAxis(&result, bounds, horizontal);
    return result;
}

fn overflows(geometry: PopupGeometry, bounds: PopupGeometry, horizontal: bool) bool {
    if (horizontal) return geometry.x < bounds.x or geometry.x + geometry.width > bounds.x + bounds.width;
    return geometry.y < bounds.y or geometry.y + geometry.height > bounds.y + bounds.height;
}

fn slideAxis(geometry: *PopupGeometry, bounds: PopupGeometry, horizontal: bool) void {
    if (horizontal) {
        if (geometry.width > bounds.width) return;
        geometry.x = std.math.clamp(geometry.x, bounds.x, bounds.x + bounds.width - geometry.width);
        return;
    }
    if (geometry.height > bounds.height) return;
    geometry.y = std.math.clamp(geometry.y, bounds.y, bounds.y + bounds.height - geometry.height);
}

fn flipAxis(geometry: *PopupGeometry, anchor: i32, horizontal: bool) void {
    if (horizontal) {
        geometry.x = anchor - (geometry.x + geometry.width - anchor);
        return;
    }
    geometry.y = anchor - (geometry.y + geometry.height - anchor);
}

fn resizeAxis(geometry: *PopupGeometry, bounds: PopupGeometry, horizontal: bool) void {
    if (horizontal) {
        const left = @max(geometry.x, bounds.x);
        const right = @min(geometry.x + geometry.width, bounds.x + bounds.width);
        geometry.x = left;
        geometry.width = @max(1, right - left);
        return;
    }
    const top = @max(geometry.y, bounds.y);
    const bottom = @min(geometry.y + geometry.height, bounds.y + bounds.height);
    geometry.y = top;
    geometry.height = @max(1, bottom - top);
}

const testing = @import("core").testing;

test "positioner applies anchor gravity offset and slide constraints" {
    const positioner = Positioner{
        .allocator = testing.allocator,
        .size = .{ .width = 200, .height = 100 },
        .anchor_rect = .{ .x = 950, .y = 700, .width = 50, .height = 50 },
        .anchor = c.XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT,
        .gravity = c.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT,
        .constraint_adjustment = c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y,
    };
    const geometry = constrainPositioner(positioner, .{ .x = 0, .y = 0, .width = 1000, .height = 800 });
    try testing.expectEqual(PopupGeometry{ .x = 800, .y = 700, .width = 200, .height = 100 }, geometry);
}

test "positioner resizes oversized popup to bounds" {
    const positioner = Positioner{
        .allocator = testing.allocator,
        .size = .{ .width = 1200, .height = 900 },
        .anchor_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .anchor = c.XDG_POSITIONER_ANCHOR_TOP_LEFT,
        .gravity = c.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT,
        .constraint_adjustment = c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_X | c.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_Y,
    };
    const geometry = constrainPositioner(positioner, .{ .x = 0, .y = 0, .width = 1000, .height = 800 });
    try testing.expectEqual(@as(i32, 1000), geometry.width);
    try testing.expectEqual(@as(i32, 800), geometry.height);
}

test "destroyed toplevel resource clears owner and parent references" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const parent_surface = try fixture.compositor.createSurface();
    const child_surface = try fixture.compositor.createSurface();
    const parent_xdg = try XdgSurface.init(testing.allocator, parent_surface);
    const child_xdg = try XdgSurface.init(testing.allocator, child_surface);
    try parent_surface.setRole(.xdg_toplevel, parent_xdg);
    try child_surface.setRole(.xdg_toplevel, child_xdg);
    const parent_toplevel = try XdgToplevel.init(testing.allocator, parent_xdg);
    const child_toplevel = try XdgToplevel.init(testing.allocator, child_xdg);
    parent_xdg.toplevel = parent_toplevel;
    child_xdg.toplevel = child_toplevel;
    child_toplevel.parent = parent_toplevel;

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    defer @import("core").unix.close(fds[1]);
    const client = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse
        return error.ClientCreateFailed;
    defer c.wl_client_destroy(client);
    const resource = c.wl_resource_create(client, &c.xdg_toplevel_interface, 1, 1) orelse
        return error.ResourceCreateFailed;
    const data = try testing.allocator.create(XdgToplevelData);
    data.* = .{ .toplevel = parent_toplevel };
    parent_toplevel.resource = resource;
    c.wl_resource_set_implementation(
        resource,
        @ptrCast(&xdg_toplevel_implementation),
        data,
        xdgToplevelResourceDestroy,
    );

    c.wl_resource_destroy(resource);

    try testing.expectNull(parent_xdg.toplevel);
    try testing.expectNull(child_toplevel.parent);
    child_xdg.deinit();
    parent_xdg.deinit();
}

test "window geometry is honored for popup scene size" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const parent_surface = try fixture.compositor.createSurface();
    const popup_surface = try fixture.compositor.createSurface();
    const parent_xdg = try XdgSurface.init(testing.allocator, parent_surface);
    const popup_xdg = try XdgSurface.init(testing.allocator, popup_surface);
    try parent_surface.setRole(.xdg_toplevel, parent_xdg);
    try popup_surface.setRole(.xdg_popup, popup_xdg);
    parent_surface.scene_geometry = .{ .x = 100, .y = 50, .width = 400, .height = 300 };
    popup_xdg.window_geometry = .{ .x = 2, .y = 4, .width = 80, .height = 60 };
    const popup = try testing.allocator.create(Popup);
    popup.* = .{
        .allocator = testing.allocator,
        .xdg_surface = popup_xdg,
        .parent = parent_xdg,
        .geometry = .{ .x = 10, .y = 20, .width = 90, .height = 70 },
    };
    popup_xdg.popup = popup;
    sendPopupConfigure(popup);
    try testing.expectEqual(@as(i32, 112), popup_surface.scene_geometry.?.x);
    try testing.expectEqual(@as(i32, 74), popup_surface.scene_geometry.?.y);
    try testing.expectEqual(@as(i32, 80), popup_surface.scene_geometry.?.width);
    try testing.expectEqual(@as(i32, 60), popup_surface.scene_geometry.?.height);
    popup.resource = null;
    popup_xdg.popup = null;
    popup.deinit();
    popup_xdg.deinit();
    parent_xdg.deinit();
}

test "XdgSurface - window geometry applies on commit" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    const xdg_surface = try XdgSurface.init(testing.allocator, surface);
    try surface.setRole(.xdg_toplevel, xdg_surface);
    xdg_surface.pending_window_geometry = .{ .x = 1, .y = 2, .width = 80, .height = 60 };
    applyCommittedGeometry(surface);
    try testing.expectEqual(@as(i32, 80), xdg_surface.window_geometry.?.width);
    try testing.expectEqual(@as(i32, 60), xdg_surface.window_geometry.?.height);
    try testing.expectEqual(@as(?PopupGeometry, null), xdg_surface.pending_window_geometry);
    xdg_surface.deinit();
}

test "XdgToplevel - sendClose emits the protocol close event" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    const xdg_surface = try XdgSurface.init(testing.allocator, surface);
    try surface.setRole(.xdg_toplevel, xdg_surface);
    const toplevel = try XdgToplevel.init(testing.allocator, xdg_surface);
    xdg_surface.toplevel = toplevel;

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    defer @import("core").unix.close(fds[1]);
    const client = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse
        return error.ClientCreateFailed;
    defer c.wl_client_destroy(client);
    const resource = c.wl_resource_create(client, &c.xdg_toplevel_interface, 1, 1) orelse
        return error.ResourceCreateFailed;
    toplevel.resource = resource;

    surface.requestClose();
    c.wl_client_flush(client);
    var message: [8]u8 = undefined;
    const read_len = try std.posix.read(fds[1], &message);
    try testing.expectEqual(@as(usize, 8), read_len);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, message[0..4], .little));
    const header = std.mem.readInt(u32, message[4..8], .little);
    try testing.expectEqual(@as(u16, 1), @as(u16, @truncate(header)));

    toplevel.resource = null;
    c.wl_resource_destroy(resource);
    xdg_surface.toplevel = null;
    toplevel.deinit();
    xdg_surface.deinit();
}
