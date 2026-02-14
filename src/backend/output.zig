//! Output management inspired by aquamarine
//! Handles display outputs, modes, and state management

const std = @import("std");
const core = @import("core");
const VTable = core.vtable.Interface;
const math = @import("core.math");
const Vector2D = math.Vec2;
const Region = math.Region;
const Mat3x3 = math.Mat3x3;
const buffer = @import("buffer.zig");
const swapchain = @import("swapchain.zig");
const misc = @import("misc.zig");

/// Output mode information
pub const Mode = struct {
    pixel_size: Vector2D = .{},
    refresh_rate: u32 = 0, // in mHz (millihertz)
    preferred: bool = false,
    drm_mode_info: ?*anyopaque = null, // drmModeModeInfo if DRM backend

    pub fn init(width: f32, height: f32, refresh: u32) Mode {
        return .{
            .pixel_size = Vector2D.init(width, height),
            .refresh_rate = refresh,
        };
    }
};

/// Output presentation mode
pub const PresentationMode = enum(u32) {
    vsync = 0,
    immediate = 1, // likely causes tearing
};

/// Subpixel layout
pub const SubpixelMode = enum(u32) {
    unknown = 0,
    none = 1,
    horizontal_rgb = 2,
    horizontal_bgr = 3,
    vertical_rgb = 4,
    vertical_bgr = 5,
};

/// Output state properties (bitmask)
pub const StateProperty = packed struct(u32) {
    damage: bool = false,
    enabled: bool = false,
    adaptive_sync: bool = false,
    presentation_mode: bool = false,
    gamma_lut: bool = false,
    mode: bool = false,
    format: bool = false,
    buffer: bool = false,
    explicit_in_fence: bool = false,
    explicit_out_fence: bool = false,
    ctm: bool = false,
    hdr: bool = false,
    degamma_lut: bool = false,
    wcg: bool = false,
    cursor_shape: bool = false,
    cursor_pos: bool = false,
    _padding: u16 = 0,
};

/// Output state management
pub const State = struct {
    committed: StateProperty = .{},
    damage: Region,
    enabled: bool = false,
    adaptive_sync: bool = false,
    presentation_mode: PresentationMode = .vsync,
    gamma_lut: std.ArrayList(u16),
    degamma_lut: std.ArrayList(u16),
    mode: ?*Mode = null,
    custom_mode: ?*Mode = null,
    drm_format: u32 = 0, // DRM_FORMAT_INVALID
    buffer: ?buffer.Interface = null,
    explicit_in_fence: i32 = -1,
    explicit_out_fence: i32 = -1,
    ctm: Mat3x3 = Mat3x3.identity(),
    wide_color_gamut: bool = false,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .damage = Region.init(allocator),
            .gamma_lut = std.ArrayList(u16){},
            .degamma_lut = std.ArrayList(u16){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.damage.deinit();
        self.gamma_lut.deinit(self.allocator);
        self.degamma_lut.deinit(self.allocator);
    }

    pub fn addDamage(self: *Self, region: Region) void {
        self.damage.add(region);
        self.committed.damage = true;
    }

    pub fn clearDamage(self: *Self) void {
        self.damage.clear();
        self.committed.damage = true;
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
        self.committed.enabled = true;
    }

    pub fn setAdaptiveSync(self: *Self, enabled: bool) void {
        self.adaptive_sync = enabled;
        self.committed.adaptive_sync = true;
    }

    pub fn setPresentationMode(self: *Self, mode: PresentationMode) void {
        self.presentation_mode = mode;
        self.committed.presentation_mode = true;
    }

    pub fn setGammaLut(self: *Self, lut: []const u16) !void {
        self.gamma_lut.clearRetainingCapacity();
        try self.gamma_lut.appendSlice(self.allocator, lut);
        self.committed.gamma_lut = true;
    }

    pub fn setDeGammaLut(self: *Self, lut: []const u16) !void {
        self.degamma_lut.clearRetainingCapacity();
        try self.degamma_lut.appendSlice(self.allocator, lut);
        self.committed.degamma_lut = true;
    }

    pub fn setMode(self: *Self, mode: *Mode) void {
        self.mode = mode;
        self.custom_mode = null;
        self.committed.mode = true;
    }

    pub fn setCustomMode(self: *Self, mode: *Mode) void {
        self.mode = null;
        self.custom_mode = mode;
        self.committed.mode = true;
    }

    pub fn setFormat(self: *Self, format: u32) void {
        self.drm_format = format;
        self.committed.format = true;
    }

    pub fn setBuffer(self: *Self, buf: buffer.Interface) void {
        self.buffer = buf;
        self.committed.buffer = true;
    }

    pub fn setExplicitInFence(self: *Self, fence_fd: i32) void {
        self.explicit_in_fence = fence_fd;
        self.committed.explicit_in_fence = true;
    }

    pub fn enableExplicitOutFence(self: *Self) void {
        self.committed.explicit_out_fence = true;
    }

    pub fn resetExplicitFences(self: *Self) void {
        self.explicit_in_fence = -1;
        self.explicit_out_fence = -1;
    }

    pub fn setCTM(self: *Self, ctm: Mat3x3) void {
        self.ctm = ctm;
        self.committed.ctm = true;
    }

    pub fn setWideColorGamut(self: *Self, wcg: bool) void {
        self.wide_color_gamut = wcg;
        self.committed.wcg = true;
    }

    pub fn onCommit(self: *Self) void {
        self.committed = .{};
        _ = self.damage.clear();
    }
};

