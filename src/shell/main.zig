//! Privileged shell client: ring + switcher over sideswipe_shell_v1 (P2, S1–S3).

const std = @import("std");
const core = @import("core");
const cli = @import("core.cli");
const c = @import("c.zig").c;
const render = @import("render.zig");
const shm = @import("shm.zig");

const Role = enum(u32) { ring = 0, switcher = 1 };

const Slice = struct {
    id: u32 = 0,
    label: [64]u8 = undefined,
    label_len: usize = 0,
    has_subring: bool = false,
};

const Overlay = struct {
    surface: ?*c.wl_surface = null,
    viewport: ?*c.wp_viewport = null,
    pool: shm.Pool = .{},
    serial: ?u32 = null,
    dirty: bool = false,
};

const Client = struct {
    gpa: std.mem.Allocator,
    logger: *cli.Logger,
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    shm_factory: ?*c.wl_shm = null,
    dmabuf: ?*c.zwp_linux_dmabuf_v1 = null,
    viewporter: ?*c.wp_viewporter = null,
    shell: ?*c.sideswipe_shell_v1 = null,
    output_name: u32 = 0,
    mode_width: i32 = 1920,
    mode_height: i32 = 1080,
    output_width: i32 = 1920,
    output_height: i32 = 1080,
    ring: Overlay = .{},
    switcher: Overlay = .{},
    slices: [8]Slice = .{Slice{}} ** 8,
    slice_count: u8 = 0,
    hover: ?u8 = null,
    ring_x: f64 = 0,
    ring_y: f64 = 0,
    scale: f32 = 1,
    columns: u32 = 0,
    progress: f64 = 0,
    running: bool = true,

    fn deinit(self: *Client) void {
        self.ring.pool.deinit();
        self.switcher.pool.deinit();
        destroyOverlay(&self.ring);
        destroyOverlay(&self.switcher);
        if (self.shell) |shell| c.sideswipe_shell_v1_destroy(shell);
        if (self.viewporter) |viewporter| c.wp_viewporter_destroy(viewporter);
        if (self.dmabuf) |dmabuf| c.zwp_linux_dmabuf_v1_destroy(dmabuf);
        if (self.shm_factory) |factory| c.wl_shm_destroy(factory);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }
};

fn destroyOverlay(overlay: *Overlay) void {
    if (overlay.viewport) |viewport| c.wp_viewport_destroy(viewport);
    if (overlay.surface) |surface| c.wl_surface_destroy(surface);
    overlay.viewport = null;
    overlay.surface = null;
}

// Wayland stores these pointers; they must outlive the proxy.
const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryRemove,
};

const shm_listener = c.wl_shm_listener{
    .format = shmFormat,
};

const output_listener = c.wl_output_listener{
    .geometry = outputGeometry,
    .mode = outputMode,
    .done = outputDone,
    .scale = outputScale,
    .name = outputName,
    .description = outputDescription,
};

const shell_listener = c.sideswipe_shell_v1_listener{
    .ring_open = onRingOpen,
    .ring_item = onRingItem,
    .ring_hover = onRingHover,
    .ring_close = onRingClose,
    .switcher_open = onSwitcherOpen,
    .switcher_column = onSwitcherColumn,
    .switcher_progress = onSwitcherProgress,
    .switcher_close = onSwitcherClose,
    .shade_open = ignoreUint,
    .shade_progress = ignoreProgress,
    .shade_close = ignoreUint,
    .edit_menu_open = ignoreEdit,
    .edit_menu_close = ignoreUint,
    .tile_enter = ignoreTileEnter,
    .tile_leave = ignoreUint,
    .toplevel_thumbnail = onThumbnail,
    .toplevel_closed = ignoreUint,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var logger = cli.Logger.init(gpa);
    defer logger.deinit();
    logger.setTime(true);
    logger.setEnableColor(true);
    logger.setLogLevel(.info);

    const socket = core.env.get("SIDESWIPE_SHELL_SOCKET") orelse {
        logger.err("SIDESWIPE_SHELL_SOCKET is unset", .{});
        return error.MissingSocket;
    };

    var client = Client{
        .gpa = gpa,
        .logger = &logger,
        .display = undefined,
        .registry = undefined,
    };
    try connect(&client, socket);
    defer client.deinit();
    try roundtrip(&client);
    if (client.shell == null or client.compositor == null or client.shm_factory == null) {
        logger.err("missing wl_compositor, wl_shm, or sideswipe_shell_v1", .{});
        return error.MissingGlobals;
    }

    try createOverlay(&client, &client.ring);
    try createOverlay(&client, &client.switcher);
    logger.info("Shell attached to {s} (SDR, shm fallback)", .{socket});

    while (client.running) {
        if (c.wl_display_dispatch(client.display) < 0) break;
        try flushOverlays(&client);
    }
}

