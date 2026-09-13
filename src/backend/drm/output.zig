//! DRM/KMS output: dumb-buffer scanout and atomic commits

const std = @import("std");
const string = @import("core.string").string;
const core = @import("core");
const cli = @import("core.cli");
const math = @import("core.math");
const Vector2D = math.Vec2;
const buffer = @import("../buffer.zig");
const output = @import("../output.zig");
const drm = @import("root.zig");
const drm_format = @import("format.zig");
const drm_fb = @import("fb.zig");
const vulkan = @import("../vulkan.zig");

const c = @cImport({
    @cInclude("drm.h");
    @cInclude("drm_mode.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

const DRM_MODE_ATOMIC_NONBLOCK: u32 = 0x0200;
const DRM_MODE_ATOMIC_ALLOW_MODESET: u32 = 0x0400;
const DRM_MODE_PAGE_FLIP_EVENT: u32 = 0x01;
const DRM_MODE_PAGE_FLIP_ASYNC: u32 = 0x02;

const DumbSlot = struct {
    handle: u32 = 0,
    pitch: u32 = 0,
    size: u64 = 0,
    fb_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    map: []align(std.heap.page_size_min) u8 = &.{},
};

const ScanoutFlags = packed struct {
    waiting_flip: bool = false,
    modeset_done: bool = false,
};

pub const Output = struct {
    name: string,
    backend: *drm.Backend,
    connector: *drm.Connector,
    allocator: std.mem.Allocator,
    state: output.State,
    needs_frame: bool = false,
    frame_scheduled: bool = false,
    flags: ScanoutFlags = .{},
    slots: [2]DumbSlot = .{ .{}, .{} },
    gpu_slots: [2]vulkan.Slot = .{ .{}, .{} },
    front: u1 = 0,
    mode_blob_id: u32 = 0,
    hdr_blob_id: u32 = 0,
    retired_hdr_blob: u32 = 0,
    hdr_engaged: bool = false,
    pending_hdr: PendingHdr = .{},
    encoded_hdr: PendingHdr = .{},
    client_scanout: ClientFb = .{},
    pending_client_fb: u32 = 0,
    atomic: drm.AtomicRequest,
    frame_event_callback: ?*const fn (userdata: ?*anyopaque) void = null,
    frame_event_userdata: ?*anyopaque = null,
    destroy_event_callback: ?*const fn (userdata: ?*anyopaque) void = null,
    destroy_event_userdata: ?*anyopaque = null,

    pub const PendingHdr = struct {
        enable: bool = false,
        eotf: u8 = 0,
        max_cll: u16 = 0,
        max_fall: u16 = 0,
        max_mastering: u16 = 0,
        min_mastering: u16 = 0,
        tearing: bool = false,

        fn sameBlob(self: PendingHdr, other: PendingHdr) bool {
            return self.enable == other.enable and
                self.eotf == other.eotf and
                self.max_cll == other.max_cll and
                self.max_fall == other.max_fall and
                self.max_mastering == other.max_mastering and
                self.min_mastering == other.min_mastering;
        }
    };

    pub const ClientPlane = struct {
        fd: i32 = -1,
        stride: u32 = 0,
        offset: u32 = 0,
        modifier: u64 = 0,
    };

    const ClientFb = struct {
        key: usize = 0,
        fb_id: u32 = 0,
        width: u32 = 0,
        height: u32 = 0,
        format: u32 = 0,
        handles: [4]u32 = .{ 0, 0, 0, 0 },
    };

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, be: *drm.Backend, connector: *drm.Connector) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, connector.name);
        errdefer allocator.free(name_copy);

        self.* = .{
            .name = name_copy,
            .backend = be,
            .connector = connector,
            .allocator = allocator,
            .state = output.State.init(allocator),
            .atomic = drm.AtomicRequest.init(allocator, be),
        };
        errdefer {
            self.atomic.deinit();
            self.state.deinit();
        }
        if (self.atomic.request == null) return error.OutOfMemory;
        if (self.preferredMode()) |mode| self.state.mode = mode;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.destroyGpuSlots();
        self.destroySlots();
        self.destroyModeBlob(self.backend.drm_fd);
        self.destroyHdrBlob(self.backend.drm_fd);
        self.dropClientScanout(self.backend.drm_fd);
        self.atomic.deinit();
        self.state.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn setFrameCallback(self: *Self, callback: *const fn (userdata: ?*anyopaque) void, userdata: ?*anyopaque) void {
        self.frame_event_callback = callback;
        self.frame_event_userdata = userdata;
    }

    pub fn setDestroyCallback(self: *Self, callback: *const fn (userdata: ?*anyopaque) void, userdata: ?*anyopaque) void {
        self.destroy_event_callback = callback;
        self.destroy_event_userdata = userdata;
    }

    pub fn clearFrameCallback(self: *Self) void {
        self.frame_event_callback = null;
        self.frame_event_userdata = null;
    }

    pub fn clearDestroyCallback(self: *Self) void {
        self.destroy_event_callback = null;
        self.destroy_event_userdata = null;
    }

    pub fn logicalSize(self: *const Self) struct { width: i32, height: i32 } {
        const mode = self.preferredMode() orelse return .{ .width = 1920, .height = 1080 };
        return .{
            .width = @intFromFloat(mode.pixel_size.getX()),
            .height = @intFromFloat(mode.pixel_size.getY()),
        };
    }

    pub fn preferredMode(self: *const Self) ?*output.Mode {
        var fallback: ?*output.Mode = null;
        var progressive: ?*output.Mode = null;
        for (self.connector.modes.items) |*mode| {
            const friendly = modeIsProgressive(mode);
            if (mode.preferred and friendly) return mode;
            if (friendly and progressive == null) progressive = mode;
            if (fallback == null) fallback = mode;
        }
        return progressive orelse fallback;
    }

    pub fn commit(self: *Self) bool {
        if (!canCommitScanout(self.flags.waiting_flip, self.backend.seat_paused)) return false;
        if (takePendingClientFb(&self.pending_client_fb)) |fb_id| return self.commitExternal(fb_id);
        const buf = self.state.buffer orelse return self.finishCommit();
        if (self.commitDmabuf(buf)) return true;
        if (self.commitGpu(buf)) return true;
        return self.commitDumb(buf);
    }

    pub fn testCommit(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn scheduleFrame(self: *Self, reason: output.ScheduleReason) void {
        _ = reason;
        if (self.frame_scheduled or self.flags.waiting_flip) {
            self.needs_frame = true;
            return;
        }
        self.needs_frame = false;
        self.frame_scheduled = true;
        self.invokeFrame();
    }

    pub fn handlePageFlip(self: *Self) void {
        std.debug.assert(self.flags.waiting_flip);
        self.flags.waiting_flip = false;
        if (!self.needs_frame) return;
        self.needs_frame = false;
        self.frame_scheduled = true;
        self.invokeFrame();
    }

    pub fn invokeFrame(self: *Self) void {
        self.frame_scheduled = false;
        const callback = self.frame_event_callback orelse return;
        callback(self.frame_event_userdata);
    }

    fn finishCommit(self: *Self) bool {
        self.state.onCommit();
        return true;
    }

    fn commitExternal(self: *Self, fb_id: u32) bool {
        return self.commitFlip(fb_id, null);
    }

    fn commitDumb(self: *Self, buf: buffer.Interface) bool {
        const pixels = buf.beginDataPtr(0);
        defer buf.endDataPtr();
        const src = pixels.ptr orelse return false;
        const shm = buf.shm();
        if (!shm.success) return false;
        const size = self.scanoutSize(shm.size) orelse return false;
        const bytes = pixels.size;
        if (bytes == 0) return false;
        std.debug.assert(!self.flags.waiting_flip);
        const back: u1 = self.front +% 1;
        if (!self.prepareBackSlot(back, size.width, size.height)) return false;
        std.debug.assert(slotReady(self.slots[back], size.width, size.height));
        if (!copyScanout(self.slots[back].map, self.slots[back].pitch, src[0..bytes], @intCast(shm.stride), size.width, size.height))
            return false;
        return self.commitFlip(self.slots[back].fb_id, back);
    }

    fn commitGpu(self: *Self, buf: buffer.Interface) bool {
        const gpu = self.backend.gpu orelse return false;
        const pixels = buf.beginDataPtr(0);
        defer buf.endDataPtr();
        const src = pixels.ptr orelse return false;
        const shm = buf.shm();
        if (!shm.success) return false;
        const size = self.scanoutSize(shm.size) orelse return false;
        std.debug.assert(!self.flags.waiting_flip);
        const back: u1 = self.front +% 1;
        if (!self.prepareGpuSlot(gpu, back, size.width, size.height, shm.format)) return false;
        std.debug.assert(vulkan.slotReady(self.gpu_slots[back], size.width, size.height, shm.format));
        const bytes = pixels.size;
        if (bytes == 0) return false;
        if (!gpu.upload(&self.gpu_slots[back], src[0..bytes], @intCast(shm.stride))) return false;
        return self.commitFlip(self.gpu_slots[back].fb_id, back);
    }

    fn commitDmabuf(self: *Self, buf: buffer.Interface) bool {
        const attrs = buf.dmabuf();
        if (!attrs.success or attrs.fds[0] < 0) return false;
        const size = self.scanoutSize(attrs.size) orelse return false;
        var planes = [_]ClientPlane{.{}} ** 4;
        const count = fillDmabufPlanes(attrs, &planes);
        const key: usize = @intFromPtr(buf.base.ptr);
        if (!self.bindClientScanout(key, size.width, size.height, attrs.format, planes[0..count])) return false;
        const fb_id = takePendingClientFb(&self.pending_client_fb) orelse return false;
        return self.commitExternal(fb_id);
    }

    fn commitFlip(self: *Self, fb_id: u32, front: ?u1) bool {
        std.debug.assert(!self.flags.waiting_flip);
        const expect_flip = shouldWaitForFlip(self.flags.modeset_done);
        if (!self.atomicCommit(self.backend.drm_fd, fb_id)) return false;
        if (front) |index| self.front = index;
        self.flags.waiting_flip = expect_flip;
        return self.finishCommit();
    }

    fn scanoutSize(self: *const Self, buffer_size: Vector2D) ?struct { width: u32, height: u32 } {
        const mode_size = self.logicalSize();
        const width: u32 = @intFromFloat(buffer_size.getX());
        const height: u32 = @intFromFloat(buffer_size.getY());
        if (!scanoutMatchesMode(width, height, mode_size.width, mode_size.height)) return null;
        return .{ .width = width, .height = height };
    }

    pub fn preheatHdr(self: *Self) void {
        if (self.pending_hdr.enable) _ = self.ensureHdrBlob(self.backend.drm_fd);
    }

    /// Control plane only: create scanout slots before the first flip.
    pub fn preheatScanout(self: *Self) void {
        const size = self.logicalSize();
        if (size.width <= 0 or size.height <= 0) return;
        const width: u32 = @intCast(size.width);
        const height: u32 = @intCast(size.height);
        const gpu_ready = if (self.backend.gpu) |gpu|
            self.prepareGpuSlot(gpu, 0, width, height, drm_format.XRGB8888)
        else
            false;
        if (!gpu_ready) _ = self.preheatSlots(width, height);
    }

    pub fn bindClientScanout(
        self: *Self,
        key: usize,
        width: u32,
        height: u32,
        format: u32,
        planes: []const ClientPlane,
    ) bool {
        if (self.clientFbMatches(key, width, height, format)) {
            self.pending_client_fb = self.client_scanout.fb_id;
            return true;
        }
        self.dropClientScanout(self.backend.drm_fd);
        const fb_id = addClientFb(
            self.backend.drm_fd,
            width,
            height,
            format,
            planes,
            &self.client_scanout.handles,
            self.backend.capabilities.supports_add_fb2_modifiers,
        ) orelse
            return false;
        self.client_scanout = .{
            .key = key,
            .fb_id = fb_id,
            .width = width,
            .height = height,
            .format = format,
            .handles = self.client_scanout.handles,
        };
        self.pending_client_fb = fb_id;
        return true;
    }

    fn clientFbMatches(self: *const Self, key: usize, width: u32, height: u32, format: u32) bool {
        return self.client_scanout.key == key and
            self.client_scanout.fb_id != 0 and
            self.client_scanout.width == width and
            self.client_scanout.height == height and
            self.client_scanout.format == format;
    }

    fn dropClientScanout(self: *Self, drm_fd: i32) void {
        if (self.client_scanout.fb_id != 0) drm_fb.remove(drm_fd, self.client_scanout.fb_id);
        closeGemHandles(drm_fd, &self.client_scanout.handles);
        self.client_scanout = .{};
        self.pending_client_fb = 0;
    }

    fn prepareBackSlot(self: *Self, index: u1, width: u32, height: u32) bool {
        if (slotReady(self.slots[index], width, height)) return true;
        if (scanoutNeedsReset(self.flags.modeset_done, self.slots[self.front], self.gpu_slots[self.front], width, height, 0))
            self.resetScanout();
        if (self.flags.modeset_done) return false;
        return self.preheatSlots(width, height);
    }

    fn resetScanout(self: *Self) void {
        std.debug.assert(!self.flags.waiting_flip);
        self.flags.modeset_done = false;
        self.destroySlots();
        self.destroyGpuSlots();
        self.destroyModeBlob(self.backend.drm_fd);
    }

    fn preheatSlots(self: *Self, width: u32, height: u32) bool {
        return self.ensureSlot(0, width, height) and self.ensureSlot(1, width, height);
    }

    /// Control plane only: create or resize a dumb slot. Do not call on the flip path.
    fn ensureSlot(self: *Self, index: u1, width: u32, height: u32) bool {
        const slot = &self.slots[index];
        if (slotReady(slot.*, width, height)) return true;
        destroyDumb(self.backend.drm_fd, slot);
        slot.* = createDumb(self.backend.drm_fd, width, height) catch return false;
        return true;
    }

    fn atomicCommit(self: *Self, drm_fd: i32, fb_id: u32) bool {
        const crtc = self.connector.crtc orelse return false;
        std.debug.assert(crtc.primary != null);
        const plane = crtc.primary orelse return false;
        const size = self.logicalSize();
        self.atomic.reset();

        if (!self.attachModeset(&self.atomic, crtc, drm_fd)) return false;
        self.applyColor(&self.atomic, drm_fd);

        self.atomic.setPlaneProps(
            plane,
            fb_id,
            crtc.id,
            Vector2D.init(0, 0),
            Vector2D.init(@floatFromInt(size.width), @floatFromInt(size.height)),
        );

        if (!self.atomic.commit(
            atomicFlags(self.flags.modeset_done, self.pending_hdr.enable and self.pending_hdr.tearing),
            drm_fd,
            self,
        )) return false;
        self.finishColor(drm_fd);
        self.flags.modeset_done = true;
        return true;
    }

    fn applyColor(self: *Self, request: *drm.AtomicRequest, drm_fd: i32) void {
        const conn = self.connector;
        if (self.pending_hdr.enable) {
            if (self.hdr_blob_id == 0) _ = self.ensureHdrBlob(drm_fd);
            if (self.hdr_blob_id == 0) return;
            if (conn.props.hdr_output_metadata != 0)
                request.add(conn.id, conn.props.hdr_output_metadata, self.hdr_blob_id);
            if (conn.props.colorspace != 0)
                request.add(conn.id, conn.props.colorspace, conn.colorspace_bt2020_rgb);
            self.addColorBpc(request, true);
            return;
        }
        if (!self.hdr_engaged and self.hdr_blob_id == 0) return;
        if (conn.props.hdr_output_metadata != 0)
            request.add(conn.id, conn.props.hdr_output_metadata, 0);
        if (conn.props.colorspace != 0)
            request.add(conn.id, conn.props.colorspace, conn.colorspace_default);
        self.addColorBpc(request, false);
    }

    fn finishColor(self: *Self, drm_fd: i32) void {
        self.destroyRetiredHdr(drm_fd);
        if (self.pending_hdr.enable) {
            self.hdr_engaged = true;
            return;
        }
        self.hdr_engaged = false;
        self.destroyHdrBlob(drm_fd);
    }

    fn ensureHdrBlob(self: *Self, drm_fd: i32) bool {
        if (self.hdr_blob_id != 0 and self.encoded_hdr.sameBlob(self.pending_hdr)) return true;
        var meta = encodeHdr(self.pending_hdr);
        var blob_id: u32 = 0;
        if (c.drmModeCreatePropertyBlob(drm_fd, &meta, @sizeOf(@TypeOf(meta)), &blob_id) != 0)
            return false;
        const previous = self.hdr_blob_id;
        self.hdr_blob_id = blob_id;
        self.encoded_hdr = self.pending_hdr;
        self.queueRetiredHdr(drm_fd, previous);
        return true;
    }

    fn queueRetiredHdr(self: *Self, drm_fd: i32, previous: u32) void {
        if (previous == 0) return;
        if (self.retired_hdr_blob != 0) _ = c.drmModeDestroyPropertyBlob(drm_fd, previous);
        if (self.retired_hdr_blob == 0) self.retired_hdr_blob = previous;
    }

    fn destroyRetiredHdr(self: *Self, drm_fd: i32) void {
        if (self.retired_hdr_blob == 0) return;
        _ = c.drmModeDestroyPropertyBlob(drm_fd, self.retired_hdr_blob);
        self.retired_hdr_blob = 0;
    }

    fn destroyHdrBlob(self: *Self, drm_fd: i32) void {
        self.destroyRetiredHdr(drm_fd);
        if (self.hdr_blob_id == 0) return;
        _ = c.drmModeDestroyPropertyBlob(drm_fd, self.hdr_blob_id);
        self.hdr_blob_id = 0;
        self.encoded_hdr = .{};
    }

    fn addColorBpc(self: *Self, request: *drm.AtomicRequest, hdr: bool) void {
        if (self.connector.props.max_bpc == 0 or self.connector.max_bpc_max == 0) return;
        const want: u64 = if (hdr) 10 else 8;
        const bpc = std.math.clamp(want, self.connector.max_bpc_min, self.connector.max_bpc_max);
        request.add(self.connector.id, self.connector.props.max_bpc, bpc);
    }

    fn attachModeset(self: *Self, request: *drm.AtomicRequest, crtc: *drm.CRTC, drm_fd: i32) bool {
        if (self.flags.modeset_done) return true;
        if (self.connector.props.crtc_id == 0 or crtc.props.mode_id == 0 or crtc.props.active == 0) return false;
        if (!self.ensureModeBlob(drm_fd)) return false;
        request.add(self.connector.id, self.connector.props.crtc_id, crtc.id);
        request.add(crtc.id, crtc.props.mode_id, self.mode_blob_id);
        request.add(crtc.id, crtc.props.active, 1);
        self.addMaxBpc(request);
        return true;
    }

    fn addMaxBpc(self: *Self, request: *drm.AtomicRequest) void {
        if (self.connector.props.max_bpc == 0 or self.connector.max_bpc_max == 0) return;
        const bpc = std.math.clamp(@as(u64, 8), self.connector.max_bpc_min, self.connector.max_bpc_max);
        request.add(self.connector.id, self.connector.props.max_bpc, bpc);
    }

    fn ensureModeBlob(self: *Self, drm_fd: i32) bool {
        if (self.mode_blob_id != 0) return true;
        const mode = self.preferredMode() orelse return false;
        const info_ptr = mode.drm_mode_info orelse return false;
        const info: *c.drmModeModeInfo = @ptrCast(@alignCast(info_ptr));
        if (c.drmModeCreatePropertyBlob(drm_fd, info, @sizeOf(c.drmModeModeInfo), &self.mode_blob_id) != 0) {
            return false;
        }
        return true;
    }

    fn destroyModeBlob(self: *Self, drm_fd: i32) void {
        if (self.mode_blob_id == 0) return;
        _ = c.drmModeDestroyPropertyBlob(drm_fd, self.mode_blob_id);
        self.mode_blob_id = 0;
    }

    fn destroySlots(self: *Self) void {
        destroyDumb(self.backend.drm_fd, &self.slots[0]);
        destroyDumb(self.backend.drm_fd, &self.slots[1]);
    }

    fn destroyGpuSlots(self: *Self) void {
        const gpu = self.backend.gpu orelse return;
        gpu.destroySlot(&self.gpu_slots[0], self.backend.drm_fd);
        gpu.destroySlot(&self.gpu_slots[1], self.backend.drm_fd);
    }

    fn prepareGpuSlot(self: *Self, gpu: *vulkan.Device, index: u1, width: u32, height: u32, format: u32) bool {
        const fourcc = if (format != 0) format else drm_format.XRGB8888;
        if (vulkan.slotReady(self.gpu_slots[index], width, height, fourcc)) return true;
        if (scanoutNeedsReset(self.flags.modeset_done, self.slots[self.front], self.gpu_slots[self.front], width, height, fourcc))
            self.resetScanout();
        if (self.flags.modeset_done) return false;
        const allow_modifiers = self.backend.capabilities.supports_add_fb2_modifiers;
        return gpu.ensureSlot(
            &self.gpu_slots[index],
            self.backend.drm_fd,
            width,
            height,
            fourcc,
            self.modifiersFor(fourcc),
            allow_modifiers,
        ) and gpu.ensureSlot(
            &self.gpu_slots[index +% 1],
            self.backend.drm_fd,
            width,
            height,
            fourcc,
            self.modifiersFor(fourcc),
            allow_modifiers,
        );
    }

    fn modifiersFor(self: *const Self, format: u32) []const u64 {
        for (self.backend.primary_formats.items) |fmt| {
            if (fmt.drm_format == format) return fmt.modifiers.items;
        }
        return &.{};
    }

    pub fn iface(self: *Self) output.IOutput {
        return output.IOutput.init(self, &.{
            .commit = commitFn,
            .test_commit = testCommitFn,
            .get_backend = getBackendFn,
            .get_render_formats = getRenderFormatsFn,
            .preferred_mode = preferredModeFn,
            .set_cursor = setCursorFn,
            .move_cursor = moveCursorFn,
            .set_cursor_visible = setCursorVisibleFn,
            .cursor_plane_size = cursorPlaneSizeFn,
            .schedule_frame = scheduleFrameFn,
            .get_gamma_size = getGammaSizeFn,
            .get_degamma_size = getDeGammaSizeFn,
            .set_buffer = setBufferFn,
            .destroy = destroyFn,
            .deinit = deinitFn,
            .clear_frame_callback = clearFrameCallbackFn,
            .clear_destroy_callback = clearDestroyCallbackFn,
        });
    }

    fn commitFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.commit();
    }

    fn testCommitFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.testCommit();
    }

    fn getBackendFn(ptr: *anyopaque) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return @ptrCast(self.backend);
    }

    fn getRenderFormatsFn(ptr: *anyopaque) []const @import("../misc.zig").DRMFormat {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.backend.primary_formats.items;
    }

    fn preferredModeFn(ptr: *anyopaque) ?*output.Mode {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.preferredMode();
    }

    fn setCursorFn(_: *anyopaque, _: buffer.Interface, _: Vector2D) bool {
        return false;
    }

    fn moveCursorFn(_: *anyopaque, _: Vector2D, _: bool) void {}

    fn setCursorVisibleFn(_: *anyopaque, _: bool) void {}

    fn cursorPlaneSizeFn(_: *anyopaque) Vector2D {
        return Vector2D.init(-1, -1);
    }

    fn scheduleFrameFn(ptr: *anyopaque, reason: output.ScheduleReason) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.scheduleFrame(reason);
    }

    fn getGammaSizeFn(_: *anyopaque) usize {
        return 0;
    }

    fn getDeGammaSizeFn(_: *anyopaque) usize {
        return 0;
    }

    fn setBufferFn(ptr: *anyopaque, buf: buffer.Interface) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.state.setBuffer(buf);
    }

    fn destroyFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.destroy_event_callback) |callback| callback(self.destroy_event_userdata);
        return true;
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn clearFrameCallbackFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.clearFrameCallback();
    }

    fn clearDestroyCallbackFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.clearDestroyCallback();
    }
};