/// Schedule frame reason
pub const ScheduleReason = enum(u32) {
    unknown = 0,
    new_connector = 1,
    cursor_visible = 2,
    cursor_shape = 3,
    cursor_move = 4,
    client_unknown = 5,
    damage = 6,
    new_monitor = 7,
    render_monitor = 8,
    needs_frame = 9,
    animation = 10,
    animation_damage = 11,
};

/// Output interface
pub const IOutput = struct {
    base: VTable(VTableDef),

    pub const VTableDef = struct {
        commit: *const fn (ptr: *anyopaque) bool,
        test_commit: *const fn (ptr: *anyopaque) bool,
        get_backend: *const fn (ptr: *anyopaque) ?*anyopaque,
        get_render_formats: *const fn (ptr: *anyopaque) []const misc.DRMFormat,
        preferred_mode: *const fn (ptr: *anyopaque) ?*Mode,
        set_cursor: *const fn (ptr: *anyopaque, buffer: buffer.Interface, hotspot: Vector2D) bool,
        move_cursor: *const fn (ptr: *anyopaque, coord: Vector2D, skip_schedule: bool) void,
        set_cursor_visible: *const fn (ptr: *anyopaque, visible: bool) void,
        cursor_plane_size: *const fn (ptr: *anyopaque) Vector2D,
        schedule_frame: *const fn (ptr: *anyopaque, reason: ScheduleReason) void,
        get_gamma_size: *const fn (ptr: *anyopaque) usize,
        get_degamma_size: *const fn (ptr: *anyopaque) usize,
        destroy: *const fn (ptr: *anyopaque) bool,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Self = @This();

    pub fn init(ptr: anytype, vtable: *const VTableDef) Self {
        return .{ .base = VTable(VTableDef).init(ptr, vtable) };
    }

    pub fn commit(self: Self) bool {
        return self.base.vtable.commit(self.base.ptr);
    }

    pub fn testCommit(self: Self) bool {
        return self.base.vtable.test_commit(self.base.ptr);
    }

    pub fn getBackend(self: Self) ?*anyopaque {
        return self.base.vtable.get_backend(self.base.ptr);
    }

    pub fn getRenderFormats(self: Self) []const misc.DRMFormat {
        return self.base.vtable.get_render_formats(self.base.ptr);
    }

    pub fn preferredMode(self: Self) ?*Mode {
        return self.base.vtable.preferred_mode(self.base.ptr);
    }

    pub fn setCursor(self: Self, buf: buffer.Interface, hotspot: Vector2D) bool {
        return self.base.vtable.set_cursor(self.base.ptr, buf, hotspot);
    }

    pub fn moveCursor(self: Self, coord: Vector2D, skip_schedule: bool) void {
        self.base.vtable.move_cursor(self.base.ptr, coord, skip_schedule);
    }

    pub fn setCursorVisible(self: Self, visible: bool) void {
        self.base.vtable.set_cursor_visible(self.base.ptr, visible);
    }

    pub fn cursorPlaneSize(self: Self) Vector2D {
        return self.base.vtable.cursor_plane_size(self.base.ptr);
    }

    pub fn scheduleFrame(self: Self, reason: ScheduleReason) void {
        self.base.vtable.schedule_frame(self.base.ptr, reason);
    }

    pub fn getGammaSize(self: Self) usize {
        return self.base.vtable.get_gamma_size(self.base.ptr);
    }

    pub fn getDeGammaSize(self: Self) usize {
        return self.base.vtable.get_degamma_size(self.base.ptr);
    }

    pub fn destroy(self: Self) bool {
        return self.base.vtable.destroy(self.base.ptr);
    }

    pub fn deinit(self: Self) void {
        self.base.vtable.deinit(self.base.ptr);
    }
};

const testing = core.testing;

// Tests
test "Mode - initialization" {
    const mode = Mode.init(1920, 1080, 60000); // 60Hz in mHz
    try testing.expectEqual(Vector2D.init(1920, 1080), mode.pixel_size);
    try testing.expectEqual(@as(u32, 60000), mode.refresh_rate);
    try testing.expectEqual(false, mode.preferred);
}

test "State - initialization and cleanup" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try testing.expectEqual(false, state.enabled);
    try testing.expectEqual(PresentationMode.vsync, state.presentation_mode);
    try testing.expectEqual(@as(u32, 0), state.drm_format);
}

