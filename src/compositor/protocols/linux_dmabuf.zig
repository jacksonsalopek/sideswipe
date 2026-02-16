//! zwp_linux_dmabuf_v1 protocol implementation
//! Handles DMA-BUF buffer sharing between clients and compositor

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;
const backend = @import("backend");

const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const SurfaceData = @import("./compositor.zig").SurfaceData;

// Protocol version we support
const ZWP_LINUX_DMABUF_V1_VERSION = 4;

// Maximum number of planes per buffer
const MAX_PLANES = 4;

/// User data attached to zwp_linux_dmabuf_v1 resources
const DmabufData = struct {
    compositor: *Compositor,
};

/// User data attached to zwp_linux_buffer_params_v1 resources
const BufferParamsData = struct {
    compositor: *Compositor,
    width: i32 = 0,
    height: i32 = 0,
    format: u32 = 0,
    flags: u32 = 0,
    num_planes: u32 = 0,
    plane_data: [MAX_PLANES]PlaneAttributes = [_]PlaneAttributes{.{}} ** MAX_PLANES,
    used: bool = false,
};

/// Attributes for a single plane
const PlaneAttributes = struct {
    fd: i32 = -1,
    offset: u32 = 0,
    stride: u32 = 0,
    modifier_hi: u32 = 0,
    modifier_lo: u32 = 0,
};

/// User data attached to created wl_buffer resources
const DmabufBufferData = struct {
    compositor: *Compositor,
    params_data: BufferParamsData,
};

// zwp_linux_dmabuf_v1 request handlers

