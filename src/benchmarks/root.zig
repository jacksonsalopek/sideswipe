//! Unified benchmarks module for Sideswipe
//! Provides common utilities and organizes all performance benchmarks

const std = @import("std");
const core = @import("core");
const testing = core.testing;
const cli = @import("core.cli");

/// Benchmark modules
pub const pollfd = @import("pollfd.zig");
pub const edid = @import("edid.zig");
pub const libdisplay_info = @import("libdisplay_info.zig");

/// Benchmark result for a single scenario
pub const Result = struct {
    name: []const u8,
    time_ns: u64,
    allocations: usize,
    bytes_allocated: usize,

    /// Print results using logger
    pub fn print(self: Result, logger: *cli.Logger) void {
        const time_ms = @as(f64, @floatFromInt(self.time_ns)) / 1_000_000.0;
        const bytes_kb = @as(f64, @floatFromInt(self.bytes_allocated)) / 1024.0;

        logger.info("  Time:        {d:.2} ms", .{time_ms});
        logger.info("  Allocations: {d}", .{self.allocations});
        logger.info("  Bytes:       {d:.2} KB", .{bytes_kb});
    }

    /// Compare two results and print improvement metrics
    pub fn compare(baseline: Result, optimized: Result, writer: anytype) !void {
        const time_improvement = (1.0 - (@as(f64, @floatFromInt(optimized.time_ns)) /
            @as(f64, @floatFromInt(baseline.time_ns)))) * 100.0;
        const speedup = @as(f64, @floatFromInt(baseline.time_ns)) /
            @as(f64, @floatFromInt(optimized.time_ns));
        const alloc_reduction = if (baseline.allocations > 0)
            (1.0 - (@as(f64, @floatFromInt(optimized.allocations)) /
                @as(f64, @floatFromInt(baseline.allocations)))) * 100.0
        else
            0.0;

        try writer.print("Improvement:\n", .{});
        try writer.print("  Time:        {d:.1}% faster ({d:.2}x speedup)\n", .{ time_improvement, speedup });
        try writer.print("  Allocations: {d:.1}% fewer\n", .{alloc_reduction});
    }
};

/// Counting allocator wrapper to track allocation statistics
pub const AllocTracker = struct {
    parent_allocator: std.mem.Allocator,
    allocation_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,

    const Self = @This();

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            self.allocation_count += 1;
            self.bytes_allocated += len;
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null) {
            self.allocation_count += 1;
            self.bytes_allocated += new_len;
        }
        return result;
    }

    /// Reset all counters to zero
    pub fn reset(self: *Self) void {
        self.allocation_count = 0;
        self.free_count = 0;
        self.bytes_allocated = 0;
    }

    /// Get current statistics as a snapshot
    pub fn snapshot(self: *Self) struct { allocations: usize, frees: usize, bytes: usize } {
        return .{
            .allocations = self.allocation_count,
            .frees = self.free_count,
            .bytes = self.bytes_allocated,
        };
    }
};

/// Timer for measuring function execution time
pub const Timer = struct {
    inner: std.time.Timer,

    const Self = @This();

    /// Start a new timer
    pub fn start() !Self {
        return Self{
            .inner = try std.time.Timer.start(),
        };
    }

    /// Read elapsed time in nanoseconds
    pub fn read(self: *Self) u64 {
        return self.inner.read();
    }

    /// Reset timer to zero
    pub fn reset(self: *Self) void {
        self.inner.reset();
    }

    /// Measure execution time of a function
    pub fn measure(comptime func: anytype, args: anytype) !struct { result: @typeInfo(@TypeOf(func)).Fn.return_type.?, time_ns: u64 } {
        var timer = try Self.start();
        const result = try @call(.auto, func, args);
        const time_ns = timer.read();
        return .{ .result = result, .time_ns = time_ns };
    }
};

/// Run all available benchmarks
pub fn runAll(allocator: std.mem.Allocator, logger: *cli.Logger) !void {
    logger.info("", .{});
    logger.info("╔" ++ "═" ** 68 ++ "╗", .{});
    logger.info("║" ++ " " ** 18 ++ "Sideswipe Benchmarks" ++ " " ** 30 ++ "║", .{});
    logger.info("╚" ++ "═" ** 68 ++ "╝", .{});

    logger.info("", .{});
    logger.info("=== Running Poll FD Benchmark ===", .{});
    try pollfd.run(allocator, logger);

    logger.info("", .{});
    logger.info("=== Running EDID Parser Benchmark ===", .{});
    try edid.run(allocator, logger);

    // Note: libdisplay-info requires C library, skip if not available
    logger.info("", .{});
    logger.info("=== Running libdisplay-info Comparison ===", .{});
    if (libdisplay_info.run(allocator, logger)) {
        // Success
    } else |err| {
        if (err == error.FileNotFound) {
            logger.warn("Skipping libdisplay-info benchmark (C library not available)", .{});
        } else {
            return err;
        }
    }

    logger.info("", .{});
    logger.info("✓ All benchmarks completed successfully!", .{});
    logger.info("", .{});
}

