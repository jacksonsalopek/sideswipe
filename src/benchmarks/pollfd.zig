//! Benchmark tests for poll FD caching optimization
//! Compares pre-optimization (allocate every call) vs post-optimization (cached)

const std = @import("std");
const backend = @import("backend");
const root = @import("root.zig");
const core = @import("core");
const testing = core.testing;
const cli = @import("core.cli");

// Use AllocTracker from root module
const AllocTracker = root.AllocTracker;

/// Mock backend implementation for benchmarking
const MockImplementation = struct {
    poll_fds: []const backend.PollFd,

    const Self = @This();

    fn create(alloc: std.mem.Allocator, fd_count: usize) !*Self {
        const self = try alloc.create(Self);

        // Create mock poll FDs
        const fds = try alloc.alloc(backend.PollFd, fd_count);
        for (fds, 0..) |*fd, i| {
            fd.* = .{
                .fd = @as(i32, @intCast(i + 100)),
                .callback = null,
            };
        }

        self.* = .{
            .poll_fds = fds,
        };

        return self;
    }

    fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        alloc.free(self.poll_fds);
        alloc.destroy(self);
    }

    fn pollFds(self: *Self) []const backend.PollFd {
        return self.poll_fds;
    }

    fn iface(self: *Self) backend.Implementation {
        return backend.Implementation.init(self, &.{
            .backend_type = backendType,
            .start = start,
            .poll_fds = pollFdsWrapper,
            .drm_fd = drmFd,
            .drm_render_node_fd = drmRenderNodeFd,
            .get_render_formats = getRenderFormats,
            .on_ready = onReady,
            .deinit = deinitWrapper,
        });
    }

    fn backendType(_: *anyopaque) backend.Type {
        return .headless;
    }

    fn start(_: *anyopaque) bool {
        return true;
    }

    fn pollFdsWrapper(ptr: *anyopaque) []const backend.PollFd {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.pollFds();
    }

    fn drmFd(_: *anyopaque) i32 {
        return -1;
    }

    fn drmRenderNodeFd(_: *anyopaque) i32 {
        return -1;
    }

    fn getRenderFormats(_: *anyopaque) []const @import("backend").misc.DRMFormat {
        return &[_]@import("backend").misc.DRMFormat{};
    }

    fn onReady(_: *anyopaque) void {}

    fn deinitWrapper(_: *anyopaque) void {}
};

/// Simulate pre-optimization behavior: allocate every time
fn getPollFdsOldBehavior(
    coordinator: *backend.Coordinator,
    alloc: std.mem.Allocator,
) ![]backend.PollFd {
    var result = std.ArrayList(backend.PollFd){};
    errdefer result.deinit(alloc);

    // Get poll FDs from all implementations
    for (coordinator.implementations.items) |impl| {
        const fds = impl.pollFds();
        for (fds) |fd| {
            try result.append(alloc, fd);
        }
    }

    // Add idle FD if available
    if (coordinator.idle_fd >= 0) {
        try result.append(alloc, .{ .fd = coordinator.idle_fd, .callback = null });
    }

    return try result.toOwnedSlice(alloc);
}

/// Benchmark configuration
const Config = struct {
    name: []const u8,
    impl_count: usize,
    fds_per_impl: usize,
    iterations: usize,
    warmup_rounds: usize,
};

