//! wl_subcompositor and wl_subsurface baseline implementation.

const wayland = @import("wayland");
const c = wayland.c;
const std = @import("std");
const testing = @import("core").testing;
const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const SurfaceData = @import("compositor.zig").SurfaceData;

const RoleData = struct {
    allocator: std.mem.Allocator,
    surface: *Surface,
    resource: *c.wl_resource,
};

const Manager = struct {
    compositor: *Compositor,
};

fn destroyRequest(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn getSubsurface(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    surface_resource: ?*c.wl_resource,
    parent_resource: ?*c.wl_resource,
) callconv(.c) void {
    const manager_resource = resource orelse return;
    const manager = data(Manager, manager_resource);
    const surface = data(SurfaceData, surface_resource orelse return).surface;
    const parent = data(SurfaceData, parent_resource orelse return).surface;
    if (!validateParent(manager_resource, surface, parent)) return;
    if (surface.role != .none and surface.role != .subsurface or
        surface.subsurface_resource != null or
        surface.role_data != null)
    {
        c.wl_resource_post_error(
            manager_resource,
            c.WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE,
            "surface has an incompatible role or live subsurface object",
        );
        return;
    }
    const created = createRole(manager, manager_resource, id, surface) orelse return;
    if (!assignRole(manager, manager_resource, created, surface, parent)) return;
    installRole(created);
}

const CreatedRole = struct {
    resource: *c.wl_resource,
    data: *RoleData,
};

fn createRole(manager: *Manager, manager_resource: *c.wl_resource, id: u32, surface: *Surface) ?CreatedRole {
    const subsurface_resource = c.wl_resource_create(
        c.wl_resource_get_client(manager_resource),
        &c.wl_subsurface_interface,
        1,
        id,
    ) orelse {
        c.wl_resource_post_no_memory(manager_resource);
        return null;
    };
    const role_data = manager.compositor.allocator.create(RoleData) catch {
        c.wl_resource_destroy(subsurface_resource);
        c.wl_resource_post_no_memory(manager_resource);
        return null;
    };
    role_data.* = .{
        .allocator = manager.compositor.allocator,
        .surface = surface,
        .resource = subsurface_resource,
    };
    return .{ .resource = subsurface_resource, .data = role_data };
}

fn assignRole(manager: *Manager, manager_resource: *c.wl_resource, created: CreatedRole, surface: *Surface, parent: *Surface) bool {
    assignAssociation(surface, parent, created.data) catch |err| {
        destroyCreatedRole(manager, created);
        switch (err) {
            error.OutOfMemory => c.wl_resource_post_no_memory(manager_resource),
            error.RoleAssigned => c.wl_resource_post_error(
                manager_resource,
                c.WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE,
                "surface already has a role",
            ),
        }
        return false;
    };
    return true;
}

fn assignAssociation(surface: *Surface, parent: *Surface, role_data: ?*anyopaque) !void {
    try parent.children.ensureUnusedCapacity(parent.allocator, 1);
    try surface.setRole(.subsurface, role_data);
    parent.addChildAssumeCapacity(surface);
}

fn destroyCreatedRole(manager: *Manager, created: CreatedRole) void {
    manager.compositor.allocator.destroy(created.data);
    c.wl_resource_destroy(created.resource);
}

fn installRole(created: CreatedRole) void {
    c.wl_resource_set_implementation(
        created.resource,
        @ptrCast(&subsurface_impl),
        created.data,
        destroySubsurface,
    );
    created.data.surface.subsurface_resource = created.resource;
}

fn validateParent(resource: *c.wl_resource, surface: *Surface, parent: *Surface) bool {
    if (isValidParent(surface, parent)) return true;
    c.wl_resource_post_error(
        resource,
        c.WL_SUBCOMPOSITOR_ERROR_BAD_PARENT,
        "surface cannot be its own ancestor",
    );
    return false;
}

fn isValidParent(surface: *Surface, parent: *Surface) bool {
    return surface != parent and !isDescendant(parent, surface);
}

fn setPosition(_: ?*c.wl_client, resource: ?*c.wl_resource, x: i32, y: i32) callconv(.c) void {
    const subsurface = data(RoleData, resource orelse return);
    subsurface.surface.setSubsurfacePosition(x, y);
}

fn placeAbove(_: ?*c.wl_client, resource: ?*c.wl_resource, sibling: ?*c.wl_resource) callconv(.c) void {
    const subsurface_resource = resource orelse return;
    const subsurface = data(RoleData, subsurface_resource);
    const sibling_surface = data(SurfaceData, sibling orelse return).surface;
    if (!validSibling(subsurface.surface, sibling_surface)) {
        c.wl_resource_post_error(subsurface_resource, c.WL_SUBSURFACE_ERROR_BAD_SURFACE, "surface is not a sibling or parent");
        return;
    }
    subsurface.surface.setSubsurfaceStack(sibling_surface, true) catch
        c.wl_resource_post_no_memory(subsurface_resource);
}

fn placeBelow(_: ?*c.wl_client, resource: ?*c.wl_resource, sibling: ?*c.wl_resource) callconv(.c) void {
    const subsurface_resource = resource orelse return;
    const subsurface = data(RoleData, subsurface_resource);
    const sibling_surface = data(SurfaceData, sibling orelse return).surface;
    if (!validSibling(subsurface.surface, sibling_surface)) {
        c.wl_resource_post_error(subsurface_resource, c.WL_SUBSURFACE_ERROR_BAD_SURFACE, "surface is not a sibling or parent");
        return;
    }
    subsurface.surface.setSubsurfaceStack(sibling_surface, false) catch
        c.wl_resource_post_no_memory(subsurface_resource);
}

fn setSync(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    data(RoleData, resource orelse return).surface.subsurface_synchronized = true;
}

fn setDesync(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    data(RoleData, resource orelse return).surface.desynchronize();
}

fn destroySubsurface(resource: ?*c.wl_resource) callconv(.c) void {
    const subsurface = data(RoleData, resource orelse return);
    subsurface.surface.subsurface_resource = null;
    subsurface.surface.destroySubsurfaceAssociation();
    subsurface.surface.compositor.scheduleFrame();
    subsurface.allocator.destroy(subsurface);
}

fn destroyManager(resource: ?*c.wl_resource) callconv(.c) void {
    const manager = data(Manager, resource orelse return);
    manager.compositor.allocator.destroy(manager);
}

var manager_impl = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&getSubsurface),
};

