//! Compositor output management
//! Connects backend outputs to compositor surfaces for rendering

const std = @import("std");
const core = @import("core");
const cli = @import("core.cli");
const backend = @import("backend");
const math = @import("core.math");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("compositor.zig").Compositor;
const Surface = @import("surface.zig").Surface;
const FrameCallback = @import("surface.zig").FrameCallback;
const scale_policy = @import("scale.zig");
const Scene = @import("scene/scene.zig").Type;

/// Compositor output state
pub const Type = struct {
    allocator: std.mem.Allocator,
    compositor: *Compositor,
    backend_output: backend.output.IOutput,
    name: []const u8,
    needs_frame: bool = false,
    frame_pending: bool = false,
    fractional_scale: f32 = 1,
    logical_x: i32 = 0,
    logical_y: i32 = 0,
    logical_width: i32 = 1920,
    logical_height: i32 = 1080,
    scale_locked: bool = false,
    scene: Scene = .{},

    const Self = @This();

    pub const Error = error{
        OutOfMemory,
        BackendError,
    };

    /// Creates a new compositor output
    pub fn init(
        allocator: std.mem.Allocator,
        compositor: *Compositor,
        backend_output: backend.output.IOutput,
        name: []const u8,
    ) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const scale_override = readScaleOverride(allocator, name);
        const fractional_scale = scale_policy.preferred(
            .{ .override = scale_override },
            .{ .width = 1920, .height = 1080 },
            null,
        ) catch 1;

        self.* = .{
            .allocator = allocator,
            .compositor = compositor,
            .backend_output = backend_output,
            .name = name_copy,
            .fractional_scale = fractional_scale,
            .scale_locked = scale_override != null,
        };

        compositor.logger.info("Created compositor output: {s}", .{name});

        return self;
    }

    pub fn applyGeometry(self: *Self, width: i32, height: i32, scale: f32) bool {
        var changed = false;
        if (width > 0 and self.logical_width != width) {
            self.logical_width = width;
            changed = true;
        }
        if (height > 0 and self.logical_height != height) {
            self.logical_height = height;
            changed = true;
        }
        if (!self.scale_locked and scale >= 0.5 and scale <= 4 and self.fractional_scale != scale) {
            self.fractional_scale = scale;
            changed = true;
        }
        return changed;
    }

    /// Destroys the output
    pub fn deinit(self: *Self) void {
        self.scene.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Schedules a frame to be rendered
    pub fn scheduleFrame(self: *Self) void {
        self.scene.output_damaged = true;
        if (self.frame_pending) {
            self.compositor.logger.trace("Output {s}: Frame already pending, setting needs_frame flag", .{self.name});
            self.needs_frame = true;
            return;
        }

        self.compositor.logger.debug("Output {s}: Scheduling frame", .{self.name});
        self.backend_output.scheduleFrame(.unknown);
        self.frame_pending = true;
    }

    /// Renders all surfaces to this output
    pub fn render(self: *Self) Error!void {
        self.compositor.logger.debug("Output {s}: Begin render (frame_pending={}, needs_frame={})", .{ self.name, self.frame_pending, self.needs_frame });

        self.frame_pending = false;
        self.needs_frame = false;

        // Get backend coordinator
        const coord = self.compositor.coordinator orelse {
            self.compositor.logger.err("Output {s}: No backend coordinator available for rendering", .{self.name});
            return error.BackendError;
        };

        _ = coord;

        // Count mapped surfaces with buffers
        var surface_count: usize = 0;
        for (self.compositor.surfaces.items) |surface| {
            if (isVisible(surface) and surface.current.buffer.buffer != null) {
                surface_count += 1;
            }
        }

        self.compositor.logger.debug("Output {s}: Found {d} mapped surface(s) with buffers (total surfaces: {d})", .{ self.name, surface_count, self.compositor.surfaces.items.len });

        if (!self.scene.beginFrame()) {
            self.compositor.logger.trace("Output {s}: No damage, sending frame callbacks", .{self.name});
            try self.sendFrameCallbacks();
            return;
        }

        self.compositor.logger.debug("Output {s}: Rendering frame with {d} surface(s)", .{ self.name, surface_count });
        var composite = try CompositeBuffer.init(
            self.allocator,
            @max(1, self.logical_width),
            @max(1, self.logical_height),
            self.fractional_scale,
        );
        defer composite.deinit();
        composite.fillOpaque(0, 0, 0);
        try self.compositeToplevels(&composite);
        self.compositeShellQuads(&composite);
        try self.setBackendBuffer(composite.iface());
        if (!self.backend_output.commit()) return error.BackendError;
        self.scene.finishFrame();

        // Send frame callbacks to all surfaces
        self.compositor.logger.debug("Output {s}: Sending frame callbacks", .{self.name});
        try self.sendFrameCallbacks();

        // If another frame was requested during rendering, schedule it
        if (self.needs_frame) {
            self.compositor.logger.debug("Output {s}: Scheduling another frame (needs_frame was set)", .{self.name});
            self.scheduleFrame();
        }

        self.compositor.logger.debug("Output {s}: Render complete", .{self.name});
    }

    /// Sends frame callbacks to all surfaces
    fn sendFrameCallbacks(self: *Self) Error!void {
        const time_ms = self.getTimestamp();

        for (self.compositor.surfaces.items) |surface| {
            if (!isVisible(surface)) continue;
            // Send frame callbacks from current state
            const callbacks = surface.current.frame_callbacks.items;
            if (callbacks.len == 0) continue;

            for (callbacks) |callback| {
                // Send the callback with current timestamp
                c.wl_callback_send_done(callback.resource, time_ms);
                c.wl_resource_destroy(callback.resource);
                self.allocator.destroy(callback);
            }

            surface.current.frame_callbacks.clearRetainingCapacity();
            self.compositor.logger.trace("Sent {d} frame callback(s) to surface {d}", .{ callbacks.len, surface.id });
        }
    }

    /// Gets current timestamp in milliseconds
    fn getTimestamp(self: *Self) u32 {
        _ = self;
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        // Access fields via std.time for compatibility
        const sec_ms: u64 = @intCast(@as(i64, ts.sec) * 1000);
        const nsec_ms: u64 = @intCast(@divTrunc(ts.nsec, 1000000));
        const ms = sec_ms + nsec_ms;
        return @truncate(ms);
    }

    /// Sets a buffer in the backend output state for rendering
    fn setBackendBuffer(self: *Self, buf: backend.buffer.Interface) Error!void {
        // Access the concrete output implementation through the interface
        // The base.ptr contains the pointer to the actual Output structure
        const output_ptr = self.backend_output.base.ptr;

        // For now, we only support Wayland backend
        // Cast to Wayland Output and set buffer in state
        const wayland_backend = @import("backend").wayland;
        const wl_output: *wayland_backend.Output = @ptrCast(@alignCast(output_ptr));

        self.compositor.logger.debug("Output {s}: Before setBuffer - committed.buffer={}", .{ self.name, wl_output.state.committed.buffer });
        wl_output.state.setBuffer(buf);
        self.compositor.logger.debug("Output {s}: After setBuffer - committed.buffer={}", .{ self.name, wl_output.state.committed.buffer });
    }

    /// Imports a wl_buffer resource as a backend buffer interface
    fn importBuffer(self: *Self, buffer_resource: *c.wl_resource) Error!backend.buffer.Interface {
        // Check if this is a wl_shm_buffer
        const shm_buffer = c.wl_shm_buffer_get(buffer_resource);
        if (shm_buffer) |shm| {
            return self.importShmBuffer(shm);
        }

        return self.importDmabufBuffer(buffer_resource);
    }

    fn importShmBuffer(self: *Self, shm_buffer: *c.wl_shm_buffer) Error!backend.buffer.Interface {
        const width = c.wl_shm_buffer_get_width(shm_buffer);
        const height = c.wl_shm_buffer_get_height(shm_buffer);
        const stride = c.wl_shm_buffer_get_stride(shm_buffer);
        const format = c.wl_shm_buffer_get_format(shm_buffer);

        self.compositor.logger.debug("Output {s}: Importing SHM buffer ({}x{} stride={} format=0x{x:0>8})", .{ self.name, width, height, stride, format });

        c.wl_shm_buffer_begin_access(shm_buffer);
        const data = c.wl_shm_buffer_get_data(shm_buffer);
        c.wl_shm_buffer_end_access(shm_buffer);

        if (data == null) {
            self.compositor.logger.warn("Output {s}: SHM buffer has null data pointer", .{self.name});
            return error.BackendError;
        }

        const wrapper = try self.allocator.create(ShmBufferWrapper);
        errdefer self.allocator.destroy(wrapper);

        wrapper.* = .{
            .allocator = self.allocator,
            .shm_buffer = shm_buffer,
            .width = width,
            .height = height,
            .stride = stride,
            .format = format,
        };

        self.compositor.logger.debug("Output {s}: Successfully imported SHM buffer ({}x{} stride={} format=0x{x:0>8})", .{ self.name, width, height, stride, format });

        return backend.buffer.Interface.init(wrapper, &shm_buffer_vtable);
    }

    fn importDmabufBuffer(self: *Self, buffer_resource: *c.wl_resource) Error!backend.buffer.Interface {
        // Get DMA-BUF data from resource
        const user_data = c.wl_resource_get_user_data(buffer_resource);
        if (user_data == null) {
            self.compositor.logger.warn("Output {s}: Buffer has no user data", .{self.name});
            return error.BackendError;
        }

        // Cast to the DMA-BUF protocol's buffer data.
        const buffer_data: *linux_dmabuf.BufferData = @ptrCast(@alignCast(user_data));
        const params = buffer_data.params_data;

        const modifier: u64 = (@as(u64, params.plane_data[0].modifier_hi) << 32) |
            @as(u64, params.plane_data[0].modifier_lo);

        self.compositor.logger.debug(
            "Output {s}: Importing DMA-BUF buffer ({}x{} format=0x{x:0>8} modifier=0x{x:0>16} planes={})",
            .{ self.name, params.width, params.height, params.format, modifier, params.num_planes },
        );

        const wrapper = try self.allocator.create(DmabufBufferWrapper);
        errdefer self.allocator.destroy(wrapper);

        wrapper.* = .{
            .allocator = self.allocator,
            .width = params.width,
            .height = params.height,
            .format = params.format,
            .num_planes = params.num_planes,
            .plane_data = params.plane_data,
        };

        self.compositor.logger.debug("Output {s}: Successfully imported DMA-BUF buffer", .{self.name});

        return backend.buffer.Interface.init(wrapper, &dmabuf_buffer_vtable);
    }

    fn compositeToplevels(self: *Self, target: *CompositeBuffer) Error!void {
        for (self.compositor.toplevels.items) |entry| {
            try self.compositeTree(target, entry.surface, .{
                .x = entry.x,
                .y = entry.y,
                .width = entry.width,
                .height = entry.height,
            });
        }
        for (self.compositor.surfaces.items) |surface| {
            if (surface.role != .xdg_popup) continue;
            const geometry = surface.scene_geometry orelse continue;
            try self.compositeTree(target, surface, .{
                .x = geometry.x,
                .y = geometry.y,
                .width = geometry.width,
                .height = geometry.height,
            });
        }
    }

    fn compositeShellQuads(self: *Self, target: *CompositeBuffer) void {
        for (self.scene.shell_quads.items) |quad| target.fillRoundedQuad(quad);
    }

    fn compositeTree(
        self: *Self,
        target: *CompositeBuffer,
        surface: *Surface,
        geometry: @import("layout/strip.zig").Geometry,
    ) Error!void {
        if (!surface.mapped) return;
        try self.compositeTreeAtDepth(target, surface, geometry, 0);
    }

    fn compositeTreeAtDepth(
        self: *Self,
        target: *CompositeBuffer,
        surface: *Surface,
        geometry: @import("layout/strip.zig").Geometry,
        depth: usize,
    ) Error!void {
        if (depth >= 256) return error.BackendError;
        if (!surface.mapped) return;
        try self.compositeChildren(target, surface, geometry, false, depth);
        try self.compositeSurface(target, surface, geometry);
        try self.compositeChildren(target, surface, geometry, true, depth);
    }

    fn compositeChildren(
        self: *Self,
        target: *CompositeBuffer,
        parent: *Surface,
        parent_geometry: @import("layout/strip.zig").Geometry,
        above_parent: bool,
        depth: usize,
    ) Error!void {
        for (parent.children.items) |child| {
            if (child.subsurface_above_parent != above_parent) continue;
            try self.compositeTreeAtDepth(target, child, childGeometry(child, parent_geometry), depth + 1);
        }
    }

    fn compositeSurface(
        self: *Self,
        target: *CompositeBuffer,
        surface: *Surface,
        geometry: @import("layout/strip.zig").Geometry,
    ) Error!void {
        if (!surface.mapped) return;
        const resource = surface.current.buffer.buffer orelse return;
        if (linux_dmabuf.isBuffer(resource)) {
            try self.compositeDmabuf(target, surface, resource, geometry);
            return;
        }
        if (c.wl_shm_buffer_get(resource)) |shm| {
            target.copyShm(shm, geometry, surface.current.buffer, surface.current.viewport);
            return;
        }
        self.compositor.logger.warn("Output {s}: Unsupported wl_buffer for surface {d}", .{ self.name, surface.id });
    }

    fn compositeDmabuf(
        self: *Self,
        target: *CompositeBuffer,
        surface: *Surface,
        resource: *c.wl_resource,
        geometry: @import("layout/strip.zig").Geometry,
    ) Error!void {
        const imported = try self.importDmabufBuffer(resource);
        defer imported.deinit();
        const data: *linux_dmabuf.BufferData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
        const crop = sourceCrop(
            data.params_data.width,
            data.params_data.height,
            @max(1, surface.current.buffer.scale),
            surface.current.buffer.transform,
            surface.current.viewport.source,
        );
        const physical = target.physicalGeometry(geometry);
        const layer = backend.renderer.Layer{
            .buffer = imported,
            .x = physical.x,
            .y = physical.y,
            .width = physical.width,
            .height = physical.height,
            .uv = textureCoordinates(
                crop,
                data.params_data.width,
                data.params_data.height,
                surface.current.buffer.transform,
            ),
        };
        const coord = self.compositor.coordinator orelse return error.BackendError;
        const renderer = coord.primary_renderer orelse return error.BackendError;
        const rgba = try self.allocator.alloc(u8, target.pixels.len);
        defer self.allocator.free(rgba);
        if (!renderer.composeDmabufs(&.{layer}, target.width, target.height, rgba)) {
            self.compositor.logger.err("Output {s}: DMA-BUF scene composition failed", .{self.name});
            return error.BackendError;
        }
        target.blendRgbaBottomUp(rgba);
    }
};

