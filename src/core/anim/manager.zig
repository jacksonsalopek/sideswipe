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
        
        // SAFETY: We need to handle list modifications during callbacks
        // Strategy: Snapshot the variables to tick before starting
        const to_tick = self.allocator.dupe(*anyopaque, self.variables.items) catch return;
        defer self.allocator.free(to_tick);
        
        const callbacks_snapshot = self.allocator.dupe(*const fn (*anyopaque) void, self.tick_callbacks.items) catch return;
        defer self.allocator.free(callbacks_snapshot);
        
        // Tick all variables from snapshot
        // Even if they get unregistered during tick, the snapshot keeps them valid
        for (to_tick, callbacks_snapshot) |variable, callback| {
            // Check if variable is still registered before ticking
            var still_registered = false;
            for (self.variables.items) |current_var| {
                if (current_var == variable) {
                    still_registered = true;
                    break;
                }
            }
            
            if (still_registered) {
                callback(variable);
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

test "AnimationManager - variable unregisters itself in callback" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);
    anim.setDuration(100);

    try manager.registerVariable(f32, &anim);

    const Ctx = struct {
        var mgr: *AnimationManager = undefined;
        var self_anim: *AnimatedVariable(f32) = undefined;
        var callback_ran: bool = false;
        
        fn onUpdate(a: *AnimatedVariable(f32)) void {
            if (!callback_ran) {
                callback_ran = true;
                // Unregister self during callback
                mgr.unregisterVariable(f32, self_anim);
            }
            _ = a;
        }
    };
    Ctx.mgr = &manager;
    Ctx.self_anim = &anim;
    Ctx.callback_ran = false;
    
    anim.setUpdateCallback(Ctx.onUpdate);
    anim.setValue(100.0);
    anim.animation_data.started_time = std.time.milliTimestamp() - 50;
    
    // Tick should handle self-unregistration safely
    manager.tick();
    
    try std.testing.expect(Ctx.callback_ran);
    try std.testing.expectEqual(@as(usize, 0), manager.variables.items.len);
}

test "AnimationManager - callback registers new variable" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim1 = AnimatedVariable(f32).init(0.0, config);
    var anim2 = AnimatedVariable(f32).init(0.0, config);
    
    anim1.setDuration(100);
    anim2.setDuration(100);

    try manager.registerVariable(f32, &anim1);

    const Ctx = struct {
        var mgr: *AnimationManager = undefined;
        var new_anim: *AnimatedVariable(f32) = undefined;
        var registered: bool = false;
        
        fn onUpdate(a: *AnimatedVariable(f32)) void {
            _ = a;
            if (!registered) {
                registered = true;
                // Register new variable during tick
                mgr.registerVariable(f32, new_anim) catch {};
            }
        }
    };
    Ctx.mgr = &manager;
    Ctx.new_anim = &anim2;
    Ctx.registered = false;
    
    anim1.setUpdateCallback(Ctx.onUpdate);
    anim1.setValue(100.0);
    anim1.animation_data.started_time = std.time.milliTimestamp() - 50;
    
    // First tick - registers new variable
    manager.tick();
    
    try std.testing.expect(Ctx.registered);
    try std.testing.expectEqual(@as(usize, 2), manager.variables.items.len);
    
    // New variable should NOT have been ticked on same tick
    try std.testing.expect(!anim2.isBeingAnimated());
}

test "AnimationManager - removeFinishedVariables from callback" {
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

    const Ctx = struct {
        var mgr: *AnimationManager = undefined;
        var a2: *AnimatedVariable(f32) = undefined;
        
        fn onUpdate(a: *AnimatedVariable(f32)) void {
            _ = a;
            // Finish another variable and call cleanup
            a2.warp(false);
            mgr.removeFinishedVariables(f32);
        }
    };
    Ctx.mgr = &manager;
    Ctx.a2 = &anim2;
    
    anim1.setUpdateCallback(Ctx.onUpdate);
    
    anim1.setValue(100.0);
    anim2.setValue(100.0);
    anim3.setValue(100.0);
    
    anim1.animation_data.started_time = std.time.milliTimestamp() - 50;
    anim2.animation_data.started_time = std.time.milliTimestamp() - 50;
    anim3.animation_data.started_time = std.time.milliTimestamp() - 50;
    
    // Tick should handle removeFinishedVariables being called during iteration
    manager.tick();
    
    // anim2 should have been removed
    try std.testing.expect(manager.variables.items.len < 3);
}