var subsurface_impl = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&setPosition),
    @ptrCast(&placeAbove),
    @ptrCast(&placeBelow),
    @ptrCast(&setSync),
    @ptrCast(&setDesync),
};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, _: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(client, &c.wl_subcompositor_interface, 1, id) orelse
        return c.wl_client_post_no_memory(client);
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
        &c.wl_subcompositor_interface,
        1,
        compositor,
        bind,
    );
}

fn data(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}

fn validSibling(surface: *Surface, sibling: *Surface) bool {
    const parent = surface.parent orelse return false;
    if (surface == sibling) return false;
    return sibling == parent or sibling.parent == parent;
}

fn isDescendant(candidate: *Surface, ancestor: *Surface) bool {
    var current: ?*Surface = candidate;
    while (current) |surface| : (current = surface.parent) {
        if (surface == ancestor) return true;
    }
    return false;
}

test "subsurface sibling validation accepts parent and siblings only" {
    var parent: Surface = undefined;
    var first: Surface = undefined;
    var second: Surface = undefined;
    var outsider: Surface = undefined;
    parent.parent = null;
    first.parent = &parent;
    second.parent = &parent;
    outsider.parent = null;

    try testing.expect(validSibling(&first, &parent));
    try testing.expect(validSibling(&first, &second));
    try testing.expectFalse(validSibling(&first, &first));
    try testing.expectFalse(validSibling(&first, &outsider));
}

test "subsurface cycle detection follows nested ancestors" {
    var root: Surface = undefined;
    var child: Surface = undefined;
    var grandchild: Surface = undefined;
    root.parent = null;
    child.parent = &root;
    grandchild.parent = &child;

    try testing.expect(isDescendant(&grandchild, &root));
    try testing.expect(isDescendant(&child, &root));
    try testing.expectFalse(isDescendant(&root, &child));
}

