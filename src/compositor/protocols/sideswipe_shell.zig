//! sideswipe_shell_v1 server. Private socket + pid-equality bind (P2).

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;
const core = @import("core");
const testing = core.testing;

const Compositor = @import("../compositor.zig").Compositor;
const Surface = @import("../surface.zig").Surface;
const SurfaceData = @import("compositor.zig").SurfaceData;
const seat = @import("../input/seat.zig");
const gesture = @import("../input/gesture.zig");
const xdg_shell = @import("xdg_shell.zig");

const WNOHANG: c_int = 1;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c.mode_t) c_int;
extern "c" fn pipe2(pipefd: *[2]c_int, flags: c_int) c_int;

/// PATH name used when env and sibling resolution both fail.
pub const binary_name = "sideswipe-shell";

/// Lifetime below this uses exponential backoff; at or above uses a 1ms timer.
pub const min_lifetime_ms: i64 = 100;
/// Lifetime before a death is healthy and `fast_deaths` resets.
pub const healthy_lifetime_ms: i64 = 5000;
/// `wl_event_source_timer_update(0)` disables the timer, so spawn-now is 1ms.
pub const spawn_now_delay_ms: u32 = 1;
/// Upper bound for exponential restart delay.
pub const max_restart_delay_ms: u32 = 2000;
/// Consecutive unhealthy deaths (or spawn failures) before the supervisor stops.
pub const max_fast_deaths: u32 = 32;

const pipe_flags: c_int = 0o2000000;

/// Decoded wait(2) status for logs and tests.
pub const ChildStatus = struct {
    exited: bool,
    signaled: bool,
    code: u32,
};

/// Next supervisor action after a death or spawn failure.
pub const Restart = enum { spawn_now, backoff, give_up };

/// Decodes a wait(2) status word into WIFEXITED / WIFSIGNALED / code.
pub fn decodeWait(status: c_int) ChildStatus {
    const word: u32 = @bitCast(status);
    const low: u32 = word & 0x7f;
    const exited = low == 0;
    const stopped = (word & 0xff) == 0x7f;
    const signaled = !exited and !stopped;
    const code: u32 = if (exited) (word >> 8) & 0xff else low;
    return .{ .exited = exited, .signaled = signaled, .code = code };
}

/// Next `fast_deaths` value after a death of `lifetime_ms`.
pub fn nextFastDeaths(lifetime_ms: i64, prior_fast_deaths: u32) u32 {
    if (lifetime_ms >= healthy_lifetime_ms) return 0;
    return prior_fast_deaths + 1;
}

/// Chooses the next supervisor action after a child death or spawn failure.
pub fn restartPlan(lifetime_ms: i64, prior_fast_deaths: u32) Restart {
    const next = nextFastDeaths(lifetime_ms, prior_fast_deaths);
    if (next >= max_fast_deaths) return .give_up;
    if (lifetime_ms >= min_lifetime_ms) return .spawn_now;
    return .backoff;
}

/// Timer delay for `plan` after `fast_deaths` has been updated.
pub fn planDelayMs(plan: Restart, fast_deaths: u32) u32 {
    if (plan == .backoff) return restartDelayMs(fast_deaths);
    return spawn_now_delay_ms;
}

/// Exponential delay for a 1-based unhealthy-death count.
pub fn restartDelayMs(fast_deaths: u32) u32 {
    if (fast_deaths == 0) return spawn_now_delay_ms;
    const shift_max: u5 = 16;
    const shift: u5 = @intCast(@min(fast_deaths - 1, shift_max));
    const delay = @as(u32, @intCast(min_lifetime_ms)) << shift;
    return @min(delay, max_restart_delay_ms);
}

/// Classifies `waitpid(pid, …)`: 0 is still running, not a death.
pub fn classifyWait(reaped: c_int, pid: i32) enum { running, dead, vanished } {
    if (reaped == pid) return .dead;
    if (reaped == 0) return .running;
    return .vanished;
}

pub const ExecRead = enum { succeeded, pending };

/// Maps a pipe `read` result. Errors other than WouldBlock are exec failure.
pub fn classifyExecRead(result: anyerror!usize) error{ExecFailed}!ExecRead {
    const n = result catch |err| return classifyExecErr(err);
    if (n > 0) return error.ExecFailed;
    return .succeeded;
}

fn classifyExecErr(err: anyerror) error{ExecFailed}!ExecRead {
    if (err == error.WouldBlock) return .pending;
    return error.ExecFailed;
}

/// `dirname(exe_path)` + `/sideswipe-shell`.
pub fn siblingPath(gpa: std.mem.Allocator, exe_path: []const u8) ![:0]u8 {
    const dir = std.fs.path.dirname(exe_path) orelse return error.NoDirname;
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, binary_name }, 0);
}

/// `SIDESWIPE_SHELL`, then sibling of this executable, then `sideswipe-shell`.
pub fn resolveBinary(gpa: std.mem.Allocator) ![:0]u8 {
    if (try envBinary(gpa)) |path| return path;
    if (try siblingOfSelf(gpa)) |path| return path;
    return gpa.dupeZ(u8, binary_name);
}

const ExecReport = struct {
    errno: i32 = 0,
    wait_status: c_int = 0,
};

pub const Role = enum(u32) {
    ring = 0,
    switcher = 1,
    shade = 2,
    edit_menu = 3,
    hud = 4,

    fn fromInt(value: u32) ?Role {
        return switch (value) {
            0 => .ring,
            1 => .switcher,
            2 => .shade,
            3 => .edit_menu,
            4 => .hud,
            else => null,
        };
    }
};

pub const Slice = struct {
    id: u32,
    label: []const u8,
    icon: []const u8,
    has_subring: bool,

    fn deinit(self: Slice, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
        gpa.free(self.icon);
    }

    fn clone(self: Slice, gpa: std.mem.Allocator) !Slice {
        return .{
            .id = self.id,
            .label = try gpa.dupe(u8, self.label),
            .icon = try gpa.dupe(u8, self.icon),
            .has_subring = self.has_subring,
        };
    }
};

pub const default_slices = [_]Slice{
    .{ .id = 0, .label = "Launch", .icon = "terminal", .has_subring = false },
    .{ .id = 1, .label = "Next", .icon = "next", .has_subring = false },
    .{ .id = 2, .label = "Close", .icon = "close", .has_subring = false },
    .{ .id = 3, .label = "Back", .icon = "back", .has_subring = false },
};

pub const overlay_slots = std.meta.tags(Role).len;

/// Returns whether `client_pid` may bind sideswipe_shell_v1.
pub fn pidAllowed(client_pid: i32, privileged_pid: ?i32) bool {
    return privileged_pid == client_pid;
}

/// Returns whether commit_surface may map `role` for `serial`.
pub fn openMatches(open_serial: ?u32, open_role: ?Role, serial: u32, role: Role) bool {
    return open_serial == serial and open_role == role;
}