fn createDumb(fd: i32, width: u32, height: u32) !DumbSlot {
    var create = std.mem.zeroes(c.struct_drm_mode_create_dumb);
    create.width = width;
    create.height = height;
    create.bpp = 32;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) return error.CreateDumbFailed;

    var slot = DumbSlot{
        .handle = create.handle,
        .pitch = create.pitch,
        .size = create.size,
        .width = width,
        .height = height,
    };
    errdefer destroyDumb(fd, &slot);

    const planes = drm_fb.Planes{
        .handles = .{ create.handle, 0, 0, 0 },
        .pitches = .{ create.pitch, 0, 0, 0 },
    };
    slot.fb_id = drm_fb.add(fd, width, height, drm_format.XRGB8888, &planes, 1, false) orelse
        return error.AddFbFailed;

    var map_arg = std.mem.zeroes(c.struct_drm_mode_map_dumb);
    map_arg.handle = create.handle;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map_arg) != 0) return error.MapDumbFailed;

    const mapped = std.posix.mmap(
        null,
        @intCast(create.size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        @intCast(map_arg.offset),
    ) catch return error.MmapFailed;
    slot.map = mapped;
    return slot;
}

fn destroyDumb(fd: i32, slot: *DumbSlot) void {
    if (slot.map.len > 0) {
        std.posix.munmap(slot.map);
        slot.map = &.{};
    }
    if (slot.fb_id != 0) {
        drm_fb.remove(fd, slot.fb_id);
        slot.fb_id = 0;
    }
    if (slot.handle != 0) {
        var destroy = std.mem.zeroes(c.struct_drm_mode_destroy_dumb);
        destroy.handle = slot.handle;
        _ = c.drmIoctl(fd, c.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
        slot.handle = 0;
    }
}

fn modeIsProgressive(mode: *const output.Mode) bool {
    const info_ptr = mode.drm_mode_info orelse return true;
    const info: *const c.drmModeModeInfo = @ptrCast(@alignCast(info_ptr));
    const interlaced = (info.flags & c.DRM_MODE_FLAG_INTERLACE) != 0;
    const dblscan = (info.flags & c.DRM_MODE_FLAG_DBLSCAN) != 0;
    return !interlaced and !dblscan;
}

fn copyScanout(dest: []u8, dest_pitch: u32, src: []const u8, src_stride: u32, width: u32, height: u32) bool {
    const row_bytes: usize = @as(usize, width) * 4;
    if (src_stride < row_bytes) return false;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_off: usize = @as(usize, y) * src_stride;
        const dst_off: usize = @as(usize, y) * dest_pitch;
        if (src_off + row_bytes > src.len or dst_off + row_bytes > dest.len) return false;
        @memcpy(dest[dst_off..][0..row_bytes], src[src_off..][0..row_bytes]);
    }
    return true;
}