fn dmabufDestroy(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn dmabufCreateParams(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    params_id: u32,
) callconv(.c) void {
    const data: *DmabufData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;

    // Create zwp_linux_buffer_params_v1 resource
    const params_resource = c.wl_resource_create(
        client,
        &c.zwp_linux_buffer_params_v1_interface,
        c.wl_resource_get_version(resource),
        params_id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Create params data
    const params_data = comp.allocator.create(BufferParamsData) catch {
        c.wl_resource_destroy(params_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    params_data.* = .{ .compositor = comp };

    c.wl_resource_set_implementation(
        params_resource,
        @ptrCast(&params_implementation),
        params_data,
        paramsDestroy,
    );

    comp.logger.trace("Created zwp_linux_buffer_params_v1", .{});
}

fn dmabufGetDefaultFeedback(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    feedback_id: u32,
) callconv(.c) void {
    const data: *DmabufData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;

    // Create zwp_linux_dmabuf_feedback_v1 resource
    const feedback_resource = c.wl_resource_create(
        client,
        &c.zwp_linux_dmabuf_feedback_v1_interface,
        c.wl_resource_get_version(resource),
        feedback_id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Attach compositor data
    const feedback_data = comp.allocator.create(DmabufData) catch {
        c.wl_resource_destroy(feedback_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    feedback_data.* = .{ .compositor = comp };

    c.wl_resource_set_implementation(
        feedback_resource,
        @ptrCast(&feedback_implementation),
        feedback_data,
        feedbackDestroy,
    );

    // Send format/modifier information
    sendDefaultFeedback(comp, feedback_resource);

    comp.logger.trace("Created zwp_linux_dmabuf_feedback_v1", .{});
}

fn dmabufGetSurfaceFeedback(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    feedback_id: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = surface_resource;
    const data: *DmabufData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;

    // Create zwp_linux_dmabuf_feedback_v1 resource
    const feedback_resource = c.wl_resource_create(
        client,
        &c.zwp_linux_dmabuf_feedback_v1_interface,
        c.wl_resource_get_version(resource),
        feedback_id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Attach compositor data
    const feedback_data = comp.allocator.create(DmabufData) catch {
        c.wl_resource_destroy(feedback_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    feedback_data.* = .{ .compositor = comp };

    c.wl_resource_set_implementation(
        feedback_resource,
        @ptrCast(&feedback_implementation),
        feedback_data,
        feedbackDestroy,
    );

    // For now, send same feedback as default
    // TODO: Optimize based on surface scanout capabilities
    sendDefaultFeedback(comp, feedback_resource);

    comp.logger.trace("Created zwp_linux_dmabuf_feedback_v1 for surface", .{});
}

var dmabuf_implementation = [_]?*const anyopaque{
    @ptrCast(&dmabufDestroy),
    @ptrCast(&dmabufCreateParams),
    @ptrCast(&dmabufGetDefaultFeedback),
    @ptrCast(&dmabufGetSurfaceFeedback),
};

// zwp_linux_buffer_params_v1 request handlers

fn paramsDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *BufferParamsData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    // Close all file descriptors
    for (data.plane_data) |plane| {
        if (plane.fd >= 0) {
            std.posix.close(plane.fd);
        }
    }

    data.compositor.allocator.destroy(data);
}

fn paramsDestroyRequest(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn paramsAdd(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    fd: i32,
    plane_idx: u32,
    offset: u32,
    stride: u32,
    modifier_hi: u32,
    modifier_lo: u32,
) callconv(.c) void {
    _ = client;

    const data: *BufferParamsData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    if (data.used) {
        c.wl_resource_post_error(
            resource,
            c.ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_ALREADY_USED,
            "params was already used to create a buffer",
        );
        std.posix.close(fd);
        return;
    }

    if (plane_idx >= MAX_PLANES) {
        c.wl_resource_post_error(
            resource,
            c.ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_PLANE_IDX,
            "plane index too large",
        );
        std.posix.close(fd);
        return;
    }

    if (data.plane_data[plane_idx].fd != -1) {
        c.wl_resource_post_error(
            resource,
            c.ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_PLANE_SET,
            "plane already set",
        );
        std.posix.close(fd);
        return;
    }

    data.plane_data[plane_idx] = .{
        .fd = fd,
        .offset = offset,
        .stride = stride,
        .modifier_hi = modifier_hi,
        .modifier_lo = modifier_lo,
    };

    if (plane_idx >= data.num_planes) {
        data.num_planes = plane_idx + 1;
    }

    data.compositor.logger.trace(
        "Added plane {d}: fd={d}, offset={d}, stride={d}",
        .{ plane_idx, fd, offset, stride },
    );
}

fn paramsCreate(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
) callconv(.c) void {
    _ = client;

    const data: *BufferParamsData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    if (data.used) {
        c.wl_resource_post_error(
            resource,
            c.ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_ALREADY_USED,
            "params was already used to create a buffer",
        );
        return;
    }

    if (!validateParams(data, width, height, format)) {
        c.zwp_linux_buffer_params_v1_send_failed(resource);
        return;
    }

    data.used = true;
    data.width = width;
    data.height = height;
    data.format = format;
    data.flags = flags;

    // Create wl_buffer
    const buffer_resource = createDmabufBuffer(data, resource);
    if (buffer_resource) |buf| {
        c.zwp_linux_buffer_params_v1_send_created(resource, buf);
        data.compositor.logger.debug(
            "Created DMA-BUF buffer: {d}x{d}, format={x}, planes={d}",
            .{ width, height, format, data.num_planes },
        );
    } else {
        c.zwp_linux_buffer_params_v1_send_failed(resource);
    }
}

fn paramsCreateImmed(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    buffer_id: u32,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
) callconv(.c) void {
    const data: *BufferParamsData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    if (data.used) {
        c.wl_resource_post_error(
            resource,
            c.ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_ALREADY_USED,
            "params was already used to create a buffer",
        );
        return;
    }

    if (!validateParams(data, width, height, format)) {
        c.wl_resource_post_error(
            resource,
            c.ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_INVALID_WL_BUFFER,
            "invalid buffer parameters",
        );
        return;
    }

    data.used = true;
    data.width = width;
    data.height = height;
    data.format = format;
    data.flags = flags;

    // Create wl_buffer with specific ID
    const buffer_resource = c.wl_resource_create(
        client,
        &c.wl_buffer_interface,
        1,
        buffer_id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    // Create buffer data
    const buffer_data = data.compositor.allocator.create(DmabufBufferData) catch {
        c.wl_resource_destroy(buffer_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    buffer_data.* = .{
        .compositor = data.compositor,
        .params_data = data.*,
    };

    c.wl_resource_set_implementation(
        buffer_resource,
        @ptrCast(&buffer_implementation),
        buffer_data,
        bufferDestroy,
    );

    data.compositor.logger.debug(
        "Created DMA-BUF buffer (immediate): {d}x{d}, format={x}, planes={d}",
        .{ width, height, format, data.num_planes },
    );
}

var params_implementation = [_]?*const anyopaque{
    @ptrCast(&paramsDestroyRequest),
    @ptrCast(&paramsAdd),
    @ptrCast(&paramsCreate),
    @ptrCast(&paramsCreateImmed),
};

// zwp_linux_dmabuf_feedback_v1 request handlers

fn feedbackDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *DmabufData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.compositor.allocator.destroy(data);
}

fn feedbackDestroyRequest(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

var feedback_implementation = [_]?*const anyopaque{
    @ptrCast(&feedbackDestroyRequest),
};

// wl_buffer handlers for dmabuf buffers

fn bufferDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *DmabufBufferData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    // Close all file descriptors
    for (data.params_data.plane_data) |plane| {
        if (plane.fd >= 0) {
            std.posix.close(plane.fd);
        }
    }

    data.compositor.allocator.destroy(data);
}

fn bufferDestroyRequest(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

var buffer_implementation = [_]?*const anyopaque{
    @ptrCast(&bufferDestroyRequest),
};

// Helper functions

/// Validate buffer parameters
fn validateParams(data: *BufferParamsData, width: i32, height: i32, format: u32) bool {
    _ = format; // Format validation could be added here

    if (width <= 0 or height <= 0) {
        return false;
    }

    if (data.num_planes == 0) {
        return false;
    }

    // Check that all planes have valid FDs
    var i: u32 = 0;
    while (i < data.num_planes) : (i += 1) {
        if (data.plane_data[i].fd < 0) {
            return false;
        }
    }

    return true;
}

/// Create wl_buffer from params
fn createDmabufBuffer(data: *BufferParamsData, params_resource: ?*c.wl_resource) ?*c.wl_resource {
    const client = c.wl_resource_get_client(params_resource);
    const buffer_resource = c.wl_resource_create(
        client,
        &c.wl_buffer_interface,
        1,
        0,
    ) orelse return null;

    // Create buffer data
    const buffer_data = data.compositor.allocator.create(DmabufBufferData) catch {
        c.wl_resource_destroy(buffer_resource);
        return null;
    };
    buffer_data.* = .{
        .compositor = data.compositor,
        .params_data = data.*,
    };

    c.wl_resource_set_implementation(
        buffer_resource,
        @ptrCast(&buffer_implementation),
        buffer_data,
        bufferDestroy,
    );

    return buffer_resource;
}

/// Send default feedback to client
fn sendDefaultFeedback(comp: *Compositor, feedback_resource: *c.wl_resource) void {
    // Get format table from backend
    const coord = comp.coordinator orelse {
        comp.logger.warn("No backend coordinator available for format feedback", .{});
        c.zwp_linux_dmabuf_feedback_v1_send_done(feedback_resource);
        return;
    };

    // Get formats from first available backend
    if (coord.implementations.items.len == 0) {
        c.zwp_linux_dmabuf_feedback_v1_send_done(feedback_resource);
        return;
    }

    const impl = coord.implementations.items[0];
    const formats = impl.getRenderFormats();

    // Create format table in memory
    var format_table = std.ArrayList(u8){};
    defer format_table.deinit(comp.allocator);

    // Build format table (format + modifier pairs)
    for (formats) |fmt| {
        for (fmt.modifiers.items) |modifier| {
            // Write format (4 bytes)
            const format_bytes = std.mem.asBytes(&fmt.drm_format);
            format_table.appendSlice(comp.allocator, format_bytes) catch continue;

            // Write modifier (8 bytes)
            const modifier_bytes = std.mem.asBytes(&modifier);
            format_table.appendSlice(comp.allocator, modifier_bytes) catch continue;
        }
    }

    if (format_table.items.len == 0) {
        c.zwp_linux_dmabuf_feedback_v1_send_done(feedback_resource);
        return;
    }

    // Create anonymous file for format table
    const fd = createAnonymousFile(format_table.items) catch {
        comp.logger.warn("Failed to create format table file", .{});
        c.zwp_linux_dmabuf_feedback_v1_send_done(feedback_resource);
        return;
    };
    defer std.posix.close(fd);

    // Send format table
    c.zwp_linux_dmabuf_feedback_v1_send_format_table(
        feedback_resource,
        fd,
        @intCast(format_table.items.len),
    );

    // Send main device (DRM device node)
    const drm_fd = impl.drmFd();
    if (drm_fd >= 0) {
        var dev_id: std.posix.dev_t = undefined;
        const stat_result = std.posix.fstat(drm_fd);
        if (stat_result) |st| {
            dev_id = st.rdev;
            const dev_bytes = std.mem.asBytes(&dev_id);
            
            var dev_array: c.wl_array = undefined;
            c.wl_array_init(&dev_array);
            defer c.wl_array_release(&dev_array);
            
            const array_data = c.wl_array_add(&dev_array, dev_bytes.len);
            if (array_data) |data_ptr| {
                const dest: [*]u8 = @ptrCast(data_ptr);
                @memcpy(dest[0..dev_bytes.len], dev_bytes);
            }
            
            c.zwp_linux_dmabuf_feedback_v1_send_main_device(feedback_resource, &dev_array);
        } else |_| {
            comp.logger.warn("Failed to stat DRM device", .{});
        }
    }

    // Send tranche (all formats in one tranche for simplicity)
    var indices = std.ArrayList(u16){};
    defer indices.deinit(comp.allocator);

    var idx: u16 = 0;
    for (formats) |fmt| {
        for (fmt.modifiers.items) |_| {
            indices.append(comp.allocator, idx) catch break;
            idx += 1;
        }
    }

    if (indices.items.len > 0) {
        var indices_array: c.wl_array = undefined;
        c.wl_array_init(&indices_array);
        defer c.wl_array_release(&indices_array);
        
        const indices_bytes = std.mem.sliceAsBytes(indices.items);
        const array_data = c.wl_array_add(&indices_array, indices_bytes.len);
        if (array_data) |data_ptr| {
            const dest: [*]u8 = @ptrCast(data_ptr);
            @memcpy(dest[0..indices_bytes.len], indices_bytes);
        }
        
        c.zwp_linux_dmabuf_feedback_v1_send_tranche_formats(feedback_resource, &indices_array);
    }

    c.zwp_linux_dmabuf_feedback_v1_send_tranche_flags(
        feedback_resource,
        c.ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SCANOUT,
    );

    c.zwp_linux_dmabuf_feedback_v1_send_tranche_done(feedback_resource);
    c.zwp_linux_dmabuf_feedback_v1_send_done(feedback_resource);
}

/// Create anonymous file with given data
fn createAnonymousFile(data: []const u8) !i32 {
    // Create anonymous file using memfd_create
    const fd = std.posix.memfd_createZ(
        "dmabuf-format-table",
        std.os.linux.MFD.CLOEXEC,
    ) catch return error.MemfdCreateFailed;
    errdefer std.posix.close(fd);

    // Write data to file
    _ = std.posix.write(fd, data) catch {
        return error.WriteFailed;
    };

    // Seal the file to make it read-only
    const F_ADD_SEALS: i32 = 1033;
    const F_SEAL_SHRINK: i32 = 0x0002;
    const F_SEAL_SEAL: i32 = 0x0001;
    _ = std.os.linux.fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_SEAL);

    return fd;
}

// Global bind handler

fn dmabufBind(
    client: ?*c.wl_client,
    data: ?*anyopaque,
    version: u32,
    id: u32,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(data));

    compositor.logger.debug("Client bound to zwp_linux_dmabuf_v1 (version {d})", .{version});

    const resource = c.wl_resource_create(
        client,
        &c.zwp_linux_dmabuf_v1_interface,
        @intCast(@min(version, ZWP_LINUX_DMABUF_V1_VERSION)),
        id,
    ) orelse {
        c.wl_client_post_no_memory(client);
        return;
    };

    const dmabuf_data = compositor.allocator.create(DmabufData) catch {
        c.wl_resource_destroy(resource);
        c.wl_client_post_no_memory(client);
        return;
    };
    dmabuf_data.* = .{ .compositor = compositor };

    c.wl_resource_set_implementation(
        resource,
        @ptrCast(&dmabuf_implementation),
        dmabuf_data,
        dmabufResourceDestroy,
    );

    // Send supported formats (for older protocol versions)
    if (version < 4) {
        sendLegacyFormats(compositor, resource);
    }
}

fn dmabufResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *DmabufData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.compositor.allocator.destroy(data);
}

/// Send formats using legacy format event (protocol version < 4)
fn sendLegacyFormats(comp: *Compositor, resource: *c.wl_resource) void {
    const coord = comp.coordinator orelse return;

    if (coord.implementations.items.len == 0) return;

    const impl = coord.implementations.items[0];
    const formats = impl.getRenderFormats();

    for (formats) |fmt| {
        for (fmt.modifiers.items) |modifier| {
            c.zwp_linux_dmabuf_v1_send_format(resource, fmt.drm_format);
            
            if (modifier != 0) {
                const modifier_hi: u32 = @intCast((modifier >> 32) & 0xFFFFFFFF);
                const modifier_lo: u32 = @intCast(modifier & 0xFFFFFFFF);
                c.zwp_linux_dmabuf_v1_send_modifier(
                    resource,
                    fmt.drm_format,
                    modifier_hi,
                    modifier_lo,
                );
            }
        }
    }
}

/// Register the zwp_linux_dmabuf_v1 global
pub fn register(compositor: *Compositor) !void {
    const global = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.zwp_linux_dmabuf_v1_interface,
        ZWP_LINUX_DMABUF_V1_VERSION,
        compositor,
        dmabufBind,
    );
    _ = global;
}

// Tests
const testing = @import("core").testing;

test "PlaneAttributes - default initialization" {
    const plane: PlaneAttributes = .{};
    try testing.expectEqual(@as(i32, -1), plane.fd);
    try testing.expectEqual(@as(u32, 0), plane.offset);
    try testing.expectEqual(@as(u32, 0), plane.stride);
}

test "BufferParamsData - initialization" {
    var dummy_comp: Compositor = undefined;
    const params: BufferParamsData = .{ .compositor = &dummy_comp };
    
    try testing.expectEqual(@as(i32, 0), params.width);
    try testing.expectEqual(@as(i32, 0), params.height);
    try testing.expectEqual(@as(u32, 0), params.format);
    try testing.expectEqual(@as(u32, 0), params.num_planes);
    try testing.expectFalse(params.used);
    
    for (params.plane_data) |plane| {
        try testing.expectEqual(@as(i32, -1), plane.fd);
    }
}

test "validateParams - rejects invalid dimensions" {
    var dummy_comp: Compositor = undefined;
    var params: BufferParamsData = .{ 
        .compositor = &dummy_comp,
        .num_planes = 1,
    };
    params.plane_data[0].fd = 3;
    
    try testing.expectFalse(validateParams(&params, 0, 100, 0x34325258));
    try testing.expectFalse(validateParams(&params, 100, 0, 0x34325258));
    try testing.expectFalse(validateParams(&params, -1, 100, 0x34325258));
}

test "validateParams - rejects zero planes" {
    var dummy_comp: Compositor = undefined;
    var params: BufferParamsData = .{ 
        .compositor = &dummy_comp,
        .num_planes = 0,
    };
    
    try testing.expectFalse(validateParams(&params, 1920, 1080, 0x34325258));
}

test "validateParams - rejects invalid FDs" {
    var dummy_comp: Compositor = undefined;
    var params: BufferParamsData = .{ 
        .compositor = &dummy_comp,
        .num_planes = 2,
    };
    params.plane_data[0].fd = 3;
    params.plane_data[1].fd = -1; // Invalid
    
    try testing.expectFalse(validateParams(&params, 1920, 1080, 0x34325258));
}

test "validateParams - accepts valid params" {
    var dummy_comp: Compositor = undefined;
    var params: BufferParamsData = .{ 
        .compositor = &dummy_comp,
        .num_planes = 1,
    };
    params.plane_data[0].fd = 3;
    
    try testing.expect(validateParams(&params, 1920, 1080, 0x34325258));
}

test "createAnonymousFile - creates file with data" {
    const test_data = "Hello, DMA-BUF!";
    const fd = try createAnonymousFile(test_data);
    defer std.posix.close(fd);
    
    try testing.expect(fd >= 0);
    
    // Read back data to verify
    var buffer: [100]u8 = undefined;
    _ = std.posix.lseek_SET(fd, 0) catch unreachable;
    const bytes_read = try std.posix.read(fd, &buffer);
    
    try testing.expectEqual(test_data.len, bytes_read);
    try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);
}