fn connect(client: *Client, path: []const u8) !void {
    const display = try connectDisplay(path);
    errdefer c.wl_display_disconnect(display);
    const registry = c.wl_display_get_registry(display) orelse return error.Registry;
    client.display = display;
    client.registry = registry;
    if (c.wl_registry_add_listener(registry, &registry_listener, client) != 0) return error.Listener;
}

fn connectDisplay(path: []const u8) !*c.wl_display {
    if (std.fs.path.isAbsolute(path)) return connectPath(path);
    const name_z = try std.posix.toPosixPath(path);
    return c.wl_display_connect(&name_z) orelse error.ConnectFailed;
}

fn connectPath(path: []const u8) !*c.wl_display {
    const fd = try core.unix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    errdefer core.unix.close(fd);
    var addr: std.posix.sockaddr.un = .{
        .family = std.posix.AF.UNIX,
        .path = @splat(0),
    };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    const addr_len: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1);
    const rc = std.posix.system.connect(fd, @ptrCast(&addr), addr_len);
    if (std.posix.errno(rc) != .SUCCESS) return error.ConnectFailed;
    return c.wl_display_connect_to_fd(fd) orelse error.ConnectFailed;
}

fn roundtrip(client: *Client) !void {
    if (c.wl_display_roundtrip(client.display) < 0) return error.Roundtrip;
}

fn createOverlay(client: *Client, overlay: *Overlay) !void {
    const compositor = client.compositor orelse return error.MissingGlobals;
    const surface = c.wl_compositor_create_surface(compositor) orelse return error.Surface;
    overlay.surface = surface;
    if (client.viewporter) |viewporter| {
        overlay.viewport = c.wp_viewporter_get_viewport(viewporter, surface);
    }
}

fn flushOverlays(client: *Client) !void {
    if (client.ring.dirty) try publish(client, &client.ring, .ring);
    if (client.switcher.dirty) try publish(client, &client.switcher, .switcher);
}

fn publish(client: *Client, overlay: *Overlay, role: Role) !void {
    const serial = overlay.serial orelse return;
    const surface = overlay.surface orelse return;
    const shm_factory = client.shm_factory orelse return;
    const logical_w = client.output_width;
    const logical_h = client.output_height;
    const width = render.physical(logical_w, client.scale);
    const height = render.physical(logical_h, client.scale);
    if (width <= 0 or height <= 0) return;
    try resizePool(overlay, shm_factory, width, height);
    const buffer = render.Buffer{
        .pixels = overlay.pool.pixels(),
        .width = width,
        .height = height,
    };
    render.clear(buffer);
    try paint(client, buffer, role);
    const wl_buffer = shm.tryDmabuf(client.dmabuf, width, height) orelse overlay.pool.buffer orelse return;
    c.wl_surface_attach(surface, wl_buffer, 0, 0);
    c.wl_surface_damage_buffer(surface, 0, 0, width, height);
    if (overlay.viewport) |viewport| {
        c.wp_viewport_set_destination(viewport, logical_w, logical_h);
    } else {
        c.wl_surface_set_buffer_scale(surface, @max(1, @as(i32, @intFromFloat(@ceil(client.scale)))));
    }
    c.wl_surface_commit(surface);
    c.sideswipe_shell_v1_commit_surface(client.shell.?, serial, @intFromEnum(role), surface);
    overlay.dirty = false;
}

fn resizePool(overlay: *Overlay, factory: *c.wl_shm, width: i32, height: i32) !void {
    if (overlay.pool.buffer != null and overlay.pool.width == width and overlay.pool.height == height) return;
    overlay.pool.deinit();
    overlay.pool = try shm.create(factory, width, height);
}

fn paint(client: *Client, buffer: render.Buffer, role: Role) !void {
    switch (role) {
        .ring => try render.paintRing(
            buffer,
            client.ring_x,
            client.ring_y,
            client.scale,
            if (client.slice_count == 0) 4 else client.slice_count,
            client.hover,
        ),
        .switcher => render.paintSwitcher(buffer, client.scale, @max(client.columns, 1), client.progress),
    }
}

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    const live = registry orelse return;
    const iface = std.mem.span(interface);
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        client.compositor = @ptrCast(c.wl_registry_bind(live, name, &c.wl_compositor_interface, @min(version, 6)));
        return;
    }
    if (std.mem.eql(u8, iface, "wl_shm")) {
        const factory: *c.wl_shm = @ptrCast(c.wl_registry_bind(live, name, &c.wl_shm_interface, 1));
        client.shm_factory = factory;
        _ = c.wl_shm_add_listener(factory, &shm_listener, client);
        return;
    }
    if (std.mem.eql(u8, iface, "wp_viewporter")) {
        client.viewporter = @ptrCast(c.wl_registry_bind(live, name, &c.wp_viewporter_interface, 1));
        return;
    }
    if (std.mem.eql(u8, iface, "wl_output")) {
        if (client.output_name == 0) client.output_name = name;
        bindOutput(client, live, name, version);
        return;
    }
    if (std.mem.eql(u8, iface, "sideswipe_shell_v1")) {
        client.shell = @ptrCast(c.wl_registry_bind(live, name, &c.sideswipe_shell_v1_interface, 1));
        listenShell(client);
    }
}