fn slotReady(slot: DumbSlot, width: u32, height: u32) bool {
    return slot.fb_id != 0 and slot.width == width and slot.height == height;
}

fn scanoutMatchesMode(buffer_w: u32, buffer_h: u32, mode_w: i32, mode_h: i32) bool {
    return buffer_w == @as(u32, @intCast(mode_w)) and buffer_h == @as(u32, @intCast(mode_h));
}

fn scanoutNeedsReset(
    modeset_done: bool,
    dumb: DumbSlot,
    gpu: vulkan.Slot,
    width: u32,
    height: u32,
    format: u32,
) bool {
    if (!modeset_done) return false;
    if (dumb.fb_id != 0 and (dumb.width != width or dumb.height != height)) return true;
    return gpuSlotMismatch(gpu, width, height, format);
}

fn gpuSlotMismatch(slot: vulkan.Slot, width: u32, height: u32, format: u32) bool {
    if (slot.fb_id == 0) return false;
    if (slot.width != width or slot.height != height) return true;
    return format != 0 and slot.format != format;
}

fn atomicFlags(modeset_done: bool, async_flip: bool) u32 {
    if (!modeset_done) return DRM_MODE_ATOMIC_ALLOW_MODESET;
    var flags: u32 = DRM_MODE_PAGE_FLIP_EVENT | DRM_MODE_ATOMIC_NONBLOCK;
    if (async_flip) flags |= DRM_MODE_PAGE_FLIP_ASYNC;
    return flags;
}

