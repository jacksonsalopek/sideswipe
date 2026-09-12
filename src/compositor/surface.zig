//! Surface state management
//! Handles wl_surface state with double-buffered pending/committed states

const std = @import("std");
const core = @import("core");
const math = @import("core.math");
const c = @import("wayland").c;

const Compositor = @import("compositor.zig").Compositor;

const BufferListener = struct {
    allocator: std.mem.Allocator,
    state: *BufferState,
    listener: c.wl_listener,
};

pub const ViewportSource = struct { x: i32, y: i32, width: i32, height: i32 };
pub const ViewportDestination = struct { width: i32, height: i32 };
pub const InputRect = struct { x: i64, y: i64, width: i64, height: i64 };

pub const ViewportState = struct {
    source: ?ViewportSource = null,
    destination: ?ViewportDestination = null,
    source_set: bool = false,
    destination_set: bool = false,

    fn reset(self: *ViewportState) void {
        self.source_set = false;
        self.destination_set = false;
    }
};

/// Surface buffer state
pub const BufferState = struct {
    /// Currently attached buffer resource
    buffer: ?*c.wl_resource = null,
    /// Buffer offset on X axis
    dx: i32 = 0,
    /// Buffer offset on Y axis
    dy: i32 = 0,
    /// Buffer scale factor
    scale: i32 = 1,
    /// Buffer transform (rotation/flip)
    transform: u32 = 0,
    /// Whether this attachment still needs a wl_buffer.release event
    needs_release: bool = false,
    /// Whether attach was requested, including an explicit null detach.
    attached: bool = false,
    scale_set: bool = false,
    transform_set: bool = false,
    listener: ?*BufferListener = null,

    pub fn reset(self: *BufferState) void {
        self.buffer = null;
        self.dx = 0;
        self.dy = 0;
        self.needs_release = false;
        self.attached = false;
        self.scale_set = false;
        self.transform_set = false;
        self.listener = null;
    }
};

/// Surface damage tracking
pub const DamageState = struct {
    /// Damaged regions in surface coordinates
    surface_damage: std.ArrayList(math.Box),
    /// Damaged regions in buffer coordinates
    buffer_damage: std.ArrayList(math.Box),

    pub fn init() DamageState {
        return .{
            .surface_damage = std.ArrayList(math.Box).empty,
            .buffer_damage = std.ArrayList(math.Box).empty,
        };
    }

    pub fn deinit(self: *DamageState, allocator: std.mem.Allocator) void {
        self.surface_damage.deinit(allocator);
        self.buffer_damage.deinit(allocator);
    }

    pub fn reset(self: *DamageState) void {
        self.surface_damage.clearRetainingCapacity();
        self.buffer_damage.clearRetainingCapacity();
    }

    pub fn addSurfaceDamage(self: *DamageState, allocator: std.mem.Allocator, box: math.Box) !void {
        try self.surface_damage.append(allocator, box);
    }

    pub fn addBufferDamage(self: *DamageState, allocator: std.mem.Allocator, box: math.Box) !void {
        try self.buffer_damage.append(allocator, box);
    }
};

/// Frame callback data
pub const FrameCallback = struct {
    resource: *c.wl_resource,
    next: ?*FrameCallback = null,
};

/// Surface role type
pub const Role = enum {
    none,
    xdg_toplevel,
    xdg_popup,
    subsurface,
    cursor,
};

