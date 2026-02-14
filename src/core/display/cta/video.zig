//! CTA-861 Video Data Block parsing
//!
//! Video data blocks contain Short Video Descriptors (SVDs) listing
//! supported video modes by VIC (Video Identification Code).

const std = @import("std");
const testing = std.testing;

/// Short Video Descriptor (1 byte)
pub const Svd = struct {
    /// VIC code (1-255)
    vic: u8,
    /// Native indicator (preferred mode)
    native: bool,
    
    /// Parse SVD from byte
    pub fn parse(byte: u8) Svd {
        return Svd{
            .vic = byte & 0x7F,  // Bits 0-6
            .native = (byte & 0x80) != 0,  // Bit 7
        };
    }
};

/// Video block (with allocations)
pub const Block = struct {
    /// Array of short video descriptors
    svds: []const Svd,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *Block) void {
        self.allocator.free(self.svds);
    }
};

/// Parse video block from payload (allocates)
pub fn parseBlock(allocator: std.mem.Allocator, data: []const u8) !Block {
    if (data.len == 0) {
        return error.EmptyVideoBlock;
    }
    
    const svds = try allocator.alloc(Svd, data.len);
    errdefer allocator.free(svds);
    
    for (data, 0..) |byte, i| {
        svds[i] = Svd.parse(byte);
    }
    
    return Block{
        .svds = svds,
        .allocator = allocator,
    };
}

/// Parse video block without allocation (zero-copy view)
pub const BlockView = struct {
    data: []const u8,
    
    /// Get SVD at index
    pub fn getSvd(self: BlockView, index: usize) ?Svd {
        if (index >= self.data.len) return null;
        return Svd.parse(self.data[index]);
    }
    
    /// Get number of SVDs
    pub fn len(self: BlockView) usize {
        return self.data.len;
    }
    
    /// Check if VIC is supported
    pub fn supportsVic(self: BlockView, vic: u8) bool {
        for (self.data) |byte| {
            const svd = Svd.parse(byte);
            if (svd.vic == vic) return true;
        }
        return false;
    }
    
    /// Get list of native VICs
    pub fn getNativeVics(self: BlockView, allocator: std.mem.Allocator) ![]u8 {
        var native_list = std.ArrayList(u8){};
        defer native_list.deinit(allocator);
        
        for (self.data) |byte| {
            const svd = Svd.parse(byte);
            if (svd.native) {
                try native_list.append(allocator, svd.vic);
            }
        }
        
        return try native_list.toOwnedSlice(allocator);
    }
    
    /// Iterator over SVDs
    pub const Iterator = struct {
        view: BlockView,
        index: usize,
        
        pub fn next(self: *Iterator) ?Svd {
            if (self.index >= self.view.len()) return null;
            const svd = self.view.getSvd(self.index).?;
            self.index += 1;
            return svd;
        }
    };
    
    /// Create iterator
    pub fn iterate(self: BlockView) Iterator {
        return Iterator{
            .view = self,
            .index = 0,
        };
    }
};

/// Parse video block as zero-copy view
pub fn parseBlockView(data: []const u8) BlockView {
    return BlockView{ .data = data };
}

// Tests

test "SVD parsing" {
    // VIC 16 (1080p60) without native flag
    const svd1 = Svd.parse(0x10);
    try testing.expectEqual(@as(u8, 16), svd1.vic);
    try testing.expect(!svd1.native);
    
    // VIC 4 (720p60) with native flag (bit 7 set)
    const svd2 = Svd.parse(0x84);
    try testing.expectEqual(@as(u8, 4), svd2.vic);
    try testing.expect(svd2.native);
    
    // VIC 127 (max without native)
    const svd3 = Svd.parse(0x7F);
    try testing.expectEqual(@as(u8, 127), svd3.vic);
    try testing.expect(!svd3.native);
}