const HdrBlob = extern struct {
    metadata_type: u32 = 1,
    eotf: u8 = 0,
    static_type: u8 = 1,
    primaries: [3][2]u16 = .{
        .{ 35400, 14600 },
        .{ 8500, 39850 },
        .{ 6550, 2300 },
    },
    white: [2]u16 = .{ 15635, 16450 },
    max_mastering: u16 = 1000,
    min_mastering: u16 = 50,
    max_cll: u16 = 1000,
    max_fall: u16 = 400,
};

fn addClientFb(
    drm_fd: i32,
    width: u32,
    height: u32,
    format: u32,
    planes: []const Output.ClientPlane,
    out_handles: *[4]u32,
    allow_modifiers: bool,
) ?u32 {
    if (!clientPlanesHaveModifiers(planes)) return null;
    var imports: [4]drm_fb.Import = .{ .{}, .{}, .{}, .{} };
    const count = @min(planes.len, imports.len);
    for (planes[0..count], 0..) |plane, index| {
        imports[index] = .{
            .fd = plane.fd,
            .stride = plane.stride,
            .offset = plane.offset,
            .modifier = plane.modifier,
        };
    }
    return drm_fb.addFromImports(drm_fd, width, height, format, imports[0..count], out_handles, allow_modifiers);
}