/// Benchmark results
const BenchmarkResult = struct {
    config: Config,
    pre_time_ns: u64,
    post_time_ns: u64,
    pre_allocations: usize,
    post_allocations: usize,
    pre_bytes: usize,
    post_bytes: usize,

    fn printResults(self: BenchmarkResult, logger: *cli.Logger) void {
        logger.info("", .{});
        logger.info("=" ** 70, .{});
        logger.info("Scenario: {s}", .{self.config.name});
        logger.info("  Implementations: {d}", .{self.config.impl_count});
        logger.info("  FDs per impl:    {d}", .{self.config.fds_per_impl});
        logger.info("  Iterations:      {d}", .{self.config.iterations});
        logger.info("-" ** 70, .{});

        // Pre-optimization results
        const pre_time_ms = @as(f64, @floatFromInt(self.pre_time_ns)) / 1_000_000.0;
        const pre_ops_per_sec = @as(f64, @floatFromInt(self.config.iterations)) /
            (@as(f64, @floatFromInt(self.pre_time_ns)) / 1_000_000_000.0);

        logger.info("Pre-optimization (allocate every call):", .{});
        logger.info("  Time:        {d:.2} ms", .{pre_time_ms});
        logger.info("  Allocations: {d}", .{self.pre_allocations});
        logger.info("  Bytes:       {d:.2} KB", .{@as(f64, @floatFromInt(self.pre_bytes)) / 1024.0});
        logger.info("  Ops/sec:     {d:.0}", .{pre_ops_per_sec});
        logger.info("", .{});

        // Post-optimization results
        const post_time_ms = @as(f64, @floatFromInt(self.post_time_ns)) / 1_000_000.0;
        const post_ops_per_sec = @as(f64, @floatFromInt(self.config.iterations)) /
            (@as(f64, @floatFromInt(self.post_time_ns)) / 1_000_000_000.0);

        logger.info("Post-optimization (cached):", .{});
        logger.info("  Time:        {d:.2} ms", .{post_time_ms});
        logger.info("  Allocations: {d}", .{self.post_allocations});
        logger.info("  Bytes:       {d:.2} KB", .{@as(f64, @floatFromInt(self.post_bytes)) / 1024.0});
        logger.info("  Ops/sec:     {d:.0}", .{post_ops_per_sec});
        logger.info("", .{});

        // Improvement calculation
        const time_improvement = (1.0 - (@as(f64, @floatFromInt(self.post_time_ns)) /
            @as(f64, @floatFromInt(self.pre_time_ns)))) * 100.0;
        const alloc_reduction = if (self.pre_allocations > 0)
            (1.0 - (@as(f64, @floatFromInt(self.post_allocations)) /
                @as(f64, @floatFromInt(self.pre_allocations)))) * 100.0
        else
            0.0;
        const speedup = @as(f64, @floatFromInt(self.pre_time_ns)) /
            @as(f64, @floatFromInt(self.post_time_ns));

        logger.info("Improvement:", .{});
        logger.info("  Time:        {d:.1}% faster ({d:.2}x speedup)", .{ time_improvement, speedup });
        logger.info("  Allocations: {d:.1}% fewer", .{alloc_reduction});
        logger.info("=" ** 70, .{});
    }
};

/// Run a single benchmark scenario
fn runBenchmark(
    alloc: std.mem.Allocator,
    config: Config,
) !BenchmarkResult {
    var counting_alloc = AllocTracker{
        .parent_allocator = alloc,
    };
    const tracked_allocator = counting_alloc.allocator();

    // Create coordinator with mock implementations
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .headless, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(tracked_allocator, &backends, opts);
    defer coordinator.deinit();

    // Clear default implementations and add our mocks
    for (coordinator.implementations.items) |_| {
        // Skip deinit since these are not real implementations
    }
    coordinator.implementations.clearRetainingCapacity();

    var mock_impls = std.ArrayList(*MockImplementation){};
    defer {
        for (mock_impls.items) |mock| {
            mock.deinit(alloc);
        }
        mock_impls.deinit(alloc);
    }

    for (0..config.impl_count) |_| {
        const mock = try MockImplementation.create(alloc, config.fds_per_impl);
        try mock_impls.append(alloc, mock);
        try coordinator.implementations.append(tracked_allocator, mock.iface());
    }

    // === Warmup Phase ===
    for (0..config.warmup_rounds) |_| {
        coordinator.invalidatePollFds();
        const warmup_fds = try coordinator.getPollFds();
        _ = warmup_fds;
    }

    // === Benchmark Pre-optimization (allocate every time) ===
    counting_alloc.reset();
    var timer = try std.time.Timer.start();

    for (0..config.iterations) |_| {
        const fds = try getPollFdsOldBehavior(coordinator, tracked_allocator);
        tracked_allocator.free(fds);
    }

    const pre_time_ns = timer.read();
    const pre_allocations = counting_alloc.allocation_count;
    const pre_bytes = counting_alloc.bytes_allocated;

    // === Benchmark Post-optimization (cached) ===
    // Reset cache to clean state
    coordinator.invalidatePollFds();

    counting_alloc.reset();
    timer.reset();

    for (0..config.iterations) |_| {
        const fds = try coordinator.getPollFds();
        _ = fds;
        // Note: Don't free - it's managed by coordinator
    }

    const post_time_ns = timer.read();
    const post_allocations = counting_alloc.allocation_count;
    const post_bytes = counting_alloc.bytes_allocated;

    return BenchmarkResult{
        .config = config,
        .pre_time_ns = pre_time_ns,
        .post_time_ns = post_time_ns,
        .pre_allocations = pre_allocations,
        .post_allocations = post_allocations,
        .pre_bytes = pre_bytes,
        .post_bytes = post_bytes,
    };
}

