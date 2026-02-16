# Sideswipe Benchmarks

Performance benchmarks for the Sideswipe Wayland compositor.

## Running Benchmarks

### Run All Benchmarks

```bash
zig build benchmark
```

This runs all available benchmarks in sequence with comprehensive output.

### Run Specific Benchmarks

```bash
# Poll FD caching benchmark
zig build benchmark -- --name pollfd

# EDID parser benchmark
zig build benchmark -- --name edid

# Zig vs C library comparison (requires libdisplay-info)
zig build benchmark -- --name libdisplay-info
```

## Available Benchmarks

### Poll FD Caching (`pollfd`)

**Command:** `zig build benchmark -- --name pollfd`

**What it measures:** Performance impact of caching poll file descriptors vs allocating on every call.

**Scenarios:**
- **Simple Backend**: 1 implementation, 2 FDs (10,000 iterations)
- **Complex Backend**: 3 implementations, 3 FDs each (10,000 iterations)
- **Event Loop Simulation**: 2 implementations, 4 FDs each (100,000 iterations)
- **Realistic Compositor**: 5 implementations, 2 FDs each (50,000 iterations)
- **Cache Invalidation Overhead**: Measures cost of invalidating vs using cached results

**Key Metrics:**
- Execution time (milliseconds)
- Allocations per scenario
- Memory usage (KB)
- Operations per second
- Speedup factor (cached vs uncached)

**Example Output:**
```
Poll FD Caching Benchmark Results
==================================================
Scenario: Simple Backend (1 impl, 2 FDs)
  Implementations: 1
  FDs per impl:    2
  Iterations:      10000

Pre-optimization (allocate every call):
  Time:        45.32 ms
  Allocations: 30000
  Bytes:       512.00 KB
  Ops/sec:     220704

Post-optimization (cached):
  Time:        2.15 ms
  Allocations: 1
  Bytes:       0.25 KB
  Ops/sec:     4651163

Improvement:
  Time:        95.3% faster (21.08x speedup)
  Allocations: 99.9% fewer
```

### EDID Parser (`edid`)

**Command:** `zig build benchmark -- --name edid`

**What it measures:** Performance comparison between standard EDID parser (with allocations) and fast parser (zero-alloc + SIMD).

**Key Metrics:**
- Parse time per operation (nanoseconds)
- Speedup factor (standard vs fast)
- Memory allocation patterns
- Multiple sample runs for accuracy

**Example Output:**
```
EDID Parser Benchmark
==================================================
Test data size:              128 bytes
Parse iterations per sample: 500000
Number of samples:           5

Standard Parser (with allocations):
  Iterations: 500000
  Average:    2500000 ns (2.50 μs)
  
Fast Parser (zero-alloc + packed + SIMD):
  Iterations: 500000
  Average:    250000 ns (0.25 μs)

⚡ Fast is 10.0x faster!
```

### libdisplay-info Comparison (`libdisplay-info`)

**Command:** `zig build benchmark -- --name libdisplay-info`

**What it measures:** Performance comparison between native Zig EDID implementation and the C libdisplay-info library, with correctness validation.

**Requirements:** Requires libdisplay-info C library installed:
- Arch Linux: `pacman -S libdisplay-info`
- Ubuntu/Debian: `apt install libdisplay-info-dev`
- Fedora: `dnf install libdisplay-info-devel`

**Key Metrics:**
- Parse time comparison (Zig vs C)
- Correctness validation against C library
- Feature comparison
- Memory allocation patterns

**Example Output:**
```
Zig vs C libdisplay-info Benchmark
==================================================
EDID size:  128 bytes
Iterations: 1000000

Zig implementation:  85.23 ns/op
C libdisplay-info:   142.67 ns/op

⚡ Zig is 1.7x faster (67% improvement)

Correctness Validation:
Version:         1.4 vs 1.4  ✅
Manufacturer ID: DEL vs DEL  ✅
Product Code:    0xA0C7 vs 0xA0C7  ✅
Serial Number:   0x4C564C42 vs 0x4C564C42  ✅
Screen Size:     60x34cm vs 60x34cm  ✅

✅ All validation checks passed!
```

## Adding New Benchmarks

### 1. Create Benchmark File

Create a new file in `src/benchmarks/` (e.g., `my_benchmark.zig`):

```zig
//! Description of what this benchmark measures

const std = @import("std");
const root = @import("root.zig");
const core = @import("core");
const testing = core.testing;
const cli = @import("core.cli");

/// Public entry point to run this benchmark
pub fn run(allocator: std.mem.Allocator, logger: *cli.Logger) !void {
    logger.info("", .{});
    logger.info("=== My Benchmark ===", .{});
    
    // Use root.Timer for timing
    var timer = try root.Timer.start();
    
    // ... benchmark code ...
    
    const elapsed = timer.read();
    logger.info("Completed in {d:.2} ms", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
}

// Add tests
test "my benchmark - validation" {
    // Test benchmark logic using core.testing
}
```