/// Main surface structure
pub const Surface = struct {
    allocator: std.mem.Allocator,
    compositor: *Compositor,
    id: u32,
    resource: ?*c.wl_resource = null,

    /// Surface role (can only be set once)
    role: Role = .none,
    role_data: ?*anyopaque = null,

    /// Pending state (accumulates until commit)
    pending: struct {
        buffer: BufferState = .{},
        damage: DamageState,
        opaque_region: std.ArrayList(math.Box),
        input_region: std.ArrayList(InputRect),
        input_region_set: bool = false,
        input_region_infinite: bool = true,
        frame_callbacks: std.ArrayList(*FrameCallback),
        viewport: ViewportState = .{},
    },

    /// Committed state (applied on commit)
    current: struct {
        buffer: BufferState = .{},
        damage: DamageState,
        width: i32 = 0,
        height: i32 = 0,
        input_region: std.ArrayList(InputRect),
        input_region_infinite: bool = true,
        frame_callbacks: std.ArrayList(*FrameCallback),
        viewport: ViewportState = .{},
    },
    cached: struct {
        buffer: BufferState = .{},
        damage: DamageState,
        input_region: std.ArrayList(InputRect),
        input_region_set: bool = false,
        input_region_infinite: bool = true,
        frame_callbacks: std.ArrayList(*FrameCallback),
        viewport: ViewportState = .{},
        committed: bool = false,
    },

    /// Parent surface for subsurfaces
    parent: ?*Surface = null,
    /// Child subsurfaces
    children: std.ArrayList(*Surface),
    pending_children: std.ArrayList(*Surface),
    pending_children_active: bool = false,
    subsurface_x: i32 = 0,
    subsurface_y: i32 = 0,
    subsurface_synchronized: bool = true,
    subsurface_above_parent: bool = true,
    pending_subsurface_above_parent: ?bool = null,
    subsurface_resource: ?*c.wl_resource = null,
    pending_subsurface_position: ?struct { x: i32, y: i32 } = null,
    pending_subsurface_stack: ?struct {
        sibling: *Surface,
        above: bool,
        sequence: u64,
    } = null,
    next_subsurface_stack_sequence: u64 = 1,

    /// Whether the surface has been mapped
    mapped: bool = false,
    /// Fractional-scale object, at most one per surface.
    fractional_scale_resource: ?*c.wl_resource = null,
    /// Viewporter object, at most one per surface.
    viewport_resource: ?*c.wl_resource = null,
    /// XDG surface object, at most one per wl_surface.
    xdg_surface_resource: ?*c.wl_resource = null,
    map_handler: ?*const fn (*Surface, bool) void = null,
    close_context: ?*anyopaque = null,
    close_handler: ?*const fn (*anyopaque) void = null,
    scene_geometry: ?struct { x: i32, y: i32, width: i32, height: i32 } = null,

    const Self = @This();

    pub const Error = error{
        OutOfMemory,
    };

    /// Creates a new surface
    pub fn init(allocator: std.mem.Allocator, compositor: *Compositor, id: u32) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .compositor = compositor,
            .id = id,
            .pending = .{
                .damage = DamageState.init(),
                .opaque_region = std.ArrayList(math.Box).empty,
                .input_region = std.ArrayList(InputRect).empty,
                .frame_callbacks = std.ArrayList(*FrameCallback).empty,
            },
            .current = .{
                .damage = DamageState.init(),
                .input_region = .empty,
                .frame_callbacks = std.ArrayList(*FrameCallback).empty,
            },
            .cached = .{
                .damage = DamageState.init(),
                .input_region = .empty,
                .frame_callbacks = std.ArrayList(*FrameCallback).empty,
            },
            .children = std.ArrayList(*Surface).empty,
            .pending_children = std.ArrayList(*Surface).empty,
        };

        compositor.logger.debug("Surface {d}: Created", .{id});
        return self;
    }

    /// Destroys the surface
    pub fn deinit(self: *Self) void {
        if (self.xdg_surface_resource) |resource| {
            self.xdg_surface_resource = null;
            c.wl_resource_destroy(resource);
        }
        if (self.viewport_resource) |resource| {
            self.viewport_resource = null;
            c.wl_resource_destroy(resource);
        }
        if (self.fractional_scale_resource) |resource| {
            self.fractional_scale_resource = null;
            c.wl_resource_destroy(resource);
        }
        if (self.subsurface_resource) |resource| {
            self.subsurface_resource = null;
            c.wl_resource_destroy(resource);
        }
        self.unmapDescendants();
        if (self.parent) |parent| parent.removeChild(self);
        for (self.children.items) |child| child.parent = null;
        if (self.compositor.destroying_clients) {
            self.discardOwnedBuffers();
        } else {
            self.releaseOwnedBuffers();
        }

        // Clean up pending frame callbacks
        for (self.pending.frame_callbacks.items) |callback| {
            c.wl_resource_destroy(callback.resource);
            self.allocator.destroy(callback);
        }
        self.pending.damage.deinit(self.allocator);
        self.pending.opaque_region.deinit(self.allocator);
        self.pending.input_region.deinit(self.allocator);
        self.pending.frame_callbacks.deinit(self.allocator);

        // Clean up current frame callbacks
        for (self.current.frame_callbacks.items) |callback| {
            c.wl_resource_destroy(callback.resource);
            self.allocator.destroy(callback);
        }
        self.current.damage.deinit(self.allocator);
        self.current.input_region.deinit(self.allocator);
        self.current.frame_callbacks.deinit(self.allocator);
        for (self.cached.frame_callbacks.items) |callback| {
            c.wl_resource_destroy(callback.resource);
            self.allocator.destroy(callback);
        }
        self.cached.damage.deinit(self.allocator);
        self.cached.input_region.deinit(self.allocator);
        self.cached.frame_callbacks.deinit(self.allocator);

        self.children.deinit(self.allocator);
        self.pending_children.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Sets the surface resource
    pub fn setResource(self: *Self, resource: *c.wl_resource) void {
        self.resource = resource;
    }

    pub fn requestClose(self: *Self) void {
        const context = self.close_context orelse return;
        const handler = self.close_handler orelse return;
        handler(context);
    }

    /// Attaches a buffer to the pending state
    pub fn attach(self: *Self, buffer: ?*c.wl_resource, dx: i32, dy: i32) Error!void {
        if (buffer) |buf| {
            self.compositor.logger.debug("Surface {d}: Attached buffer @{*} (dx={d}, dy={d})", .{ self.id, buf, dx, dy });
        } else {
            self.compositor.logger.debug("Surface {d}: Detached buffer", .{self.id});
        }
        if (buffer != null and self.pending.buffer.buffer == buffer) {
            self.pending.buffer.dx = dx;
            self.pending.buffer.dy = dy;
            self.pending.buffer.attached = true;
            return;
        }
        const listener = if (buffer) |resource|
            try createBufferListener(self.allocator, &self.pending.buffer, resource)
        else
            null;
        errdefer if (listener) |created| destroyBufferListener(created);

        releaseBuffer(&self.pending.buffer);
        self.pending.buffer.buffer = buffer;
        self.pending.buffer.dx = dx;
        self.pending.buffer.dy = dy;
        self.pending.buffer.needs_release = buffer != null;
        self.pending.buffer.attached = true;
        self.pending.buffer.listener = listener;
        if (listener) |installed| installed.state = &self.pending.buffer;
    }

    /// Adds damage to the pending state (surface coordinates)
    pub fn damage(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
        const box = math.Box{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        self.compositor.logger.trace("Surface {d}: Added surface damage ({d},{d} {d}x{d})", .{ self.id, x, y, width, height });
        try self.pending.damage.addSurfaceDamage(self.allocator, box);
    }

    /// Adds damage to the pending state (buffer coordinates)
    pub fn damageBuffer(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
        const box = math.Box{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        self.compositor.logger.trace("Surface {d}: Added buffer damage ({d},{d} {d}x{d})", .{ self.id, x, y, width, height });
        try self.pending.damage.addBufferDamage(self.allocator, box);
    }

    /// Adds a frame callback to the pending state
    pub fn frame(self: *Self, callback: *FrameCallback) Error!void {
        self.compositor.logger.trace("Surface {d}: Added frame callback @{*}", .{ self.id, callback.resource });
        try self.pending.frame_callbacks.append(self.allocator, callback);
    }

    /// Sets the surface scale
    pub fn setScale(self: *Self, scale: i32) void {
        self.pending.buffer.scale = scale;
        self.pending.buffer.scale_set = true;
    }

    /// Sets the surface transform
    pub fn setTransform(self: *Self, transform: u32) void {
        self.pending.buffer.transform = transform;
        self.pending.buffer.transform_set = true;
    }

    pub fn setViewportSource(self: *Self, source: ?ViewportSource) void {
        self.pending.viewport.source = source;
        self.pending.viewport.source_set = true;
    }

    pub fn setViewportDestination(self: *Self, destination: ?ViewportDestination) void {
        self.pending.viewport.destination = destination;
        self.pending.viewport.destination_set = true;
    }

    pub fn setInputRegion(self: *Self, rectangles: ?[]const InputRect) Error!void {
        var replacement = std.ArrayList(InputRect).empty;
        errdefer replacement.deinit(self.allocator);
        if (rectangles) |region| try replacement.appendSlice(self.allocator, region);
        self.pending.input_region.deinit(self.allocator);
        self.pending.input_region = replacement;
        self.pending.input_region_set = true;
        self.pending.input_region_infinite = rectangles == null;
    }

    pub fn acceptsInput(self: *const Self, x: f64, y: f64) bool {
        if (self.current.input_region_infinite) return true;
        for (self.current.input_region.items) |rectangle| {
            const right = rectangle.x + rectangle.width;
            const bottom = rectangle.y + rectangle.height;
            if (x >= @as(f64, @floatFromInt(rectangle.x)) and
                y >= @as(f64, @floatFromInt(rectangle.y)) and
                x < @as(f64, @floatFromInt(right)) and
                y < @as(f64, @floatFromInt(bottom)))
                return true;
        }
        return false;
    }

    pub const CommitValidationError = error{
        InvalidScale,
        InvalidSize,
        ViewportBadSize,
        ViewportOutOfBuffer,
    };

    pub fn validatePendingState(self: *const Self) CommitValidationError!void {
        const scale = effectiveBufferScale(self);
        const dimensions = effectiveBufferDimensions(self) orelse return;
        const source = effectiveViewportSource(self);
        const destination = effectiveViewportDestination(self);
        const transform = effectiveBufferTransform(self);
        try validateCommitDimensions(dimensions.width, dimensions.height, scale, transform, source, destination);
    }

    /// Commits the pending state to current state
    pub fn commit(self: *Self) void {
        if (self.isEffectivelySynchronized()) {
            self.cachePending();
            return;
        }
        self.applyPending();
        self.applySynchronizedDescendants();
    }

    pub fn isEffectivelySynchronized(self: *const Self) bool {
        if (self.role != .subsurface) return false;
        if (self.subsurface_synchronized) return true;
        var ancestor = self.parent;
        while (ancestor) |surface| : (ancestor = surface.parent) {
            if (surface.role == .subsurface and surface.subsurface_synchronized) return true;
        }
        return false;
    }

    pub fn setSubsurfacePosition(self: *Self, x: i32, y: i32) void {
        self.pending_subsurface_position = .{ .x = x, .y = y };
    }

    pub fn setSubsurfaceStack(self: *Self, sibling: *Surface, above: bool) Error!void {
        const parent = self.parent orelse return;
        try parent.ensurePendingChildOrder();
        parent.reorderPendingChild(self, sibling, above);
        self.pending_subsurface_stack = .{
            .sibling = sibling,
            .above = above,
            .sequence = parent.next_subsurface_stack_sequence,
        };
        parent.next_subsurface_stack_sequence +%= 1;
    }

    pub fn desynchronize(self: *Self) void {
        self.subsurface_synchronized = false;
        if (self.isEffectivelySynchronized()) return;
        self.applyCached();
        self.applySynchronizedDescendants();
        self.compositor.scheduleFrame();
    }

    fn cachePending(self: *Self) void {
        if (self.pending.buffer.attached) self.replaceCachedBuffer();
        if (self.pending.buffer.scale_set) {
            self.cached.buffer.scale = self.pending.buffer.scale;
            self.cached.buffer.scale_set = true;
        }
        if (self.pending.buffer.transform_set) {
            self.cached.buffer.transform = self.pending.buffer.transform;
            self.cached.buffer.transform_set = true;
        }
        appendDamage(&self.cached.damage, &self.pending.damage, self.allocator);
        moveCallbacks(&self.cached.frame_callbacks, &self.pending.frame_callbacks, self.allocator);
        moveInputRegionToCache(self);
        applyViewportState(&self.cached.viewport, self.pending.viewport);
        self.cached.committed = true;
        self.clearPending();
    }

    fn applyPending(self: *Self) void {
        if (self.pending.buffer.attached) self.replaceCurrentBuffer(self.pending.buffer);
        self.applyBufferProperties(self.pending.buffer);
        self.replaceCurrentDamage(&self.pending.damage);
        moveCallbacks(&self.current.frame_callbacks, &self.pending.frame_callbacks, self.allocator);
        movePendingInputRegion(self);
        applyViewportState(&self.current.viewport, self.pending.viewport);
        self.clearPending();
        self.finishAppliedCommit();
    }

    fn applyCached(self: *Self) void {
        if (!self.cached.committed) return;
        if (self.cached.buffer.attached) self.replaceCurrentBuffer(self.cached.buffer);
        self.applyBufferProperties(self.cached.buffer);
        self.replaceCurrentDamage(&self.cached.damage);
        moveCallbacks(&self.current.frame_callbacks, &self.cached.frame_callbacks, self.allocator);
        moveCachedInputRegion(self);
        applyViewportState(&self.current.viewport, self.cached.viewport);
        self.cached.buffer.reset();
        self.cached.damage.reset();
        self.cached.input_region_set = false;
        self.cached.viewport.reset();
        self.cached.committed = false;
        self.finishAppliedCommit();
    }

    fn applySynchronizedDescendants(self: *Self) void {
        self.applySynchronizedDescendantsAtDepth(0);
    }

    fn applySynchronizedDescendantsAtDepth(self: *Self, depth: usize) void {
        if (depth >= 256) return;
        self.applyChildSubsurfaceStates();
        for (self.children.items) |child| {
            child.applyCached();
            child.applySynchronizedDescendantsAtDepth(depth + 1);
        }
    }

    fn applyChildSubsurfaceStates(self: *Self) void {
        for (self.children.items) |child| child.applySubsurfacePosition();
        if (!self.pending_children_active) return;
        std.mem.swap(std.ArrayList(*Surface), &self.children, &self.pending_children);
        self.pending_children.clearRetainingCapacity();
        self.pending_children_active = false;
        for (self.children.items) |child| {
            child.pending_subsurface_stack = null;
            if (child.pending_subsurface_above_parent) |above| child.subsurface_above_parent = above;
            child.pending_subsurface_above_parent = null;
        }
    }

    fn applySubsurfacePosition(self: *Self) void {
        const position = self.pending_subsurface_position orelse return;
        self.subsurface_x = position.x;
        self.subsurface_y = position.y;
        self.pending_subsurface_position = null;
    }

    fn applySubsurfaceStack(self: *Self) void {
        const stack = self.pending_subsurface_stack orelse return;
        self.pending_subsurface_stack = null;
        const parent = self.parent orelse return;
        parent.reorderChild(self, stack.sibling, stack.above);
    }

    fn nextChildWithPendingStack(self: *Self) ?*Surface {
        var next: ?*Surface = null;
        for (self.children.items) |child| {
            const stack = child.pending_subsurface_stack orelse continue;
            const selected = next orelse {
                next = child;
                continue;
            };
            if (stack.sequence < selected.pending_subsurface_stack.?.sequence) next = child;
        }
        return next;
    }

    fn replaceCachedBuffer(self: *Self) void {
        replaceBufferReference(&self.cached.buffer, &self.pending.buffer);
        moveBufferAttachment(&self.cached.buffer, &self.pending.buffer);
        self.cached.buffer.dx = self.pending.buffer.dx;
        self.cached.buffer.dy = self.pending.buffer.dy;
        self.cached.buffer.attached = true;
    }

    fn replaceCurrentBuffer(self: *Self, next: BufferState) void {
        _ = next;
        const source = if (self.cached.buffer.attached) &self.cached.buffer else &self.pending.buffer;
        replaceBufferReference(&self.current.buffer, source);
        const scale = self.current.buffer.scale;
        const transform = self.current.buffer.transform;
        moveBufferAttachment(&self.current.buffer, source);
        self.current.buffer.dx = source.dx;
        self.current.buffer.dy = source.dy;
        if (!source.scale_set) self.current.buffer.scale = scale;
        if (!source.transform_set) self.current.buffer.transform = transform;
        self.current.buffer.attached = false;
        self.current.buffer.scale_set = false;
        self.current.buffer.transform_set = false;
    }

    fn applyBufferProperties(self: *Self, state: BufferState) void {
        if (state.scale_set) self.current.buffer.scale = state.scale;
        if (state.transform_set) self.current.buffer.transform = state.transform;
    }

    fn replaceCurrentDamage(self: *Self, pending_damage: *DamageState) void {
        self.current.damage.deinit(self.allocator);
        self.current.damage = pending_damage.*;
        pending_damage.* = DamageState.init();
    }

    fn clearPending(self: *Self) void {
        self.pending.buffer.reset();
        self.pending.damage.reset();
        self.pending.opaque_region.clearRetainingCapacity();
        self.pending.input_region.clearRetainingCapacity();
        self.pending.input_region_set = false;
        self.pending.viewport.reset();
    }

    fn finishAppliedCommit(self: *Self) void {
        const was_mapped = self.mapped;
        self.mapped = self.current.buffer.buffer != null;
        if (was_mapped != self.mapped) {
            if (self.map_handler) |handler| {
                handler(self, self.mapped);
                return;
            }
        }
        if (self.mapped or was_mapped) self.compositor.scheduleFrame();
    }

    /// Sets the surface role
    /// Returns error if role is already set to a different value
    pub fn setRole(self: *Self, role: Role, data: ?*anyopaque) error{RoleAssigned}!void {
        if (self.role == role and self.role_data == null) {
            self.role_data = data;
            return;
        }
        if (self.role != .none) return error.RoleAssigned;
        self.role = role;
        self.role_data = data;
    }

    /// Checks if surface has a specific role
    pub fn hasRole(self: *Self, role: Role) bool {
        return self.role == role;
    }

    /// Adds a child subsurface
    pub fn addChild(self: *Self, child: *Surface) Error!void {
        self.discardPendingChildOrder();
        try self.children.append(self.allocator, child);
        child.parent = self;
        child.subsurface_above_parent = true;
    }

    pub fn addChildAssumeCapacity(self: *Self, child: *Surface) void {
        self.discardPendingChildOrder();
        self.children.appendAssumeCapacity(child);
        child.parent = self;
        child.subsurface_above_parent = true;
    }

    pub fn destroySubsurfaceAssociation(self: *Self) void {
        if (self.parent) |parent| parent.removeChild(self);
        self.pending_subsurface_position = null;
        self.pending_subsurface_stack = null;
        self.pending_subsurface_above_parent = null;
        self.role_data = null;
        self.unmapTree();
    }

    /// Removes a child subsurface
    pub fn removeChild(self: *Self, child: *Surface) void {
        self.discardPendingChildOrder();
        for (self.children.items, 0..) |surface_child, i| {
            if (surface_child != child) continue;
            _ = self.children.orderedRemove(i);
            child.parent = null;
            self.clearStackReferences(child);
            return;
        }
    }

    fn reorderChild(self: *Self, child: *Surface, sibling: *Surface, above: bool) void {
        self.removeChildWithoutClearing(child);
        if (sibling == self) {
            child.subsurface_above_parent = above;
            const index = if (above) self.firstAboveParent() else self.firstAboveParent();
            self.children.insert(self.allocator, index, child) catch return;
            child.parent = self;
            return;
        }

        const sibling_index = self.childIndex(sibling) orelse return;
        child.subsurface_above_parent = sibling.subsurface_above_parent;
        const index = sibling_index + @intFromBool(above);
        self.children.insert(self.allocator, index, child) catch return;
        child.parent = self;
    }

    fn removeChildWithoutClearing(self: *Self, child: *Surface) void {
        const index = self.childIndex(child) orelse return;
        _ = self.children.orderedRemove(index);
        child.parent = null;
    }

    fn childIndex(self: *const Self, child: *Surface) ?usize {
        for (self.children.items, 0..) |candidate, index| {
            if (candidate == child) return index;
        }
        return null;
    }

    fn firstAboveParent(self: *const Self) usize {
        for (self.children.items, 0..) |child, index| {
            if (child.subsurface_above_parent) return index;
        }
        return self.children.items.len;
    }

    fn clearStackReferences(self: *Self, removed: *Surface) void {
        for (self.children.items) |child| {
            const stack = child.pending_subsurface_stack orelse continue;
            if (stack.sibling == removed) child.pending_subsurface_stack = null;
        }
    }

    fn ensurePendingChildOrder(self: *Self) Error!void {
        if (self.pending_children_active) return;
        self.pending_children.clearRetainingCapacity();
        try self.pending_children.appendSlice(self.allocator, self.children.items);
        self.pending_children_active = true;
    }

    fn discardPendingChildOrder(self: *Self) void {
        if (!self.pending_children_active) return;
        self.pending_children.clearRetainingCapacity();
        self.pending_children_active = false;
        for (self.children.items) |child| {
            child.pending_subsurface_stack = null;
            child.pending_subsurface_above_parent = null;
        }
    }

    fn reorderPendingChild(self: *Self, child: *Surface, sibling: *Surface, above: bool) void {
        const child_index = childIndexIn(self.pending_children.items, child) orelse return;
        _ = self.pending_children.orderedRemove(child_index);
        if (sibling == self) {
            child.pending_subsurface_above_parent = above;
            const index = pendingParentBoundary(self.pending_children.items);
            self.pending_children.insertAssumeCapacity(index, child);
            return;
        }
        const sibling_index = childIndexIn(self.pending_children.items, sibling) orelse return;
        child.pending_subsurface_above_parent = sibling.pending_subsurface_above_parent orelse sibling.subsurface_above_parent;
        self.pending_children.insertAssumeCapacity(sibling_index + @intFromBool(above), child);
    }

    fn releaseOwnedBuffers(self: *Self) void {
        releaseBuffer(&self.pending.buffer);
        releaseBuffer(&self.cached.buffer);
        releaseBuffer(&self.current.buffer);
    }

    fn unmapDescendants(self: *Self) void {
        for (self.children.items) |child| child.unmapTree();
    }

    fn unmapTree(self: *Self) void {
        self.unmapDescendants();
        const was_mapped = self.mapped;
        self.mapped = false;
        self.releaseOwnedBuffers();
        if (was_mapped) {
            if (self.map_handler) |handler| handler(self, false);
        }
    }

    fn discardOwnedBuffers(self: *Self) void {
        discardBuffer(&self.pending.buffer);
        discardBuffer(&self.cached.buffer);
        discardBuffer(&self.current.buffer);
    }
};

fn appendDamage(destination: *DamageState, source: *DamageState, allocator: std.mem.Allocator) void {
    destination.surface_damage.appendSlice(allocator, source.surface_damage.items) catch {};
    destination.buffer_damage.appendSlice(allocator, source.buffer_damage.items) catch {};
    source.reset();
}

fn moveCallbacks(destination: *std.ArrayList(*FrameCallback), source: *std.ArrayList(*FrameCallback), allocator: std.mem.Allocator) void {
    for (source.items) |callback| {
        destination.append(allocator, callback) catch {
            c.wl_resource_destroy(callback.resource);
            allocator.destroy(callback);
        };
    }
    source.clearRetainingCapacity();
}

fn moveInputRegionToCache(surface: *Surface) void {
    if (!surface.pending.input_region_set) return;
    swapInputRegions(&surface.cached.input_region, &surface.pending.input_region);
    surface.cached.input_region_infinite = surface.pending.input_region_infinite;
    surface.cached.input_region_set = true;
}

fn movePendingInputRegion(surface: *Surface) void {
    if (!surface.pending.input_region_set) return;
    swapInputRegions(&surface.current.input_region, &surface.pending.input_region);
    surface.current.input_region_infinite = surface.pending.input_region_infinite;
}

fn moveCachedInputRegion(surface: *Surface) void {
    if (!surface.cached.input_region_set) return;
    swapInputRegions(&surface.current.input_region, &surface.cached.input_region);
    surface.current.input_region_infinite = surface.cached.input_region_infinite;
}

fn swapInputRegions(
    destination: *std.ArrayList(InputRect),
    source: *std.ArrayList(InputRect),
) void {
    destination.clearRetainingCapacity();
    std.mem.swap(std.ArrayList(InputRect), destination, source);
    source.clearRetainingCapacity();
}

fn releaseBuffer(state: *BufferState) void {
    const resource = state.buffer orelse return;
    if (state.needs_release) c.wl_buffer_send_release(resource);
    if (state.listener) |listener| {
        c.wl_list_remove(&listener.listener.link);
        listener.allocator.destroy(listener);
    }
    state.buffer = null;
    state.needs_release = false;
    state.listener = null;
}

fn replaceBufferReference(current: *BufferState, next: *const BufferState) void {
    if (current.buffer != null and current.buffer == next.buffer) {
        discardBuffer(current);
        return;
    }
    releaseBuffer(current);
}

fn discardBuffer(state: *BufferState) void {
    state.needs_release = false;
    releaseBuffer(state);
}

fn createBufferListener(
    allocator: std.mem.Allocator,
    state: *BufferState,
    resource: *c.wl_resource,
) !*BufferListener {
    const listener = try allocator.create(BufferListener);
    listener.* = .{
        .allocator = allocator,
        .state = state,
        .listener = .{
            .link = undefined,
            .notify = bufferDestroyed,
        },
    };
    c.wl_resource_add_destroy_listener(resource, &listener.listener);
    return listener;
}

fn destroyBufferListener(listener: *BufferListener) void {
    c.wl_list_remove(&listener.listener.link);
    listener.allocator.destroy(listener);
}

fn bufferDestroyed(listener: ?*c.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const handle = listener orelse return;
    const buffer_listener: *BufferListener = @fieldParentPtr("listener", handle);
    buffer_listener.state.buffer = null;
    buffer_listener.state.needs_release = false;
    buffer_listener.state.listener = null;
    c.wl_list_remove(&handle.link);
    buffer_listener.allocator.destroy(buffer_listener);
}

fn moveBufferAttachment(destination: *BufferState, source: *BufferState) void {
    destination.buffer = source.buffer;
    destination.needs_release = source.needs_release;
    destination.listener = source.listener;
    if (destination.listener) |listener| listener.state = destination;
    source.buffer = null;
    source.needs_release = false;
    source.listener = null;
}

fn applyViewportState(destination: *ViewportState, source: ViewportState) void {
    if (source.source_set) {
        destination.source = source.source;
        destination.source_set = true;
    }
    if (source.destination_set) {
        destination.destination = source.destination;
        destination.destination_set = true;
    }
}

fn effectiveViewportSource(surface: *const Surface) ?ViewportSource {
    if (surface.pending.viewport.source_set) return surface.pending.viewport.source;
    return surface.current.viewport.source;
}

fn effectiveBufferScale(surface: *const Surface) i64 {
    const scale = if (surface.pending.buffer.scale_set)
        surface.pending.buffer.scale
    else
        surface.current.buffer.scale;
    return scale;
}

fn effectiveViewportDestination(surface: *const Surface) ?ViewportDestination {
    if (surface.pending.viewport.destination_set) return surface.pending.viewport.destination;
    return surface.current.viewport.destination;
}

fn effectiveBufferTransform(surface: *const Surface) u32 {
    if (surface.pending.buffer.transform_set) return surface.pending.buffer.transform;
    return surface.current.buffer.transform;
}

fn effectiveBufferDimensions(surface: *const Surface) ?struct { width: i32, height: i32 } {
    const resource = if (surface.pending.buffer.attached)
        surface.pending.buffer.buffer orelse return null
    else
        surface.current.buffer.buffer orelse return null;
    if (c.wl_shm_buffer_get(resource)) |shm| {
        return .{
            .width = c.wl_shm_buffer_get_width(shm),
            .height = c.wl_shm_buffer_get_height(shm),
        };
    }
    const linux_dmabuf = @import("protocols/linux_dmabuf.zig");
    if (!linux_dmabuf.isBuffer(resource)) return null;
    const data: *linux_dmabuf.BufferData = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    return .{ .width = data.params_data.width, .height = data.params_data.height };
}

fn transformedDimensions(width: i32, height: i32, transform: u32) struct { width: i32, height: i32 } {
    return switch (transform) {
        c.WL_OUTPUT_TRANSFORM_90,
        c.WL_OUTPUT_TRANSFORM_270,
        c.WL_OUTPUT_TRANSFORM_FLIPPED_90,
        c.WL_OUTPUT_TRANSFORM_FLIPPED_270,
        => .{ .width = height, .height = width },
        else => .{ .width = width, .height = height },
    };
}

fn viewportSourceFits(source: ViewportSource, width: i32, height: i32, scale: i64) bool {
    const max_x = @divTrunc(@as(i64, width) * 256, scale);
    const max_y = @divTrunc(@as(i64, height) * 256, scale);
    const right = @as(i64, source.x) + source.width;
    const bottom = @as(i64, source.y) + source.height;
    return right <= max_x and bottom <= max_y;
}

fn validateCommitDimensions(
    width: i32,
    height: i32,
    scale: i64,
    transform: u32,
    source: ?ViewportSource,
    destination: ?ViewportDestination,
) Surface.CommitValidationError!void {
    if (scale <= 0) return error.InvalidScale;
    if (@mod(@as(i64, width), scale) != 0 or @mod(@as(i64, height), scale) != 0)
        return error.InvalidSize;
    const viewport_source = source orelse return;
    if (destination == null and
        (@mod(viewport_source.width, 256) != 0 or @mod(viewport_source.height, 256) != 0))
        return error.ViewportBadSize;
    const transformed = transformedDimensions(width, height, transform);
    if (!viewportSourceFits(viewport_source, transformed.width, transformed.height, scale))
        return error.ViewportOutOfBuffer;
}

fn childIndexIn(children: []const *Surface, child: *Surface) ?usize {
    for (children, 0..) |candidate, index| {
        if (candidate == child) return index;
    }
    return null;
}

fn pendingParentBoundary(children: []const *Surface) usize {
    for (children, 0..) |child, index| {
        if (child.pending_subsurface_above_parent orelse child.subsurface_above_parent) return index;
    }
    return children.len;
}

fn attachTestBuffer(surface: *Surface, resource: *c.wl_resource) void {
    surface.pending.buffer.buffer = resource;
    surface.pending.buffer.needs_release = true;
    surface.pending.buffer.attached = true;
}

// Tests
const testing = core.testing;

/// Test fixture for setting up compositor test environment
pub const TestFixture = struct {
    allocator: std.mem.Allocator,
    runtime: @import("wayland").test_setup.RuntimeDir,
    server: @import("wayland").Server,
    logger: @import("core.cli").Logger,
    compositor: *Compositor,

    pub fn setup(allocator: std.mem.Allocator) !TestFixture {
        const wayland = @import("wayland");
        const cli = @import("core.cli");

        var runtime = try wayland.test_setup.RuntimeDir.setup(allocator);
        errdefer runtime.cleanup();

        var server = try wayland.Server.init(allocator, null);
        errdefer server.deinit();

        var fixture = TestFixture{
            .allocator = allocator,
            .runtime = runtime,
            .server = server,
            .logger = cli.Logger.init(allocator),
            .compositor = undefined,
        };

        fixture.logger.setLogLevel(.err); // Disable debug/info/warn logging in tests
        fixture.logger.setEnableStdout(false);
        errdefer fixture.logger.deinit();

        fixture.compositor = try Compositor.init(allocator, &fixture.server, &fixture.logger);
        errdefer fixture.compositor.deinit();

        return fixture;
    }

    pub fn cleanup(self: *TestFixture) void {
        self.compositor.deinit();
        self.logger.deinit();
        self.server.deinit();
        self.runtime.cleanup();
    }
};

test "Surface - init and deinit" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var surface = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer surface.deinit();

    try testing.expectEqual(@as(u32, 1), surface.id);
    try testing.expectEqual(Role.none, surface.role);
    try testing.expectFalse(surface.mapped);
}

test "Surface - attach and commit" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var surface = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer surface.deinit();

    // Create a dummy buffer resource (in real usage this would be a wl_resource from client)
    var dummy_resource: u32 = 0xDEADBEEF;
    const dummy_buffer: *c.wl_resource = @ptrCast(@alignCast(&dummy_resource));

    attachTestBuffer(surface, dummy_buffer);
    try testing.expectEqual(dummy_buffer, surface.pending.buffer.buffer);

    surface.commit();
    try testing.expectEqual(dummy_buffer, surface.current.buffer.buffer);
    try testing.expectEqual(@as(?*c.wl_resource, null), surface.pending.buffer.buffer);
    try testing.expect(surface.mapped);
    surface.current.buffer.needs_release = false;
}