test "video block view" {
    const data = [_]u8{
        0x10, // VIC 16
        0x84, // VIC 4 (native)
        0x1F, // VIC 31
    };
    
    const view = parseBlockView(&data);
    
    try testing.expectEqual(@as(usize, 3), view.len());
    
    // Check specific SVD
    const svd = view.getSvd(1).?;
    try testing.expectEqual(@as(u8, 4), svd.vic);
    try testing.expect(svd.native);
}

test "video block view - supports VIC" {
    const data = [_]u8{ 0x10, 0x04, 0x1F };
    const view = parseBlockView(&data);
    
    try testing.expect(view.supportsVic(16));
    try testing.expect(view.supportsVic(4));
    try testing.expect(view.supportsVic(31));
    try testing.expect(!view.supportsVic(95));
}

test "video block view - get native VICs" {
    const data = [_]u8{
        0x10,  // VIC 16 (not native)
        0x84,  // VIC 4 (native)
        0x9F,  // VIC 31 (native)
    };
    
    const view = parseBlockView(&data);
    const native_vics = try view.getNativeVics(testing.allocator);
    defer testing.allocator.free(native_vics);
    
    try testing.expectEqual(@as(usize, 2), native_vics.len);
    try testing.expectEqual(@as(u8, 4), native_vics[0]);
    try testing.expectEqual(@as(u8, 31), native_vics[1]);
}

test "video block view - iterator" {
    const data = [_]u8{ 0x10, 0x84, 0x1F };
    const view = parseBlockView(&data);
    
    var iter = view.iterate();
    var count: usize = 0;
    var native_count: usize = 0;
    
    while (iter.next()) |svd| {
        count += 1;
        if (svd.native) native_count += 1;
    }
    
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(usize, 1), native_count);
}

// Video Capability Data Block

/// Over/underscan capability
pub const OverUnderscan = enum(u2) {
    unknown = 0,
    always_overscan = 1,
    always_underscan = 2,
    both = 3,
};

/// Video Capability Data Block
pub const CapabilityBlock = struct {
    /// Selectable YCC quantization range
    selectable_ycc_quantization: bool,
    
    /// Selectable RGB quantization range
    selectable_rgb_quantization: bool,
    
    /// PT (Preferred Timing) overscan/underscan
    pt_over_underscan: OverUnderscan,
    
    /// IT (Information Technology) overscan/underscan
    it_over_underscan: OverUnderscan,
    
    /// CE (Consumer Electronics) overscan/underscan
    ce_over_underscan: OverUnderscan,
    
    /// Parse from extended data block payload (1 byte minimum)
    pub fn parse(data: []const u8) ?CapabilityBlock {
        if (data.len < 1) return null;
        
        const byte = data[0];
        
        return CapabilityBlock{
            .selectable_ycc_quantization = (byte & 0x80) != 0,
            .selectable_rgb_quantization = (byte & 0x40) != 0,
            .pt_over_underscan = @enumFromInt((byte >> 4) & 0x03),
            .it_over_underscan = @enumFromInt((byte >> 2) & 0x03),
            .ce_over_underscan = @enumFromInt(byte & 0x03),
        };
    }
};

test "video capability parsing - basic" {
    const data = [_]u8{
        0b11000000, // Selectable YCC + RGB quantization
    };
    
    const block = CapabilityBlock.parse(&data).?;
    
    try testing.expect(block.selectable_ycc_quantization);
    try testing.expect(block.selectable_rgb_quantization);
    try testing.expectEqual(OverUnderscan.unknown, block.pt_over_underscan);
}

test "video capability parsing - overscan modes" {
    // Bits: [YCC][RGB][PT1][PT0][IT1][IT0][CE1][CE0]
    // PT=01 (always_overscan), IT=10 (always_underscan), CE=11 (both)
    const data = [_]u8{
        0b00011011, // PT=01, IT=10, CE=11
    };
    
    const block = CapabilityBlock.parse(&data).?;
    
    try testing.expectEqual(OverUnderscan.always_overscan, block.pt_over_underscan);
    try testing.expectEqual(OverUnderscan.always_underscan, block.it_over_underscan);
    try testing.expectEqual(OverUnderscan.both, block.ce_over_underscan);
}