/// Test-only readback hook for exercising the real SHM scene compositor.
pub fn testCompositeTree(
    allocator: std.mem.Allocator,
    compositor: *Compositor,
    root: *Surface,
    width: i32,
    height: i32,
) ![]u8 {
    var output = Type{
        .allocator = allocator,
        .compositor = compositor,
        .backend_output = undefined,
        .name = "test-readback",
    };
    var target = try CompositeBuffer.init(allocator, width, height, 1);
    defer target.deinit();
    try output.compositeTree(&target, root, .{ .x = 0, .y = 0, .width = width, .height = height });
    return allocator.dupe(u8, target.pixels);
}

/// Test-only hook that completes callbacks on the server event-loop thread.
pub fn testFinishFrame(compositor: *Compositor) !void {
    var output = Type{
        .allocator = compositor.allocator,
        .compositor = compositor,
        .backend_output = undefined,
        .name = "test-frame",
    };
    try output.sendFrameCallbacks();
}

fn childGeometry(child: *Surface, parent: @import("layout/strip.zig").Geometry) @import("layout/strip.zig").Geometry {
    const size = surfaceLogicalSize(child);
    return .{
        .x = parent.x + child.subsurface_x,
        .y = parent.y + child.subsurface_y,
        .width = size.width,
        .height = size.height,
    };
}