test "Surface - damage tracking" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var surface = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer surface.deinit();

    try surface.damage(10, 20, 100, 200);
    try testing.expectEqual(@as(usize, 1), surface.pending.damage.surface_damage.items.len);

    const box = surface.pending.damage.surface_damage.items[0];
    try testing.expectEqual(@as(i32, 10), box.x);
    try testing.expectEqual(@as(i32, 20), box.y);
    try testing.expectEqual(@as(i32, 100), box.width);
    try testing.expectEqual(@as(i32, 200), box.height);
}

test "Surface - role management" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var surface = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer surface.deinit();

    try surface.setRole(.xdg_toplevel, null);
    try testing.expectEqual(Role.xdg_toplevel, surface.role);
    try testing.expect(surface.hasRole(.xdg_toplevel));

    // A destroyed role object may be recreated with the same permanent role.
    surface.role_data = null;
    try surface.setRole(.xdg_toplevel, null);
    surface.role_data = @ptrFromInt(1);
    try testing.expectError(error.RoleAssigned, surface.setRole(.xdg_toplevel, null));
    const result = surface.setRole(.xdg_popup, null);
    try testing.expectError(error.RoleAssigned, result);
}

test "Surface - parent/child relationships" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();

    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();

    try parent.addChild(child);
    try testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try testing.expectEqual(parent, child.parent);

    parent.removeChild(child);
    try testing.expectEqual(@as(usize, 0), parent.children.items.len);
    try testing.expectNull(child.parent);
}

