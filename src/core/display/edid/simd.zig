//! SIMD-optimized EDID operations
//!
//! This module demonstrates how to add SIMD optimizations on top of
//! the packed struct foundation for performance-critical operations.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// SIMD-optimized checksum validation for EDID blocks
///
/// Uses vector operations to process 16 bytes at a time instead of 1.
/// Falls back to scalar on architectures without SIMD support.
pub fn validateChecksumSIMD(data: *const [128]u8) bool {
    // Check if we have SIMD support at compile time
    comptime {
        const has_simd = switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => true,
            else => false,
        };
        
        if (!has_simd) {
            // Fallback to scalar implementation
            return validateChecksumScalar(data);
        }
    }
    
    // Use 128-bit vectors (16 bytes at a time)
    const Vec16u8 = @Vector(16, u8);
    
    // Initialize accumulator vector to zeros
    var acc: Vec16u8 = @splat(0);
    
    // Process 128 bytes in chunks of 16
    // 128 / 16 = 8 iterations
    comptime var i: usize = 0;
    inline while (i < 8) : (i += 1) {
        const offset = i * 16;
        
        // Load 16 bytes into a vector
        const chunk: Vec16u8 = data[offset..][0..16].*;
        
        // Vector addition with wrapping (automatic SIMD add)
        acc +%= chunk;
    }
    
    // Horizontal sum: reduce 16 bytes to 1
    var sum: u8 = 0;
    var j: usize = 0;
    while (j < 16) : (j += 1) {
        sum +%= acc[j];
    }
    
    return sum == 0;
}

/// Scalar fallback for checksum validation
pub fn validateChecksumScalar(data: *const [128]u8) bool {
    var sum: u8 = 0;
    for (data) |byte| {
        sum +%= byte;
    }
    return sum == 0;
}

/// SIMD-optimized header validation
///
/// Compares 8 bytes at once using vector comparison.
pub fn validateHeaderSIMD(header: *const [8]u8) bool {
    const expected = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    
    comptime {
        const has_simd = switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => true,
            else => false,
        };
        
        if (!has_simd) {
            return std.mem.eql(u8, header, &expected);
        }
    }
    
    // Load both as vectors
    const Vec8u8 = @Vector(8, u8);
    const header_vec: Vec8u8 = header.*;
    const expected_vec: Vec8u8 = expected;
    
    // Vector equality comparison
    const cmp = header_vec == expected_vec;
    
    // Check if all lanes are true
    return @reduce(.And, cmp);
}

/// SIMD-optimized memory comparison
///
/// Generic SIMD comparison for arbitrary-sized buffers.
pub fn memEqualSIMD(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    
    const len = a.len;
    
    // Use largest vector size that fits in the data
    if (len >= 32 and builtin.cpu.arch == .x86_64) {
        return memEqualSIMD32(a, b);
    } else if (len >= 16) {
        return memEqualSIMD16(a, b);
    } else {
        return std.mem.eql(u8, a, b);
    }
}

/// 128-bit SIMD comparison (16 bytes at a time)
fn memEqualSIMD16(a: []const u8, b: []const u8) bool {
    std.debug.assert(a.len == b.len);
    
    const Vec16u8 = @Vector(16, u8);
    const len = a.len;
    var i: usize = 0;
    
    // Process 16-byte chunks
    while (i + 16 <= len) : (i += 16) {
        const va: Vec16u8 = a[i..][0..16].*;
        const vb: Vec16u8 = b[i..][0..16].*;
        
        if (!@reduce(.And, va == vb)) {
            return false;
        }
    }
    
    // Handle remaining bytes
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    
    return true;
}