fn surfaceLogicalSize(surface: *Surface) struct { width: i32, height: i32 } {
    if (surface.current.viewport.destination) |destination| {
        return .{ .width = destination.width, .height = destination.height };
    }
    const resource = surface.current.buffer.buffer orelse return .{ .width = 0, .height = 0 };
    const scale = @max(1, surface.current.buffer.scale);
    if (surface.current.viewport.source) |source| {
        return .{
            .width = @divTrunc(source.width + 255, 256),
            .height = @divTrunc(source.height + 255, 256),
        };
    }
    if (c.wl_shm_buffer_get(resource)) |shm| {
        const size = transformedSize(
            c.wl_shm_buffer_get_width(shm),
            c.wl_shm_buffer_get_height(shm),
            surface.current.buffer.transform,
        );
        return .{
            .width = @divTrunc(size.width, scale),
            .height = @divTrunc(size.height, scale),
        };
    }
    if (linux_dmabuf.isBuffer(resource)) {
        const buffer_data: *linux_dmabuf.BufferData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
        const size = transformedSize(
            buffer_data.params_data.width,
            buffer_data.params_data.height,
            surface.current.buffer.transform,
        );
        return .{
            .width = @divTrunc(size.width, scale),
            .height = @divTrunc(size.height, scale),
        };
    }
    return .{ .width = surface.current.width, .height = surface.current.height };
}

fn isVisible(surface: *const Surface) bool {
    if (!surface.mapped) return false;
    var root = surface;
    while (root.parent) |parent| {
        if (!parent.mapped) return false;
        root = parent;
    }
    return root.role == .xdg_toplevel or root.role == .xdg_popup;
}

const SourceCrop = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

fn transformedSize(width: i32, height: i32, transform: u32) struct { width: i32, height: i32 } {
    if (transform == c.WL_OUTPUT_TRANSFORM_90 or
        transform == c.WL_OUTPUT_TRANSFORM_270 or
        transform == c.WL_OUTPUT_TRANSFORM_FLIPPED_90 or
        transform == c.WL_OUTPUT_TRANSFORM_FLIPPED_270)
    {
        return .{ .width = height, .height = width };
    }
    return .{ .width = width, .height = height };
}

fn sourceCrop(
    width: i32,
    height: i32,
    scale: i32,
    transform: u32,
    source: ?@import("surface.zig").ViewportSource,
) SourceCrop {
    const transformed = transformedSize(width, height, transform);
    const requested = source orelse return .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(transformed.width),
        .height = @floatFromInt(transformed.height),
    };
    const scale_f: f32 = @floatFromInt(scale);
    const x = @as(f32, @floatFromInt(requested.x)) * scale_f / 256;
    const y = @as(f32, @floatFromInt(requested.y)) * scale_f / 256;
    const right = (@as(f32, @floatFromInt(requested.x)) +
        @as(f32, @floatFromInt(requested.width))) * scale_f / 256;
    const bottom = (@as(f32, @floatFromInt(requested.y)) +
        @as(f32, @floatFromInt(requested.height))) * scale_f / 256;
    const transformed_width: f32 = @floatFromInt(transformed.width);
    const transformed_height: f32 = @floatFromInt(transformed.height);
    return .{
        .x = @max(0, x),
        .y = @max(0, y),
        .width = @max(0, @min(transformed_width, right) - @max(0, x)),
        .height = @max(0, @min(transformed_height, bottom) - @max(0, y)),
    };
}