fn closeGemHandles(drm_fd: i32, handles: *[4]u32) void {
    drm_fb.closeHandles(drm_fd, handles);
}

/// Client KMS FBs must carry LINEAR or a vendor modifier, never `MOD_INVALID`.
fn clientPlanesHaveModifiers(planes: []const Output.ClientPlane) bool {
    if (planes.len == 0) return false;
    for (planes) |plane| {
        if (plane.modifier == drm_format.MOD_INVALID) return false;
    }
    return true;
}

fn fillDmabufPlanes(attrs: buffer.DMABUFAttrs, planes: *[4]Output.ClientPlane) usize {
    const count: usize = @intCast(@min(@max(attrs.planes, 0), 4));
    var index: usize = 0;
    while (index < count) : (index += 1) {
        planes[index] = .{
            .fd = attrs.fds[index],
            .stride = attrs.strides[index],
            .offset = attrs.offsets[index],
            .modifier = attrs.modifier,
        };
    }
    return count;
}

/// Consume a one-shot client FB id so a later SHM frame cannot reuse it.
fn takePendingClientFb(pending: *u32) ?u32 {
    const fb_id = pending.*;
    pending.* = 0;
    if (fb_id == 0) return null;
    return fb_id;
}

fn encodeHdr(pending: Output.PendingHdr) HdrBlob {
    return .{
        .eotf = pending.eotf,
        .max_mastering = pending.max_mastering,
        .min_mastering = pending.min_mastering,
        .max_cll = pending.max_cll,
        .max_fall = pending.max_fall,
    };
}