test "Surface - commit without attach preserves current buffer" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var surface = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer surface.deinit();

    var dummy_resource: u32 = 1;
    const buffer: *c.wl_resource = @ptrCast(@alignCast(&dummy_resource));
    attachTestBuffer(surface, buffer);
    surface.commit();
    surface.setScale(2);
    surface.commit();

    try testing.expectEqual(buffer, surface.current.buffer.buffer);
    try testing.expectEqual(@as(i32, 2), surface.current.buffer.scale);
    surface.current.buffer.needs_release = false;
}

test "Surface - synchronized child applies on parent commit" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    try child.setRole(.subsurface, null);
    try parent.addChild(child);

    var dummy_resource: u32 = 2;
    const buffer: *c.wl_resource = @ptrCast(@alignCast(&dummy_resource));
    attachTestBuffer(child, buffer);
    child.commit();
    try testing.expect(child.cached.committed);
    try testing.expectFalse(child.mapped);

    parent.commit();
    try testing.expectFalse(child.cached.committed);
    try testing.expect(child.mapped);
    try testing.expectEqual(buffer, child.current.buffer.buffer);
    child.current.buffer.needs_release = false;
}

test "Surface - desynchronized child commits immediately" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    try child.setRole(.subsurface, null);
    try parent.addChild(child);
    child.desynchronize();

    var dummy_resource: u32 = 3;
    const buffer: *c.wl_resource = @ptrCast(@alignCast(&dummy_resource));
    attachTestBuffer(child, buffer);
    child.commit();
    try testing.expect(child.mapped);
    try testing.expectFalse(child.cached.committed);
    child.current.buffer.needs_release = false;
}