fn inverseTransform(x: i32, y: i32, width: i32, height: i32, transform: u32) struct { x: i32, y: i32 } {
    return switch (transform) {
        c.WL_OUTPUT_TRANSFORM_90 => .{ .x = y, .y = height - 1 - x },
        c.WL_OUTPUT_TRANSFORM_180 => .{ .x = width - 1 - x, .y = height - 1 - y },
        c.WL_OUTPUT_TRANSFORM_270 => .{ .x = width - 1 - y, .y = x },
        c.WL_OUTPUT_TRANSFORM_FLIPPED => .{ .x = width - 1 - x, .y = y },
        c.WL_OUTPUT_TRANSFORM_FLIPPED_90 => .{ .x = width - 1 - y, .y = height - 1 - x },
        c.WL_OUTPUT_TRANSFORM_FLIPPED_180 => .{ .x = x, .y = height - 1 - y },
        c.WL_OUTPUT_TRANSFORM_FLIPPED_270 => .{ .x = y, .y = x },
        else => .{ .x = x, .y = y },
    };
}

fn textureCoordinates(crop: SourceCrop, width: i32, height: i32, transform: u32) [8]f32 {
    const corners = [_]struct { x: f32, y: f32 }{
        .{ .x = crop.x + crop.width, .y = crop.y },
        .{ .x = crop.x, .y = crop.y },
        .{ .x = crop.x + crop.width, .y = crop.y + crop.height },
        .{ .x = crop.x, .y = crop.y + crop.height },
    };
    var uv: [8]f32 = undefined;
    for (corners, 0..) |corner, index| {
        const point = inverseTransformEdge(corner.x, corner.y, width, height, transform);
        uv[index * 2] = point.x / @as(f32, @floatFromInt(width));
        uv[index * 2 + 1] = point.y / @as(f32, @floatFromInt(height));
    }
    return uv;
}

fn inverseTransformEdge(x: f32, y: f32, width: i32, height: i32, transform: u32) struct { x: f32, y: f32 } {
    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);
    return switch (transform) {
        c.WL_OUTPUT_TRANSFORM_90 => .{ .x = y, .y = height_f - x },
        c.WL_OUTPUT_TRANSFORM_180 => .{ .x = width_f - x, .y = height_f - y },
        c.WL_OUTPUT_TRANSFORM_270 => .{ .x = width_f - y, .y = x },
        c.WL_OUTPUT_TRANSFORM_FLIPPED => .{ .x = width_f - x, .y = y },
        c.WL_OUTPUT_TRANSFORM_FLIPPED_90 => .{ .x = width_f - y, .y = height_f - x },
        c.WL_OUTPUT_TRANSFORM_FLIPPED_180 => .{ .x = x, .y = height_f - y },
        c.WL_OUTPUT_TRANSFORM_FLIPPED_270 => .{ .x = y, .y = x },
        else => .{ .x = x, .y = y },
    };
}

fn sampleCoordinate(origin: f32, extent: f32, index: i32, count: i32) f32 {
    const index_f: f32 = @floatFromInt(index);
    const count_f: f32 = @floatFromInt(@max(1, count));
    return origin + (index_f + 0.5) * extent / count_f;
}

fn shmByteLength(width: i32, height: i32, stride: i32) ?usize {
    if (width <= 0 or height <= 0 or stride <= 0) return null;
    const minimum_stride = std.math.mul(i64, @as(i64, width), 4) catch return null;
    if (@as(i64, stride) < minimum_stride) return null;
    const length = std.math.mul(i64, @as(i64, height), @as(i64, stride)) catch return null;
    return std.math.cast(usize, length);
}