/// Test cache invalidation overhead
fn benchmarkCacheInvalidation(alloc: std.mem.Allocator, logger: *cli.Logger) !void {
    logger.info("", .{});
    logger.info("=" ** 70, .{});
    logger.info("Cache Invalidation Overhead Benchmark", .{});
    logger.info("-" ** 70, .{});

    var counting_alloc = AllocTracker{
        .parent_allocator = alloc,
    };
    const tracked_allocator = counting_alloc.allocator();

    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .headless, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(tracked_allocator, &backends, opts);
    defer coordinator.deinit();

    // Clear default implementations and add mock
    coordinator.implementations.clearRetainingCapacity();
    const mock = try MockImplementation.create(alloc, 5);
    defer mock.deinit(alloc);
    try coordinator.implementations.append(tracked_allocator, mock.iface());

    const iterations: usize = 1000;

    // Benchmark: Cached calls (no invalidation)
    counting_alloc.reset();
    coordinator.invalidatePollFds();
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        const fds = try coordinator.getPollFds();
        _ = fds;
    }

    const cached_time_ns = timer.read();
    const cached_allocs = counting_alloc.allocation_count;

    // Benchmark: With invalidation every call
    counting_alloc.reset();
    timer.reset();

    for (0..iterations) |_| {
        coordinator.invalidatePollFds();
        const fds = try coordinator.getPollFds();
        _ = fds;
    }

    const invalidated_time_ns = timer.read();
    const invalidated_allocs = counting_alloc.allocation_count;

    const cached_time_ms = @as(f64, @floatFromInt(cached_time_ns)) / 1_000_000.0;
    const invalidated_time_ms = @as(f64, @floatFromInt(invalidated_time_ns)) / 1_000_000.0;
    const overhead = @as(f64, @floatFromInt(invalidated_time_ns)) /
        @as(f64, @floatFromInt(cached_time_ns));

    logger.info("Iterations: {d}", .{iterations});
    logger.info("", .{});
    logger.info("Fully cached (no invalidation):", .{});
    logger.info("  Time:        {d:.2} ms", .{cached_time_ms});
    logger.info("  Allocations: {d}", .{cached_allocs});
    logger.info("", .{});

    logger.info("With invalidation every call:", .{});
    logger.info("  Time:        {d:.2} ms", .{invalidated_time_ms});
    logger.info("  Allocations: {d}", .{invalidated_allocs});
    logger.info("", .{});

    logger.info("Cache invalidation overhead: {d:.2}x", .{overhead});
    logger.info("=" ** 70, .{});
}