test "subsurface parent validation rejects self and descendants" {
    var root: Surface = undefined;
    var child: Surface = undefined;
    var grandchild: Surface = undefined;
    root.parent = null;
    child.parent = &root;
    grandchild.parent = &child;

    try testing.expectFalse(isValidParent(&root, &root));
    try testing.expectFalse(isValidParent(&root, &grandchild));
    try testing.expect(isValidParent(&grandchild, &root));
    try testing.expectEqual(@as(u32, 1), c.WL_SUBCOMPOSITOR_ERROR_BAD_PARENT);
}

test "subsurface association allocation failure preserves permanent role state" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var parent: Surface = undefined;
    var child: Surface = undefined;
    parent.allocator = failing.allocator();
    parent.children = std.ArrayList(*Surface).empty;
    parent.pending_children = std.ArrayList(*Surface).empty;
    parent.pending_children_active = false;
    child.role = .none;
    child.role_data = null;

    try testing.expectError(error.OutOfMemory, assignAssociation(&child, &parent, null));
    try testing.expectEqual(@import("../surface.zig").Role.none, child.role);
    try testing.expectNull(child.role_data);
    try testing.expectEqual(@as(usize, 0), parent.children.items.len);
}

test "live subsurface association never overwrites role ownership" {
    var parent: Surface = undefined;
    var child: Surface = undefined;
    parent.allocator = testing.allocator;
    parent.children = std.ArrayList(*Surface).empty;
    defer parent.children.deinit(testing.allocator);
    parent.pending_children = std.ArrayList(*Surface).empty;
    parent.pending_children_active = false;
    var original_owner: u8 = 0;
    var replacement_owner: u8 = 0;
    child.role = .subsurface;
    child.role_data = &original_owner;

    try testing.expectError(error.RoleAssigned, assignAssociation(&child, &parent, &replacement_owner));
    try testing.expectEqual(@as(?*anyopaque, &original_owner), child.role_data);
    try testing.expectEqual(@as(usize, 0), parent.children.items.len);
}

test "destroyed subsurface association permits same permanent role recreation" {
    var parent: Surface = undefined;
    var child: Surface = undefined;
    parent.allocator = testing.allocator;
    parent.children = std.ArrayList(*Surface).empty;
    defer parent.children.deinit(testing.allocator);
    parent.pending_children = std.ArrayList(*Surface).empty;
    parent.pending_children_active = false;
    child.role = .subsurface;
    child.role_data = null;
    child.parent = null;

    var replacement_owner: u8 = 0;
    try assignAssociation(&child, &parent, &replacement_owner);
    try testing.expectEqual(@as(?*anyopaque, &replacement_owner), child.role_data);
    try testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try testing.expectEqual(&parent, child.parent);
}

test "destroyed wl_subsurface keeps permanent role and detaches tree" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    defer @import("core").unix.close(fds[1]);
    const client = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse
        return error.ClientCreateFailed;
    defer c.wl_client_destroy(client);
    const resource = c.wl_resource_create(client, &c.wl_subsurface_interface, 1, 1) orelse
        return error.ResourceCreateFailed;
    const role_data = try testing.allocator.create(RoleData);
    role_data.* = .{
        .allocator = testing.allocator,
        .surface = child,
        .resource = resource,
    };
    try child.setRole(.subsurface, role_data);
    try parent.addChild(child);
    child.subsurface_resource = resource;
    child.mapped = true;
    c.wl_resource_set_implementation(resource, @ptrCast(&subsurface_impl), role_data, destroySubsurface);

    c.wl_resource_destroy(resource);

    try testing.expectEqual(@import("../surface.zig").Role.subsurface, child.role);
    try testing.expectNull(child.role_data);
    try testing.expectNull(child.parent);
    try testing.expectEqual(@as(usize, 0), parent.children.items.len);
    try testing.expectFalse(child.mapped);
    try child.setRole(.subsurface, null);
    try testing.expectEqual(@import("../surface.zig").Role.subsurface, child.role);
}

const SmokeGlobals = struct {
    compositor: ?*c.wl_compositor = null,
    subcompositor: ?*c.wl_subcompositor = null,
    shm: ?*c.wl_shm = null,
    viewporter: ?*c.wp_viewporter = null,
};

