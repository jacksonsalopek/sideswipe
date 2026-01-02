const std = @import("std");
const core = @import("core");
const string_utils = @import("core.string");
const string = string_utils.string;
const c_string = string_utils.c_string;
const c = @cImport(@cInclude("drm_fourcc.h"));

extern "c" fn setenv(name: c_string, value: c_string, overwrite: c_int) c_int;
extern "c" fn drmGetFormatName(format: u32) ?[*:0]u8;

pub const Env = struct {
    // Trace flag - initialized once from SIDESWIPE_TRACE environment variable
    var trace_value: ?bool = null;

    pub fn enabled(env: string) bool {
        const val = std.posix.getenv(env) orelse return false;
        return std.mem.eql(u8, val, "1");
    }

    pub fn explicitlyDisabled(env: string) bool {
        const val = std.posix.getenv(env) orelse return false;
        return std.mem.eql(u8, val, "0");
    }

    pub fn isTrace() bool {
        if (trace_value == null) {
            trace_value = enabled("SIDESWIPE_TRACE");
        }
        return trace_value.?;
    }
};

pub const Fmt = struct {
    /// Convert DRM fourcc format to a human-readable name.
    /// Caller owns the returned memory and must free it with the provided allocator.
    pub fn fourccToName(format: u32, allocator: std.mem.Allocator) !string {
        const fmt = drmGetFormatName(format);
        if (fmt == null) {
            return allocator.dupe(u8, "unknown");
        }

        defer std.c.free(fmt.?);
        const name = std.mem.span(fmt.?);
        return allocator.dupe(u8, name);
    }
};

const testing = core.testing;

test "Env.enabled - not set" {
    try testing.expectFalse(Env.enabled("SIDESWIPE_TEST_NOT_SET"));
}

test "Env.enabled - set to 1" {
    if (setenv("SIDESWIPE_TEST_ENABLED", "1", 1) != 0) return error.SetEnvFailed;
    try testing.expect(Env.enabled("SIDESWIPE_TEST_ENABLED"));
}

test "Env.enabled - set to 0" {
    if (setenv("SIDESWIPE_TEST_ZERO", "0", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.enabled("SIDESWIPE_TEST_ZERO"));
}

test "Env.enabled - set to true" {
    if (setenv("SIDESWIPE_TEST_TRUE", "true", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.enabled("SIDESWIPE_TEST_TRUE"));
}

test "Env.enabled - set to empty string" {
    if (setenv("SIDESWIPE_TEST_EMPTY", "", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.enabled("SIDESWIPE_TEST_EMPTY"));
}

test "Env.enabled - set to arbitrary value" {
    if (setenv("SIDESWIPE_TEST_ARBITRARY", "yes", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.enabled("SIDESWIPE_TEST_ARBITRARY"));
}

test "Env.explicitlyDisabled - not set" {
    try testing.expectFalse(Env.explicitlyDisabled("SIDESWIPE_TEST_DISABLED_NOT_SET"));
}

test "Env.explicitlyDisabled - set to 0" {
    if (setenv("SIDESWIPE_TEST_DISABLED", "0", 1) != 0) return error.SetEnvFailed;
    try testing.expect(Env.explicitlyDisabled("SIDESWIPE_TEST_DISABLED"));
}

test "Env.explicitlyDisabled - set to 1" {
    if (setenv("SIDESWIPE_TEST_DISABLED_ONE", "1", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.explicitlyDisabled("SIDESWIPE_TEST_DISABLED_ONE"));
}

test "Env.explicitlyDisabled - set to false" {
    if (setenv("SIDESWIPE_TEST_DISABLED_FALSE", "false", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.explicitlyDisabled("SIDESWIPE_TEST_DISABLED_FALSE"));
}

test "Env.explicitlyDisabled - set to empty string" {
    if (setenv("SIDESWIPE_TEST_DISABLED_EMPTY", "", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.explicitlyDisabled("SIDESWIPE_TEST_DISABLED_EMPTY"));
}

test "Env.explicitlyDisabled - set to arbitrary value" {
    if (setenv("SIDESWIPE_TEST_DISABLED_ARBITRARY", "no", 1) != 0) return error.SetEnvFailed;
    try testing.expectFalse(Env.explicitlyDisabled("SIDESWIPE_TEST_DISABLED_ARBITRARY"));
}

test "Env.isTrace - not set" {
    // Test when SIDESWIPE_TRACE is not set (default case)
    // Note: Since trace_value is cached, this test should run first
    // or we need to ensure SIDESWIPE_TRACE is unset
    const was_set = std.posix.getenv("SIDESWIPE_TRACE") != null;
    if (was_set) {
        // Skip this test if SIDESWIPE_TRACE is already set in the environment
        return error.SkipZigTest;
    }

    // Reset trace_value for testing
    Env.trace_value = null;
    try testing.expectFalse(Env.isTrace());

    // Verify it's cached
    try testing.expectFalse(Env.isTrace());
}

test "Env.isTrace - enabled" {
    if (setenv("SIDESWIPE_TRACE", "1", 1) != 0) return error.SetEnvFailed;

    // Reset trace_value to force re-read
    Env.trace_value = null;
    try testing.expect(Env.isTrace());

    // Verify it's cached - even if we change the env var
    if (setenv("SIDESWIPE_TRACE", "0", 1) != 0) return error.SetEnvFailed;
    try testing.expect(Env.isTrace()); // Still true because cached
}

test "Fmt.fourccToName - unknown format" {
    const allocator = testing.allocator;

    // Use an invalid/unknown format (0)
    const name = try Fmt.fourccToName(0, allocator);
    defer allocator.free(name);

    // Should return a valid string for invalid formats
    try testing.expect(name.len > 0);
}

test "Fmt.fourccToName - known format XRGB8888" {
    const allocator = testing.allocator;

    // DRM_FORMAT_XRGB8888 = fourcc_code('X', 'R', '2', '4')
    // This is a common 32-bit RGB format
    const DRM_FORMAT_XRGB8888: u32 = ('X') | (@as(u32, 'R') << 8) | (@as(u32, '2') << 16) | (@as(u32, '4') << 24);

    const name = try Fmt.fourccToName(DRM_FORMAT_XRGB8888, allocator);
    defer allocator.free(name);

    // Should return a valid format name
    try testing.expect(name.len > 0);
    // The name should contain the format identifier
    try testing.expectNotEqual(name, "unknown");
}

test "Fmt.fourccToName - known format ARGB8888" {
    const allocator = testing.allocator;

    // DRM_FORMAT_ARGB8888 = fourcc_code('A', 'R', '2', '4')
    const DRM_FORMAT_ARGB8888: u32 = ('A') | (@as(u32, 'R') << 8) | (@as(u32, '2') << 16) | (@as(u32, '4') << 24);

    const name = try Fmt.fourccToName(DRM_FORMAT_ARGB8888, allocator);
    defer allocator.free(name);

    try testing.expect(name.len > 0);
    try testing.expectNotEqual(name, "unknown");
}