/// Public entry point to run all poll FD benchmarks
pub fn run(allocator: std.mem.Allocator, logger: *cli.Logger) !void {
    logger.info("", .{});
    logger.info("╔" ++ "═" ** 68 ++ "╗", .{});
    logger.info("║" ++ " " ** 10 ++ "Poll FD Caching Benchmark Results" ++ " " ** 24 ++ "║", .{});
    logger.info("╚" ++ "═" ** 68 ++ "╝", .{});

    // Scenario A: Simple backend
    const scenario_a = Config{
        .name = "Simple Backend (1 impl, 2 FDs)",
        .impl_count = 1,
        .fds_per_impl = 2,
        .iterations = 10_000,
        .warmup_rounds = 100,
    };
    const result_a = try runBenchmark(allocator, scenario_a);
    result_a.printResults(logger);

    // Scenario B: Complex backend
    const scenario_b = Config{
        .name = "Complex Backend (3 impls, 3 FDs each)",
        .impl_count = 3,
        .fds_per_impl = 3,
        .iterations = 10_000,
        .warmup_rounds = 100,
    };
    const result_b = try runBenchmark(allocator, scenario_b);
    result_b.printResults(logger);

    // Scenario C: High frequency (event loop simulation)
    const scenario_c = Config{
        .name = "Event Loop Simulation (100,000 calls)",
        .impl_count = 2,
        .fds_per_impl = 4,
        .iterations = 100_000,
        .warmup_rounds = 100,
    };
    const result_c = try runBenchmark(allocator, scenario_c);
    result_c.printResults(logger);

    // Scenario D: Realistic compositor (5 impls, varying FDs)
    const scenario_d = Config{
        .name = "Realistic Compositor (5 impls, 2 FDs each)",
        .impl_count = 5,
        .fds_per_impl = 2,
        .iterations = 50_000,
        .warmup_rounds = 100,
    };
    const result_d = try runBenchmark(allocator, scenario_d);
    result_d.printResults(logger);

    // Cache invalidation overhead test
    try benchmarkCacheInvalidation(allocator, logger);

    logger.info("", .{});
    logger.info("✓ All benchmarks completed successfully!", .{});
    logger.info("", .{});
}

// Unit tests

test "MockImplementation creates valid interface" {
    const mock = try MockImplementation.create(testing.allocator, 3);
    defer mock.deinit(testing.allocator);

    const impl = mock.iface();
    try testing.expectEqual(backend.Type.headless, impl.backendType());
    try testing.expect(impl.start());

    const fds = impl.pollFds();
    try testing.expectEqual(@as(usize, 3), fds.len);
    try testing.expectEqual(@as(i32, 100), fds[0].fd);
    try testing.expectEqual(@as(i32, 101), fds[1].fd);
    try testing.expectEqual(@as(i32, 102), fds[2].fd);
}

test "Old behavior allocates every time" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .headless, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    // Clear and add mock
    coordinator.implementations.clearRetainingCapacity();
    const mock = try MockImplementation.create(testing.allocator, 2);
    defer mock.deinit(testing.allocator);
    try coordinator.implementations.append(testing.allocator, mock.iface());

    // Each call should allocate new memory
    const fds1 = try getPollFdsOldBehavior(coordinator, testing.allocator);
    defer testing.allocator.free(fds1);

    const fds2 = try getPollFdsOldBehavior(coordinator, testing.allocator);
    defer testing.allocator.free(fds2);

    // Different pointers (different allocations)
    try testing.expect(fds1.ptr != fds2.ptr);
    try testing.expectEqual(fds1.len, fds2.len);
}

test "New behavior returns cached slice" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .headless, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    // Clear and add mock
    coordinator.implementations.clearRetainingCapacity();
    const mock = try MockImplementation.create(testing.allocator, 2);
    defer mock.deinit(testing.allocator);
    try coordinator.implementations.append(testing.allocator, mock.iface());

    // Invalidate to force rebuild
    coordinator.invalidatePollFds();

    // First call builds cache
    const fds1 = try coordinator.getPollFds();

    // Second call returns same pointer
    const fds2 = try coordinator.getPollFds();

    // Same pointer (cached)
    try testing.expectEqual(fds1.ptr, fds2.ptr);
    try testing.expectEqual(fds1.len, fds2.len);
}

test "Benchmark configuration validation" {
    const config = Config{
        .name = "Test",
        .impl_count = 3,
        .fds_per_impl = 5,
        .iterations = 1000,
        .warmup_rounds = 10,
    };

    try testing.expectEqual(@as(usize, 3), config.impl_count);
    try testing.expectEqual(@as(usize, 5), config.fds_per_impl);
    try testing.expectEqual(@as(usize, 1000), config.iterations);
}