/// Writes staged slices as a `[ring]` TOML snippet. Loaded again on compositor start.
pub fn writeRingToml(gpa: std.mem.Allocator, path: []const u8, slices: []const Slice) !void {
    if (std.fs.path.dirname(path)) |dir| {
        const dir_z = try gpa.dupeZ(u8, dir);
        defer gpa.free(dir_z);
        _ = std.c.mkdir(dir_z.ptr, 0o755);
    }
    var body = std.ArrayList(u8).empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "# Written by sideswipe_shell_v1.set_ring. Loaded on compositor start.\n[ring]\n");
    for (slices) |slice| {
        try appendSliceToml(gpa, &body, slice);
    }
    const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{ .truncate = true });
    defer file.close(std.Options.debug_io);
    try file.writeStreamingAll(std.Options.debug_io, body.items);
}

fn appendSliceToml(gpa: std.mem.Allocator, body: *std.ArrayList(u8), slice: Slice) !void {
    const line = try std.fmt.allocPrint(
        gpa,
        "\n[[ring.slices]]\nid = {d}\nlabel = \"{s}\"\nicon = \"{s}\"\nhas_subring = {s}\n",
        .{
            slice.id,
            slice.label,
            slice.icon,
            if (slice.has_subring) "true" else "false",
        },
    );
    defer gpa.free(line);
    try body.appendSlice(gpa, line);
}

const PendingSlice = struct {
    id: ?u32 = null,
    label: ?[]u8 = null,
    icon: ?[]u8 = null,
    has_subring: bool = false,

    fn deinit(self: PendingSlice, gpa: std.mem.Allocator) void {
        if (self.label) |label| gpa.free(label);
        if (self.icon) |icon| gpa.free(icon);
    }
};

/// Parses the `[ring]` snippet written by `writeRingToml`.
pub fn parseRingToml(gpa: std.mem.Allocator, body: []const u8) !std.ArrayList(Slice) {
    var result = std.ArrayList(Slice).empty;
    errdefer deinitSliceList(gpa, &result);
    var current: ?PendingSlice = null;
    errdefer if (current) |pending| pending.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (skipTomlLine(line)) continue;
        if (std.mem.eql(u8, line, "[[ring.slices]]")) {
            try flushPending(gpa, &result, &current);
            current = .{};
            continue;
        }
        try applyTomlField(gpa, &current, line);
    }
    try flushPending(gpa, &result, &current);
    return result;
}

/// Reads persisted ring slices from `path`.
pub fn readRingToml(gpa: std.mem.Allocator, path: []const u8) !std.ArrayList(Slice) {
    const body = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, gpa, .limited(64 * 1024));
    defer gpa.free(body);
    return parseRingToml(gpa, body);
}

fn skipTomlLine(line: []const u8) bool {
    return line.len == 0 or line[0] == '#' or std.mem.eql(u8, line, "[ring]");
}

fn unquoteToml(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn applyTomlField(gpa: std.mem.Allocator, current: *?PendingSlice, line: []const u8) !void {
    const pending = if (current.*) |*item| item else return;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, key, "id")) {
        pending.id = std.fmt.parseInt(u32, value, 10) catch return;
        return;
    }
    if (std.mem.eql(u8, key, "has_subring")) {
        pending.has_subring = std.mem.eql(u8, value, "true");
        return;
    }
    if (std.mem.eql(u8, key, "label")) {
        if (pending.label) |old| gpa.free(old);
        pending.label = try gpa.dupe(u8, unquoteToml(value));
        return;
    }
    if (std.mem.eql(u8, key, "icon")) {
        if (pending.icon) |old| gpa.free(old);
        pending.icon = try gpa.dupe(u8, unquoteToml(value));
    }
}

fn flushPending(gpa: std.mem.Allocator, result: *std.ArrayList(Slice), current: *?PendingSlice) !void {
    const pending = current.* orelse return;
    current.* = null;
    const id = pending.id orelse {
        pending.deinit(gpa);
        return;
    };
    const label = pending.label orelse {
        pending.deinit(gpa);
        return;
    };
    const icon = pending.icon orelse {
        pending.deinit(gpa);
        return;
    };
    result.append(gpa, .{
        .id = id,
        .label = label,
        .icon = icon,
        .has_subring = pending.has_subring,
    }) catch {
        gpa.free(label);
        gpa.free(icon);
        return error.OutOfMemory;
    };
}

fn deinitSliceList(gpa: std.mem.Allocator, list: *std.ArrayList(Slice)) void {
    for (list.items) |slice| slice.deinit(gpa);
    list.deinit(gpa);
}

/// Live slice count used by fallback hover/placeholder quads.
pub fn sliceCount(compositor: *const Compositor) u8 {
    const host = compositor.shell orelse return @intCast(default_slices.len);
    return host.sliceCount();
}