/// Blocking first modesets complete before return; only later NONBLOCK flips wait.
fn shouldWaitForFlip(modeset_done: bool) bool {
    return modeset_done;
}

fn canCommitScanout(waiting_flip: bool, seat_paused: bool) bool {
    return !waiting_flip and !seat_paused;
}

/// Native DRM is only safe when the caller asked for it and no parent compositor is live.
pub fn shouldStartNative(want_physical: bool, has_parent_compositor: bool) bool {
    return want_physical and !has_parent_compositor;
}

/// A usable parent display or an inherited Wayland session both mean another compositor owns KMS.
pub fn hasLiveParentCompositor(parent_display_usable: bool, session_type: ?string) bool {
    if (parent_display_usable) return true;
    const kind = session_type orelse return false;
    return std.mem.eql(u8, kind, "wayland");
}

const testing = core.testing;

test "shouldWaitForFlip - first modeset is not flip-gated" {
    try testing.expect(!shouldWaitForFlip(false));
    try testing.expect(shouldWaitForFlip(true));
}

test "canCommitScanout - rejects wait and pause" {
    try testing.expect(canCommitScanout(false, false));
    try testing.expect(!canCommitScanout(true, false));
    try testing.expect(!canCommitScanout(false, true));
    try testing.expect(!canCommitScanout(true, true));
}

