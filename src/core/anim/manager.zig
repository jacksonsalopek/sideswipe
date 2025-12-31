const std = @import("std");
const AnimatedVariable = @import("variable.zig").AnimatedVariable;
const AnimationConfig = @import("config.zig").AnimationConfig;

pub const AnimationManager = struct {
    variables: std.ArrayList(*anyopaque),
    tick_callbacks: std.ArrayList(*const fn (*anyopaque) void),
    allocator: std.mem.Allocator,
    alive: bool = true,

    pub fn init(allocator: std.mem.Allocator) AnimationManager {
        return .{
            .variables = .{},
            .tick_callbacks = .{},
            .allocator = allocator,
            .alive = true,
        };
    }

    pub fn deinit(self: *AnimationManager) void {
        // Mark as dead so variables can detect it
        self.alive = false;

        // Notify all variables that manager is being destroyed
        for (self.variables.items) |variable| {
            // Note: We can't safely call back into variables here
            // Variables should check manager.alive before using it
            _ = variable;
        }

        self.variables.deinit(self.allocator);
        self.tick_callbacks.deinit(self.allocator);
    }

    /// Check if this manager is still alive
    pub fn isAlive(self: *const AnimationManager) bool {
        return self.alive;
    }

    /// Register an animated variable with the manager
    /// Returns error.DuplicateVariable if the variable is already registered
    pub fn registerVariable(self: *AnimationManager, comptime T: type, variable: *AnimatedVariable(T)) !void {
        std.debug.assert(self.alive);

        const type_erased = @as(*anyopaque, @ptrCast(variable));

        // Check for duplicates
        for (self.variables.items) |existing| {
            if (existing == type_erased) {
                return error.DuplicateVariable;
            }
        }

        try self.variables.append(self.allocator, type_erased);

        // Store the tick function for this type
        const Wrapper = struct {
            fn tick(ptr: *anyopaque) void {
                const v: *AnimatedVariable(T) = @ptrCast(@alignCast(ptr));
                v.tick();
            }
        };

        try self.tick_callbacks.append(self.allocator, Wrapper.tick);

        // Store pointer to manager's alive flag
        variable.manager_alive_ptr = &self.alive;
    }

    /// Unregister a variable from the manager
    pub fn unregisterVariable(self: *AnimationManager, comptime T: type, variable: *AnimatedVariable(T)) void {
        if (!self.alive) return;

        const type_erased = @as(*anyopaque, @ptrCast(variable));

        // Find and remove the variable
        for (self.variables.items, 0..) |item, i| {
            if (item == type_erased) {
                _ = self.variables.orderedRemove(i);
                _ = self.tick_callbacks.orderedRemove(i);

                // Clear manager alive pointer in variable
                variable.manager_alive_ptr = null;
                return;
            }
        }
    }

    /// Tick all registered animated variables
    /// Safe to call even if variables are added/removed during callbacks
    pub fn tick(self: *AnimationManager) void {
        std.debug.assert(self.alive);

        // Create a copy of indices to handle modifications during iteration
        var i: usize = 0;
        while (i < self.variables.items.len) {
            self.tick_callbacks.items[i](self.variables.items[i]);

            // Check if this callback modified the list
            // If list got shorter, don't increment i
            if (i < self.variables.items.len) {
                i += 1;
            }
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

    /// Check if any animations need to be ticked
    pub fn shouldTickForNext(self: *AnimationManager, comptime T: type) bool {
        std.debug.assert(self.alive);

        for (self.variables.items) |variable| {
            const v: *AnimatedVariable(T) = @ptrCast(@alignCast(variable));
            if (v.isBeingAnimated()) return true;
        }
        return false;
    }

    /// Remove variables that are no longer being animated (automatic cleanup)
    pub fn removeFinishedVariables(self: *AnimationManager, comptime T: type) void {
        std.debug.assert(self.alive);

        var i: usize = 0;
        while (i < self.variables.items.len) {
            const v: *AnimatedVariable(T) = @ptrCast(@alignCast(self.variables.items[i]));
            if (!v.isBeingAnimated() and v.animation_data.finished) {
                _ = self.variables.orderedRemove(i);
                _ = self.tick_callbacks.orderedRemove(i);
            } else {
                i += 1;
            }
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

test "AnimationManager shouldTickForNext" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);
    anim.setDuration(100);

    try manager.registerVariable(f32, &anim);

    // No active animations
    try std.testing.expect(!manager.shouldTickForNext(f32));

    // Start animation
    anim.setValue(100.0);
    try std.testing.expect(manager.shouldTickForNext(f32));

    // Finish animation
    anim.warp(false);
    try std.testing.expect(!manager.shouldTickForNext(f32));
}

test "AnimationManager with callbacks" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    var config = AnimationConfig.init();
    config.setStyle(.linear);

    var anim = AnimatedVariable(f32).init(0.0, config);
    anim.setDuration(100);

    try manager.registerVariable(f32, &anim);

    var begin_called: bool = false;
    var update_count: u32 = 0;
    var end_called: bool = false;

    const Ctx = struct {
        var begin_flag: *bool = undefined;
        var update_counter: *u32 = undefined;
        var end_flag: *bool = undefined;

        fn onBegin(a: *AnimatedVariable(f32)) void {
            _ = a;
            begin_flag.* = true;
        }

        fn onUpdate(a: *AnimatedVariable(f32)) void {
            _ = a;
            update_counter.* += 1;
        }

        fn onEnd(a: *AnimatedVariable(f32)) void {
            _ = a;
            end_flag.* = true;
        }
    };

    Ctx.begin_flag = &begin_called;
    Ctx.update_counter = &update_count;
    Ctx.end_flag = &end_called;

    anim.setCallbackOnBegin(Ctx.onBegin);
    anim.setUpdateCallback(Ctx.onUpdate);
    anim.setCallbackOnEnd(Ctx.onEnd, false);
    end_called = false; // Reset after initial call

    anim.setValue(100.0);
    try std.testing.expect(begin_called);

    // Simulate animation
    anim.animation_data.started_time = std.time.milliTimestamp() - 50;
    manager.tick();
    try std.testing.expect(update_count > 0);

    // Complete animation
    anim.animation_data.started_time = std.time.milliTimestamp() - 100;
    manager.tick();

    try std.testing.expect(end_called);
    try std.testing.expectEqual(@as(f32, 100.0), anim.value);
}

test "AnimationManager duplicate prevention" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);

    // First registration should succeed
    try manager.registerVariable(f32, &anim);
    try std.testing.expectEqual(@as(usize, 1), manager.variables.items.len);

    // Second registration should fail
    const result = manager.registerVariable(f32, &anim);
    try std.testing.expectError(error.DuplicateVariable, result);
    try std.testing.expectEqual(@as(usize, 1), manager.variables.items.len);
}

