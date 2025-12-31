pub const BezierCurve = @import("bezier.zig").BezierCurve;
pub const AnimationConfig = @import("config.zig").AnimationConfig;
pub const AnimationStyle = @import("config.zig").AnimationStyle;
pub const AnimatedVariable = @import("variable.zig").AnimatedVariable;
pub const AnimationData = @import("variable.zig").AnimationData;
pub const AnimationManager = @import("manager.zig").AnimationManager;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("bezier.zig");
    _ = @import("config.zig");
    _ = @import("manager.zig");
    _ = @import("variable.zig");
}