pub const Host = struct {
    compositor: *Compositor,
    resource: ?*c.wl_resource = null,
    privileged_pid: ?i32 = null,
    child_pid: ?i32 = null,
    child_source: ?*c.wl_event_source = null,
    restart_timer: ?*c.wl_event_source = null,
    spawned_at_ms: i64 = 0,
    fast_deaths: u32 = 0,
    global: ?*c.wl_global = null,
    socket_name: ?[]u8 = null,
    socket_path: ?[]u8 = null,
    pending: std.ArrayList(Slice) = .empty,
    live: std.ArrayList(Slice) = .empty,
    overlays: [overlay_slots]?*Surface = .{null} ** overlay_slots,
    open_serial: [overlay_slots]?u32 = .{null} ** overlay_slots,
    replaced_ring: bool = false,
    tiles: std.AutoHashMap(u32, void),

    fn gpa(self: *const Host) std.mem.Allocator {
        return self.compositor.allocator;
    }

    fn deinitSlices(self: *Host, list: *std.ArrayList(Slice)) void {
        for (list.items) |slice| slice.deinit(self.gpa());
        list.deinit(self.gpa());
        list.* = .empty;
    }

    pub fn deinit(self: *Host) void {
        self.dropAllOverlays();
        self.stopSupervisor();
        self.deinitSlices(&self.pending);
        self.deinitSlices(&self.live);
        self.tiles.deinit();
        if (self.socket_name) |name| self.gpa().free(name);
        if (self.socket_path) |path| self.gpa().free(path);
        self.compositor.shell = null;
        self.gpa().destroy(self);
    }

    fn stopSupervisor(self: *Host) void {
        dropEventSource(&self.restart_timer);
        dropEventSource(&self.child_source);
        const pid = self.child_pid orelse return;
        self.child_pid = null;
        _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        _ = waitpid(pid, null, 0);
    }

    /// Returns the overlay in `index` even when earlier roles are holes.
    pub fn overlayAt(self: *const Host, index: usize) ?*Surface {
        if (index >= self.overlays.len) return null;
        return self.overlays[index];
    }

    pub fn sliceCount(self: *const Host) u8 {
        const n = self.slices().len;
        if (n == 0) return @intCast(default_slices.len);
        return @intCast(@min(n, 8));
    }

    fn slices(self: *const Host) []const Slice {
        if (self.live.items.len == 0) return &default_slices;
        return self.live.items;
    }

    fn loadPersisted(self: *Host) void {
        const path = ringTomlPath(self.gpa()) catch return;
        defer self.gpa().free(path);
        const loaded = readRingToml(self.gpa(), path) catch return;
        if (loaded.items.len == 0) {
            var empty = loaded;
            empty.deinit(self.gpa());
            return;
        }
        self.deinitSlices(&self.live);
        self.live = loaded;
    }

    /// Nulls overlay slots that point at `surface` without touching it. Call before free.
    pub fn forgetSurface(self: *Host, surface: *const Surface) void {
        var forgot_ring = false;
        for (0..overlay_slots) |index| {
            if (self.overlays[index] != surface) continue;
            self.overlays[index] = null;
            if (index == @intFromEnum(Role.ring)) forgot_ring = true;
        }
        if (!forgot_ring) return;
        self.replaced_ring = false;
        self.compositor.refreshFallbackRing();
    }

    fn dropOverlay(self: *Host, index: usize) void {
        const surface = self.overlays[index] orelse return;
        self.overlays[index] = null;
        unmapOverlay(surface);
    }

    fn dropAllOverlays(self: *Host) void {
        self.replaced_ring = false;
        for (0..overlay_slots) |index| {
            self.open_serial[index] = null;
            self.dropOverlay(index);
        }
        self.compositor.refreshFallbackRing();
    }

    /// Clears overlays and privileged identity after the shell process exits.
    pub fn resetAfterDeath(self: *Host) void {
        self.child_pid = null;
        self.privileged_pid = null;
        self.resource = null;
        self.spawned_at_ms = 0;
        self.dropAllOverlays();
    }

    fn listenPrivate(self: *Host) !void {
        const pid = std.os.linux.getpid();
        const name = try std.fmt.allocPrint(self.gpa(), "sideswipe-shell-{d}", .{pid});
        errdefer self.gpa().free(name);
        try self.compositor.server.display.addSocket(name);
        const runtime = core.env.get("XDG_RUNTIME_DIR") orelse "/tmp";
        const path = try std.fmt.allocPrint(self.gpa(), "{s}/{s}", .{ runtime, name });
        errdefer self.gpa().free(path);
        const path_z = try self.gpa().dupeZ(u8, path);
        defer self.gpa().free(path_z);
        if (chmod(path_z.ptr, 0o700) != 0) {
            self.compositor.logger.warn("Private shell socket chmod failed: {s}", .{path});
        } else {
            self.compositor.logger.info("Private shell socket {s} (mode 0700)", .{path});
        }
        const loop = self.compositor.server.getEventLoop();
        self.child_source = try loop.addSignal(@intFromEnum(std.posix.SIG.CHLD), onChild, self);
        errdefer dropEventSource(&self.child_source);
        self.restart_timer = try loop.addTimer(onRestartTimer, self);
        self.socket_name = name;
        self.socket_path = path;
    }

    fn spawn(self: *Host) !void {
        if (self.child_pid != null) return;
        const path = self.socket_path orelse return error.ShellSocketMissing;
        const binary = try resolveBinary(self.gpa());
        defer self.gpa().free(binary);
        try exportSocket(path);
        var report: ExecReport = .{};
        const child = forkExec(binary, &report) catch |err| {
            if (err == error.ExecFailed) logSpawnFail(self, binary, err, report);
            return err;
        };
        disarmTimer(self.restart_timer);
        self.child_pid = child;
        self.privileged_pid = child;
        self.spawned_at_ms = nowMs();
        self.compositor.logger.info("Spawned shell pid {d} ({s}) on {s}", .{ child, binary, path });
    }

    fn sendRingOpen(self: *Host, point: gesture.Point) void {
        const resource = self.resource orelse return;
        dismissPopups(self.compositor);
        const serial = self.compositor.nextSerial();
        self.open_serial[@intFromEnum(Role.ring)] = serial;
        const output_name = outputName(self.compositor);
        const scale = self.compositor.preferredScale();
        c.sideswipe_shell_v1_send_ring_open(
            resource,
            serial,
            c.wl_fixed_from_double(point.x),
            c.wl_fixed_from_double(point.y),
            output_name,
            c.wl_fixed_from_double(scale),
        );
        for (self.slices()) |slice| {
            sendRingItem(resource, serial, slice);
        }
    }

    fn sendRingHover(self: *Host, slice_id: ?u8) void {
        const resource = self.resource orelse return;
        const serial = self.open_serial[@intFromEnum(Role.ring)] orelse return;
        const id: u32 = if (slice_id) |value| value else std.math.maxInt(u32);
        c.sideswipe_shell_v1_send_ring_hover(resource, serial, id);
    }

    fn closeRole(self: *Host, role: Role) void {
        const index = @intFromEnum(role);
        const serial = self.open_serial[index];
        self.open_serial[index] = null;
        self.dropOverlay(index);
        if (role == .ring) self.replaced_ring = false;
        const live = serial orelse return;
        const resource = self.resource orelse return;
        sendClose(resource, role, live, self.compositor.focused_column);
    }

    fn ensureSwitcher(self: *Host) u32 {
        if (self.open_serial[@intFromEnum(Role.switcher)]) |serial| return serial;
        const resource = self.resource orelse return 0;
        dismissPopups(self.compositor);
        const serial = self.compositor.nextSerial();
        self.open_serial[@intFromEnum(Role.switcher)] = serial;
        c.sideswipe_shell_v1_send_switcher_open(resource, serial);
        for (self.compositor.toplevels.items, 0..) |entry, handle| {
            sendColumn(resource, serial, @intCast(handle), entry.surface);
        }
        return serial;
    }
};

fn sendColumn(resource: *c.wl_resource, serial: u32, handle: u32, surface: *Surface) void {
    var title_buf: [256]u8 = undefined;
    var app_buf: [256]u8 = undefined;
    const meta = columnMeta(surface);
    c.sideswipe_shell_v1_send_switcher_column(
        resource,
        serial,
        handle,
        zCopy(&title_buf, meta.title),
        zCopy(&app_buf, meta.app_id),
    );
}

const ColumnMeta = struct {
    title: []const u8,
    app_id: []const u8,
};

fn columnMeta(surface: *Surface) ColumnMeta {
    if (surface.role != .xdg_toplevel) return .{ .title = "", .app_id = "" };
    const xdg: *xdg_shell.XdgSurface = @ptrCast(@alignCast(surface.role_data orelse return .{
        .title = "",
        .app_id = "",
    }));
    const toplevel = xdg.toplevel orelse return .{ .title = "", .app_id = "" };
    return .{
        .title = toplevel.title orelse "",
        .app_id = toplevel.app_id orelse "",
    };
}

fn zCopy(buf: []u8, text: []const u8) [*:0]const u8 {
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}

