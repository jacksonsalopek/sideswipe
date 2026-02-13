//! Benchmark comparing packed struct vs manual parsing performance

const std = @import("std");
const edid = @import("edid/root.zig");

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

/// Benchmark result statistics
const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    max_ns: u64,

    fn calculate(name: []const u8, iterations: usize, samples: []const u64) BenchmarkResult {
        var total: u64 = 0;
        var min: u64 = std.math.maxInt(u64);
        var max: u64 = 0;

        for (samples) |sample| {
            total += sample;
            if (sample < min) min = sample;
            if (sample > max) max = sample;
        }

        return BenchmarkResult{
            .name = name,
            .iterations = iterations,
            .total_ns = total,
            .avg_ns = total / @as(u64, samples.len),
            .min_ns = min,
            .max_ns = max,
        };
    }

    fn print(self: BenchmarkResult) void {
        std.debug.print("\n{s}:\n", .{self.name});
        std.debug.print("  Iterations: {d}\n", .{self.iterations});
        std.debug.print("  Average:    {d} ns ({d:.2} μs)\n", .{ self.avg_ns, @as(f64, @floatFromInt(self.avg_ns)) / 1000.0 });
        std.debug.print("  Min:        {d} ns\n", .{self.min_ns});
        std.debug.print("  Max:        {d} ns\n", .{self.max_ns});
        std.debug.print("  Total:      {d} ns ({d:.2} ms)\n", .{ self.total_ns, @as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0 });
    }

    fn compare(baseline: BenchmarkResult, optimized: BenchmarkResult) void {
        const speedup = @as(f64, @floatFromInt(baseline.avg_ns)) / @as(f64, @floatFromInt(optimized.avg_ns));
        const percent_faster = (speedup - 1.0) * 100.0;

        std.debug.print("\n========================================\n", .{});
        std.debug.print("Performance Comparison:\n", .{});
        std.debug.print("========================================\n", .{});
        std.debug.print("Baseline (manual):  {d} ns/op\n", .{baseline.avg_ns});
        std.debug.print("Optimized (packed): {d} ns/op\n", .{optimized.avg_ns});
        std.debug.print("Speedup:            {d:.2}x\n", .{speedup});
        std.debug.print("Improvement:        {d:.1}% faster\n", .{percent_faster});
        std.debug.print("========================================\n", .{});
    }
};

/// Benchmark parsing with manual bit manipulation
fn benchmarkManualParsing(allocator: std.mem.Allocator, data: []const u8, iterations: usize, samples: []u64) !void {
    for (samples) |*sample| {
        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            var parsed = try edid.standard.parse(allocator, data);
            parsed.deinit();
        }

        const end = std.time.nanoTimestamp();
        sample.* = @intCast(end - start);
    }
}

/// Benchmark fast parser (zero-alloc + packed + SIMD)
fn benchmarkFast(data: []const u8, iterations: usize, samples: []u64) !void {
    for (samples) |*sample| {
        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const fast = try edid.fast.parse(data);
            _ = fast;
        }

        const end = std.time.nanoTimestamp();
        sample.* = @intCast(end - start);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_data = generateTestEdid();

    // Configuration
    const parse_iterations = 500_000;
    const num_samples = 5;

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("EDID Parser Benchmark\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("Test data size: {d} bytes\n", .{test_data.len});
    std.debug.print("Parse iterations per sample: {d}\n", .{parse_iterations});
    std.debug.print("Number of samples: {d}\n", .{num_samples});
    std.debug.print("========================================\n", .{});

    // Allocate sample arrays
    const parse_standard_samples = try allocator.alloc(u64, num_samples);
    defer allocator.free(parse_standard_samples);

    const parse_fast_samples = try allocator.alloc(u64, num_samples);
    defer allocator.free(parse_fast_samples);

    // Warm up
    std.debug.print("\nWarming up...\n", .{});
    {
        var warmup = try edid.standard.parse(allocator, &test_data);
        warmup.deinit();
    }
    {
        const warmup = try edid.fast.parse(&test_data);
        _ = warmup;
    }

    // Benchmark parsing
    std.debug.print("\nBenchmarking parsing...\n", .{});

    std.debug.print("  Running standard parser...\n", .{});
    try benchmarkManualParsing(allocator, &test_data, parse_iterations, parse_standard_samples);

    std.debug.print("  Running fast parser...\n", .{});
    try benchmarkFast(&test_data, parse_iterations, parse_fast_samples);

    // Calculate and print results
    const parse_standard_result = BenchmarkResult.calculate(
        "Standard Parser (with allocations)",
        parse_iterations,
        parse_standard_samples,
    );
    parse_standard_result.print();

    const parse_fast_result = BenchmarkResult.calculate(
        "Fast Parser (zero-alloc + packed + SIMD)",
        parse_iterations,
        parse_fast_samples,
    );
    parse_fast_result.print();

    std.debug.print("\n========================================\n", .{});
    std.debug.print("FINAL COMPARISON (per operation)\n", .{});
    std.debug.print("========================================\n", .{});

    // Calculate per-operation times as floats for precision
    const standard_per_op = @as(f64, @floatFromInt(parse_standard_result.avg_ns)) / @as(f64, @floatFromInt(parse_iterations));
    const fast_per_op = @as(f64, @floatFromInt(parse_fast_result.avg_ns)) / @as(f64, @floatFromInt(parse_iterations));

    std.debug.print("Standard:           {d:.2} ns/op\n", .{standard_per_op});
    std.debug.print("Fast:               {d:.2} ns/op  ⚡\n", .{fast_per_op});

    const speedup = standard_per_op / fast_per_op;

    std.debug.print("\n⚡ Fast is {d:.0}x faster!\n", .{speedup});
    std.debug.print("========================================\n\n", .{});
}

test "both parsers produce equivalent results" {
    const test_data = generateTestEdid();

    var standard = try edid.standard.parse(std.testing.allocator, &test_data);
    defer standard.deinit();

    const fast = try edid.fast.parse(&test_data);

    // Compare results
    try std.testing.expectEqual(standard.version, fast.getVersion());
    try std.testing.expectEqual(standard.revision, fast.getRevision());
    try std.testing.expectEqualStrings(&standard.vendor_product.manufacturer, &fast.getManufacturer());
    try std.testing.expectEqual(standard.vendor_product.product, fast.getProductCode());
    try std.testing.expectEqual(standard.vendor_product.serial, fast.getSerialNumber());
    try std.testing.expectEqual(standard.screen_width_cm, fast.getScreenWidthCm());
    try std.testing.expectEqual(standard.screen_height_cm, fast.getScreenHeightCm());

    const standard_gamma = if (standard.gamma_times_100 != 0xFF)
        (@as(f64, @floatFromInt(standard.gamma_times_100)) + 100.0) / 100.0
    else
        0.0;
    try std.testing.expectEqual(@as(f32, @floatCast(standard_gamma)), fast.getGamma());
}