/// 256-bit SIMD comparison (32 bytes at a time) - AVX2
fn memEqualSIMD32(a: []const u8, b: []const u8) bool {
    std.debug.assert(a.len == b.len);
    
    const Vec32u8 = @Vector(32, u8);
    const len = a.len;
    var i: usize = 0;
    
    // Process 32-byte chunks
    while (i + 32 <= len) : (i += 32) {
        const va: Vec32u8 = a[i..][0..32].*;
        const vb: Vec32u8 = b[i..][0..32].*;
        
        if (!@reduce(.And, va == vb)) {
            return false;
        }
    }
    
    // Handle remaining bytes with 16-byte vectors
    if (i + 16 <= len) {
        const Vec16u8 = @Vector(16, u8);
        const va: Vec16u8 = a[i..][0..16].*;
        const vb: Vec16u8 = b[i..][0..16].*;
        
        if (!@reduce(.And, va == vb)) {
            return false;
        }
        i += 16;
    }
    
    // Handle tail
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    
    return true;
}

/// SIMD-accelerated byte search
///
/// Searches for a specific byte value using SIMD.
pub fn findByteSIMD(haystack: []const u8, needle: u8) ?usize {
    if (haystack.len >= 16) {
        return findByteSIMD16(haystack, needle);
    } else {
        return std.mem.indexOfScalar(u8, haystack, needle);
    }
}

fn findByteSIMD16(haystack: []const u8, needle: u8) ?usize {
    const Vec16u8 = @Vector(16, u8);
    const needle_vec: Vec16u8 = @splat(needle);
    
    var i: usize = 0;
    const len = haystack.len;
    
    // Process 16-byte chunks
    while (i + 16 <= len) : (i += 16) {
        const chunk: Vec16u8 = haystack[i..][0..16].*;
        const matches = chunk == needle_vec;
        
        // Check if any lane matched
        if (@reduce(.Or, matches)) {
            // Find which lane matched
            var j: usize = 0;
            while (j < 16) : (j += 1) {
                if (matches[j]) return i + j;
            }
        }
    }
    
    // Handle tail
    while (i < len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    
    return null;
}

// Tests

fn generateTestData() [128]u8 {
    var data = [_]u8{0} ** 128;
    
    // Fill with some pattern
    for (&data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }
    
    // Calculate checksum
    var sum: u8 = 0;
    for (data[0..127]) |byte| {
        sum +%= byte;
    }
    data[127] = 0 -% sum;
    
    return data;
}

test "SIMD checksum validation" {
    const data = generateTestData();
    
    // Both should produce same result
    const scalar_result = validateChecksumScalar(&data);
    const simd_result = validateChecksumSIMD(&data);
    
    try testing.expect(scalar_result);
    try testing.expect(simd_result);
    try testing.expectEqual(scalar_result, simd_result);
}

test "SIMD checksum validation - invalid" {
    var data = generateTestData();
    data[127] = 0xFF; // Break checksum
    
    const scalar_result = validateChecksumScalar(&data);
    const simd_result = validateChecksumSIMD(&data);
    
    try testing.expect(!scalar_result);
    try testing.expect(!simd_result);
    try testing.expectEqual(scalar_result, simd_result);
}

test "SIMD header validation" {
    const valid_header = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    try testing.expect(validateHeaderSIMD(&valid_header));
    
    const invalid_header = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    try testing.expect(!validateHeaderSIMD(&invalid_header));
}

test "SIMD memory comparison" {
    const a = "Hello, World! This is a test of SIMD memory comparison!";
    const b = "Hello, World! This is a test of SIMD memory comparison!";
    const c = "Hello, World! This is a test of SIMD memory comparison?";
    
    try testing.expect(memEqualSIMD(a, b));
    try testing.expect(!memEqualSIMD(a, c));
}

test "SIMD byte search" {
    const haystack = "The quick brown fox jumps over the lazy dog";
    
    const idx = findByteSIMD(haystack, 'q');
    try testing.expectEqual(@as(?usize, 4), idx);
    
    const no_match = findByteSIMD(haystack, 'X');
    try testing.expectEqual(@as(?usize, null), no_match);
}

// Benchmark helpers

pub fn benchmarkChecksumScalar(data: *const [128]u8, iterations: usize) u64 {
    const start = std.time.nanoTimestamp();
    
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = validateChecksumScalar(data);
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

pub fn benchmarkChecksumSIMD(data: *const [128]u8, iterations: usize) u64 {
    const start = std.time.nanoTimestamp();
    
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = validateChecksumSIMD(data);
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}
