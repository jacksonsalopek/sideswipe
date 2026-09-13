//! xdg_decoration_unstable_v1 — server-side decoration configure (W4, W7).

const wayland = @import("wayland");
const c = wayland.c;
const Compositor = @import("../compositor.zig").Compositor;
const xdg_shell = @import("xdg_shell.zig");

const VERSION = 2;

pub const Mode = enum(u32) {
    client_side = c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE,
    server_side = c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
};

const Manager = struct {
    compositor: *Compositor,
};

fn destroyRequest(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn getToplevelDecoration(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    toplevel_resource: ?*c.wl_resource,
) callconv(.c) void {
    const manager_resource = resource orelse return;
    const toplevel = xdg_shell.toplevelFromResource(toplevel_resource) orelse {
        c.wl_resource_post_error(
            manager_resource,
            c.ZXDG_TOPLEVEL_DECORATION_V1_ERROR_ORPHANED,
            "decoration requires an xdg_toplevel",
        );
        return;
    };
    if (toplevel.decoration_resource != null) {
        c.wl_resource_post_error(
            manager_resource,
            c.ZXDG_TOPLEVEL_DECORATION_V1_ERROR_ALREADY_CONSTRUCTED,
            "xdg_toplevel already has a decoration object",
        );
        return;
    }

    const decoration = c.wl_resource_create(
        c.wl_resource_get_client(manager_resource),
        &c.zxdg_toplevel_decoration_v1_interface,
        VERSION,
        id,
    ) orelse return c.wl_resource_post_no_memory(manager_resource);

    toplevel.decoration_resource = decoration;
    c.wl_resource_set_implementation(
        decoration,
        @ptrCast(&decoration_impl),
        toplevel,
        destroyDecoration,
    );
    sendMode(toplevel);
    toplevel.xdg_surface.sendConfigure(toplevel.xdg_surface.surface.compositor.nextSerial());
}

fn setMode(_: ?*c.wl_client, resource: ?*c.wl_resource, mode: u32) callconv(.c) void {
    const decoration = resource orelse return;
    if (mode != @intFromEnum(Mode.client_side) and mode != @intFromEnum(Mode.server_side)) {
        c.wl_resource_post_error(
            decoration,
            c.ZXDG_TOPLEVEL_DECORATION_V1_ERROR_INVALID_MODE,
            "invalid decoration mode",
        );
        return;
    }
    const toplevel = xdg_shell.toplevelFromUserData(decoration) orelse return;
    toplevel.client_decoration_mode = mode;
    sendMode(toplevel);
    toplevel.xdg_surface.sendConfigure(toplevel.xdg_surface.surface.compositor.nextSerial());
}

fn unsetMode(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const toplevel = xdg_shell.toplevelFromUserData(resource) orelse return;
    toplevel.client_decoration_mode = null;
    sendMode(toplevel);
    toplevel.xdg_surface.sendConfigure(toplevel.xdg_surface.surface.compositor.nextSerial());
}

/// Sends the compositor-chosen decoration mode. Sheets always get server-side.
pub fn sendMode(toplevel: *xdg_shell.XdgToplevel) void {
    const resource = toplevel.decoration_resource orelse return;
    const mode = effectiveMode(toplevel);
    c.zxdg_toplevel_decoration_v1_send_configure(resource, mode);
}

pub fn effectiveMode(toplevel: *const xdg_shell.XdgToplevel) u32 {
    if (toplevel.force_ssd) return @intFromEnum(Mode.server_side);
    if (toplevel.force_csd) return @intFromEnum(Mode.client_side);
    return toplevel.client_decoration_mode orelse @intFromEnum(Mode.server_side);
}

fn destroyManager(resource: ?*c.wl_resource) callconv(.c) void {
    const manager = data(Manager, resource orelse return);
    manager.compositor.allocator.destroy(manager);
}

fn destroyDecoration(resource: ?*c.wl_resource) callconv(.c) void {
    const toplevel = xdg_shell.toplevelFromUserData(resource) orelse return;
    if (toplevel.decoration_resource == resource) toplevel.decoration_resource = null;
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&getToplevelDecoration),
};

var decoration_impl = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&setMode),
    @ptrCast(&unsetMode),
};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, _: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.zxdg_decoration_manager_v1_interface,
        VERSION,
        id,
    ) orelse return c.wl_client_post_no_memory(client);
    const manager = compositor.allocator.create(Manager) catch {
        c.wl_resource_destroy(resource);
        return c.wl_client_post_no_memory(client);
    };
    manager.* = .{ .compositor = compositor };
    c.wl_resource_set_implementation(resource, @ptrCast(&manager_impl), manager, destroyManager);
}

/// Registers the `zxdg_decoration_manager_v1` global.
pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.zxdg_decoration_manager_v1_interface,
        VERSION,
        compositor,
        bind,
    );
}

fn data(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}

const testing = @import("core").testing;

test "decoration sheets force server-side mode" {
    const fake = xdg_shell.XdgToplevel{
        .xdg_surface = undefined,
        .allocator = testing.allocator,
        .force_ssd = true,
        .client_decoration_mode = @intFromEnum(Mode.client_side),
    };
    try testing.expectEqual(@intFromEnum(Mode.server_side), effectiveMode(&fake));
}

test "decoration W7 ssd false forces client-side mode" {
    const fake = xdg_shell.XdgToplevel{
        .xdg_surface = undefined,
        .allocator = testing.allocator,
        .force_csd = true,
        .client_decoration_mode = @intFromEnum(Mode.server_side),
    };
    try testing.expectEqual(@intFromEnum(Mode.client_side), effectiveMode(&fake));
}
