const std = @import("std");
const string = @import("string.zig").string;

/// Check whether a config in the form basePath/hypr/programName.conf exists
pub fn checkConfigExists(base_path: string, program_name: string, allocator: std.mem.Allocator) !bool {
    const full_path = try fullConfigPath(base_path, program_name, allocator);
    defer allocator.free(full_path);

    std.fs.accessAbsolute(full_path, .{}) catch return false;
    return true;
}

/// Constructs a full config path given the basePath and programName
pub fn fullConfigPath(base_path: string, program_name: string, allocator: std.mem.Allocator) !string {
    return std.fmt.allocPrint(allocator, "{s}/hypr/{s}.conf", .{ base_path, program_name });
}

/// Retrieves the absolute path of the $HOME/.config directory
pub fn getHome(allocator: std.mem.Allocator) ?string {
    const home_dir = std.posix.getenv("HOME") orelse return null;

    // Check if it's an absolute path
    if (!std.fs.path.isAbsolute(home_dir)) return null;

    return std.fmt.allocPrint(allocator, "{s}/.config", .{home_dir}) catch return null;
}

/// Retrieves a list of paths from the $XDG_CONFIG_DIRS env variable
pub fn getXdgConfigDirs(allocator: std.mem.Allocator) ?[]string {
    const xdg_config_dirs = std.posix.getenv("XDG_CONFIG_DIRS") orelse return null;

    var list = std.ArrayList(string){};
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, xdg_config_dirs, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const duped = allocator.dupe(u8, dir) catch return null;
        list.append(allocator, duped) catch {
            allocator.free(duped);
            return null;
        };
    }

    return list.toOwnedSlice(allocator) catch return null;
}

/// Retrieves the absolute path of the $XDG_CONFIG_HOME env variable
pub fn getXdgConfigHome() ?string {
    const xdg_config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse return null;

    // Check if it's an absolute path
    if (!std.fs.path.isAbsolute(xdg_config_home)) return null;

    return xdg_config_home;
}

pub const ConfigPath = struct {
    /// Full path to the config file, or null if not found
    config_path: ?string,
    /// Base directory where config was found, or null
    base_path: ?string,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConfigPath) void {
        if (self.config_path) |path| self.allocator.free(path);
        if (self.base_path) |path| self.allocator.free(path);
    }
};

/// Searches for a config according to the XDG Base Directory specification
/// Returns the full path to a config and the base path
pub fn findConfig(program_name: string, allocator: std.mem.Allocator) !ConfigPath {
    // Try XDG_CONFIG_HOME first
    const xdg_config_home = getXdgConfigHome();
    if (xdg_config_home) |xdg_home| {
        if (try checkConfigExists(xdg_home, program_name, allocator)) {
            return .{
                .config_path = try fullConfigPath(xdg_home, program_name, allocator),
                .base_path = try allocator.dupe(string, xdg_home),
                .allocator = allocator,
            };
        }
    }

    // Try $HOME/.config
    const home = getHome(allocator);
    defer if (home) |h| allocator.free(h);

    if (home) |h| {
        if (try checkConfigExists(h, program_name, allocator)) {
            return .{
                .config_path = try fullConfigPath(h, program_name, allocator),
                .base_path = try allocator.dupe(string, h),
                .allocator = allocator,
            };
        }
    }

    // Try XDG_CONFIG_DIRS
    const xdg_config_dirs = getXdgConfigDirs(allocator);
    if (xdg_config_dirs) |dirs| {
        defer {
            for (dirs) |dir| allocator.free(dir);
            allocator.free(dirs);
        }

        for (dirs) |dir| {
            if (try checkConfigExists(dir, program_name, allocator)) {
                return .{
                    .config_path = try fullConfigPath(dir, program_name, allocator),
                    .base_path = null,
                    .allocator = allocator,
                };
            }
        }
    }

    // Try /etc/xdg as fallback
    if (try checkConfigExists("/etc/xdg", program_name, allocator)) {
        return .{
            .config_path = try fullConfigPath("/etc/xdg", program_name, allocator),
            .base_path = null,
            .allocator = allocator,
        };
    }

    // Nothing found, but return the preferred base path
    if (xdg_config_home) |xdg_home| {
        return .{
            .config_path = null,
            .base_path = try allocator.dupe(string, xdg_home),
            .allocator = allocator,
        };
    }

    if (home) |h| {
        return .{
            .config_path = null,
            .base_path = try allocator.dupe(string, h),
            .allocator = allocator,
        };
    }

    return .{
        .config_path = null,
        .base_path = null,
        .allocator = allocator,
    };
}

test "fullConfigPath" {
    const path = try fullConfigPath("/home/user/.config", "hyprland", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/home/user/.config/hypr/hyprland.conf", path);
}

test "getXdgConfigDirs parsing" {
    // This test would require setting env vars, skip in normal testing
    if (std.posix.getenv("XDG_CONFIG_DIRS")) |_| {
        const dirs = getXdgConfigDirs(std.testing.allocator);
        if (dirs) |d| {
            defer {
                for (d) |dir| std.testing.allocator.free(dir);
                std.testing.allocator.free(d);
            }
            try std.testing.expect(d.len > 0);
        }
    }
}