test "Surface - synchronized ancestor caches nested descendant" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var root = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer root.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    var grandchild = try Surface.init(testing.allocator, fixture.compositor, 3);
    defer grandchild.deinit();
    try child.setRole(.subsurface, null);
    try grandchild.setRole(.subsurface, null);
    try root.addChild(child);
    try child.addChild(grandchild);
    grandchild.subsurface_synchronized = false;

    try testing.expect(grandchild.isEffectivelySynchronized());
    try grandchild.damage(1, 2, 3, 4);
    grandchild.commit();
    try testing.expect(grandchild.cached.committed);
    root.commit();
    try testing.expectFalse(grandchild.cached.committed);
    try testing.expectEqual(@as(usize, 1), grandchild.current.damage.surface_damage.items.len);
}

test "Surface - parent commit applies position and sibling stacking" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var first = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer first.deinit();
    var second = try Surface.init(testing.allocator, fixture.compositor, 3);
    defer second.deinit();
    try first.setRole(.subsurface, null);
    try second.setRole(.subsurface, null);
    try parent.addChild(first);
    try parent.addChild(second);

    first.setSubsurfacePosition(25, -10);
    try first.setSubsurfaceStack(parent, false);
    try second.setSubsurfaceStack(first, false);
    try testing.expectEqual(@as(i32, 0), first.subsurface_x);
    parent.commit();

    try testing.expectEqual(@as(i32, 25), first.subsurface_x);
    try testing.expectEqual(@as(i32, -10), first.subsurface_y);
    try testing.expectFalse(first.subsurface_above_parent);
    try testing.expectFalse(second.subsurface_above_parent);
    try testing.expectEqual(second, parent.children.items[0]);
    try testing.expectEqual(first, parent.children.items[1]);
}