const CompositeBuffer = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    logical_width: i32,
    width: i32,
    height: i32,
    stride: i32,

    fn init(allocator: std.mem.Allocator, logical_width: i32, logical_height: i32, scale: f32) !CompositeBuffer {
        const width: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical_width)) * scale));
        const height: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical_height)) * scale));
        const stride = width * 4;
        const pixels = try allocator.alloc(u8, @intCast(stride * height));
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .pixels = pixels,
            .logical_width = logical_width,
            .width = width,
            .height = height,
            .stride = stride,
        };
    }

    fn fillOpaque(self: *CompositeBuffer, blue: u8, green: u8, red: u8) void {
        var offset: usize = 0;
        while (offset + 3 < self.pixels.len) : (offset += 4) {
            self.pixels[offset] = blue;
            self.pixels[offset + 1] = green;
            self.pixels[offset + 2] = red;
            self.pixels[offset + 3] = 255;
        }
    }

    fn deinit(self: *CompositeBuffer) void {
        self.allocator.free(self.pixels);
    }

    const PhysicalGeometry = struct {
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    };

    fn physicalGeometry(self: *const CompositeBuffer, logical: @import("layout/strip.zig").Geometry) PhysicalGeometry {
        const scale = @as(f32, @floatFromInt(self.width)) /
            @as(f32, @floatFromInt(self.logical_width));
        const left: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical.x)) * scale));
        const top: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical.y)) * scale));
        const right: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical.x + logical.width)) * scale));
        const bottom: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical.y + logical.height)) * scale));
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }

    fn copyShm(
        self: *CompositeBuffer,
        source: *c.wl_shm_buffer,
        logical: @import("layout/strip.zig").Geometry,
        buffer: @import("surface.zig").BufferState,
        viewport: @import("surface.zig").ViewportState,
    ) void {
        const src_width = c.wl_shm_buffer_get_width(source);
        const src_height = c.wl_shm_buffer_get_height(source);
        const src_stride = c.wl_shm_buffer_get_stride(source);
        _ = shmByteLength(src_width, src_height, src_stride) orelse return;

        c.wl_shm_buffer_begin_access(source);
        defer c.wl_shm_buffer_end_access(source);
        const data = c.wl_shm_buffer_get_data(source) orelse return;
        const source_bytes: [*]const u8 = @ptrCast(data);
        const physical = self.physicalGeometry(logical);
        const crop = sourceCrop(src_width, src_height, @max(1, buffer.scale), buffer.transform, viewport.source);
        self.blitNearest(
            source_bytes,
            src_width,
            src_height,
            src_stride,
            c.wl_shm_buffer_get_format(source),
            crop,
            buffer.transform,
            physical.x,
            physical.y,
            physical.width,
            physical.height,
        );
    }

    fn blendRgbaBottomUp(self: *CompositeBuffer, rgba: []const u8) void {
        if (rgba.len < self.pixels.len) return;
        var y: i32 = 0;
        while (y < self.height) : (y += 1) {
            self.blendRgbaRow(rgba, y);
        }
    }

    fn fillRoundedQuad(self: *CompositeBuffer, quad: @import("ring_geometry.zig").Quad) void {
        const scale = @as(f32, @floatFromInt(self.width)) /
            @as(f32, @floatFromInt(self.logical_width));
        const physical = quad.physical(scale);
        var y: i32 = 0;
        while (y < physical.height) : (y += 1)
            self.fillRoundedRow(physical, y);
    }

    fn fillRoundedRow(
        self: *CompositeBuffer,
        quad: @import("ring_geometry.zig").PhysicalQuad,
        local_y: i32,
    ) void {
        const output_y = quad.y + local_y;
        if (output_y < 0 or output_y >= self.height) return;
        var local_x: i32 = 0;
        while (local_x < quad.width) : (local_x += 1) {
            const output_x = quad.x + local_x;
            if (output_x < 0 or output_x >= self.width) continue;
            if (!insideRoundedRect(local_x, local_y, quad.width, quad.height, quad.radius)) continue;
            const offset: usize = @intCast(output_y * self.stride + output_x * 4);
            blendColor(self.pixels[offset .. offset + 4], quad.color);
        }
    }

    fn blendRgbaRow(self: *CompositeBuffer, rgba: []const u8, y: i32) void {
        const source_y = self.height - 1 - y;
        var x: i32 = 0;
        while (x < self.width) : (x += 1) {
            const source_offset: usize = @intCast((source_y * self.width + x) * 4);
            const destination_offset: usize = @intCast(y * self.stride + x * 4);
            const alpha = rgba[source_offset + 3];
            if (alpha == 0) continue;
            blendPremultipliedBgra(
                self.pixels[destination_offset .. destination_offset + 4],
                rgba[source_offset .. source_offset + 4],
            );
        }
    }

    fn blitNearest(
        self: *CompositeBuffer,
        source: [*]const u8,
        src_width: i32,
        src_height: i32,
        src_stride: i32,
        format: u32,
        crop: SourceCrop,
        transform: u32,
        dst_x: i32,
        dst_y: i32,
        dst_width: i32,
        dst_height: i32,
    ) void {
        var y: i32 = 0;
        while (y < dst_height) : (y += 1) {
            const output_y = dst_y + y;
            if (output_y < 0 or output_y >= self.height) continue;
            const transformed_y = sampleCoordinate(crop.y, crop.height, y, dst_height);
            self.blitRow(source, src_width, src_height, src_stride, format, crop, transform, transformed_y, dst_x, output_y, dst_width);
        }
    }

    fn blitRow(
        self: *CompositeBuffer,
        source: [*]const u8,
        src_width: i32,
        src_height: i32,
        src_stride: i32,
        format: u32,
        crop: SourceCrop,
        transform: u32,
        transformed_y: f32,
        dst_x: i32,
        output_y: i32,
        dst_width: i32,
    ) void {
        var x: i32 = 0;
        while (x < dst_width) : (x += 1) {
            const output_x = dst_x + x;
            if (output_x < 0 or output_x >= self.width) continue;
            const transformed_x = sampleCoordinate(crop.x, crop.width, x, dst_width);
            const source_point = inverseTransform(
                @intFromFloat(@floor(transformed_x)),
                @intFromFloat(@floor(transformed_y)),
                src_width,
                src_height,
                transform,
            );
            if (source_point.x < 0 or source_point.x >= src_width or source_point.y < 0 or source_point.y >= src_height) continue;
            const source_offset: usize = @intCast(source_point.y * src_stride + source_point.x * 4);
            const output_offset: usize = @intCast(output_y * self.stride + output_x * 4);
            const source_pixel = source[source_offset .. source_offset + 4];
            if (format == c.WL_SHM_FORMAT_XRGB8888) {
                blendShmBgra(self.pixels[output_offset .. output_offset + 4], source_pixel, 255);
            } else {
                blendShmBgra(self.pixels[output_offset .. output_offset + 4], source_pixel, source_pixel[3]);
            }
        }
    }

    fn iface(self: *CompositeBuffer) backend.buffer.Interface {
        return backend.buffer.Interface.init(self, &composite_buffer_vtable);
    }

    fn caps(_: *anyopaque) backend.buffer.Capability {
        return .{ .dataptr = true };
    }
    fn bufferType(_: *anyopaque) backend.buffer.Type {
        return .shm;
    }
    fn update(_: *anyopaque, _: *const anyopaque) void {}
    fn isSynchronous(_: *anyopaque) bool {
        return true;
    }
    fn good(_: *anyopaque) bool {
        return true;
    }
    fn dmabuf(_: *anyopaque) backend.buffer.DMABUFAttrs {
        return .{ .success = false };
    }
    fn shm(ptr: *anyopaque) backend.buffer.SSHMAttrs {
        const self: *CompositeBuffer = @ptrCast(@alignCast(ptr));
        return .{
            .success = true,
            .format = c.WL_SHM_FORMAT_ARGB8888,
            .size = math.Vec2.init(@floatFromInt(self.width), @floatFromInt(self.height)),
            .stride = self.stride,
            .offset = 0,
        };
    }
    fn beginDataPtr(ptr: *anyopaque, _: u32) backend.buffer.DataPtrResult {
        const self: *CompositeBuffer = @ptrCast(@alignCast(ptr));
        return .{ .ptr = self.pixels.ptr, .flags = 0, .size = self.pixels.len };
    }
    fn endDataPtr(_: *anyopaque) void {}
    fn sendRelease(_: *anyopaque) void {}
    fn lock(_: *anyopaque) void {}
    fn unlock(_: *anyopaque) void {}
    fn locked(_: *anyopaque) bool {
        return false;
    }
    fn destroy(_: *anyopaque) void {}
};

const composite_buffer_vtable = backend.buffer.Interface.VTableDef{
    .caps = CompositeBuffer.caps,
    .type = CompositeBuffer.bufferType,
    .update = CompositeBuffer.update,
    .is_synchronous = CompositeBuffer.isSynchronous,
    .good = CompositeBuffer.good,
    .dmabuf = CompositeBuffer.dmabuf,
    .shm = CompositeBuffer.shm,
    .begin_data_ptr = CompositeBuffer.beginDataPtr,
    .end_data_ptr = CompositeBuffer.endDataPtr,
    .send_release = CompositeBuffer.sendRelease,
    .lock = CompositeBuffer.lock,
    .unlock = CompositeBuffer.unlock,
    .locked = CompositeBuffer.locked,
    .deinit = CompositeBuffer.destroy,
};

fn blendPremultipliedBgra(destination: []u8, source_rgba: []const u8) void {
    const inverse_alpha = 255 - @as(u16, source_rgba[3]);
    destination[0] = blendChannel(source_rgba[2], destination[0], inverse_alpha);
    destination[1] = blendChannel(source_rgba[1], destination[1], inverse_alpha);
    destination[2] = blendChannel(source_rgba[0], destination[2], inverse_alpha);
    destination[3] = blendChannel(source_rgba[3], destination[3], inverse_alpha);
}