### 2. Export in Root Module

Add to `src/benchmarks/root.zig`:

```zig
pub const my_benchmark = @import("my_benchmark.zig");
```

### 3. Register in Runner

Update `runAll()` in `root.zig`:

```zig
pub fn runAll(allocator: std.mem.Allocator, logger: *cli.Logger) !void {
    // ... existing benchmarks ...
    
    logger.info("", .{});
    logger.info("=== Running My Benchmark ===", .{});
    try my_benchmark.run(allocator, logger);
}
```

Update `runByName()` in `root.zig`:

```zig
pub fn runByName(allocator: std.mem.Allocator, name: []const u8, logger: *cli.Logger) !void {
    if (std.mem.eql(u8, name, "pollfd")) {
        try pollfd.run(allocator, logger);
    } else if (std.mem.eql(u8, name, "my-benchmark")) {
        try my_benchmark.run(allocator, logger);
    } else {
        logger.err("Unknown benchmark: {s}", .{name});
        logger.info("Available benchmarks: pollfd, my-benchmark", .{});
        return error.BenchmarkNotFound;
    }
}
```

## Common Utilities

The `root.zig` module provides shared utilities:

### AllocTracker

Track memory allocations during benchmarks:

```zig
var tracker = root.AllocTracker{
    .parent_allocator = base_allocator,
};
const alloc = tracker.allocator();

// ... use alloc ...

const stats = tracker.snapshot();
print("Allocated: {d} bytes in {d} calls\n", .{stats.bytes, stats.allocations});
```

### Timer

Measure execution time:

```zig
var timer = try root.Timer.start();

// ... code to benchmark ...

const elapsed_ns = timer.read();
```

### Result

Store and compare benchmark results:

```zig
const result = root.Result{
    .name = "test",
    .time_ns = elapsed,
    .allocations = tracker.allocation_count,
    .bytes_allocated = tracker.bytes_allocated,
};

result.print(logger); // Print using logger

// Compare two results
try root.Result.compare(baseline, optimized, writer);
```

## Best Practices

1. **Use ReleaseFast optimization**: Benchmarks run with `optimize = .ReleaseFast` for realistic measurements
2. **Warmup rounds**: Run iterations before measuring to warm up caches
3. **Multiple scenarios**: Test different scales and configurations
4. **Track allocations**: Memory patterns are as important as speed
5. **Baseline comparisons**: Compare optimized vs unoptimized implementations
6. **Consistent environment**: Run benchmarks in controlled conditions

## Benchmark Guidelines

### What to Benchmark

- **Hot paths**: Functions called frequently in main loops
- **Optimizations**: Compare before/after for optimization work
- **Scalability**: Test with varying input sizes
- **Memory patterns**: Track allocation behavior

### What NOT to Benchmark

- One-time initialization code
- Error paths (unless critical)
- Trivial operations (unless in hot path)
- Platform-specific code (document which platforms tested)

## Reading Results

### Time Metrics

- **Time**: Absolute execution time in milliseconds
- **Ops/sec**: Operations per second (higher is better)
- **Speedup**: Multiplier of performance improvement (e.g., 2.5x faster)

### Memory Metrics

- **Allocations**: Number of allocation calls (fewer is better)
- **Bytes**: Total memory allocated in KB
- **Reduction**: Percentage decrease in allocations

### Typical Goals

- **Time improvement**: 10-50% faster for micro-optimizations, 2-10x for algorithmic changes
- **Allocation reduction**: Eliminate allocations in hot paths where possible
- **Consistency**: Low variance between runs indicates stable performance

## Future Benchmarks

Potential benchmarks to add:

- **Rendering performance**: Frame composition and rendering pipeline
- **Input latency**: Event processing speed
- **Window management**: Surface creation and destruction overhead
- **Memory usage**: Peak and average memory consumption
- **DRM/KMS operations**: Mode setting and page flipping
- **Protocol handling**: Wayland protocol message processing

## Troubleshooting

### Benchmark fails to compile

- Check that all dependencies are linked in `build.zig`
- Verify imports match the module structure
- Run `zig build test` to ensure tests pass

### Results seem inconsistent

- Ensure system is not under load during benchmarking
- Increase iteration count for more stable averages
- Add warmup rounds to stabilize caches
- Check if background processes are interfering

### Benchmark runs too slowly

- Reduce iteration count (but keep high enough for accuracy)
- Use smaller test data sets
- Consider if the benchmark is testing the right thing

### Out of memory

- Check for memory leaks in benchmark code
- Use `testing.allocator` which detects leaks
- Ensure proper cleanup in defer blocks
- Reduce data set size if necessary

## Contributing

When adding benchmarks:

1. Document what is being measured and why
2. Include multiple scenarios (small, medium, large)
3. Add tests to validate benchmark logic
4. Compare against baseline when measuring optimizations
5. Update this README with benchmark description
6. Include example output in documentation
