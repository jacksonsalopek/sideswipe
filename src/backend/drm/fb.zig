//! Shared KMS framebuffer import: GEM handles and AddFB2 with modifiers.

const std = @import("std");
const core = @import("core");
const drm_format = @import("format.zig");

const c = @cImport({
    @cInclude("drm.h");
    @cInclude("drm_mode.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

pub const Planes = struct {
    handles: [4]u32 = .{ 0, 0, 0, 0 },
    pitches: [4]u32 = .{ 0, 0, 0, 0 },
    offsets: [4]u32 = .{ 0, 0, 0, 0 },
    modifiers: [4]u64 = .{ 0, 0, 0, 0 },
};

pub const Import = struct {
    fd: i32 = -1,
    stride: u32 = 0,
    offset: u32 = 0,
    modifier: u64 = 0,
};

/// True when any used plane carries a non-linear modifier.
pub fn usesModifiers(modifiers: []const u64) bool {
    for (modifiers) |modifier| {
        if (drm_format.needsModifierFlag(modifier)) return true;
    }
    return false;
}

/// True when any plane names LINEAR or a vendor modifier (not `MOD_INVALID`).
pub fn hasExplicitModifier(modifiers: []const u64) bool {
    for (modifiers) |modifier| {
        if (modifier != drm_format.MOD_INVALID) return true;
    }
    return false;
}

/// Import a PRIME fd as a GEM handle. Returns 0 on failure.
pub fn importPrime(drm_fd: i32, prime_fd: i32) u32 {
    if (prime_fd < 0) return 0;
    var handle: u32 = 0;
    if (c.drmPrimeFDToHandle(drm_fd, prime_fd, &handle) != 0) return 0;
    return handle;
}

pub fn closeHandles(drm_fd: i32, handles: *[4]u32) void {
    for (handles) |*handle| {
        if (handle.* == 0) continue;
        var gem_close = std.mem.zeroes(c.struct_drm_gem_close);
        gem_close.handle = handle.*;
        _ = c.drmIoctl(drm_fd, c.DRM_IOCTL_GEM_CLOSE, &gem_close);
        handle.* = 0;
    }
}

/// Import client/GBM planes and add a framebuffer. Closes handles on failure.
pub fn addFromImports(
    drm_fd: i32,
    width: u32,
    height: u32,
    format: u32,
    imports: []const Import,
    out_handles: *[4]u32,
    allow_modifiers: bool,
) ?u32 {
    var planes = Planes{};
    const count = @min(imports.len, 4);
    if (!fillHandles(drm_fd, imports[0..count], &planes)) return null;
    const fb_id = add(drm_fd, width, height, format, &planes, count, allow_modifiers) orelse {
        closeHandles(drm_fd, &planes.handles);
        return null;
    };
    out_handles.* = planes.handles;
    return fb_id;
}

pub fn remove(drm_fd: i32, fb_id: u32) void {
    if (fb_id == 0) return;
    _ = c.drmModeRmFB(drm_fd, fb_id);
}

pub fn add(
    drm_fd: i32,
    width: u32,
    height: u32,
    format: u32,
    planes: *const Planes,
    plane_count: usize,
    allow_modifiers: bool,
) ?u32 {
    const count = @min(plane_count, 4);
    if (allow_modifiers and hasExplicitModifier(planes.modifiers[0..count])) {
        if (addWithModifiers(drm_fd, width, height, format, planes)) |fb_id| return fb_id;
        if (!usesModifiers(planes.modifiers[0..count])) return addSimple(drm_fd, width, height, format, planes);
        return null;
    }
    return addSimple(drm_fd, width, height, format, planes);
}

fn fillHandles(drm_fd: i32, imports: []const Import, planes: *Planes) bool {
    if (imports.len == 0) return false;
    for (imports, 0..) |plane, index| {
        if (plane.fd < 0) {
            closeHandles(drm_fd, &planes.handles);
            return false;
        }
        const handle = importPrime(drm_fd, plane.fd);
        if (handle == 0) {
            closeHandles(drm_fd, &planes.handles);
            return false;
        }
        planes.handles[index] = handle;
        planes.pitches[index] = plane.stride;
        planes.offsets[index] = plane.offset;
        planes.modifiers[index] = plane.modifier;
    }
    return true;
}

fn addSimple(drm_fd: i32, width: u32, height: u32, format: u32, planes: *const Planes) ?u32 {
    var fb_id: u32 = 0;
    if (c.drmModeAddFB2(
        drm_fd,
        width,
        height,
        format,
        &planes.handles,
        &planes.pitches,
        &planes.offsets,
        &fb_id,
        0,
    ) != 0) return null;
    return fb_id;
}

fn addWithModifiers(drm_fd: i32, width: u32, height: u32, format: u32, planes: *const Planes) ?u32 {
    var fb_id: u32 = 0;
    if (c.drmModeAddFB2WithModifiers(
        drm_fd,
        width,
        height,
        format,
        &planes.handles,
        &planes.pitches,
        &planes.offsets,
        &planes.modifiers,
        &fb_id,
        c.DRM_MODE_FB_MODIFIERS,
    ) != 0) return null;
    return fb_id;
}

const testing = core.testing;

test "usesModifiers - linear and invalid do not force AddFB2WithModifiers" {
    try testing.expect(!usesModifiers(&.{ drm_format.MOD_LINEAR, drm_format.MOD_INVALID }));
    try testing.expect(usesModifiers(&.{drm_format.MOD_LINEAR, 0x0100000000000002}));
}

test "LINEAR explicit modifier can fall back to AddFB2" {
    try testing.expect(hasExplicitModifier(&.{drm_format.MOD_LINEAR}));
    try testing.expect(!usesModifiers(&.{drm_format.MOD_LINEAR}));
    try testing.expect(usesModifiers(&.{0x0100000000000002}));
}

test "hasExplicitModifier - LINEAR counts, INVALID does not" {
    try testing.expect(hasExplicitModifier(&.{drm_format.MOD_LINEAR}));
    try testing.expect(hasExplicitModifier(&.{0x0100000000000002}));
    try testing.expect(!hasExplicitModifier(&.{drm_format.MOD_INVALID}));
    try testing.expect(!hasExplicitModifier(&.{}));
}

test "Planes - default handles are unused" {
    const planes = Planes{};
    try testing.expectEqual(@as(u32, 0), planes.handles[0]);
    try testing.expectEqual(@as(u64, 0), planes.modifiers[0]);
}

test "importPrime - negative fd is unused" {
    try testing.expectEqual(@as(u32, 0), importPrime(-1, -1));
}
