//! Internationalization (i18n) utilities

pub const engine = @import("engine.zig");

// Re-export commonly used types
pub const Engine = engine.Engine;
pub const Locale = engine.Locale;
pub const TranslationVarMap = engine.TranslationVarMap;
pub const TranslationFn = engine.TranslationFn;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("engine.zig");
}