fn smokeGlobal(data_ptr: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const globals: *SmokeGlobals = @ptrCast(@alignCast(data_ptr orelse return));
    const interface_name = std.mem.span(interface);
    if (std.mem.eql(u8, interface_name, "wl_compositor")) {
        globals.compositor = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4))));
    } else if (std.mem.eql(u8, interface_name, "wl_subcompositor")) {
        globals.subcompositor = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_subcompositor_interface, @min(version, 1))));
    } else if (std.mem.eql(u8, interface_name, "wl_shm")) {
        globals.shm = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, @min(version, 1))));
    } else if (std.mem.eql(u8, interface_name, "wp_viewporter")) {
        globals.viewporter = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wp_viewporter_interface, @min(version, 1))));
    }
}

fn smokeGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

const SmokeServer = struct {
    server: *wayland.Server,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    fn run(self: *SmokeServer) void {
        while (self.running.load(.acquire)) {
            _ = self.server.dispatch(10) catch return;
            c.wl_display_flush_clients(self.server.getDisplay());
        }
    }
};

const ReleaseCounter = struct {
    count: usize = 0,
};

fn smokeBufferRelease(data_ptr: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
    const counter: *ReleaseCounter = @ptrCast(@alignCast(data_ptr orelse return));
    counter.count += 1;
}

const smoke_buffer_listener = c.wl_buffer_listener{
    .release = smokeBufferRelease,
};

const FrameCounter = struct {
    count: usize = 0,
};

fn smokeFrameDone(data_ptr: ?*anyopaque, callback: ?*c.wl_callback, _: u32) callconv(.c) void {
    const counter: *FrameCounter = @ptrCast(@alignCast(data_ptr orelse return));
    counter.count += 1;
    c.wl_callback_destroy(callback);
}

const smoke_frame_listener = c.wl_callback_listener{
    .done = smokeFrameDone,
};

fn createSmokeBuffer(pool: *c.wl_shm_pool, offset: i32, counter: *ReleaseCounter) !*c.wl_buffer {
    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        offset,
        2,
        2,
        8,
        c.WL_SHM_FORMAT_ARGB8888,
    ) orelse return error.BufferCreateFailed;
    if (c.wl_buffer_add_listener(buffer, &smoke_buffer_listener, counter) != 0)
        return error.BufferListenerFailed;
    return buffer;
}

test "nested subsurface client smoke composes a three-level tree" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    try @import("compositor.zig").register(fixture.compositor);
    try register(fixture.compositor);

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    _ = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse return error.ClientCreateFailed;
    const display = c.wl_display_connect_to_fd(fds[1]) orelse return error.DisplayConnectFailed;

    var smoke_server = SmokeServer{ .server = &fixture.server };
    var thread = try std.Thread.spawn(.{}, SmokeServer.run, .{&smoke_server});
    defer {
        smoke_server.running.store(false, .release);
        thread.join();
        c.wl_display_disconnect(display);
        _ = fixture.server.dispatch(0) catch {};
    }
    defer _ = c.wl_display_roundtrip(display);

    const registry = c.wl_display_get_registry(display) orelse return error.RegistryCreateFailed;
    defer c.wl_registry_destroy(registry);
    var globals = SmokeGlobals{};
    const listener = c.wl_registry_listener{
        .global = smokeGlobal,
        .global_remove = smokeGlobalRemove,
    };
    if (c.wl_registry_add_listener(registry, &listener, &globals) != 0) return error.RegistryListenerFailed;
    if (c.wl_display_roundtrip(display) < 0) return error.RegistryRoundtripFailed;
    const client_compositor = globals.compositor orelse return error.MissingCompositor;
    defer c.wl_compositor_destroy(client_compositor);
    const client_subcompositor = globals.subcompositor orelse return error.MissingSubcompositor;
    defer c.wl_subcompositor_destroy(client_subcompositor);

    const parent = c.wl_compositor_create_surface(client_compositor) orelse return error.SurfaceCreateFailed;
    defer c.wl_surface_destroy(parent);
    const child = c.wl_compositor_create_surface(client_compositor) orelse return error.SurfaceCreateFailed;
    defer c.wl_surface_destroy(child);
    const grandchild = c.wl_compositor_create_surface(client_compositor) orelse return error.SurfaceCreateFailed;
    defer c.wl_surface_destroy(grandchild);
    const child_role = c.wl_subcompositor_get_subsurface(client_subcompositor, child, parent) orelse return error.SubsurfaceCreateFailed;
    defer c.wl_subsurface_destroy(child_role);
    const grandchild_role = c.wl_subcompositor_get_subsurface(client_subcompositor, grandchild, child) orelse return error.SubsurfaceCreateFailed;
    defer c.wl_subsurface_destroy(grandchild_role);
    c.wl_subsurface_set_position(child_role, 12, 18);
    c.wl_subsurface_set_position(grandchild_role, -3, 7);
    c.wl_surface_commit(grandchild);
    c.wl_surface_commit(child);
    c.wl_surface_commit(parent);
    if (c.wl_display_roundtrip(display) < 0) return error.CommitRoundtripFailed;

    try testing.expectEqual(@as(usize, 3), fixture.compositor.surfaces.items.len);
    const server_parent = fixture.compositor.surfaces.items[0];
    const server_child = fixture.compositor.surfaces.items[1];
    const server_grandchild = fixture.compositor.surfaces.items[2];
    try testing.expectEqual(server_parent, server_child.parent);
    try testing.expectEqual(server_child, server_grandchild.parent);
    try testing.expectEqual(@as(i32, 12), server_child.subsurface_x);
    try testing.expectEqual(@as(i32, 7), server_grandchild.subsurface_y);
}

