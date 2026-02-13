//! Raw EDID binary structures using packed structs
//!
//! This module defines packed structs that directly map to the EDID binary format,
//! allowing zero-copy parsing and efficient memory usage.

const std = @import("std");

/// Raw manufacturer ID as stored in EDID bytes 0x08-0x09
/// Bit layout: [reserved:1][char1:5][char2:5][char3:5]
pub const ManufacturerId = packed struct(u16) {
    /// Third character (bits 0-4)
    char3: u5,
    /// Second character (bits 5-9)
    char2: u5,
    /// First character (bits 10-14)
    char1: u5,
    /// Reserved bit (bit 15, must be 0)
    _reserved: u1,

    /// Decode manufacturer ID to three-character string
    pub fn decode(self: ManufacturerId) [3]u8 {
        var result: [3]u8 = undefined;
        result[0] = if (self.char1 > 0) @as(u8, 'A') + self.char1 - 1 else 0;
        result[1] = if (self.char2 > 0) @as(u8, 'A') + self.char2 - 1 else 0;
        result[2] = if (self.char3 > 0) @as(u8, 'A') + self.char3 - 1 else 0;
        return result;
    }
};

/// Raw analog video input definition (byte 0x14, bit 7 = 0)
pub const AnalogVideoInputRaw = packed struct(u8) {
    /// Serrations on vertical sync
    serrations_on_vsync: bool,
    /// Sync on green supported
    composite_sync_on_green: bool,
    /// Composite sync on horizontal
    composite_sync_on_h: bool,
    /// Separate sync supported
    separate_sync_h_and_v: bool,
    /// Blank-to-black setup expected
    video_setup: u1,
    /// Signal level standard
    signal_level: u2,
    /// Must be 0 for analog
    _is_digital: u1,
};

/// Raw digital video input definition (byte 0x14, bit 7 = 1)
pub const DigitalVideoInputRaw = packed struct(u8) {
    /// Digital interface standard
    interface_type: u4,
    /// Color bit depth
    color_depth: u3,
    /// Must be 1 for digital
    _is_digital: u1,
};

/// Video input byte can be either analog or digital
pub const VideoInputRaw = extern union {
    analog: AnalogVideoInputRaw,
    digital: DigitalVideoInputRaw,
    raw: u8,

    pub fn isDigital(self: VideoInputRaw) bool {
        return (self.raw & 0x80) != 0;
    }
};

/// Feature support byte (byte 0x18)
pub const FeatureSupport = packed struct(u8) {
    /// GTF supported using default parameter values
    gtf_supported: bool,
    /// Preferred timing mode specified in descriptor block 1
    preferred_timing_mode: bool,
    /// Standard sRGB color space
    srgb_is_primary: bool,
    /// Display color type (2 bits)
    /// - For digital: 00=RGB 4:4:4, 01=RGB 4:4:4 + YCrCb 4:4:4, 10=RGB 4:4:4 + YCrCb 4:2:2
    /// - For analog: 00=Monochrome, 01=RGB color, 10=Non-RGB color, 11=Undefined
    display_color_type: u2,
    /// Active off supported
    dpms_active_off: bool,
    /// Suspend supported
    dpms_suspend: bool,
    /// Standby supported
    dpms_standby: bool,
};

/// Standard timing descriptor (2 bytes)
pub const StandardTiming = packed struct(u16) {
    /// Vertical frequency - 60 Hz (bits 0-5)
    vfreq_minus_60: u6,
    /// Aspect ratio (bits 6-7)
    /// 00 = 16:10, 01 = 4:3, 10 = 5:4, 11 = 16:9
    aspect_ratio: u2,
    /// Horizontal resolution / 8 - 31 (bits 8-15)
    hsize_div8_minus_31: u8,
};