fn blendShmBgra(destination: []u8, source_bgra: []const u8, alpha: u8) void {
    const inverse_alpha = 255 - @as(u16, alpha);
    destination[0] = blendChannel(source_bgra[0], destination[0], inverse_alpha);
    destination[1] = blendChannel(source_bgra[1], destination[1], inverse_alpha);
    destination[2] = blendChannel(source_bgra[2], destination[2], inverse_alpha);
    destination[3] = blendChannel(alpha, destination[3], inverse_alpha);
}

fn blendColor(destination: []u8, color: @import("ring_geometry.zig").Color) void {
    const alpha: u16 = color.alpha;
    const source = [_]u8{
        @intCast(@divTrunc(@as(u16, color.blue) * alpha + 127, 255)),
        @intCast(@divTrunc(@as(u16, color.green) * alpha + 127, 255)),
        @intCast(@divTrunc(@as(u16, color.red) * alpha + 127, 255)),
        color.alpha,
    };
    blendShmBgra(destination, &source, color.alpha);
}

fn insideRoundedRect(x: i32, y: i32, width: i32, height: i32, radius: i32) bool {
    const clamped_radius = @min(@max(0, radius), @divTrunc(@min(width, height), 2));
    if (clamped_radius == 0) return true;
    const nearest_x = if (x < clamped_radius)
        clamped_radius
    else if (x >= width - clamped_radius)
        width - clamped_radius - 1
    else
        x;
    const nearest_y = if (y < clamped_radius)
        clamped_radius
    else if (y >= height - clamped_radius)
        height - clamped_radius - 1
    else
        y;
    const dx = x - nearest_x;
    const dy = y - nearest_y;
    return dx * dx + dy * dy <= clamped_radius * clamped_radius;
}

fn blendChannel(source: u8, destination: u8, inverse_alpha: u16) u8 {
    const value = @as(u16, source) + @divTrunc(@as(u16, destination) * inverse_alpha + 127, 255);
    return @intCast(@min(value, 255));
}

fn readScaleOverride(allocator: std.mem.Allocator, output_name: []const u8) ?f32 {
    if (core.env.get("SIDESWIPE_SCALE")) |value| {
        return std.fmt.parseFloat(f32, value) catch null;
    }
    const config_home = core.env.get("XDG_CONFIG_HOME") orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}/sideswipe/config.toml", .{config_home}) catch return null;
    defer allocator.free(path);
    const contents = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(64 * 1024),
    ) catch return null;
    defer allocator.free(contents);
    return parseScaleOverride(contents, output_name);
}

fn parseScaleOverride(contents: []const u8, output_name: []const u8) ?f32 {
    var matching_section = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            matching_section = isOutputSection(line, output_name);
            continue;
        }
        if (!matching_section) continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.mem.eql(u8, key, "scale")) continue;
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        return std.fmt.parseFloat(f32, value) catch null;
    }
    return null;
}

fn isOutputSection(line: []const u8, output_name: []const u8) bool {
    if (line.len < 10 or line[line.len - 1] != ']') return false;
    const section = line[1 .. line.len - 1];
    if (!std.mem.startsWith(u8, section, "output.")) return false;
    const name = std.mem.trim(u8, section["output.".len..], "\"");
    return std.mem.eql(u8, name, output_name);
}

const linux_dmabuf = @import("protocols/linux_dmabuf.zig");
const PlaneAttributes = linux_dmabuf.PlaneAttributes;