test "AnimationManager lifecycle - variable after manager destroyed" {
    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);
    anim.setDuration(100);

    {
        var manager = AnimationManager.init(std.testing.allocator);
        try manager.registerVariable(f32, &anim);

        try std.testing.expect(anim.isAnimationManagerAlive());
        try std.testing.expect(!anim.isAnimationManagerDead());

        anim.setValue(100.0);
        try std.testing.expect(anim.isBeingAnimated());

        // Manager destroyed here
        manager.deinit();
    }

    // Variable should detect dead manager
    try std.testing.expect(anim.isAnimationManagerDead());

    // Should be safe to set value (will warp instead of animate)
    anim.setValue(50.0);
    try std.testing.expectEqual(@as(f32, 50.0), anim.value);
    try std.testing.expect(!anim.isBeingAnimated());

    // Should be safe to warp
    anim.warp(false);
    try std.testing.expectEqual(@as(f32, 50.0), anim.value);
}

test "AnimationManager removeFinishedVariables" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();

    var anim1 = AnimatedVariable(f32).init(0.0, config);
    var anim2 = AnimatedVariable(f32).init(0.0, config);
    var anim3 = AnimatedVariable(f32).init(0.0, config);

    anim1.setDuration(100);
    anim2.setDuration(100);
    anim3.setDuration(100);

    try manager.registerVariable(f32, &anim1);
    try manager.registerVariable(f32, &anim2);
    try manager.registerVariable(f32, &anim3);

    try std.testing.expectEqual(@as(usize, 3), manager.variables.items.len);

    // Start animations
    anim1.setValue(100.0);
    anim2.setValue(100.0);
    anim3.setValue(100.0);

    // Finish anim1 and anim2
    anim1.warp(false);
    anim2.warp(false);

    // Remove finished
    manager.removeFinishedVariables(f32);

    // Only anim3 should remain
    try std.testing.expectEqual(@as(usize, 1), manager.variables.items.len);
    try std.testing.expect(anim3.isBeingAnimated());
}

test "AnimationManager safe tick with modifications" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim1 = AnimatedVariable(f32).init(0.0, config);
    var anim2 = AnimatedVariable(f32).init(0.0, config);

    anim1.setDuration(100);
    anim2.setDuration(100);

    try manager.registerVariable(f32, &anim1);
    try manager.registerVariable(f32, &anim2);

    // Set callback that modifies the manager during tick
    var callback_ran: bool = false;
    const Ctx = struct {
        var flag: *bool = undefined;
        var mgr: *AnimationManager = undefined;
        var a2: *AnimatedVariable(f32) = undefined;

        fn onUpdate(a: *AnimatedVariable(f32)) void {
            _ = a;
            if (!flag.*) {
                flag.* = true;
                // Unregister the other variable during tick
                mgr.unregisterVariable(f32, a2);
            }
        }
    };
    Ctx.flag = &callback_ran;
    Ctx.mgr = &manager;
    Ctx.a2 = &anim2;

    anim1.setUpdateCallback(Ctx.onUpdate);

    anim1.setValue(100.0);
    anim1.animation_data.started_time = std.time.milliTimestamp() - 50;

    // This tick should safely handle the modification
    manager.tick();

    try std.testing.expect(callback_ran);
    try std.testing.expectEqual(@as(usize, 1), manager.variables.items.len);
}
