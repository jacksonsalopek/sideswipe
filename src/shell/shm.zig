//! wl_shm buffer helper. DMA-BUF attach is attempted first and falls back here.

const std = @import("std");
const core = @import("core");
const c = @import("c.zig").c;

pub const Pool = struct {
    fd: i32 = -1,
    pool: ?*c.wl_shm_pool = null,
    buffer: ?*c.wl_buffer = null,
    map: []align(std.heap.page_size_min) u8 = &.{},
    width: i32 = 0,
    height: i32 = 0,
    stride: i32 = 0,

    pub fn deinit(self: *Pool) void {
        if (self.buffer) |buffer| c.wl_buffer_destroy(buffer);
        if (self.pool) |pool| c.wl_shm_pool_destroy(pool);
        if (self.map.len != 0) std.posix.munmap(self.map);
        if (self.fd >= 0) core.unix.close(self.fd);
        self.* = .{};
    }

    pub fn pixels(self: *Pool) []u32 {
        const count = @as(usize, @intCast(self.height)) * @as(usize, @intCast(self.width));
        const bytes = self.map[0 .. count * 4];
        return std.mem.bytesAsSlice(u32, bytes);
    }
};

pub fn create(shm: *c.wl_shm, width: i32, height: i32) !Pool {
    const stride = width * 4;
    const size: usize = @intCast(stride * height);
    const fd = try anonymousFile(size);
    errdefer core.unix.close(fd);
    const map = std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return error.MmapFailed;
    errdefer std.posix.munmap(map);
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse return error.ShmPool;
    errdefer c.wl_shm_pool_destroy(pool);
    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        width,
        height,
        stride,
        c.WL_SHM_FORMAT_ARGB8888,
    ) orelse return error.ShmBuffer;
    return .{
        .fd = fd,
        .pool = pool,
        .buffer = buffer,
        .map = map,
        .width = width,
        .height = height,
        .stride = stride,
    };
}

/// DMA-BUF export for shell-drawn frames. Returns null until the shell has a
/// GBM/EGL render-to-texture path; callers must use wl_shm.
pub fn tryDmabuf(_: ?*c.zwp_linux_dmabuf_v1, _: i32, _: i32) ?*c.wl_buffer {
    return null;
}

fn anonymousFile(size: usize) !i32 {
    const fd = std.posix.memfd_createZ("sideswipe-shell", 0) catch return error.Memfd;
    errdefer core.unix.close(fd);
    try core.unix.ftruncate(fd, size);
    return fd;
}