test "nested synchronized SHM buffers release only after replacement" {
    var fixture = try @import("../surface.zig").TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    try @import("compositor.zig").register(fixture.compositor);
    try register(fixture.compositor);
    try @import("hidpi.zig").register(fixture.compositor);

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    _ = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse
        return error.ClientCreateFailed;
    const display = c.wl_display_connect_to_fd(fds[1]) orelse
        return error.DisplayConnectFailed;
    var smoke_server = SmokeServer{ .server = &fixture.server };
    var thread = try std.Thread.spawn(.{}, SmokeServer.run, .{&smoke_server});
    var thread_running = true;
    defer {
        if (thread_running) {
            smoke_server.running.store(false, .release);
            thread.join();
        }
        c.wl_display_disconnect(display);
        _ = fixture.server.dispatch(0) catch {};
    }

    const registry = c.wl_display_get_registry(display) orelse return error.RegistryCreateFailed;
    defer c.wl_registry_destroy(registry);
    var globals = SmokeGlobals{};
    const registry_listener = c.wl_registry_listener{
        .global = smokeGlobal,
        .global_remove = smokeGlobalRemove,
    };
    if (c.wl_registry_add_listener(registry, &registry_listener, &globals) != 0)
        return error.RegistryListenerFailed;
    if (c.wl_display_roundtrip(display) < 0) return error.RegistryRoundtripFailed;
    const client_compositor = globals.compositor orelse return error.MissingCompositor;
    defer c.wl_compositor_destroy(client_compositor);
    const client_subcompositor = globals.subcompositor orelse return error.MissingSubcompositor;
    defer c.wl_subcompositor_destroy(client_subcompositor);
    const shm = globals.shm orelse return error.MissingShm;
    defer c.wl_shm_destroy(shm);
    const viewporter = globals.viewporter orelse return error.MissingViewporter;
    defer c.wl_proxy_destroy(@ptrCast(viewporter));

    const fd = try std.posix.memfd_createZ("sideswipe-subsurface-smoke", 0);
    defer @import("core").unix.close(fd);
    try @import("core").unix.ftruncate(fd, 32);
    const pixels = [_]u8{
        100, 0,  0, 255, 110, 0,  0,  255,
        120, 0,  0, 255, 130, 0,  0,  255,
        0,   64, 0, 128, 0,   0,  64, 128,
        64,  0,  0, 128, 64,  64, 0,  128,
    };
    _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);
    try testing.expectEqual(pixels.len, try @import("core").unix.write(fd, &pixels));
    const pool = c.wl_shm_create_pool(shm, fd, 32) orelse return error.PoolCreateFailed;
    defer c.wl_shm_pool_destroy(pool);
    var first_release = ReleaseCounter{};
    var second_release = ReleaseCounter{};
    const first = try createSmokeBuffer(pool, 0, &first_release);
    defer c.wl_buffer_destroy(first);
    const second = try createSmokeBuffer(pool, 16, &second_release);
    defer c.wl_buffer_destroy(second);

    const parent = c.wl_compositor_create_surface(client_compositor) orelse
        return error.SurfaceCreateFailed;
    defer c.wl_surface_destroy(parent);
    const child = c.wl_compositor_create_surface(client_compositor) orelse
        return error.SurfaceCreateFailed;
    defer c.wl_surface_destroy(child);
    const role = c.wl_subcompositor_get_subsurface(client_subcompositor, child, parent) orelse
        return error.SubsurfaceCreateFailed;

    c.wl_surface_attach(child, first, 0, 0);
    c.wl_surface_commit(child);
    if (c.wl_display_roundtrip(display) < 0) return error.CommitRoundtripFailed;
    try testing.expectEqual(@as(usize, 0), first_release.count);

    c.wl_surface_attach(child, first, 0, 0);
    c.wl_surface_commit(child);
    if (c.wl_display_roundtrip(display) < 0) return error.CommitRoundtripFailed;
    try testing.expectEqual(@as(usize, 0), first_release.count);

    c.wl_surface_attach(child, second, 0, 0);
    c.wl_surface_commit(child);
    if (c.wl_display_roundtrip(display) < 0) return error.CommitRoundtripFailed;
    try testing.expectEqual(@as(usize, 1), first_release.count);
    try testing.expectEqual(@as(usize, 0), second_release.count);

    const viewport = c.wp_viewporter_get_viewport(viewporter, child) orelse
        return error.ViewportCreateFailed;
    defer c.wp_viewport_destroy(viewport);
    c.wp_viewport_set_source(viewport, 128, 128, 256, 256);
    c.wp_viewport_set_destination(viewport, 1, 1);
    c.wl_surface_set_buffer_transform(child, c.WL_OUTPUT_TRANSFORM_180);
    c.wl_subsurface_set_position(role, 1, 0);
    var frame_counter = FrameCounter{};
    const frame = c.wl_surface_frame(parent) orelse return error.FrameCreateFailed;
    if (c.wl_callback_add_listener(frame, &smoke_frame_listener, &frame_counter) != 0)
        return error.FrameListenerFailed;
    c.wl_surface_attach(parent, first, 0, 0);
    c.wl_surface_commit(child);
    c.wl_surface_commit(parent);
    if (c.wl_display_roundtrip(display) < 0) return error.CommitRoundtripFailed;

    const server_parent = fixture.compositor.surfaces.items[0];
    const server_child = fixture.compositor.surfaces.items[1];
    server_parent.role = .xdg_toplevel;
    const readback = try @import("../output.zig").testCompositeTree(
        testing.allocator,
        fixture.compositor,
        server_parent,
        2,
        2,
    );
    defer testing.allocator.free(readback);
    smoke_server.running.store(false, .release);
    thread.join();
    thread_running = false;
    try @import("../output.zig").testFinishFrame(fixture.compositor);
    smoke_server.running.store(true, .release);
    thread = try std.Thread.spawn(.{}, SmokeServer.run, .{&smoke_server});
    thread_running = true;
    if (c.wl_display_roundtrip(display) < 0) return error.FrameRoundtripFailed;
    try testing.expectEqualSlices(u8, &.{ 100, 0, 0, 255 }, readback[0..4]);
    try testing.expectEqualSlices(u8, &.{ 79, 45, 0, 255 }, readback[4..8]);
    try testing.expectEqualSlices(u8, &.{ 120, 0, 0, 255 }, readback[8..12]);
    try testing.expectEqualSlices(u8, &.{ 130, 0, 0, 255 }, readback[12..16]);
    try testing.expectEqual(@as(usize, 1), frame_counter.count);
    try testing.expectEqual(@as(usize, 0), second_release.count);

    c.wl_subsurface_destroy(role);
    if (c.wl_display_roundtrip(display) < 0) return error.DestroyRoundtripFailed;
    try testing.expectFalse(server_child.mapped);
    try testing.expectNull(server_child.current.buffer.buffer);
    try testing.expectNull(server_child.parent);
    try testing.expectEqual(@as(usize, 1), second_release.count);

    c.wl_surface_attach(parent, null, 0, 0);
    c.wl_surface_commit(parent);
    if (c.wl_display_roundtrip(display) < 0) return error.CommitRoundtripFailed;
    try testing.expectEqual(@as(usize, 2), first_release.count);
}
