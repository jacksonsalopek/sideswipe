//! xdg_dialog_v1 — marks an xdg_toplevel as a dialog (W4).

const wayland = @import("wayland");
const c = wayland.c;
const Compositor = @import("../compositor.zig").Compositor;
const xdg_shell = @import("xdg_shell.zig");

const VERSION = 1;

const Manager = struct {
    compositor: *Compositor,
};

fn destroyRequest(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn getDialog(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    toplevel_resource: ?*c.wl_resource,
) callconv(.c) void {
    const manager_resource = resource orelse return;
    const manager = data(Manager, manager_resource);
    const toplevel = xdg_shell.toplevelFromResource(toplevel_resource) orelse {
        c.wl_resource_post_error(
            manager_resource,
            c.XDG_WM_DIALOG_V1_ERROR_ALREADY_USED,
            "xdg_dialog_v1 requires an xdg_toplevel",
        );
        return;
    };
    if (toplevel.dialog_resource != null) {
        c.wl_resource_post_error(
            manager_resource,
            c.XDG_WM_DIALOG_V1_ERROR_ALREADY_USED,
            "xdg_toplevel already has an xdg_dialog_v1",
        );
        return;
    }

    const dialog_resource = c.wl_resource_create(
        c.wl_resource_get_client(manager_resource),
        &c.xdg_dialog_v1_interface,
        VERSION,
        id,
    ) orelse return c.wl_resource_post_no_memory(manager_resource);

    toplevel.dialog_resource = dialog_resource;
    toplevel.is_dialog = true;
    c.wl_resource_set_implementation(dialog_resource, @ptrCast(&dialog_impl), toplevel, destroyDialog);
    manager.compositor.setToplevelDialog(toplevel.xdg_surface.surface, true, toplevel.modal);
}

fn setModal(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const toplevel = xdg_shell.toplevelFromUserData(resource) orelse return;
    toplevel.modal = true;
    toplevel.xdg_surface.surface.compositor.setToplevelDialog(
        toplevel.xdg_surface.surface,
        true,
        true,
    );
}

fn unsetModal(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const toplevel = xdg_shell.toplevelFromUserData(resource) orelse return;
    toplevel.modal = false;
    toplevel.xdg_surface.surface.compositor.setToplevelDialog(
        toplevel.xdg_surface.surface,
        true,
        false,
    );
}

fn destroyManager(resource: ?*c.wl_resource) callconv(.c) void {
    const manager = data(Manager, resource orelse return);
    manager.compositor.allocator.destroy(manager);
}

fn destroyDialog(resource: ?*c.wl_resource) callconv(.c) void {
    const toplevel = xdg_shell.toplevelFromUserData(resource) orelse return;
    if (toplevel.dialog_resource == resource) {
        toplevel.dialog_resource = null;
        toplevel.is_dialog = false;
        toplevel.modal = false;
        toplevel.xdg_surface.surface.compositor.setToplevelDialog(
            toplevel.xdg_surface.surface,
            false,
            false,
        );
    }
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&getDialog),
};

var dialog_impl = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&setModal),
    @ptrCast(&unsetModal),
};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, _: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.xdg_wm_dialog_v1_interface,
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

/// Registers the `xdg_wm_dialog_v1` global.
pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.xdg_wm_dialog_v1_interface,
        VERSION,
        compositor,
        bind,
    );
}

fn data(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}