fn sendRingItem(resource: *c.wl_resource, serial: u32, slice: Slice) void {
    const label_z = std.posix.toPosixPath(slice.label) catch return;
    const icon_z = std.posix.toPosixPath(slice.icon) catch return;
    c.sideswipe_shell_v1_send_ring_item(
        resource,
        serial,
        slice.id,
        &label_z,
        &icon_z,
        if (slice.has_subring) @as(u32, 1) else 0,
    );
}

fn sendClose(resource: *c.wl_resource, role: Role, serial: u32, focused: ?usize) void {
    switch (role) {
        .ring => c.sideswipe_shell_v1_send_ring_close(resource, serial),
        .switcher => {
            const selected: u32 = if (focused) |index| @intCast(index) else 0;
            c.sideswipe_shell_v1_send_switcher_close(resource, serial, selected);
        },
        .shade => c.sideswipe_shell_v1_send_shade_close(resource, serial),
        .edit_menu => c.sideswipe_shell_v1_send_edit_menu_close(resource, serial),
        .hud => {},
    }
}

fn outputName(compositor: *Compositor) u32 {
    if (compositor.outputs.items.len == 0) return 0;
    return 1;
}

fn envBinary(gpa: std.mem.Allocator) !?[:0]u8 {
    const raw = core.env.get("SIDESWIPE_SHELL") orelse return null;
    if (raw.len == 0) return null;
    if (std.Io.Dir.path.isAbsolute(raw)) return try gpa.dupeZ(u8, raw);
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, raw, gpa) catch
        try gpa.dupeZ(u8, raw);
    return resolved;
}

fn siblingOfSelf(gpa: std.mem.Allocator) !?[:0]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(std.Options.debug_io, &buf) catch return null;
    return siblingPath(gpa, buf[0..n]) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
}

fn unmapOverlay(surface: *Surface) void {
    surface.attach(null, 0, 0) catch {};
    surface.commit();
    surface.scene_geometry = null;
}

pub fn dismissPopups(compositor: *Compositor) void {
    if (compositor.seat.popup_grab) |resource| {
        c.xdg_popup_send_popup_done(resource);
        compositor.seat.popup_grab = null;
    }
    for (compositor.surfaces.items) |surface| dismissPopupSurface(surface);
}

fn dismissPopupSurface(surface: *Surface) void {
    if (surface.role != .xdg_popup) return;
    const xdg: *xdg_shell.XdgSurface = @ptrCast(@alignCast(surface.role_data orelse return));
    const popup = xdg.popup orelse return;
    popup.dismiss();
}

fn clientPid(client: ?*c.wl_client) ?i32 {
    const live = client orelse return null;
    var pid: c.pid_t = 0;
    var uid: c.uid_t = 0;
    var gid: c.gid_t = 0;
    c.wl_client_get_credentials(live, &pid, &uid, &gid);
    return @intCast(pid);
}

fn globalFilter(
    client: ?*const c.wl_client,
    global: ?*const c.wl_global,
    data: ?*anyopaque,
) callconv(.c) bool {
    const iface = c.wl_global_get_interface(global) orelse return true;
    if (!std.mem.eql(u8, std.mem.span(iface.*.name), "sideswipe_shell_v1")) return true;
    const compositor: *Compositor = @ptrCast(@alignCast(data orelse return false));
    const host = compositor.shell orelse return false;
    const pid = clientPid(@constCast(client)) orelse return false;
    return pidAllowed(pid, host.privileged_pid);
}

fn onChild(_: i32, data: ?*anyopaque) callconv(.c) i32 {
    const host: *Host = @ptrCast(@alignCast(data orelse return 0));
    reapAndRestart(host);
    return 0;
}

fn onRestartTimer(data: ?*anyopaque) callconv(.c) i32 {
    const host: *Host = @ptrCast(@alignCast(data orelse return 0));
    requestStart(host);
    return 0;
}

fn reapAndRestart(host: *Host) void {
    const pid = host.child_pid orelse return;
    const lifetime = lifetimeMs(host);
    var status: c_int = 0;
    const reaped = waitpid(pid, &status, WNOHANG);
    switch (classifyWait(reaped, pid)) {
        .running => return,
        .dead => finishDeath(host, pid, lifetime, decodeWait(status)),
        .vanished => finishVanished(host, pid, lifetime),
    }
}

fn finishDeath(host: *Host, pid: i32, lifetime: i64, decoded: ChildStatus) void {
    host.resetAfterDeath();
    logDeath(host, pid, decoded);
    afterDeath(host, lifetime);
}

fn finishVanished(host: *Host, pid: i32, lifetime: i64) void {
    host.resetAfterDeath();
    host.compositor.logger.warn("Shell pid {d} vanished (waitpid); treating as dead", .{pid});
    afterDeath(host, lifetime);
}

fn lifetimeMs(host: *const Host) i64 {
    if (host.spawned_at_ms == 0) return 0;
    return nowMs() - host.spawned_at_ms;
}

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
}

fn logDeath(host: *Host, pid: i32, decoded: ChildStatus) void {
    host.compositor.logger.warn(
        "Shell pid {d} exited; WIFEXITED={d} WIFSIGNALED={d} code={d}",
        .{ pid, @intFromBool(decoded.exited), @intFromBool(decoded.signaled), decoded.code },
    );
}

fn afterDeath(host: *Host, lifetime: i64) void {
    const plan = restartPlan(lifetime, host.fast_deaths);
    host.fast_deaths = nextFastDeaths(lifetime, host.fast_deaths);
    if (plan == .give_up) {
        host.compositor.logger.warn("Shell restart cap ({d}) reached; giving up", .{max_fast_deaths});
        return;
    }
    scheduleRestart(host, planDelayMs(plan, host.fast_deaths));
}

fn requestStart(host: *Host) void {
    host.spawn() catch |err| {
        if (err != error.ExecFailed) {
            host.compositor.logger.warn("Failed to spawn privileged shell: {}", .{err});
        }
        afterDeath(host, 0);
    };
}

fn logSpawnFail(host: *Host, binary: [:0]const u8, err: anyerror, report: ExecReport) void {
    const decoded = decodeWait(report.wait_status);
    host.compositor.logger.warn(
        "Failed to spawn privileged shell {s}: {} errno={d} wait={d} WIFEXITED={d} WIFSIGNALED={d} code={d}",
        .{
            binary,
            err,
            report.errno,
            report.wait_status,
            @intFromBool(decoded.exited),
            @intFromBool(decoded.signaled),
            decoded.code,
        },
    );
}

fn scheduleRestart(host: *Host, delay_ms: u32) void {
    if (host.fast_deaths >= max_fast_deaths) {
        host.compositor.logger.warn("Shell restart cap ({d}) reached; giving up", .{max_fast_deaths});
        return;
    }
    const delay = @max(delay_ms, spawn_now_delay_ms);
    const timer = host.restart_timer orelse {
        host.compositor.logger.warn("Shell restart timer missing", .{});
        return;
    };
    if (c.wl_event_source_timer_update(timer, @intCast(delay)) < 0) {
        host.compositor.logger.warn("Shell restart timer update failed", .{});
        return;
    }
    host.compositor.logger.warn("Restarting shell in {d} ms", .{delay});
}