fn registryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

fn bindOutput(client: *Client, registry: *c.wl_registry, name: u32, version: u32) void {
    const output: *c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 4)));
    _ = c.wl_output_add_listener(output, &output_listener, client);
}

fn outputGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}

fn applyMode(client: *Client) void {
    const size = render.logicalSize(client.mode_width, client.mode_height, client.scale);
    client.output_width = size.width;
    client.output_height = size.height;
}

fn outputMode(data: ?*anyopaque, _: ?*c.wl_output, flags: u32, width: i32, height: i32, _: i32) callconv(.c) void {
    if (flags & c.WL_OUTPUT_MODE_CURRENT == 0) return;
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.mode_width = @max(1, width);
    client.mode_height = @max(1, height);
    applyMode(client);
}

fn outputDone(_: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {}
fn outputScale(_: ?*anyopaque, _: ?*c.wl_output, _: i32) callconv(.c) void {}
fn outputName(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}
fn outputDescription(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}
fn shmFormat(_: ?*anyopaque, _: ?*c.wl_shm, _: u32) callconv(.c) void {}

fn listenShell(client: *Client) void {
    const shell = client.shell orelse return;
    _ = c.sideswipe_shell_v1_add_listener(shell, &shell_listener, client);
}

fn onRingOpen(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, serial: u32, x: c.wl_fixed_t, y: c.wl_fixed_t, _: u32, scale: c.wl_fixed_t) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.slice_count = 0;
    client.hover = null;
    client.ring_x = c.wl_fixed_to_double(x);
    client.ring_y = c.wl_fixed_to_double(y);
    client.scale = @floatCast(c.wl_fixed_to_double(scale));
    applyMode(client);
    client.ring.serial = serial;
    client.ring.dirty = true;
}

fn onRingItem(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, id: u32, label: [*c]const u8, _: [*c]const u8, has_subring: u32) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    if (client.slice_count >= client.slices.len) return;
    const text = std.mem.span(label);
    var slice = Slice{ .id = id, .has_subring = has_subring != 0 };
    const len = @min(text.len, slice.label.len);
    @memcpy(slice.label[0..len], text[0..len]);
    slice.label_len = len;
    client.slices[client.slice_count] = slice;
    client.slice_count += 1;
    client.ring.dirty = true;
}

fn onRingHover(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, slice_id: u32) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.hover = if (slice_id <= 7) @intCast(slice_id) else null;
    client.ring.dirty = true;
}

fn onRingClose(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.ring.serial = null;
    client.ring.dirty = false;
}

fn onSwitcherOpen(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, serial: u32) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.columns = 0;
    client.progress = 0;
    client.switcher.serial = serial;
    client.switcher.dirty = true;
}

fn onSwitcherColumn(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, _: u32, _: [*c]const u8, _: [*c]const u8) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.columns += 1;
    client.switcher.dirty = true;
}

fn onSwitcherProgress(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, progress: c.wl_fixed_t) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.progress = std.math.clamp(c.wl_fixed_to_double(progress), 0, 1);
    client.switcher.dirty = true;
}

fn onSwitcherClose(data: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, _: u32) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(data orelse return));
    client.switcher.serial = null;
    client.switcher.dirty = false;
}

fn ignoreUint(_: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32) callconv(.c) void {}
fn ignoreProgress(_: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
fn ignoreEdit(_: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t, _: [*c]const u8) callconv(.c) void {}
fn ignoreTileEnter(_: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, _: [*c]const u8, _: [*c]const u8) callconv(.c) void {}

/// Thumbnail wl_buffers are compositor-exported DMA-BUFs when a renderer path
/// exists. The current compositor sends a null shm stub; destroy non-null
/// buffers immediately to release the export.
fn onThumbnail(_: ?*anyopaque, _: ?*c.sideswipe_shell_v1, _: u32, buffer: ?*c.wl_buffer, _: i32, _: i32, _: c.wl_fixed_t) callconv(.c) void {
    if (buffer) |live| c.wl_buffer_destroy(live);
}

test "connectPath fails for a missing socket" {
    try std.testing.expectError(error.ConnectFailed, connectPath("/no/such/sideswipe-shell-socket"));
}

test {
    _ = render;
    _ = shm;
}
