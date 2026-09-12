//! xdg_activation_v1 token issuance and focus requests.

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;
const Compositor = @import("../compositor.zig").Compositor;
const SurfaceData = @import("compositor.zig").SurfaceData;

const Manager = struct {
    compositor: *Compositor,
};

const Token = struct {
    compositor: *Compositor,
    committed: bool = false,
};

fn destroyRequest(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn getToken(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const manager_resource = resource orelse return;
    const manager = data(Manager, manager_resource);
    const token_resource = c.wl_resource_create(
        c.wl_resource_get_client(manager_resource),
        &c.xdg_activation_token_v1_interface,
        1,
        id,
    ) orelse return c.wl_resource_post_no_memory(manager_resource);
    const token = manager.compositor.allocator.create(Token) catch {
        c.wl_resource_destroy(token_resource);
        return c.wl_resource_post_no_memory(manager_resource);
    };
    token.* = .{ .compositor = manager.compositor };
    c.wl_resource_set_implementation(token_resource, @ptrCast(&token_impl), token, destroyToken);
}

fn activate(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    token_text: [*:0]const u8,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    const manager = data(Manager, resource orelse return);
    const prefix = "sideswipe-";
    const text = std.mem.span(token_text);
    if (!std.mem.startsWith(u8, text, prefix)) return;
    const token = std.fmt.parseInt(u64, text[prefix.len..], 10) catch return;
    const surface = data(SurfaceData, surface_resource orelse return).surface;
    manager.compositor.activateWithToken(token, surface);
}

fn ignoreSetSerial(_: ?*c.wl_client, _: ?*c.wl_resource, _: u32, _: ?*c.wl_resource) callconv(.c) void {}
fn ignoreSetAppId(_: ?*c.wl_client, _: ?*c.wl_resource, _: [*:0]const u8) callconv(.c) void {}
fn ignoreSetSurface(_: ?*c.wl_client, _: ?*c.wl_resource, _: ?*c.wl_resource) callconv(.c) void {}

fn commitToken(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const token_resource = resource orelse return;
    const token = data(Token, token_resource);
    if (token.committed) {
        c.wl_resource_post_error(
            token_resource,
            c.XDG_ACTIVATION_TOKEN_V1_ERROR_ALREADY_USED,
            "activation token already committed",
        );
        return;
    }
    const id = token.compositor.issueActivationToken() catch
        return c.wl_resource_post_no_memory(token_resource);
    token.committed = true;
    var buffer: [64]u8 = undefined;
    const token_z = std.fmt.bufPrintZ(&buffer, "sideswipe-{d}", .{id}) catch return;
    c.xdg_activation_token_v1_send_done(token_resource, token_z.ptr);
}

fn destroyManager(resource: ?*c.wl_resource) callconv(.c) void {
    const manager = data(Manager, resource orelse return);
    manager.compositor.allocator.destroy(manager);
}

fn destroyToken(resource: ?*c.wl_resource) callconv(.c) void {
    const token = data(Token, resource orelse return);
    token.compositor.allocator.destroy(token);
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&getToken),
    @ptrCast(&activate),
};

var token_impl = [_]?*const anyopaque{
    @ptrCast(&ignoreSetSerial),
    @ptrCast(&ignoreSetAppId),
    @ptrCast(&ignoreSetSurface),
    @ptrCast(&commitToken),
    @ptrCast(&destroyRequest),
};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, _: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.xdg_activation_v1_interface,
        1,
        id,
    ) orelse return c.wl_client_post_no_memory(client);
    const manager = compositor.allocator.create(Manager) catch {
        c.wl_resource_destroy(resource);
        return c.wl_client_post_no_memory(client);
    };
    manager.* = .{ .compositor = compositor };
    c.wl_resource_set_implementation(resource, @ptrCast(&manager_impl), manager, destroyManager);
}

pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.xdg_activation_v1_interface,
        1,
        compositor,
        bind,
    );
}

fn data(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}