test "scanoutMatchesMode - buffer must match mode" {
    try testing.expect(scanoutMatchesMode(1920, 1080, 1920, 1080));
    try testing.expect(!scanoutMatchesMode(1280, 720, 1920, 1080));
}

test "scanoutNeedsReset - size or format change after modeset" {
    const dumb = DumbSlot{ .fb_id = 1, .width = 1920, .height = 1080 };
    const gpu = vulkan.Slot{ .fb_id = 2, .width = 1920, .height = 1080, .format = drm_format.XRGB8888 };
    try testing.expect(!scanoutNeedsReset(false, dumb, .{}, 1280, 720, 0));
    try testing.expect(scanoutNeedsReset(true, dumb, .{}, 1280, 720, 0));
    try testing.expect(!scanoutNeedsReset(true, dumb, gpu, 1920, 1080, drm_format.XRGB8888));
    try testing.expect(scanoutNeedsReset(true, .{}, gpu, 1920, 1080, drm_format.ARGB8888));
}

test "slotReady - requires fb and matching size" {
    try testing.expect(!slotReady(.{}, 1920, 1080));
    try testing.expect(slotReady(.{ .fb_id = 1, .width = 1920, .height = 1080 }, 1920, 1080));
    try testing.expect(!slotReady(.{ .fb_id = 1, .width = 1280, .height = 720 }, 1920, 1080));
}

test "atomicFlags - blocking modeset then NONBLOCK flip" {
    try testing.expectEqual(DRM_MODE_ATOMIC_ALLOW_MODESET, atomicFlags(false, false));
    try testing.expectEqual(
        DRM_MODE_PAGE_FLIP_EVENT | DRM_MODE_ATOMIC_NONBLOCK,
        atomicFlags(true, false),
    );
}

test "atomicFlags - async only after modeset on HDR tearing" {
    try testing.expectEqual(
        DRM_MODE_PAGE_FLIP_EVENT | DRM_MODE_ATOMIC_NONBLOCK | DRM_MODE_PAGE_FLIP_ASYNC,
        atomicFlags(true, true),
    );
    try testing.expectEqual(DRM_MODE_ATOMIC_ALLOW_MODESET, atomicFlags(false, true));
}

test "PendingHdr - commit and clear stay distinct" {
    const on = Output.PendingHdr{ .enable = true, .eotf = 2, .max_cll = 600 };
    const off = Output.PendingHdr{};
    try testing.expect(!on.sameBlob(off));
    try testing.expect(off.sameBlob(.{}));
}

test "AtomicRequest - HDR metadata commit and clear reuse one request" {
    var request = drm.AtomicRequest.init(testing.allocator, null);
    defer request.deinit();
    request.add(1, 2, 42);
    try testing.expectEqual(@as(c_int, 1), request.cursor());
    try testing.expect(!request.failed);
    request.reset();
    request.add(1, 2, 0);
    try testing.expectEqual(@as(c_int, 1), request.cursor());
    try testing.expect(!request.failed);
}

test "encodeHdr - PQ BT.2020 infoframe fields" {
    const blob = encodeHdr(.{
        .enable = true,
        .eotf = 2,
        .max_cll = 600,
        .max_fall = 200,
        .max_mastering = 1000,
        .min_mastering = 50,
    });
    try testing.expectEqual(@as(u32, 1), blob.metadata_type);
    try testing.expectEqual(@as(u8, 1), blob.static_type);
    try testing.expectEqual(@as(u8, 2), blob.eotf);
    try testing.expectEqual(@as(u16, 35400), blob.primaries[0][0]);
    try testing.expectEqual(@as(u16, 600), blob.max_cll);
    try testing.expectEqual(@as(u16, 200), blob.max_fall);
}

test "shouldStartNative - refuses a live parent compositor" {
    try testing.expect(!shouldStartNative(false, false));
    try testing.expect(!shouldStartNative(true, true));
    try testing.expect(shouldStartNative(true, false));
}

test "hasLiveParentCompositor - wayland session counts as a parent" {
    try testing.expect(hasLiveParentCompositor(true, "tty"));
    try testing.expect(hasLiveParentCompositor(false, "wayland"));
    try testing.expect(!hasLiveParentCompositor(false, "tty"));
    try testing.expect(!hasLiveParentCompositor(false, null));
}

test "takePendingClientFb - consumes a one-shot fb id" {
    var pending: u32 = 7;
    try testing.expectEqual(@as(u32, 7), takePendingClientFb(&pending).?);
    try testing.expectEqual(@as(u32, 0), pending);
    try testing.expect(takePendingClientFb(&pending) == null);
}