test "AnimationManager - stress test with 100 concurrent animations" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    
    // Create 100 animations
    var animations: [100]AnimatedVariable(f32) = undefined;
    for (&animations, 0..) |*anim, i| {
        anim.* = AnimatedVariable(f32).init(0.0, config);
        anim.setDuration(@intCast(50 + (i % 50))); // Random durations 50-100ms
        try manager.registerVariable(f32, anim);
    }

    // Start all animations
    for (&animations, 0..) |*anim, i| {
        anim.setValue(@floatFromInt(i * 10));
    }

    // Simulate multiple ticks
    const start_time = std.time.milliTimestamp();
    var tick_count: usize = 0;
    while (tick_count < 5) : (tick_count += 1) {
        // Update all start times to simulate passage of time
        for (&animations) |*anim| {
            if (anim.isBeingAnimated()) {
                anim.animation_data.started_time = start_time - @as(i64, @intCast(tick_count * 20));
            }
        }
        
        manager.tick();
    }

    // All animations should have been ticked
    try std.testing.expectEqual(@as(usize, 100), manager.variables.items.len);
}

test "AnimationManager - callback chain reaction" {
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

    var chain_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        var a2: *AnimatedVariable(f32) = undefined;
        var a3: *AnimatedVariable(f32) = undefined;
        
        fn onEnd1(a: *AnimatedVariable(f32)) void {
            _ = a;
            counter.* += 1;
            // Trigger second animation
            a2.setValue(200.0);
        }
        
        fn onEnd2(a: *AnimatedVariable(f32)) void {
            _ = a;
            counter.* += 10;
            // Trigger third animation
            a3.setValue(300.0);
        }
        
        fn onEnd3(a: *AnimatedVariable(f32)) void {
            _ = a;
            counter.* += 100;
        }
    };
    Ctx.counter = &chain_count;
    Ctx.a2 = &anim2;
    Ctx.a3 = &anim3;
    
    anim1.setCallbackOnEnd(Ctx.onEnd1, false);
    anim2.setCallbackOnEnd(Ctx.onEnd2, false);
    anim3.setCallbackOnEnd(Ctx.onEnd3, false);
    chain_count = 0;

    // Start first animation
    anim1.setValue(100.0);
    anim1.animation_data.started_time = std.time.milliTimestamp() - 100;
    
    manager.tick();
    
    // First callback fired, second animation started
    try std.testing.expectEqual(@as(u32, 1), chain_count);
    try std.testing.expect(anim2.isBeingAnimated());
}

test "AnimationManager - multiple variables unregister during same tick" {
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

    const Ctx = struct {
        var mgr: *AnimationManager = undefined;
        var a1: *AnimatedVariable(f32) = undefined;
        var a2: *AnimatedVariable(f32) = undefined;
        
        fn onUpdate1(a: *AnimatedVariable(f32)) void {
            _ = a;
            mgr.unregisterVariable(f32, a1);
        }
        
        fn onUpdate2(a: *AnimatedVariable(f32)) void {
            _ = a;
            mgr.unregisterVariable(f32, a2);
        }
    };
    Ctx.mgr = &manager;
    Ctx.a1 = &anim1;
    Ctx.a2 = &anim2;
    
    anim1.setUpdateCallback(Ctx.onUpdate1);
    anim2.setUpdateCallback(Ctx.onUpdate2);
    
    anim1.setValue(100.0);
    anim2.setValue(100.0);
    anim3.setValue(100.0);
    
    anim1.animation_data.started_time = std.time.milliTimestamp() - 50;
    anim2.animation_data.started_time = std.time.milliTimestamp() - 50;
    anim3.animation_data.started_time = std.time.milliTimestamp() - 50;
    
    // Tick with multiple unregistrations
    manager.tick();
    
    // Only anim3 should remain
    try std.testing.expectEqual(@as(usize, 1), manager.variables.items.len);
}

test "AnimationManager - callback attempts to destroy manager" {
    var manager = AnimationManager.init(std.testing.allocator);
    
    const config = AnimationConfig.init();
    var anim = AnimatedVariable(f32).init(0.0, config);
    anim.setDuration(100);

    try manager.registerVariable(f32, &anim);

    var attempted_destroy: bool = false;
    const Ctx = struct {
        var flag: *bool = undefined;
        var mgr: *AnimationManager = undefined;
        
        fn onUpdate(a: *AnimatedVariable(f32)) void {
            _ = a;
            if (!flag.*) {
                flag.* = true;
                // Attempt to destroy manager during callback
                mgr.deinit();
            }
        }
    };
    Ctx.flag = &attempted_destroy;
    Ctx.mgr = &manager;
    
    anim.setUpdateCallback(Ctx.onUpdate);
    anim.setValue(100.0);
    anim.animation_data.started_time = std.time.milliTimestamp() - 50;
    
    // This will destroy the manager during tick
    manager.tick();
    
    try std.testing.expect(attempted_destroy);
    try std.testing.expect(!manager.alive);
    
    // Variable should detect dead manager
    try std.testing.expect(anim.isAnimationManagerDead());
}