fn dropEventSource(slot: *?*c.wl_event_source) void {
    const source = slot.* orelse return;
    _ = c.wl_event_source_remove(source);
    slot.* = null;
}

fn disarmTimer(source: ?*c.wl_event_source) void {
    const timer = source orelse return;
    _ = c.wl_event_source_timer_update(timer, 0);
}

fn exportSocket(path: []const u8) !void {
    const path_z = try std.posix.toPosixPath(path);
    if (setenv("SIDESWIPE_SHELL_SOCKET", &path_z, 1) != 0) return error.ShellSpawnFailed;
}

fn forkExec(binary: [:0]const u8, report: *ExecReport) !i32 {
    var fds: [2]c_int = undefined;
    if (pipe2(&fds, pipe_flags) != 0) return error.ShellSpawnFailed;
    const child = fork();
    if (child < 0) {
        core.unix.close(fds[0]);
        core.unix.close(fds[1]);
        return error.ShellSpawnFailed;
    }
    if (child == 0) execOrReport(binary, fds[1], fds[0]);
    core.unix.close(fds[1]);
    return waitExec(fds[0], child, report);
}

fn waitExec(read_fd: c_int, child: i32, report: *ExecReport) !i32 {
    var errno_buf: i32 = 0;
    const result = core.unix.read(read_fd, std.mem.asBytes(&errno_buf));
    _ = classifyExecRead(result) catch {
        report.errno = readErrno(result, errno_buf);
        core.unix.close(read_fd);
        _ = waitpid(child, &report.wait_status, 0);
        return error.ExecFailed;
    };
    core.unix.close(read_fd);
    return child;
}

fn readErrno(result: anyerror!usize, stored: i32) i32 {
    const n = result catch return 0;
    if (n != @sizeOf(i32)) return 0;
    return stored;
}

fn execOrReport(binary: [:0]const u8, write_fd: c_int, read_fd: c_int) noreturn {
    core.unix.close(read_fd);
    const argv = [_:null]?[*:0]const u8{ binary.ptr, null };
    const rc = execvp(binary.ptr, &argv);
    const err: i32 = @intFromEnum(std.posix.errno(rc));
    _ = std.posix.system.write(write_fd, std.mem.asBytes(&err).ptr, @sizeOf(i32));
    _exit(127);
}

fn userData(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}

fn surfaceFrom(resource: ?*c.wl_resource) ?*Surface {
    const live = resource orelse return null;
    return userData(SurfaceData, live).surface;
}

fn destroyRequest(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn setRingItem(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32, label_z: [*:0]const u8, icon_z: [*:0]const u8, has_subring: u32) callconv(.c) void {
    const host = userData(Host, resource orelse return);
    if (host.pending.items.len >= 8) return;
    const label = host.gpa().dupe(u8, std.mem.span(label_z)) catch return;
    const icon = host.gpa().dupe(u8, std.mem.span(icon_z)) catch {
        host.gpa().free(label);
        return;
    };
    const slice = Slice{
        .id = id,
        .label = label,
        .icon = icon,
        .has_subring = has_subring != 0,
    };
    host.pending.append(host.gpa(), slice) catch {
        slice.deinit(host.gpa());
    };
}

fn setRing(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    const host = userData(Host, resource orelse return);
    host.deinitSlices(&host.live);
    host.live = host.pending;
    host.pending = .empty;
    persistLive(host);
}

fn persistLive(host: *Host) void {
    const path = ringTomlPath(host.gpa()) catch |err| {
        host.compositor.logger.warn("set_ring persist skipped: {}", .{err});
        return;
    };
    defer host.gpa().free(path);
    writeRingToml(host.gpa(), path, host.live.items) catch |err| {
        host.compositor.logger.warn("set_ring persist failed: {}", .{err});
        return;
    };
    host.compositor.logger.info("Persisted {d} ring slice(s) to {s}", .{ host.live.items.len, path });
}

fn ringTomlPath(gpa: std.mem.Allocator) ![]u8 {
    if (core.path.getXdgConfigHome()) |home| {
        return std.fs.path.join(gpa, &.{ home, "sideswipe", "ring.toml" });
    }
    const home = core.path.getHome(gpa) orelse return error.NoConfigDir;
    defer gpa.free(home);
    return std.fs.path.join(gpa, &.{ home, "sideswipe", "ring.toml" });
}

fn activate(_: ?*c.wl_client, resource: ?*c.wl_resource, serial: u32, slice_id: u32) callconv(.c) void {
    const host = userData(Host, resource orelse return);
    const ring_serial = host.open_serial[@intFromEnum(Role.ring)];
    if (!openMatches(ring_serial, .ring, serial, .ring)) {
        c.wl_resource_post_error(resource, c.SIDESWIPE_SHELL_V1_ERROR_INVALID_SERIAL, "activate serial is not live");
        return;
    }
    if (slice_id > 7) return;
    host.compositor.activateFallbackSlice(
        host.compositor.fallback_ring orelse return,
        @intCast(slice_id),
    );
}

fn commitSurface(
    _: ?*c.wl_client,
    resource: ?*c.wl_resource,
    serial: u32,
    role_value: u32,
    surface_resource: ?*c.wl_resource,
) callconv(.c) void {
    const host = userData(Host, resource orelse return);
    const role = Role.fromInt(role_value) orelse {
        c.wl_resource_post_error(resource, c.SIDESWIPE_SHELL_V1_ERROR_INVALID_ROLE, "unknown shell role");
        return;
    };
    if (!openMatches(host.open_serial[@intFromEnum(role)], role, serial, role)) {
        c.wl_resource_post_error(resource, c.SIDESWIPE_SHELL_V1_ERROR_INVALID_SERIAL, "commit_surface serial is not live");
        return;
    }
    const surface = surfaceFrom(surface_resource) orelse return;
    mapOverlay(host, role, surface);
}

/// True when `surface` can be composited as a shell overlay.
pub fn overlayReady(surface: *const Surface) bool {
    if (!surface.mapped) return false;
    const geometry = surface.scene_geometry orelse return false;
    return geometry.width > 0 and geometry.height > 0;
}

fn mapOverlay(host: *Host, role: Role, surface: *Surface) void {
    const viewport = host.compositor.viewportSize();
    surface.setRole(.shell, null) catch {};
    surface.scene_geometry = .{
        .x = 0,
        .y = 0,
        .width = viewport.width,
        .height = viewport.height,
    };
    host.overlays[@intFromEnum(role)] = surface;
    if (role == .ring) host.replaced_ring = overlayReady(surface);
    host.compositor.replacePlaceholderRing();
    host.compositor.scheduleFrame();
}

/// S3 thumbnail export. `backend.renderer` has no offscreen DMA-BUF target yet;
/// this shm stub sends a null wl_buffer so the protocol still compiles and the
/// shell can ignore the event. Unknown handles are a protocol error.
pub fn sendThumbnail(host: *Host, handle: u32, width: i32, height: i32, scale: f32) void {
    const resource = host.resource orelse return;
    if (!host.tiles.contains(handle)) {
        c.wl_resource_post_error(resource, c.SIDESWIPE_SHELL_V1_ERROR_UNKNOWN_HANDLE, "unknown thumbnail handle");
        return;
    }
    host.compositor.logger.debug(
        "sideswipe_shell: thumbnail stub (no render-to-texture); handle={d} {d}x{d} scale={d:.2}",
        .{ handle, width, height, scale },
    );
    c.sideswipe_shell_v1_send_toplevel_thumbnail(
        resource,
        handle,
        null,
        width,
        height,
        c.wl_fixed_from_double(scale),
    );
}

fn destroyResource(resource: ?*c.wl_resource) callconv(.c) void {
    const host = userData(Host, resource orelse return);
    if (host.resource == resource) host.resource = null;
}

fn bind(client: ?*c.wl_client, context: ?*anyopaque, _: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const host = compositor.shell orelse return c.wl_client_post_no_memory(client);
    const resource = c.wl_resource_create(client, &c.sideswipe_shell_v1_interface, 1, id) orelse {
        return c.wl_client_post_no_memory(client);
    };
    const pid = clientPid(client) orelse {
        c.wl_resource_post_error(resource, c.SIDESWIPE_SHELL_V1_ERROR_UNAUTHORIZED, "missing credentials");
        return;
    };
    if (!pidAllowed(pid, host.privileged_pid)) {
        c.wl_resource_post_error(resource, c.SIDESWIPE_SHELL_V1_ERROR_UNAUTHORIZED, "pid mismatch");
        return;
    }
    c.wl_resource_set_implementation(resource, @ptrCast(&implementation), host, destroyResource);
    host.resource = resource;
}

var implementation = [_]?*const anyopaque{
    @ptrCast(&destroyRequest),
    @ptrCast(&setRingItem),
    @ptrCast(&setRing),
    @ptrCast(&activate),
    @ptrCast(&commitSurface),
};

pub fn register(compositor: *Compositor) !void {
    if (compositor.shell != null) return;
    const host = try compositor.allocator.create(Host);
    host.* = .{
        .compositor = compositor,
        .tiles = std.AutoHashMap(u32, void).init(compositor.allocator),
    };
    compositor.shell = host;
    errdefer host.deinit();
    const created = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.sideswipe_shell_v1_interface,
        1,
        compositor,
        bind,
    );
    host.global = created.handle;
    host.loadPersisted();
    c.wl_display_set_global_filter(compositor.server.getDisplay(), globalFilter, compositor);
}

