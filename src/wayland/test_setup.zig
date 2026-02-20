//! Shared test setup utilities for Wayland tests
//! Provides XDG_RUNTIME_DIR setup for tests that need Wayland sockets
//! Note: Requires -lc to be linked for setenv/unsetenv

const std = @import("std");
const testing = std.testing;

// libc functions for environment manipulation
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const RuntimeDir = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,
    path_z: [:0]const u8,
    allocator: std.mem.Allocator,
    saved_runtime_dir: ?[:0]const u8,

    /// Set up XDG_RUNTIME_DIR for tests using a temporary directory.
    /// Always creates a new temp dir and overrides existing XDG_RUNTIME_DIR.
    /// Call cleanup() when done to restore environment.
    pub fn setup(allocator: std.mem.Allocator) !RuntimeDir {
        // Save existing XDG_RUNTIME_DIR to restore later
        const old_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR");
        const saved_path = if (old_runtime_dir) |dir|
            try allocator.dupeZ(u8, dir)
        else
            null;
        errdefer if (saved_path) |p| allocator.free(p);

        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();

        const path = try temp.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(path);

        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);

        // Use libc setenv to override any existing value
        _ = setenv("XDG_RUNTIME_DIR", path_z.ptr, 1);

        return RuntimeDir{
            .tmp = temp,
            .path = path,
            .path_z = path_z,
            .allocator = allocator,
            .saved_runtime_dir = saved_path,
        };
    }

    /// Clean up temporary directory and restore environment.
    /// Note: Restores or unsets XDG_RUNTIME_DIR first, then cleans up temp dir.
    /// This ensures Wayland sockets are closed before directory removal.
    pub fn cleanup(self: *RuntimeDir) void {
        // Restore or unset env var first to prevent new files being created
        if (self.saved_runtime_dir) |saved| {
            _ = setenv("XDG_RUNTIME_DIR", saved.ptr, 1);
            self.allocator.free(saved);
        } else {
            _ = unsetenv("XDG_RUNTIME_DIR");
        }
        
        // Free allocations
        self.allocator.free(self.path_z);
        self.allocator.free(self.path);
        
        // Clean up temp directory last
        var tmp = self.tmp;
        tmp.cleanup();
    }
};

test "RuntimeDir: setup and cleanup" {
    var runtime = try RuntimeDir.setup(testing.allocator);
    defer runtime.cleanup();

    // Should have XDG_RUNTIME_DIR set
    const xdg_dir = std.posix.getenv("XDG_RUNTIME_DIR");
    try testing.expect(xdg_dir != null);
}