test "clientPlanesHaveModifiers - rejects invalid and empty" {
    try testing.expect(!clientPlanesHaveModifiers(&.{}));
    try testing.expect(!clientPlanesHaveModifiers(&.{.{ .modifier = drm_format.MOD_INVALID }}));
    try testing.expect(clientPlanesHaveModifiers(&.{.{ .modifier = drm_format.MOD_LINEAR }}));
    try testing.expect(clientPlanesHaveModifiers(&.{.{ .modifier = 0x0100000000000001 }}));
}

test "fillDmabufPlanes - copies fd stride offset and modifier" {
    var planes = [_]Output.ClientPlane{.{}} ** 4;
    const count = fillDmabufPlanes(.{
        .success = true,
        .planes = 1,
        .fds = .{ 5, -1, -1, -1 },
        .strides = .{ 7680, 0, 0, 0 },
        .offsets = .{ 16, 0, 0, 0 },
        .modifier = 0x0100000000000001,
    }, &planes);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(i32, 5), planes[0].fd);
    try testing.expectEqual(@as(u32, 7680), planes[0].stride);
    try testing.expectEqual(@as(u32, 16), planes[0].offset);
    try testing.expectEqual(@as(u64, 0x0100000000000001), planes[0].modifier);
}

test "copyScanout - copies a packed BGRA row and rejects a short source" {
    var dest = [_]u8{0} ** 16;
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expect(copyScanout(&dest, 8, &src, 8, 2, 1));
    try testing.expectEqualSlices(u8, src[0..8], dest[0..8]);
    try testing.expect(!copyScanout(&dest, 8, src[0..4], 8, 2, 1));
}

test "Output - preferredMode prefers the marked connector mode" {
    var be = try drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    var modes = std.ArrayList(output.Mode).empty;
    defer modes.deinit(testing.allocator);
    try modes.append(testing.allocator, output.Mode.init(1280, 720, 60000));
    try modes.append(testing.allocator, .{
        .pixel_size = Vector2D.init(1920, 1080),
        .refresh_rate = 60000,
        .preferred = true,
    });

    var connector = drm.Connector{
        .id = 1,
        .name = "eDP-1",
        .type = 0,
        .type_id = 1,
        .status = .connected,
        .modes = modes,
        .allocator = testing.allocator,
        .be = be,
    };

    const out = try Output.create(testing.allocator, be, &connector);
    defer out.deinit();

    const mode = out.preferredMode() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 1920), mode.pixel_size.getX());
    try testing.expectEqual(@as(i32, 1920), out.logicalSize().width);
}

fn markProbeFlag(userdata: ?*anyopaque) void {
    const flag: *bool = @ptrCast(@alignCast(userdata orelse return));
    flag.* = true;
}

fn testConnector(be: *drm.Backend, modes: std.ArrayList(output.Mode)) drm.Connector {
    return .{
        .id = 1,
        .name = "eDP-1",
        .type = 0,
        .type_id = 1,
        .status = .connected,
        .modes = modes,
        .allocator = testing.allocator,
        .be = be,
    };
}

test "Output - invokeFrame clears frame_scheduled without a callback" {
    var be = try drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    var connector = testConnector(be, .empty);
    const out = try Output.create(testing.allocator, be, &connector);
    defer out.deinit();

    out.frame_scheduled = true;
    out.invokeFrame();
    try testing.expect(!out.frame_scheduled);
}

test "Output - clearCallbacks is safe when no callback was set" {
    var be = try drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    var connector = testConnector(be, .empty);
    const out = try Output.create(testing.allocator, be, &connector);
    defer out.deinit();

    out.iface().clearCallbacks();
    out.invokeFrame();
    try testing.expect(out.iface().destroy());
}

test "Output - clearCallbacks drops frame and destroy userdata" {
    var be = try drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    var connector = testConnector(be, .empty);
    const out = try Output.create(testing.allocator, be, &connector);
    defer out.deinit();

    var frame_fired = false;
    var destroy_fired = false;
    out.setFrameCallback(markProbeFlag, &frame_fired);
    out.setDestroyCallback(markProbeFlag, &destroy_fired);
    out.iface().clearCallbacks();
    out.invokeFrame();
    try testing.expect(out.iface().destroy());
    try testing.expect(!frame_fired);
    try testing.expect(!destroy_fired);
}

test "Output - preferredMode skips interlaced when progressive exists" {
    var be = try drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    const interlaced = try testing.allocator.create(c.drmModeModeInfo);
    defer testing.allocator.destroy(interlaced);
    interlaced.* = std.mem.zeroes(c.drmModeModeInfo);
    interlaced.flags = c.DRM_MODE_FLAG_INTERLACE;

    var modes = std.ArrayList(output.Mode).empty;
    defer modes.deinit(testing.allocator);
    try modes.append(testing.allocator, .{
        .pixel_size = Vector2D.init(1920, 1080),
        .refresh_rate = 60000,
        .preferred = true,
        .drm_mode_info = interlaced,
    });
    try modes.append(testing.allocator, output.Mode.init(1280, 720, 60000));

    var connector = drm.Connector{
        .id = 1,
        .name = "HDMI-A-1",
        .type = 0,
        .type_id = 1,
        .status = .connected,
        .modes = modes,
        .allocator = testing.allocator,
        .be = be,
    };

    const out = try Output.create(testing.allocator, be, &connector);
    defer out.deinit();

    const mode = out.preferredMode() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 1280), mode.pixel_size.getX());
}