pub fn attach(compositor: *Compositor) !void {
    const host = compositor.shell orelse return;
    try host.listenPrivate();
    requestStart(host);
}

/// True only when the privileged client has a mapped ring overlay.
/// A bound shell pid or sticky `replaced_ring` flag is not enough.
pub fn ringReplaced(compositor: *const Compositor) bool {
    const host = compositor.shell orelse return false;
    const surface = host.overlayAt(@intFromEnum(Role.ring)) orelse return false;
    return overlayReady(surface);
}

pub fn onHold(compositor: *Compositor, point: gesture.Point) void {
    const host = compositor.shell orelse return;
    host.sendRingOpen(point);
}

pub fn onHover(compositor: *Compositor, slice_id: ?u8) void {
    const host = compositor.shell orelse return;
    host.sendRingHover(slice_id);
}

pub fn onRingClose(compositor: *Compositor) void {
    const host = compositor.shell orelse return;
    host.closeRole(.ring);
}

pub fn onDrag(compositor: *Compositor, event: gesture.Primitive.Drag) void {
    const host = compositor.shell orelse return;
    const resource = host.resource orelse return;
    switch (event.direction) {
        .up => {
            const serial = host.ensureSwitcher();
            if (serial == 0) return;
            c.sideswipe_shell_v1_send_switcher_progress(resource, serial, c.wl_fixed_from_double(event.progress));
        },
        else => {},
    }
}

pub fn onRelease(compositor: *Compositor) void {
    const host = compositor.shell orelse return;
    host.closeRole(.switcher);
    host.closeRole(.shade);
}

test "pid mismatch is unauthorized" {
    try testing.expect(!pidAllowed(2, 1));
    try testing.expect(!pidAllowed(1, null));
    try testing.expect(pidAllowed(7, 7));
}

test "commit_surface requires a live matching open" {
    try testing.expect(!openMatches(null, null, 1, .ring));
    try testing.expect(!openMatches(2, .ring, 1, .ring));
    try testing.expect(!openMatches(1, .switcher, 1, .ring));
    try testing.expect(openMatches(4, .ring, 4, .ring));
}

test "overlayReady requires mapped positive geometry" {
    var surface: Surface = undefined;
    surface.mapped = false;
    surface.scene_geometry = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try testing.expect(!overlayReady(&surface));
    surface.mapped = true;
    try testing.expect(overlayReady(&surface));
    surface.scene_geometry = .{ .x = 0, .y = 0, .width = 0, .height = 100 };
    try testing.expect(!overlayReady(&surface));
    surface.scene_geometry = null;
    try testing.expect(!overlayReady(&surface));
}

test "writeRingToml emits [ring] slices" {
    const gpa = testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    const file_path = try std.fs.path.join(gpa, &.{ path, "ring.toml" });
    defer gpa.free(file_path);
    try writeRingToml(gpa, file_path, &default_slices);
    const body = try dir.dir.readFileAlloc(std.testing.io, "ring.toml", gpa, .limited(4096));
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "[ring]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "label = \"Launch\"") != null);
}

test "bind without pid match posts unauthorized" {
    const test_setup = wayland.test_setup;
    var runtime = try test_setup.RuntimeDir.setup(testing.allocator);
    defer runtime.cleanup();
    var server = try wayland.Server.init(testing.allocator, null);
    defer server.deinit();
    var logger = @import("core.cli").Logger.init(testing.allocator);
    defer logger.deinit();
    logger.setEnableStdout(false);
    logger.setLogLevel(.err);
    const compositor = try Compositor.init(testing.allocator, &server, &logger);
    defer {
        compositor.destroyClients();
        compositor.deinit();
    }
    try register(compositor);
    compositor.shell.?.privileged_pid = 1;

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    defer core.unix.close(fds[1]);
    const client = c.wl_client_create(server.getDisplay(), fds[0]) orelse return error.ClientCreateFailed;
    bind(client, compositor, 1, 1);
    try testing.expect(compositor.shell.?.resource == null);
}