/// Run a specific benchmark by name
pub fn runByName(allocator: std.mem.Allocator, name: []const u8, logger: *cli.Logger) !void {
    if (std.mem.eql(u8, name, "pollfd")) {
        try pollfd.run(allocator, logger);
    } else if (std.mem.eql(u8, name, "edid")) {
        try edid.run(allocator, logger);
    } else if (std.mem.eql(u8, name, "libdisplay-info")) {
        try libdisplay_info.run(allocator, logger);
    } else {
        logger.err("Unknown benchmark: {s}", .{name});
        logger.info("Available benchmarks: pollfd, edid, libdisplay-info", .{});
        return error.BenchmarkNotFound;
    }
}

/// Main entry point for benchmark executable
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logger for benchmark output
    var logger = cli.Logger.init(allocator);
    defer logger.deinit();
    logger.setLogLevel(.info);
    logger.setEnableColor(true);

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var benchmark_name: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            benchmark_name = args.next();
        } else {
            logger.err("Unknown argument: {s}", .{arg});
            logger.info("Usage: benchmark [--name <benchmark-name>]", .{});
            return error.InvalidArguments;
        }
    }

    // Run requested benchmark or all benchmarks
    if (benchmark_name) |name| {
        try runByName(allocator, name, &logger);
    } else {
        try runAll(allocator, &logger);
    }
}

// Tests

test "AllocTracker - tracks allocations" {
    var tracker = AllocTracker{
        .parent_allocator = testing.allocator,
    };
    const alloc = tracker.allocator();

    const slice = try alloc.alloc(u8, 100);
    defer alloc.free(slice);

    try testing.expectEqual(@as(usize, 1), tracker.allocation_count);
    try testing.expectEqual(@as(usize, 100), tracker.bytes_allocated);
}

test "AllocTracker - reset clears counters" {
    var tracker = AllocTracker{
        .parent_allocator = testing.allocator,
    };
    const alloc = tracker.allocator();

    const slice = try alloc.alloc(u8, 50);
    alloc.free(slice);

    try testing.expectEqual(@as(usize, 1), tracker.allocation_count);

    tracker.reset();
    try testing.expectEqual(@as(usize, 0), tracker.allocation_count);
    try testing.expectEqual(@as(usize, 0), tracker.bytes_allocated);
}

test "AllocTracker - snapshot returns current stats" {
    var tracker = AllocTracker{
        .parent_allocator = testing.allocator,
    };
    const alloc = tracker.allocator();

    const slice = try alloc.alloc(u8, 75);
    defer alloc.free(slice);

    const snap = tracker.snapshot();
    try testing.expectEqual(@as(usize, 1), snap.allocations);
    try testing.expectEqual(@as(usize, 75), snap.bytes);
}

test "Timer - basic timing" {
    var timer = try Timer.start();
    std.time.sleep(1_000_000); // Sleep 1ms
    const elapsed = timer.read();
    try testing.expect(elapsed >= 1_000_000); // At least 1ms
}

test "Timer - reset works" {
    var timer = try Timer.start();
    std.time.sleep(1_000_000);
    timer.reset();
    const elapsed = timer.read();
    try testing.expect(elapsed < 1_000_000); // Should be much less
}

test "Result - formatting" {
    const result = Result{
        .name = "test",
        .time_ns = 1_500_000,
        .allocations = 10,
        .bytes_allocated = 2048,
    };

    // Just verify struct is valid
    try testing.expectEqual(@as(usize, 10), result.allocations);
    try testing.expectEqual(@as(u64, 1_500_000), result.time_ns);
}

test "Result - compare calculates improvements" {
    const baseline = Result{
        .name = "baseline",
        .time_ns = 2_000_000,
        .allocations = 100,
        .bytes_allocated = 10240,
    };

    const optimized = Result{
        .name = "optimized",
        .time_ns = 1_000_000,
        .allocations = 10,
        .bytes_allocated = 1024,
    };

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try Result.compare(baseline, optimized, stream.writer());

    const output = stream.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "faster") != null);
    try testing.expect(std.mem.indexOf(u8, output, "fewer") != null);
}

test "runByName - unknown benchmark returns error" {
    var logger = cli.Logger.init(testing.allocator);
    defer logger.deinit();
    logger.setEnableStdout(false);

    const result = runByName(testing.allocator, "nonexistent", &logger);
    try testing.expectError(error.BenchmarkNotFound, result);
}