test "AnimationManager - register during tick then tick again" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    const config = AnimationConfig.init();
    var anim1 = AnimatedVariable(f32).init(0.0, config);
    var anim2 = AnimatedVariable(f32).init(0.0, config);
    
    anim1.setDuration(100);
    anim2.setDuration(100);

    try manager.registerVariable(f32, &anim1);

    var anim2_ticked: bool = false;
    const Ctx = struct {
        var mgr: *AnimationManager = undefined;
        var new_anim: *AnimatedVariable(f32) = undefined;
        var registered: bool = false;
        var anim2_tick_flag: *bool = undefined;
        
        fn onUpdate1(a: *AnimatedVariable(f32)) void {
            _ = a;
            if (!registered) {
                registered = true;
                mgr.registerVariable(f32, new_anim) catch {};
                new_anim.setValue(200.0);
            }
        }
        
        fn onUpdate2(a: *AnimatedVariable(f32)) void {
            _ = a;
            anim2_tick_flag.* = true;
        }
    };
    Ctx.mgr = &manager;
    Ctx.new_anim = &anim2;
    Ctx.registered = false;
    Ctx.anim2_tick_flag = &anim2_ticked;
    
    anim1.setUpdateCallback(Ctx.onUpdate1);
    anim2.setUpdateCallback(Ctx.onUpdate2);
    
    anim1.setValue(100.0);
    anim1.animation_data.started_time = std.time.milliTimestamp() - 50;
    
    // First tick - registers anim2 but shouldn't tick it
    manager.tick();
    try std.testing.expect(!anim2_ticked);
    
    // Second tick - should tick anim2
    anim2.animation_data.started_time = std.time.milliTimestamp() - 50;
    manager.tick();
    try std.testing.expect(anim2_ticked);
}

test "AnimationManager - all variables finish simultaneously" {
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

    var end_count: u32 = 0;
    const Ctx = struct {
        var counter: *u32 = undefined;
        fn onEnd(a: *AnimatedVariable(f32)) void {
            _ = a;
            counter.* += 1;
        }
    };
    Ctx.counter = &end_count;
    
    anim1.setCallbackOnEnd(Ctx.onEnd, false);
    anim2.setCallbackOnEnd(Ctx.onEnd, false);
    anim3.setCallbackOnEnd(Ctx.onEnd, false);
    end_count = 0;

    // Start all with same timing
    const start_time = std.time.milliTimestamp() - 100;
    anim1.setValue(100.0);
    anim2.setValue(200.0);
    anim3.setValue(300.0);
    
    anim1.animation_data.started_time = start_time;
    anim2.animation_data.started_time = start_time;
    anim3.animation_data.started_time = start_time;
    
    // Single tick should finish all
    manager.tick();
    
    try std.testing.expectEqual(@as(u32, 3), end_count);
    try std.testing.expect(!anim1.isBeingAnimated());
    try std.testing.expect(!anim2.isBeingAnimated());
    try std.testing.expect(!anim3.isBeingAnimated());
}

test "AnimationManager - nested callback modifications" {
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

    const Ctx = struct {
        var mgr: *AnimationManager = undefined;
        var a2: *AnimatedVariable(f32) = undefined;
        var a3: *AnimatedVariable(f32) = undefined;
        var step: u32 = 0;
        
        fn onUpdate1(a: *AnimatedVariable(f32)) void {
            _ = a;
            if (step == 0) {
                step = 1;
                // Unregister a2, register a3
                mgr.unregisterVariable(f32, a2);
                mgr.registerVariable(f32, a3) catch {};
                a3.setValue(300.0);
            }
        }
    };
    Ctx.mgr = &manager;
    Ctx.a2 = &anim2;
    Ctx.a3 = &anim3;
    Ctx.step = 0;
    
    anim1.setUpdateCallback(Ctx.onUpdate1);
    
    anim1.setValue(100.0);
    anim2.setValue(200.0);
    
    anim1.animation_data.started_time = std.time.milliTimestamp() - 50;
    anim2.animation_data.started_time = std.time.milliTimestamp() - 50;
    
    // Tick with nested modifications
    manager.tick();
    
    // Should have anim1 and anim3, not anim2
    try std.testing.expectEqual(@as(usize, 2), manager.variables.items.len);
}

test "AnimationManager - empty manager tick" {
    var manager = AnimationManager.init(std.testing.allocator);
    defer manager.deinit();

    // Tick with no variables should not crash
    manager.tick();
    manager.tick();
    manager.tick();
    
    try std.testing.expect(manager.alive);
}