/// Complete EDID base block (128 bytes)
/// Using extern struct for C-compatible memory layout
pub const EdidBaseBlock = extern struct {
    /// Header (8 bytes): 00 FF FF FF FF FF FF 00
    header: [8]u8,

    /// Manufacturer ID (2 bytes, big-endian packed)
    manufacturer_id: ManufacturerId,
    
    /// Product code (2 bytes, little-endian)
    product_code: u16,
    
    /// Serial number (4 bytes, little-endian)
    serial_number: u32,
    
    /// Week of manufacture (0 = not specified, 1-54 = week, 0xFF = model year in year field)
    manufacture_week: u8,
    
    /// Year of manufacture (year = 1990 + this value)
    manufacture_year: u8,
    
    /// EDID version (should be 1)
    edid_version: u8,
    
    /// EDID revision (3 or 4)
    edid_revision: u8,
    
    /// Video input definition
    video_input: VideoInputRaw,
    
    /// Maximum horizontal image size in cm (0 if not specified)
    max_h_image_size: u8,
    
    /// Maximum vertical image size in cm (0 if not specified)
    max_v_image_size: u8,
    
    /// Display gamma = (gamma_value + 100) / 100 (0xFF = defined in extension)
    display_gamma: u8,
    
    /// Feature support
    feature_support: FeatureSupport,
    
    /// Color characteristics (10 bytes, 0x19-0x22)
    /// Bytes 0-1: Low bits (2 bits each for red/green/blue/white x/y)
    /// Bytes 2-9: High bits (8 bits each)
    color_characteristics: [10]u8,
    
    /// Established timings (3 bytes, bitmap)
    established_timings: [3]u8,
    
    /// Standard timing identification (16 bytes = 8 x 2-byte descriptors)
    standard_timings: [8]StandardTiming,
    
    /// Detailed timing descriptors / display descriptors (72 bytes = 4 x 18-byte blocks)
    detailed_timing_descriptors: [4][18]u8,
    
    /// Number of extensions to follow
    extension_flag: u8,
    
    /// Checksum (sum of all 128 bytes should be 0)
    checksum: u8,

    comptime {
        // Verify the struct is exactly 128 bytes
        if (@sizeOf(@This()) != 128) {
            @compileError("EdidBaseBlock must be exactly 128 bytes");
        }
    }

    /// Cast raw EDID bytes to the structured format (zero-copy)
    pub fn fromBytes(data: *align(1) const [128]u8) *align(1) const EdidBaseBlock {
        return @ptrCast(data);
    }

    /// Validate the EDID header pattern
    pub fn hasValidHeader(self: *align(1) const EdidBaseBlock) bool {
        const expected = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
        return std.mem.eql(u8, &self.header, &expected);
    }

    /// Validate the checksum
    pub fn hasValidChecksum(self: *align(1) const EdidBaseBlock) bool {
        const bytes: *const [128]u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (bytes) |byte| {
            sum +%= byte;
        }
        return sum == 0;
    }

    /// Get the decoded manufacturer string
    pub fn getManufacturer(self: *align(1) const EdidBaseBlock) [3]u8 {
        // Need to byte-swap because EDID stores it big-endian
        const raw: u16 = @bitCast(self.manufacturer_id);
        const swapped: ManufacturerId = @bitCast(@byteSwap(raw));
        return swapped.decode();
    }

    /// Get product code (already little-endian in EDID)
    pub fn getProductCode(self: *align(1) const EdidBaseBlock) u16 {
        return self.product_code;
    }

    /// Get serial number (already little-endian in EDID)
    pub fn getSerialNumber(self: *align(1) const EdidBaseBlock) u32 {
        return self.serial_number;
    }

    /// Get manufacture year (0 if not specified)
    pub fn getManufactureYear(self: *align(1) const EdidBaseBlock) u16 {
        return if (self.manufacture_year > 0)
            @as(u16, 1990) + self.manufacture_year
        else
            0;
    }

    /// Get model year (0 if not specified via week = 0xFF)
    pub fn getModelYear(self: *align(1) const EdidBaseBlock) u16 {
        return if (self.manufacture_week == 0xFF)
            self.getManufactureYear()
        else
            0;
    }

    /// Get display gamma value (returns 0 if defined in extension)
    pub fn getGamma(self: *align(1) const EdidBaseBlock) f32 {
        return if (self.display_gamma != 0xFF)
            (@as(f32, @floatFromInt(self.display_gamma)) + 100.0) / 100.0
        else
            0.0;
    }
};

// Tests

const testing = std.testing;

test "ManufacturerId decode" {
    // "ABC" = 1, 2, 3
    // Binary: 0 00001 00010 00011 = 0x0443
    const id = ManufacturerId{
        .char1 = 1,
        .char2 = 2,
        .char3 = 3,
        ._reserved = 0,
    };

    const str = id.decode();
    try testing.expectEqualStrings("ABC", &str);
}

test "ManufacturerId size" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(ManufacturerId));
}

test "AnalogVideoInputRaw size and fields" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(AnalogVideoInputRaw));

    const raw: AnalogVideoInputRaw = @bitCast(@as(u8, 0b00011111));
    try testing.expect(raw.serrations_on_vsync);
    try testing.expect(raw.composite_sync_on_green);
    try testing.expect(raw.composite_sync_on_h);
    try testing.expect(raw.separate_sync_h_and_v);
    try testing.expectEqual(@as(u1, 1), raw.video_setup);
    try testing.expectEqual(@as(u2, 0), raw.signal_level);
}

test "DigitalVideoInputRaw size and fields" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(DigitalVideoInputRaw));

    // Digital (bit 7 = 1), 8-bit color (010), HDMI-A interface (0010)
    const raw: DigitalVideoInputRaw = @bitCast(@as(u8, 0b10100010));
    try testing.expectEqual(@as(u4, 2), raw.interface_type); // HDMI-A
    try testing.expectEqual(@as(u3, 2), raw.color_depth); // 8-bit
    try testing.expectEqual(@as(u1, 1), raw._is_digital);
}

test "EdidBaseBlock size" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(EdidBaseBlock));
}

test "EdidBaseBlock fromBytes and validation" {
    var data: [128]u8 align(1) = [_]u8{0} ** 128;

    // Set header
    const header = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    @memcpy(data[0..8], &header);

    // Set manufacturer ID: "TST" (20, 19, 20)
    // Binary: 0 10100 10011 10100 = 0xA4F4
    const id: u16 = 0xA4F4;
    data[8] = @intCast(id >> 8);
    data[9] = @intCast(id & 0xFF);

    // Set version
    data[0x12] = 1;
    data[0x13] = 4;

    // Calculate checksum
    var sum: u8 = 0;
    for (data[0..127]) |byte| {
        sum +%= byte;
    }
    data[127] = 0 -% sum;

    const edid = EdidBaseBlock.fromBytes(&data);

    try testing.expect(edid.hasValidHeader());
    try testing.expect(edid.hasValidChecksum());
    try testing.expectEqual(@as(u8, 1), edid.edid_version);
    try testing.expectEqual(@as(u8, 4), edid.edid_revision);
}

test "EdidBaseBlock manufacturer decoding" {
    var data: [128]u8 align(1) = [_]u8{0} ** 128;

    // "ABC" in big-endian = 0x0443
    data[8] = 0x04;
    data[9] = 0x43;

    const edid = EdidBaseBlock.fromBytes(&data);
    const mfg = edid.getManufacturer();

    try testing.expectEqualStrings("ABC", &mfg);
}