test "State - setEnabled marks committed" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    try testing.expectFalse(state.committed.enabled);

    state.setEnabled(true);
    try testing.expect(state.enabled);
    try testing.expect(state.committed.enabled);
}

test "State - setMode vs setCustomMode" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    var mode1 = Mode.init(1920, 1080, 60000);
    var mode2 = Mode.init(3840, 2160, 144000);

    state.setMode(&mode1);
    try testing.expectEqual(&mode1, state.mode);
    try testing.expectNull(state.custom_mode);
    try testing.expect(state.committed.mode);

    state.setCustomMode(&mode2);
    try testing.expectNull(state.mode);
    try testing.expectEqual(&mode2, state.custom_mode);
}

test "State - gamma LUT management" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    const lut = [_]u16{ 0, 256, 512, 768, 1024 };
    try state.setGammaLut(&lut);

    try testing.expectEqual(@as(usize, 5), state.gamma_lut.items.len);
    try testing.expect(state.committed.gamma_lut);
    try testing.expectEqual(@as(u16, 512), state.gamma_lut.items[2]);
}

test "State - onCommit clears committed flags" {
    var state = State.init(testing.allocator);
    defer state.deinit();

    state.setEnabled(true);
    state.setFormat(0x34325258);

    try testing.expect(state.committed.enabled);
    try testing.expect(state.committed.format);

    state.onCommit();

    try testing.expectFalse(state.committed.enabled);
    try testing.expectFalse(state.committed.format);
}

test "SubpixelMode - enum values" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(SubpixelMode.unknown));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(SubpixelMode.none));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(SubpixelMode.horizontal_rgb));
}

test "ScheduleReason - enum values" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(ScheduleReason.unknown));
    try testing.expectEqual(@as(u32, 6), @intFromEnum(ScheduleReason.damage));
    try testing.expectEqual(@as(u32, 11), @intFromEnum(ScheduleReason.animation_damage));
}
