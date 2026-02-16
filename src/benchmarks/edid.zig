//! EDID parser performance benchmark
//! Compares standard EDID parser (with allocations) vs fast parser (zero-alloc + SIMD)

const std = @import("std");
const root = @import("root.zig");
const core = @import("core");
const display = @import("core.display");
const cli = @import("core.cli");
const testing = core.testing;

/// Generate realistic EDID test data
fn generateTestEdid() [128]u8 {
    var data = [_]u8{0} ** 128;

    // Header
    const header = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    @memcpy(data[0..8], &header);

    // Manufacturer ID: "DEL" (Dell) - 0x10AC
    data[0x08] = 0x10;
    data[0x09] = 0xAC;

    // Product code: 0xA0C7
    data[0x0A] = 0xC7;
    data[0x0B] = 0xA0;

    // Serial: 0x4C564C42 (random)
    data[0x0C] = 0x42;
    data[0x0D] = 0x4C;
    data[0x0E] = 0x56;
    data[0x0F] = 0x4C;

    // Manufacture: week 15, year 2023 (33 years after 1990)
    data[0x10] = 15;
    data[0x11] = 33;

    // Version 1.4
    data[0x12] = 1;
    data[0x13] = 4;

    // Video input: Digital, 8-bit color, DisplayPort
    data[0x14] = 0b10100101;

    // Screen size: 60cm x 34cm (27" 16:9 display)
    data[0x15] = 60;
    data[0x16] = 34;

    // Gamma: 2.20
    data[0x17] = 120;

    // Feature support
    data[0x18] = 0b00011110;

    // Color characteristics (simplified - normally more complex)
    data[0x19] = 0xEE;
    data[0x1A] = 0x91;
    data[0x1B] = 0xA3;
    data[0x1C] = 0x54;
    data[0x1D] = 0x4C;
    data[0x1E] = 0x99;
    data[0x1F] = 0x26;
    data[0x20] = 0x0F;
    data[0x21] = 0x50;
    data[0x22] = 0x54;

    // Established timings
    data[0x23] = 0xFF;
    data[0x24] = 0xFF;
    data[0x25] = 0xFF;

    // Standard timings (8 entries)
    data[0x26] = 0xD1;
    data[0x27] = 0xC0; // 1920x1080 @ 60Hz
    data[0x28] = 0x81;
    data[0x29] = 0xC0; // 1920x1080 @ 60Hz
    data[0x2A] = 0x81;
    data[0x2B] = 0x80; // 1920x1080 @ 60Hz
    data[0x2C] = 0x95;
    data[0x2D] = 0x00; // Various
    data[0x2E] = 0xA9;
    data[0x2F] = 0x40; // Various
    data[0x30] = 0xB3;
    data[0x31] = 0x00; // Various
    data[0x32] = 0x01;
    data[0x33] = 0x01; // Unused
    data[0x34] = 0x01;
    data[0x35] = 0x01; // Unused

    // Extension flag
    data[0x7E] = 0;

    // Calculate checksum
    var sum: u8 = 0;
    for (data[0..127]) |byte| {
        sum +%= byte;
    }
    data[127] = 0 -% sum;

    return data;
}

/// Benchmark standard parser with allocations
fn benchmarkStandard(
    allocator: std.mem.Allocator,
    data: []const u8,
    iterations: usize,
    samples: []u64,
) !void {
    for (samples) |*sample| {
        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            var parsed = try display.edid.standard.parse(allocator, data);
            parsed.deinit();
        }

        const end = std.time.nanoTimestamp();
        sample.* = @intCast(end - start);
    }
}

/// Benchmark fast parser (zero-alloc + SIMD)
fn benchmarkFast(
    data: []const u8,
    iterations: usize,
    samples: []u64,
) !void {
    for (samples) |*sample| {
        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const fast = try display.edid.fast.parse(data);
            _ = fast;
        }

        const end = std.time.nanoTimestamp();
        sample.* = @intCast(end - start);
    }
}

/// Calculate statistics from samples
fn calculateStats(samples: []const u64) struct {
    total: u64,
    avg: u64,
    min: u64,
    max: u64,
} {
    var total: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    for (samples) |sample| {
        total += sample;
        if (sample < min) min = sample;
        if (sample > max) max = sample;
    }

    return .{
        .total = total,
        .avg = total / @as(u64, samples.len),
        .min = min,
        .max = max,
    };
}

