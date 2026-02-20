//! Shared test setup utilities for Wayland tests
//! Provides XDG_RUNTIME_DIR setup for tests that need Wayland sockets
//! Note: Requires -lc to be linked for setenv/unsetenv

const std = @import("std");
const testing = std.testing;

// libc functions for environment manipulation
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const RuntimeDir = struct {
    tmp: ?std.testing.TmpDir,
    path: ?[]const u8,
    path_z: ?[:0]const u8,
    allocator: std.mem.Allocator,

    /// Set up XDG_RUNTIME_DIR for tests. If already set, does nothing.
    /// Call cleanup() when done to restore environment.
    pub fn setup(allocator: std.mem.Allocator) !RuntimeDir {
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |_| {
            // Already set, no need to create temp dir
            return RuntimeDir{
                .tmp = null,
                .path = null,
                .path_z = null,
                .allocator = allocator,
            };
        }

        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();

        const path = try temp.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(path);

        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);

        // Use libc setenv
        _ = setenv("XDG_RUNTIME_DIR", path_z.ptr, 1);

        return RuntimeDir{
            .tmp = temp,
            .path = path,
            .path_z = path_z,
            .allocator = allocator,
        };
    }

    /// Clean up temporary directory and restore environment.
    /// Note: Unsets XDG_RUNTIME_DIR first, then cleans up temp dir.
    /// This ensures Wayland sockets are closed before directory removal.
    pub fn cleanup(self: *RuntimeDir) void {
        // Unset env var first to prevent new files being created
        if (self.tmp != null) {
            _ = unsetenv("XDG_RUNTIME_DIR");
        }
        
        // Free allocations
        if (self.path_z) |path_z| self.allocator.free(path_z);
        if (self.path) |path| self.allocator.free(path);
        
        // Clean up temp directory last
        if (self.tmp) |*t| t.cleanup();
    }
};

test "RuntimeDir: setup and cleanup" {
    var runtime = try RuntimeDir.setup(testing.allocator);
    defer runtime.cleanup();

    // Should have XDG_RUNTIME_DIR set
    const xdg_dir = std.posix.getenv("XDG_RUNTIME_DIR");
    try testing.expect(xdg_dir != null);
}