const ShellFixture = struct {
    runtime: wayland.test_setup.RuntimeDir,
    server: wayland.Server,
    logger: @import("core.cli").Logger,
    compositor: *Compositor,

    fn setup() !*ShellFixture {
        var runtime = try wayland.test_setup.RuntimeDir.setup(testing.allocator);
        errdefer runtime.cleanup();
        var server = try wayland.Server.init(testing.allocator, null);
        errdefer server.deinit();
        const fixture = try testing.allocator.create(ShellFixture);
        errdefer testing.allocator.destroy(fixture);
        fixture.* = .{
            .runtime = runtime,
            .server = server,
            .logger = @import("core.cli").Logger.init(testing.allocator),
            .compositor = undefined,
        };
        fixture.logger.setEnableStdout(false);
        fixture.logger.setLogLevel(.err);
        errdefer fixture.logger.deinit();
        fixture.compositor = try Compositor.init(testing.allocator, &fixture.server, &fixture.logger);
        errdefer fixture.compositor.deinit();
        try register(fixture.compositor);
        return fixture;
    }

    fn cleanup(self: *ShellFixture) void {
        self.compositor.destroyClients();
        self.compositor.deinit();
        self.logger.deinit();
        self.server.deinit();
        self.runtime.cleanup();
        testing.allocator.destroy(self);
    }

    fn host(self: *ShellFixture) *Host {
        return self.compositor.shell.?;
    }
};

fn walkCompositeOverlays(compositor: *const Compositor) void {
    var index: usize = 0;
    while (index < overlay_slots) : (index += 1) {
        const surface = compositor.shellOverlay(index) orelse continue;
        _ = surface.mapped;
        _ = surface.scene_geometry;
    }
}

fn liveOverlayCount(compositor: *const Compositor) usize {
    var seen: usize = 0;
    var index: usize = 0;
    while (index < overlay_slots) : (index += 1) {
        if (compositor.shellOverlay(index) != null) seen += 1;
    }
    return seen;
}

fn mapTestSurface(compositor: *Compositor, role: Role) !*Surface {
    const surface = try compositor.createSurface();
    surface.mapped = true;
    surface.current.width = 200;
    surface.current.height = 200;
    mapOverlay(compositor.shell.?, role, surface);
    return surface;
}

fn mapTile(compositor: *Compositor) !*Surface {
    const tile = try compositor.createSurface();
    try tile.setRole(.xdg_toplevel, null);
    tile.mapped = true;
    tile.scene_geometry = .{ .x = 0, .y = 0, .width = 200, .height = 200 };
    tile.current.width = 200;
    tile.current.height = 200;
    return tile;
}

test "overlayAt composites hole roles" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    const switcher = try mapTestSurface(fixture.compositor, .switcher);
    try testing.expectNull(fixture.host().overlayAt(0));
    try testing.expectEqual(switcher, fixture.host().overlayAt(1));
    try testing.expectEqual(@as(usize, 1), liveOverlayCount(fixture.compositor));
}

test "ringReplaced ignores attach and unmapped overlays" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    fixture.host().replaced_ring = true;
    try testing.expect(!ringReplaced(fixture.compositor));
    const surface = try fixture.compositor.createSurface();
    surface.mapped = false;
    mapOverlay(fixture.host(), .ring, surface);
    try testing.expectEqual(surface, fixture.host().overlayAt(0));
    try testing.expect(!ringReplaced(fixture.compositor));
    try testing.expect(!fixture.host().replaced_ring);
    surface.mapped = true;
    try testing.expect(ringReplaced(fixture.compositor));
}

test "mapped ring overlay claims replacement" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    _ = try mapTestSurface(fixture.compositor, .ring);
    try testing.expect(ringReplaced(fixture.compositor));
    try testing.expect(fixture.host().replaced_ring);
}

test "forgetSurface of ring overlay unclaims replacement" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    const overlay = try mapTestSurface(fixture.compositor, .ring);
    try testing.expect(ringReplaced(fixture.compositor));
    fixture.compositor.destroySurface(overlay, "client destroyed wl_surface");
    try testing.expectNull(fixture.host().overlayAt(0));
    try testing.expect(!ringReplaced(fixture.compositor));
    try testing.expectFalse(fixture.host().replaced_ring);
}

test "closeRole unmaps overlay and hit-test falls through" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    const tile = try mapTile(fixture.compositor);
    const overlay = try mapTestSurface(fixture.compositor, .ring);
    const before = seat.hitTest(&.{ tile, overlay }, 10, 10).?;
    try testing.expectEqual(tile, before.surface);
    fixture.host().closeRole(.ring);
    try testing.expect(!overlay.mapped);
    try testing.expectNull(overlay.scene_geometry);
    try testing.expectNull(fixture.host().overlayAt(0));
    const after = seat.hitTest(&.{ tile, overlay }, 10, 10).?;
    try testing.expectEqual(tile, after.surface);
}

test "destroySurface forgets overlay before composite and resetAfterDeath" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    const overlay = try mapTestSurface(fixture.compositor, .switcher);
    fixture.host().replaced_ring = true;
    fixture.compositor.destroySurface(overlay, "client destroyed wl_surface");
    try testing.expectNull(fixture.host().overlayAt(1));
    try testing.expectEqual(@as(usize, 0), liveOverlayCount(fixture.compositor));
    walkCompositeOverlays(fixture.compositor);
    fixture.host().resetAfterDeath();
    try testing.expectNull(fixture.host().overlayAt(1));
    try testing.expectFalse(fixture.host().replaced_ring);
}

test "resetAfterDeath drops overlays and replaced_ring" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    const overlay = try mapTestSurface(fixture.compositor, .switcher);
    fixture.host().replaced_ring = true;
    fixture.host().resetAfterDeath();
    try testing.expectNull(fixture.host().overlayAt(0));
    try testing.expectNull(fixture.host().overlayAt(1));
    try testing.expectFalse(fixture.host().replaced_ring);
    try testing.expect(!overlay.mapped);
    try testing.expectNull(overlay.scene_geometry);
}

test "write then load ring slices" {
    const gpa = testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    const file_path = try std.fs.path.join(gpa, &.{ path, "ring.toml" });
    defer gpa.free(file_path);
    const custom = [_]Slice{
        .{ .id = 7, .label = "Mail", .icon = "mail", .has_subring = true },
        .{ .id = 8, .label = "Chat", .icon = "chat", .has_subring = false },
    };
    try writeRingToml(gpa, file_path, &custom);
    var loaded = try readRingToml(gpa, file_path);
    defer deinitSliceList(gpa, &loaded);
    try testing.expectEqual(@as(usize, 2), loaded.items.len);
    try testing.expectEqual(@as(u32, 7), loaded.items[0].id);
    try testing.expectEqualStrings("Mail", loaded.items[0].label);
    try testing.expectEqualStrings("mail", loaded.items[0].icon);
    try testing.expect(loaded.items[0].has_subring);
    try testing.expectEqualStrings("Chat", loaded.items[1].label);
    try testing.expect(!loaded.items[1].has_subring);
}