/// Public entry point to run EDID benchmark
pub fn run(allocator: std.mem.Allocator, log: *cli.Logger) !void {
    const test_data = generateTestEdid();

    // Configuration
    const parse_iterations = 500_000;
    const num_samples = 5;

    log.info("", .{});
    log.info("╔" ++ "═" ** 68 ++ "╗", .{});
    log.info("║" ++ " " ** 20 ++ "EDID Parser Benchmark" ++ " " ** 27 ++ "║", .{});
    log.info("╚" ++ "═" ** 68 ++ "╝", .{});
    log.info("", .{});
    log.info("Test data size:              {d} bytes", .{test_data.len});
    log.info("Parse iterations per sample: {d}", .{parse_iterations});
    log.info("Number of samples:           {d}", .{num_samples});
    log.info("", .{});

    // Allocate sample arrays
    const standard_samples = try allocator.alloc(u64, num_samples);
    defer allocator.free(standard_samples);

    const fast_samples = try allocator.alloc(u64, num_samples);
    defer allocator.free(fast_samples);

    // Warm up
    log.info("Warming up...", .{});
    {
        var warmup = try display.edid.standard.parse(allocator, &test_data);
        warmup.deinit();
    }
    {
        const warmup = try display.edid.fast.parse(&test_data);
        _ = warmup;
    }

    // Benchmark parsing
    log.info("Running benchmarks...", .{});
    log.info("", .{});

    log.info("  Standard parser (with allocations)...", .{});
    try benchmarkStandard(allocator, &test_data, parse_iterations, standard_samples);

    log.info("  Fast parser (zero-alloc + SIMD)...", .{});
    try benchmarkFast(&test_data, parse_iterations, fast_samples);

    // Calculate results
    const standard_stats = calculateStats(standard_samples);
    const fast_stats = calculateStats(fast_samples);

    // Print results
    log.info("", .{});
    log.info("═" ** 70, .{});
    log.info("Results", .{});
    log.info("═" ** 70, .{});
    log.info("", .{});

    log.info("Standard Parser (with allocations):", .{});
    log.info("  Iterations: {d}", .{parse_iterations});
    log.info("  Average:    {d} ns ({d:.2} μs)", .{
        standard_stats.avg,
        @as(f64, @floatFromInt(standard_stats.avg)) / 1000.0,
    });
    log.info("  Min:        {d} ns", .{standard_stats.min});
    log.info("  Max:        {d} ns", .{standard_stats.max});
    log.info("  Total:      {d} ns ({d:.2} ms)", .{
        standard_stats.total,
        @as(f64, @floatFromInt(standard_stats.total)) / 1_000_000.0,
    });
    log.info("", .{});

    log.info("Fast Parser (zero-alloc + packed + SIMD):", .{});
    log.info("  Iterations: {d}", .{parse_iterations});
    log.info("  Average:    {d} ns ({d:.2} μs)", .{
        fast_stats.avg,
        @as(f64, @floatFromInt(fast_stats.avg)) / 1000.0,
    });
    log.info("  Min:        {d} ns", .{fast_stats.min});
    log.info("  Max:        {d} ns", .{fast_stats.max});
    log.info("  Total:      {d} ns ({d:.2} ms)", .{
        fast_stats.total,
        @as(f64, @floatFromInt(fast_stats.total)) / 1_000_000.0,
    });
    log.info("", .{});

    // Compare per-operation times
    log.info("═" ** 70, .{});
    log.info("Performance Comparison (per operation)", .{});
    log.info("═" ** 70, .{});

    const standard_per_op = @as(f64, @floatFromInt(standard_stats.avg)) /
        @as(f64, @floatFromInt(parse_iterations));
    const fast_per_op = @as(f64, @floatFromInt(fast_stats.avg)) /
        @as(f64, @floatFromInt(parse_iterations));

    log.info("Standard:  {d:.2} ns/op", .{standard_per_op});
    log.info("Fast:      {d:.2} ns/op", .{fast_per_op});
    log.info("", .{});

    const speedup = standard_per_op / fast_per_op;
    log.info("⚡ Fast is {d:.1}x faster!", .{speedup});
    log.info("═" ** 70, .{});
}

// Tests

test "both parsers produce equivalent results" {
    const test_data = generateTestEdid();

    var standard = try display.edid.standard.parse(testing.allocator, &test_data);
    defer standard.deinit();

    const fast = try display.edid.fast.parse(&test_data);

    // Compare results
    try testing.expectEqual(standard.version, fast.getVersion());
    try testing.expectEqual(standard.revision, fast.getRevision());
    try testing.expectEqualStrings(&standard.vendor_product.manufacturer, &fast.getManufacturer());
    try testing.expectEqual(standard.vendor_product.product, fast.getProductCode());
    try testing.expectEqual(standard.vendor_product.serial, fast.getSerialNumber());
    try testing.expectEqual(standard.screen_width_cm, fast.getScreenWidthCm());
    try testing.expectEqual(standard.screen_height_cm, fast.getScreenHeightCm());

    const standard_gamma = if (standard.gamma_times_100 != 0xFF)
        (@as(f64, @floatFromInt(standard.gamma_times_100)) + 100.0) / 100.0
    else
        0.0;
    try testing.expectEqual(@as(f32, @floatCast(standard_gamma)), fast.getGamma());
}

test "generateTestEdid produces valid EDID" {
    const test_data = generateTestEdid();

    // Verify header
    try testing.expectEqual(@as(u8, 0x00), test_data[0]);
    try testing.expectEqual(@as(u8, 0xFF), test_data[1]);
    try testing.expectEqual(@as(u8, 0xFF), test_data[7]);
    try testing.expectEqual(@as(u8, 0x00), test_data[7]);

    // Verify can be parsed
    const parsed = try display.edid.fast.parse(&test_data);
    try testing.expectEqual(@as(u8, 1), parsed.getVersion());
    try testing.expectEqual(@as(u8, 4), parsed.getRevision());
}