test "Surface - synchronized commits accumulate damage and callbacks" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    try child.setRole(.subsurface, null);
    try parent.addChild(child);

    try child.damage(0, 0, 10, 10);
    var callback_resource: u32 = 4;
    const callback = try testing.allocator.create(FrameCallback);
    callback.* = .{ .resource = @ptrCast(@alignCast(&callback_resource)) };
    try child.frame(callback);
    child.commit();
    try child.damageBuffer(10, 10, 5, 5);
    child.commit();
    try testing.expectEqual(@as(usize, 1), child.cached.damage.surface_damage.items.len);
    try testing.expectEqual(@as(usize, 1), child.cached.damage.buffer_damage.items.len);
    try testing.expectEqual(@as(usize, 1), child.cached.frame_callbacks.items.len);

    parent.commit();
    try testing.expectEqual(@as(usize, 1), child.current.damage.surface_damage.items.len);
    try testing.expectEqual(@as(usize, 1), child.current.damage.buffer_damage.items.len);
    try testing.expectEqual(@as(usize, 1), child.current.frame_callbacks.items.len);
    _ = child.current.frame_callbacks.pop();
    testing.allocator.destroy(callback);
}

test "Surface - removing child clears pending sibling references" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var first = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer first.deinit();
    var second = try Surface.init(testing.allocator, fixture.compositor, 3);
    defer second.deinit();
    try parent.addChild(first);
    try parent.addChild(second);
    try second.setSubsurfaceStack(first, true);

    parent.removeChild(first);
    try testing.expectNull(second.pending_subsurface_stack);
    try testing.expectNull(first.parent);
}