test "sliceCount uses the live list" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    fixture.host().deinitSlices(&fixture.host().live);
    try testing.expectEqual(@as(u8, 4), sliceCount(fixture.compositor));
    const extra = try fixture.host().gpa().dupe(u8, "extra");
    const icon = try fixture.host().gpa().dupe(u8, "icon");
    try fixture.host().live.append(fixture.host().gpa(), .{
        .id = 0,
        .label = extra,
        .icon = icon,
        .has_subring = false,
    });
    try testing.expectEqual(@as(u8, 1), sliceCount(fixture.compositor));
}

test "decodeWait reports exit code" {
    const decoded = decodeWait(42 << 8);
    try testing.expect(decoded.exited);
    try testing.expect(!decoded.signaled);
    try testing.expectEqual(@as(u32, 42), decoded.code);
}

test "decodeWait reports signal" {
    const decoded = decodeWait(9);
    try testing.expect(!decoded.exited);
    try testing.expect(decoded.signaled);
    try testing.expectEqual(@as(u32, 9), decoded.code);
}

test "restartPlan backs off under 100ms and caps" {
    try testing.expectEqual(Restart.spawn_now, restartPlan(100, 8));
    try testing.expectEqual(Restart.spawn_now, restartPlan(200, 8));
    try testing.expectEqual(Restart.spawn_now, restartPlan(healthy_lifetime_ms, 31));
    try testing.expectEqual(Restart.backoff, restartPlan(0, 0));
    try testing.expectEqual(Restart.backoff, restartPlan(99, 30));
    try testing.expectEqual(Restart.give_up, restartPlan(99, 31));
    try testing.expectEqual(Restart.give_up, restartPlan(200, 31));
    try testing.expectEqual(Restart.give_up, restartPlan(1, max_fast_deaths));
}

test "restartDelayMs backs off then caps" {
    try testing.expectEqual(spawn_now_delay_ms, restartDelayMs(0));
    try testing.expectEqual(@as(u32, 100), restartDelayMs(1));
    try testing.expectEqual(@as(u32, 200), restartDelayMs(2));
    try testing.expectEqual(@as(u32, 400), restartDelayMs(3));
    try testing.expectEqual(max_restart_delay_ms, restartDelayMs(16));
    try testing.expectEqual(spawn_now_delay_ms, planDelayMs(.spawn_now, 9));
}

test "classifyWait treats ECHILD as vanished and 0 as running" {
    try testing.expectEqual(.dead, classifyWait(7, 7));
    try testing.expectEqual(.running, classifyWait(0, 7));
    try testing.expectEqual(.vanished, classifyWait(-1, 7));
}

test "classifyExecRead does not invent success" {
    try testing.expectEqual(ExecRead.succeeded, classifyExecRead(0));
    try testing.expectEqual(ExecRead.pending, classifyExecRead(error.WouldBlock));
    try testing.expectError(error.ExecFailed, classifyExecRead(1));
    try testing.expectError(error.ExecFailed, classifyExecRead(error.Unexpected));
}

test "afterDeath increments attach-then-die and gives up at 32" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    const host = fixture.host();
    afterDeath(host, 200);
    try testing.expectEqual(@as(u32, 1), host.fast_deaths);
    afterDeath(host, 0);
    try testing.expectEqual(@as(u32, 2), host.fast_deaths);
    host.fast_deaths = 8;
    afterDeath(host, 250);
    try testing.expectEqual(@as(u32, 9), host.fast_deaths);
    host.fast_deaths = 31;
    afterDeath(host, 0);
    try testing.expectEqual(@as(u32, 32), host.fast_deaths);
    afterDeath(host, 150);
    try testing.expectEqual(@as(u32, 33), host.fast_deaths);
}

test "afterDeath resets cap only after a healthy lifetime" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    const host = fixture.host();
    host.fast_deaths = 8;
    afterDeath(host, healthy_lifetime_ms);
    try testing.expectEqual(@as(u32, 0), host.fast_deaths);
}

test "siblingPath joins compositor dirname" {
    const gpa = testing.allocator;
    const path = try siblingPath(gpa, "/home/dev/zig-out/bin/sideswipe");
    defer gpa.free(path);
    try testing.expectEqualStrings("/home/dev/zig-out/bin/sideswipe-shell", path);
}

test "siblingPath rejects paths without a directory" {
    try testing.expectError(error.NoDirname, siblingPath(testing.allocator, "sideswipe"));
    try testing.expectError(error.NoDirname, siblingPath(testing.allocator, "/"));
}

test "resolveBinary prefers absolute SIDESWIPE_SHELL" {
    const gpa = testing.allocator;
    const prior = try snapshotEnv(gpa);
    defer restoreEnv(gpa, prior);
    try testing.expectEqual(@as(c_int, 0), setenv("SIDESWIPE_SHELL", "/tmp/custom-shell", 1));
    const path = try resolveBinary(gpa);
    defer gpa.free(path);
    try testing.expectEqualStrings("/tmp/custom-shell", path);
}

test "resolveBinary uses sibling of this executable without SIDESWIPE_SHELL" {
    const gpa = testing.allocator;
    const prior = try snapshotEnv(gpa);
    defer restoreEnv(gpa, prior);
    _ = unsetenv("SIDESWIPE_SHELL");
    const resolved = try resolveBinary(gpa);
    defer gpa.free(resolved);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(std.Options.debug_io, &buf);
    const expected = try siblingPath(gpa, buf[0..n]);
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, resolved);
}

test "forkExec missing binary is ExecFailed" {
    var report: ExecReport = .{};
    try testing.expectError(error.ExecFailed, forkExec("/no/such/sideswipe-shell", &report));
    try testing.expectEqual(@as(i32, @intFromEnum(std.posix.E.NOENT)), report.errno);
    const decoded = decodeWait(report.wait_status);
    try testing.expect(decoded.exited);
    try testing.expectEqual(@as(u32, 127), decoded.code);
}

fn snapshotEnv(gpa: std.mem.Allocator) !?[:0]u8 {
    const raw = core.env.get("SIDESWIPE_SHELL") orelse return null;
    return try gpa.dupeZ(u8, raw);
}

fn restoreEnv(gpa: std.mem.Allocator, saved: ?[:0]u8) void {
    if (saved) |value| {
        _ = setenv("SIDESWIPE_SHELL", value, 1);
        gpa.free(value);
        return;
    }
    _ = unsetenv("SIDESWIPE_SHELL");
}

test "resetAfterDeath keeps fast_deaths for backoff" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    fixture.host().fast_deaths = 3;
    fixture.host().spawned_at_ms = 12;
    fixture.host().resetAfterDeath();
    try testing.expectEqual(@as(u32, 3), fixture.host().fast_deaths);
    try testing.expectEqual(@as(i64, 0), fixture.host().spawned_at_ms);
}

test "public clients do not advertise sideswipe_shell_v1" {
    var fixture = try ShellFixture.setup();
    defer fixture.cleanup();
    fixture.host().privileged_pid = 1;
    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    defer core.unix.close(fds[1]);
    const client = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse return error.ClientCreateFailed;
    try testing.expect(!globalFilter(client, fixture.host().global, fixture.compositor));
    try testing.expect(!pidAllowed(std.os.linux.getpid(), 1));
}