/// Wrapper for client DMA-BUF buffers to be used with backend
const DmabufBufferWrapper = struct {
    allocator: std.mem.Allocator,
    width: i32,
    height: i32,
    format: u32,
    num_planes: u32,
    plane_data: [4]PlaneAttributes,

    fn caps(_: *anyopaque) backend.buffer.Capability {
        return .{};
    }

    fn bufferType(_: *anyopaque) backend.buffer.Type {
        return .dmabuf;
    }

    fn update(_: *anyopaque, _: *const anyopaque) void {}

    fn isSynchronous(_: *anyopaque) bool {
        return false;
    }

    fn good(ptr: *anyopaque) bool {
        const self: *DmabufBufferWrapper = @ptrCast(@alignCast(ptr));
        return self.width > 0 and self.height > 0 and self.num_planes > 0;
    }

    fn dmabuf(ptr: *anyopaque) backend.buffer.DMABUFAttrs {
        const self: *DmabufBufferWrapper = @ptrCast(@alignCast(ptr));

        const modifier: u64 = (@as(u64, self.plane_data[0].modifier_hi) << 32) |
            @as(u64, self.plane_data[0].modifier_lo);

        var attrs: backend.buffer.DMABUFAttrs = .{
            .success = true,
            .size = math.Vec2.init(@floatFromInt(self.width), @floatFromInt(self.height)),
            .format = self.format,
            .modifier = modifier,
            .planes = @intCast(self.num_planes),
        };

        // Copy plane FDs, strides, and offsets
        for (0..@min(self.num_planes, 4)) |i| {
            attrs.fds[i] = self.plane_data[i].fd;
            attrs.strides[i] = self.plane_data[i].stride;
            attrs.offsets[i] = self.plane_data[i].offset;
        }

        return attrs;
    }

    fn shm(_: *anyopaque) backend.buffer.SSHMAttrs {
        return .{ .success = false };
    }

    fn beginDataPtr(_: *anyopaque, _: u32) backend.buffer.DataPtrResult {
        return .{ .ptr = null, .flags = 0, .size = 0 };
    }

    fn endDataPtr(_: *anyopaque) void {}

    fn sendRelease(_: *anyopaque) void {}

    fn lock(_: *anyopaque) void {}

    fn unlock(_: *anyopaque) void {}

    fn locked(_: *anyopaque) bool {
        return false;
    }

    fn deinitBuffer(ptr: *anyopaque) void {
        const self: *DmabufBufferWrapper = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

const dmabuf_buffer_vtable = backend.buffer.Interface.VTableDef{
    .caps = DmabufBufferWrapper.caps,
    .type = DmabufBufferWrapper.bufferType,
    .update = DmabufBufferWrapper.update,
    .is_synchronous = DmabufBufferWrapper.isSynchronous,
    .good = DmabufBufferWrapper.good,
    .dmabuf = DmabufBufferWrapper.dmabuf,
    .shm = DmabufBufferWrapper.shm,
    .begin_data_ptr = DmabufBufferWrapper.beginDataPtr,
    .end_data_ptr = DmabufBufferWrapper.endDataPtr,
    .send_release = DmabufBufferWrapper.sendRelease,
    .lock = DmabufBufferWrapper.lock,
    .unlock = DmabufBufferWrapper.unlock,
    .locked = DmabufBufferWrapper.locked,
    .deinit = DmabufBufferWrapper.deinitBuffer,
};

/// Wrapper for client SHM buffers to be used with backend
const ShmBufferWrapper = struct {
    allocator: std.mem.Allocator,
    shm_buffer: *c.wl_shm_buffer,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,

    fn caps(_: *anyopaque) backend.buffer.Capability {
        return .{ .dataptr = true };
    }

    fn bufferType(_: *anyopaque) backend.buffer.Type {
        return .shm;
    }

    fn update(_: *anyopaque, _: *const anyopaque) void {}

    fn isSynchronous(_: *anyopaque) bool {
        return true;
    }

    fn good(ptr: *anyopaque) bool {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        return shmByteLength(self.width, self.height, self.stride) != null;
    }

    fn dmabuf(_: *anyopaque) backend.buffer.DMABUFAttrs {
        return .{ .success = false };
    }

    fn shm(ptr: *anyopaque) backend.buffer.SSHMAttrs {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));

        return .{
            .success = true,
            .fd = -1,
            .format = self.format,
            .size = math.Vec2.init(@floatFromInt(self.width), @floatFromInt(self.height)),
            .stride = self.stride,
            .offset = 0,
        };
    }

    fn beginDataPtr(ptr: *anyopaque, _: u32) backend.buffer.DataPtrResult {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        const size = shmByteLength(self.width, self.height, self.stride) orelse return .{
            .ptr = null,
            .flags = 0,
            .size = 0,
        };

        c.wl_shm_buffer_begin_access(self.shm_buffer);
        const data = c.wl_shm_buffer_get_data(self.shm_buffer);
        if (data == null) return .{ .ptr = null, .flags = 0, .size = 0 };

        return .{
            .ptr = @ptrCast(data),
            .flags = 0,
            .size = size,
        };
    }

    fn endDataPtr(ptr: *anyopaque) void {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        c.wl_shm_buffer_end_access(self.shm_buffer);
    }

    fn sendRelease(_: *anyopaque) void {}

    fn lock(_: *anyopaque) void {}

    fn unlock(_: *anyopaque) void {}

    fn locked(_: *anyopaque) bool {
        return false;
    }

    fn deinitBuffer(ptr: *anyopaque) void {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

const shm_buffer_vtable = backend.buffer.Interface.VTableDef{
    .caps = ShmBufferWrapper.caps,
    .type = ShmBufferWrapper.bufferType,
    .update = ShmBufferWrapper.update,
    .is_synchronous = ShmBufferWrapper.isSynchronous,
    .good = ShmBufferWrapper.good,
    .dmabuf = ShmBufferWrapper.dmabuf,
    .shm = ShmBufferWrapper.shm,
    .begin_data_ptr = ShmBufferWrapper.beginDataPtr,
    .end_data_ptr = ShmBufferWrapper.endDataPtr,
    .send_release = ShmBufferWrapper.sendRelease,
    .lock = ShmBufferWrapper.lock,
    .unlock = ShmBufferWrapper.unlock,
    .locked = ShmBufferWrapper.locked,
    .deinit = ShmBufferWrapper.deinitBuffer,
};

// Tests
const testing = core.testing;

test "Output - init and deinit" {
    // Skip test if no WAYLAND_DISPLAY
    if (core.env.get("WAYLAND_DISPLAY") == null) {
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;
    const test_setup = @import("wayland").test_setup;

    var runtime = try test_setup.RuntimeDir.setup(allocator);
    defer runtime.cleanup();

    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var comp = try Compositor.init(allocator, &server, &logger);
    defer comp.deinit();

    // Create a mock backend output (simplified for testing)
    // In reality, this would come from the backend
    const backend_opts = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };

    var coord = try backend.Coordinator.create(allocator, &backend_opts, .{});
    defer coord.deinit();

    // We can't easily test full output creation without a real backend
    // Just verify the structures compile
}

test "Output - scheduleFrame sets pending flag" {
    // This test would require a mock backend output
    // Skipping for now as it needs more infrastructure
}

test "Output - parses connector scale override" {
    const config =
        \\[output."DP-1"]
        \\scale = 1.5
        \\
        \\[output.HDMI-A-1]
        \\scale = 2.0
    ;
    try testing.expectEqual(@as(?f32, 1.5), parseScaleOverride(config, "DP-1"));
    try testing.expectEqual(@as(?f32, 2.0), parseScaleOverride(config, "HDMI-A-1"));
    try testing.expectNull(parseScaleOverride(config, "eDP-1"));
}

test "Output - applyGeometry updates size and unlocked scale" {
    var output = Type{
        .allocator = testing.allocator,
        .compositor = undefined,
        .backend_output = undefined,
        .name = "WL-1",
        .logical_width = 1920,
        .logical_height = 1080,
        .fractional_scale = 1,
    };
    try testing.expect(output.applyGeometry(1280, 800, 1.5));
    try testing.expectEqual(@as(i32, 1280), output.logical_width);
    try testing.expectEqual(@as(i32, 800), output.logical_height);
    try testing.expectEqual(@as(f32, 1.5), output.fractional_scale);
    output.scale_locked = true;
    try testing.expect(output.applyGeometry(1920, 1080, 2));
    try testing.expectEqual(@as(f32, 1.5), output.fractional_scale);
    try testing.expect(!output.applyGeometry(1920, 1080, 2));
}

test "CompositeBuffer - fillOpaque writes solid BGRA" {
    var composite = try CompositeBuffer.init(testing.allocator, 2, 1, 1);
    defer composite.deinit();
    composite.fillOpaque(16, 32, 64);
    try testing.expectEqualSlices(u8, &.{ 16, 32, 64, 255, 16, 32, 64, 255 }, composite.pixels);
}

test "CompositeBuffer - allocates physical scale matrix" {
    var one = try CompositeBuffer.init(testing.allocator, 100, 50, 1);
    defer one.deinit();
    var fractional = try CompositeBuffer.init(testing.allocator, 100, 50, 1.5);
    defer fractional.deinit();
    var two = try CompositeBuffer.init(testing.allocator, 100, 50, 2);
    defer two.deinit();

    try testing.expectEqual(@as(i32, 100), one.width);
    try testing.expectEqual(@as(i32, 150), fractional.width);
    try testing.expectEqual(@as(i32, 200), two.width);
}

test "CompositeBuffer - physical geometry shares rounded edges" {
    var composite = try CompositeBuffer.init(testing.allocator, 1920, 1080, 1.5);
    defer composite.deinit();
    const left = composite.physicalGeometry(.{ .x = 0, .y = 0, .width = 333, .height = 100 });
    const right = composite.physicalGeometry(.{ .x = 333, .y = 0, .width = 333, .height = 100 });
    try testing.expectEqual(left.x + left.width, right.x);
}

test "Output - blends premultiplied RGBA into SHM BGRA" {
    var destination = [_]u8{ 10, 20, 30, 255 };
    const source = [_]u8{ 100, 50, 25, 128 };
    blendPremultipliedBgra(&destination, &source);
    try testing.expectEqual(@as(u8, 30), destination[0]);
    try testing.expectEqual(@as(u8, 60), destination[1]);
    try testing.expectEqual(@as(u8, 115), destination[2]);
    try testing.expectEqual(@as(u8, 255), destination[3]);
}

test "Output - alpha blends premultiplied SHM BGRA" {
    var destination = [_]u8{ 10, 20, 30, 255 };
    const source = [_]u8{ 50, 25, 10, 128 };
    blendShmBgra(&destination, &source, source[3]);
    try testing.expectEqualSlices(u8, &.{ 55, 35, 25, 255 }, &destination);
}

test "CompositeBuffer - rounded shell quad scales and leaves corners clear" {
    var composite = try CompositeBuffer.init(testing.allocator, 20, 20, 1.5);
    defer composite.deinit();
    composite.fillRoundedQuad(.{
        .x = 2,
        .y = 2,
        .width = 8,
        .height = 8,
        .radius = 3,
        .color = .{ .red = 255, .green = 0, .blue = 0, .alpha = 255 },
    });
    const corner: usize = @intCast(3 * composite.stride + 3 * 4);
    const center: usize = @intCast(9 * composite.stride + 9 * 4);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, composite.pixels[corner .. corner + 4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, composite.pixels[center .. center + 4]);
}

test "Output - SHM blit crops the committed viewport source" {
    var composite = try CompositeBuffer.init(testing.allocator, 1920, 1080, 1);
    defer composite.deinit();
    const source = [_]u8{
        10, 20, 30, 255,
        40, 50, 60, 255,
    };
    composite.blitNearest(
        &source,
        2,
        1,
        8,
        c.WL_SHM_FORMAT_ARGB8888,
        .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        c.WL_OUTPUT_TRANSFORM_NORMAL,
        0,
        0,
        1,
        1,
    );
    try testing.expectEqualSlices(u8, &.{ 40, 50, 60, 255 }, composite.pixels[0..4]);
}

test "Output - fractional viewport crop remains subpixel through sampling" {
    const crop = sourceCrop(
        4,
        1,
        1,
        c.WL_OUTPUT_TRANSFORM_NORMAL,
        .{ .x = 128, .y = 0, .width = 512, .height = 256 },
    );
    try testing.expectEqual(@as(f32, 0.5), crop.x);
    try testing.expectEqual(@as(f32, 2), crop.width);
    const uv = textureCoordinates(crop, 4, 1, c.WL_OUTPUT_TRANSFORM_NORMAL);
    try testing.expectApproxEqAbs(@as(f32, 0.625), uv[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.125), uv[2], 0.0001);

    var composite = try CompositeBuffer.init(testing.allocator, 1920, 1080, 1);
    defer composite.deinit();
    const source = [_]u8{
        10, 0, 0, 255,
        20, 0, 0, 255,
        30, 0, 0, 255,
        40, 0, 0, 255,
    };
    composite.blitNearest(
        &source,
        4,
        1,
        16,
        c.WL_SHM_FORMAT_ARGB8888,
        crop,
        c.WL_OUTPUT_TRANSFORM_NORMAL,
        0,
        0,
        2,
        1,
    );
    try testing.expectEqual(@as(u8, 20), composite.pixels[0]);
    try testing.expectEqual(@as(u8, 30), composite.pixels[4]);
}

test "Output - SHM layout rejects signed overflow and short strides" {
    try testing.expectNull(shmByteLength(1, 1, -1));
    try testing.expectNull(shmByteLength(std.math.maxInt(i32), 2, std.math.maxInt(i32)));
    try testing.expectNull(shmByteLength(16, 16, 63));
    try testing.expectEqual(@as(?usize, 1024), shmByteLength(16, 16, 64));
}

test "Output - transformed buffer size and sampling rotate together" {
    const size = transformedSize(4, 2, c.WL_OUTPUT_TRANSFORM_90);
    try testing.expectEqual(@as(i32, 2), size.width);
    try testing.expectEqual(@as(i32, 4), size.height);
    const point = inverseTransform(0, 0, 4, 2, c.WL_OUTPUT_TRANSFORM_90);
    try testing.expectEqual(@as(i32, 0), point.x);
    try testing.expectEqual(@as(i32, 1), point.y);
    const uv = textureCoordinates(.{ .x = 1, .y = 0, .width = 1, .height = 1 }, 2, 1, c.WL_OUTPUT_TRANSFORM_NORMAL);
    try testing.expectEqual(@as(f32, 1), uv[0]);
    try testing.expectEqual(@as(f32, 0.5), uv[2]);
}

test "Output - subsurface geometry is parent-relative and viewport-sized" {
    var child: Surface = undefined;
    child.subsurface_x = 30;
    child.subsurface_y = -20;
    child.current.viewport.destination = .{ .width = 240, .height = 120 };
    const geometry = childGeometry(&child, .{ .x = 100, .y = 200, .width = 800, .height = 600 });

    try testing.expectEqual(@as(i32, 130), geometry.x);
    try testing.expectEqual(@as(i32, 180), geometry.y);
    try testing.expectEqual(@as(i32, 240), geometry.width);
    try testing.expectEqual(@as(i32, 120), geometry.height);
}

test "Output - viewport source controls logical size without destination" {
    var surface: Surface = undefined;
    var resource: u32 = 1;
    surface.current.buffer.buffer = @ptrCast(@alignCast(&resource));
    surface.current.viewport.destination = null;
    surface.current.viewport.source = .{ .x = 0, .y = 0, .width = 10 * 256, .height = 7 * 256 };
    const size = surfaceLogicalSize(&surface);
    try testing.expectEqual(@as(i32, 10), size.width);
    try testing.expectEqual(@as(i32, 7), size.height);
}

test "Output - descendants require every ancestor to remain mapped" {
    var root: Surface = undefined;
    var child: Surface = undefined;
    var grandchild: Surface = undefined;
    root.role = .xdg_toplevel;
    root.parent = null;
    root.mapped = true;
    child.role = .subsurface;
    child.parent = &root;
    child.mapped = true;
    grandchild.role = .subsurface;
    grandchild.parent = &child;
    grandchild.mapped = true;

    try testing.expect(isVisible(&grandchild));
    child.mapped = false;
    try testing.expectFalse(isVisible(&grandchild));
    child.mapped = true;
    root.mapped = false;
    try testing.expectFalse(isVisible(&grandchild));
    root.mapped = true;
    root.role = .none;
    try testing.expectFalse(isVisible(&grandchild));
}