test "Surface - stacking requests apply in protocol order" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var first = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer first.deinit();
    var second = try Surface.init(testing.allocator, fixture.compositor, 3);
    defer second.deinit();
    var third = try Surface.init(testing.allocator, fixture.compositor, 4);
    defer third.deinit();
    try parent.addChild(first);
    try parent.addChild(second);
    try parent.addChild(third);

    try third.setSubsurfaceStack(first, false);
    try first.setSubsurfaceStack(second, true);
    parent.commit();

    try testing.expectEqual(third, parent.children.items[0]);
    try testing.expectEqual(second, parent.children.items[1]);
    try testing.expectEqual(first, parent.children.items[2]);
}

test "Surface - sequential stacking requests update pending order" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var first = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer first.deinit();
    var second = try Surface.init(testing.allocator, fixture.compositor, 3);
    defer second.deinit();
    var third = try Surface.init(testing.allocator, fixture.compositor, 4);
    defer third.deinit();
    try parent.addChild(first);
    try parent.addChild(second);
    try parent.addChild(third);

    try first.setSubsurfaceStack(third, true);
    try first.setSubsurfaceStack(second, false);
    try testing.expectEqual(first, parent.children.items[0]);
    parent.commit();

    try testing.expectEqual(first, parent.children.items[0]);
    try testing.expectEqual(second, parent.children.items[1]);
    try testing.expectEqual(third, parent.children.items[2]);
}

test "Surface - viewport state follows synchronized commits" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    try child.setRole(.subsurface, null);
    try parent.addChild(child);

    child.setViewportSource(.{ .x = 256, .y = 512, .width = 1024, .height = 768 });
    child.setViewportDestination(.{ .width = 40, .height = 30 });
    child.commit();
    try testing.expectNull(child.current.viewport.source);
    try testing.expectNull(child.current.viewport.destination);

    parent.commit();
    try testing.expectEqual(@as(i32, 256), child.current.viewport.source.?.x);
    try testing.expectEqual(@as(i32, 40), child.current.viewport.destination.?.width);
}

