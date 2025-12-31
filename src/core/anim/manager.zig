const std = @import("std");
const AnimatedVariable = @import("variable.zig").AnimatedVariable;
const AnimationConfig = @import("config.zig").AnimationConfig;

pub const AnimationManager = struct {
    variables: std.ArrayList(*anyopaque),
    tick_callbacks: std.ArrayList(*const fn (*anyopaque) void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnimationManager {
        return .{
            .variables = .{},
            .tick_callbacks = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnimationManager) void {
        self.variables.deinit(self.allocator);
        self.tick_callbacks.deinit(self.allocator);
    }

    /// Register an animated variable with the manager
    pub fn registerVariable(self: *AnimationManager, comptime T: type, variable: *AnimatedVariable(T)) !void {
        const type_erased = @as(*anyopaque, @ptrCast(variable));
        try self.variables.append(self.allocator, type_erased);

        // Store the tick function for this type
        const Wrapper = struct {
            fn tick(ptr: *anyopaque) void {
                const v: *AnimatedVariable(T) = @ptrCast(@alignCast(ptr));
                v.tick();
            }
        };

        try self.tick_callbacks.append(self.allocator, Wrapper.tick);
    }

    /// Unregister a variable from the manager
    pub fn unregisterVariable(self: *AnimationManager, comptime T: type, variable: *AnimatedVariable(T)) void {
        const type_erased = @as(*anyopaque, @ptrCast(variable));

        // Find and remove the variable
        for (self.variables.items, 0..) |item, i| {
            if (item == type_erased) {
                _ = self.variables.orderedRemove(i);
                _ = self.tick_callbacks.orderedRemove(i);
                return;
            }
        }
    }

    /// Tick all registered animated variables
    pub fn tick(self: *AnimationManager) void {
        for (self.variables.items, 0..) |variable, i| {
            self.tick_callbacks.items[i](variable);
        }
    }

    /// Check if any animations are currently running
    pub fn hasActiveAnimations(self: *AnimationManager, comptime T: type) bool {
        for (self.variables.items) |variable| {
            const v: *AnimatedVariable(T) = @ptrCast(@alignCast(variable));
            if (v.isBeingAnimated()) return true;
        }
        return false;
    }

    /// Pause all animations
    pub fn pauseAll(self: *AnimationManager, comptime T: type) void {
        for (self.variables.items) |variable| {
            const v: *AnimatedVariable(T) = @ptrCast(@alignCast(variable));
            v.setPaused(true);
        }
    }

    /// Resume all animations
    pub fn resumeAll(self: *AnimationManager, comptime T: type) void {
        for (self.variables.items) |variable| {
            const v: *AnimatedVariable(T) = @ptrCast(@alignCast(variable));
            v.setPaused(false);
        }
    }
};

test "AnimationManager basic" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    var config = AnimationConfig.init();
    config.setStyle(.linear);

    var anim1 = AnimatedVariable(f32).init(0.0, config);
    anim1.setDuration(100);

    var anim2 = AnimatedVariable(f32).init(0.0, config);
    anim2.setDuration(100);

    try manager.registerVariable(f32, &anim1);
    try manager.registerVariable(f32, &anim2);

    anim1.setValue(100.0);
    anim2.setValue(100.0);

    // Simulate time
    anim1.animation_data.started_time = std.time.milliTimestamp() - 50;
    anim2.animation_data.started_time = std.time.milliTimestamp() - 50;

    manager.tick();

    try std.testing.expect(anim1.value > 40.0 and anim1.value < 60.0);
    try std.testing.expect(anim2.value > 40.0 and anim2.value < 60.0);
}

test "AnimationManager unregister" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);

    try manager.registerVariable(f32, &anim);
    try std.testing.expectEqual(@as(usize, 1), manager.variables.items.len);

    manager.unregisterVariable(f32, &anim);
    try std.testing.expectEqual(@as(usize, 0), manager.variables.items.len);
}

test "AnimationManager hasActiveAnimations" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);
    anim.setDuration(100);

    try manager.registerVariable(f32, &anim);

    try std.testing.expect(!manager.hasActiveAnimations(f32));

    anim.setValue(100.0);
    try std.testing.expect(manager.hasActiveAnimations(f32));
}

test "AnimationManager pause and resume" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);
    anim.setDuration(100);

    try manager.registerVariable(f32, &anim);

    anim.setValue(100.0);
    manager.pauseAll(f32);

    try std.testing.expect(anim.animation_data.paused);

    manager.resumeAll(f32);
    try std.testing.expect(!anim.animation_data.paused);
}