test "Surface - input region becomes effective only on commit" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var surface = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer surface.deinit();

    const region = [_]InputRect{.{
        .x = 10,
        .y = 20,
        .width = 30,
        .height = 40,
    }};
    try surface.setInputRegion(&region);
    try testing.expect(surface.acceptsInput(0, 0));
    surface.commit();
    try testing.expectFalse(surface.acceptsInput(0, 0));
    try testing.expect(surface.acceptsInput(15, 25));

    try surface.setInputRegion(null);
    surface.commit();
    try testing.expect(surface.acceptsInput(0, 0));
}

test "Surface - synchronized child input region applies with parent commit" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    try child.setRole(.subsurface, null);
    try parent.addChild(child);
    const region = [_]InputRect{.{
        .x = -10,
        .y = 5,
        .width = 30,
        .height = 20,
    }};

    try child.setInputRegion(&region);
    child.commit();
    try testing.expect(child.current.input_region_infinite);
    try testing.expect(child.cached.input_region_set);
    parent.commit();

    try testing.expectFalse(child.current.input_region_infinite);
    try testing.expect(child.acceptsInput(-5, 10));
    try testing.expectFalse(child.acceptsInput(25, 10));
}

test "Surface - destroyed attached buffer clears every resource pointer" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var surface = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer surface.deinit();

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer core.unix.close(fds[1]);
    const client = c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse return error.ClientCreateFailed;
    defer c.wl_client_destroy(client);
    const pending_resource = c.wl_resource_create(client, &c.wl_buffer_interface, 1, 1) orelse return error.ResourceCreateFailed;

    try surface.attach(pending_resource, 0, 0);
    try testing.expectEqual(pending_resource, surface.pending.buffer.buffer);
    c.wl_resource_destroy(pending_resource);

    try testing.expectNull(surface.pending.buffer.buffer);
    try testing.expectNull(surface.pending.buffer.listener);
    try testing.expectFalse(surface.pending.buffer.needs_release);

    const current_resource = c.wl_resource_create(client, &c.wl_buffer_interface, 1, 2) orelse return error.ResourceCreateFailed;
    try surface.attach(current_resource, 0, 0);
    surface.commit();
    c.wl_resource_destroy(current_resource);
    try testing.expectNull(surface.current.buffer.buffer);
    try testing.expectNull(surface.current.buffer.listener);

    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    try child.setRole(.subsurface, null);
    try surface.addChild(child);
    const cached_resource = c.wl_resource_create(client, &c.wl_buffer_interface, 1, 3) orelse return error.ResourceCreateFailed;
    try child.attach(cached_resource, 0, 0);
    child.commit();
    c.wl_resource_destroy(cached_resource);
    try testing.expectNull(child.cached.buffer.buffer);
    try testing.expectNull(child.cached.buffer.listener);
}

test "Surface - parent destruction detaches nested children safely" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    try child.setRole(.subsurface, null);
    try parent.addChild(child);

    parent.deinit();
    try testing.expectNull(child.parent);
    child.deinit();
}

test "Surface - unmapping a parent recursively unmaps descendant buffers" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var parent = try Surface.init(testing.allocator, fixture.compositor, 1);
    defer parent.deinit();
    var child = try Surface.init(testing.allocator, fixture.compositor, 2);
    defer child.deinit();
    var grandchild = try Surface.init(testing.allocator, fixture.compositor, 3);
    defer grandchild.deinit();
    try parent.addChild(child);
    try child.addChild(grandchild);
    parent.mapped = true;
    child.mapped = true;
    grandchild.mapped = true;
    var child_resource: u64 = 1;
    var grandchild_resource: u64 = 2;
    child.current.buffer.buffer = @ptrCast(@alignCast(&child_resource));
    grandchild.current.buffer.buffer = @ptrCast(@alignCast(&grandchild_resource));

    parent.unmapTree();

    try testing.expectFalse(parent.mapped);
    try testing.expectFalse(child.mapped);
    try testing.expectFalse(grandchild.mapped);
    try testing.expectNull(child.current.buffer.buffer);
    try testing.expectNull(grandchild.current.buffer.buffer);
}

test "Surface - buffer listener allocation failure leaves attachment tracked" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var resource_storage: u64 = 0;
    const resource: *c.wl_resource = @ptrCast(@alignCast(&resource_storage));
    var state = BufferState{
        .buffer = resource,
        .needs_release = true,
        .attached = true,
    };

    try testing.expectError(
        error.OutOfMemory,
        createBufferListener(failing.allocator(), &state, resource),
    );
    try testing.expectEqual(resource, state.buffer);
    try testing.expect(state.needs_release);
    try testing.expectNull(state.listener);
}

test "Surface - viewport source bounds account for scale" {
    try testing.expect(viewportSourceFits(
        .{ .x = 0, .y = 0, .width = 1280, .height = 768 },
        10,
        6,
        2,
    ));
    try testing.expectFalse(viewportSourceFits(
        .{ .x = 0, .y = 0, .width = 1281, .height = 768 },
        10,
        6,
        2,
    ));
}

test "Surface - commit validation rejects scale divisibility and fractional source size" {
    try testing.expectError(
        error.InvalidScale,
        validateCommitDimensions(8, 8, 0, 0, null, null),
    );
    try testing.expectError(
        error.InvalidSize,
        validateCommitDimensions(7, 8, 2, 0, null, null),
    );
    try testing.expectError(
        error.ViewportBadSize,
        validateCommitDimensions(
            8,
            8,
            1,
            0,
            .{ .x = 0, .y = 0, .width = 257, .height = 256 },
            null,
        ),
    );
    try validateCommitDimensions(
        8,
        8,
        1,
        0,
        .{ .x = 0, .y = 0, .width = 257, .height = 256 },
        .{ .width = 2, .height = 1 },
    );
}

test "Surface - commit validation rejects transformed viewport out of bounds" {
    try testing.expectError(
        error.ViewportOutOfBuffer,
        validateCommitDimensions(
            8,
            4,
            1,
            c.WL_OUTPUT_TRANSFORM_90,
            .{ .x = 0, .y = 0, .width = 5 * 256, .height = 8 * 256 },
            .{ .width = 5, .height = 8 },
        ),
    );
}
