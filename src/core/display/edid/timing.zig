//! EDID detailed timing descriptors
//!
//! Detailed timing descriptors define precise video timings for display modes.
//! Each EDID base block contains 4 × 18-byte descriptor slots.

const std = @import("std");
const testing = std.testing;

/// Stereo viewing support
pub const StereoMode = enum(u3) {
    none = 0,
    field_seq_right = 1,
    field_seq_left = 2,
    two_way_interleaved_right = 3,
    two_way_interleaved_left = 4,
    four_way_interleaved = 5,
    side_by_side_interleaved = 6,
    _,
};

/// Signal type for detailed timing
pub const SignalType = enum(u2) {
    analog_composite = 0,
    bipolar_analog_composite = 1,
    digital_composite = 2,
    digital_separate = 3,
};

/// Sync polarity for digital separate sync
pub const SyncPolarity = enum(u1) {
    negative = 0,
    positive = 1,
};

/// Analog composite sync flags (bits in flags byte)
pub const AnalogCompositeSync = packed struct(u8) {
    sync_serrations: bool,
    sync_on_green: bool,
    _reserved: u6,
};

/// Digital separate sync details
pub const DigitalSeparateSync = struct {
    vsync_polarity: SyncPolarity,
    hsync_polarity: SyncPolarity,
};

/// Sync information based on signal type
pub const SyncInfo = union(SignalType) {
    analog_composite: AnalogCompositeSync,
    bipolar_analog_composite: AnalogCompositeSync,
    digital_composite: void,
    digital_separate: DigitalSeparateSync,
};

/// Raw detailed timing descriptor (18 bytes)
///
/// This uses a mix of packed and regular structs due to split fields
pub const DetailedRaw = extern struct {
    /// Pixel clock in 10 kHz units (little-endian)
    pixel_clock_10khz: u16,
    
    /// Horizontal addressable video (low 8 bits)
    h_active_lo: u8,
    
    /// Horizontal blanking (low 8 bits)
    h_blank_lo: u8,
    
    /// Horizontal addressable (bits 11-8) and blanking (bits 11-8)
    h_hi: u8,
    
    /// Vertical addressable video (low 8 bits)
    v_active_lo: u8,
    
    /// Vertical blanking (low 8 bits)
    v_blank_lo: u8,
    
    /// Vertical addressable (bits 11-8) and blanking (bits 11-8)
    v_hi: u8,
    
    /// Horizontal front porch (low 8 bits)
    h_front_porch_lo: u8,
    
    /// Horizontal sync pulse width (low 8 bits)
    h_sync_pulse_lo: u8,
    
    /// Vertical front porch (bits 7-4) and sync pulse (bits 3-0), both low 4 bits
    v_front_sync_lo: u8,
    
    /// High bits for front porch and sync
    front_sync_hi: u8,
    
    /// Horizontal image size in mm (low 8 bits)
    h_image_mm_lo: u8,
    
    /// Vertical image size in mm (low 8 bits)
    v_image_mm_lo: u8,
    
    /// High bits for image size
    image_size_hi: u8,
    
    /// Horizontal border pixels
    h_border: u8,
    
    /// Vertical border lines
    v_border: u8,
    
    /// Flags byte
    flags: u8,

    comptime {
        if (@sizeOf(@This()) != 18) {
            @compileError("DetailedRaw must be 18 bytes");
        }
    }

    /// Get horizontal active pixels
    pub fn getHActive(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, (self.h_hi >> 4) & 0x0F) << 8) | self.h_active_lo;
    }

    /// Get horizontal blanking pixels
    pub fn getHBlank(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, self.h_hi & 0x0F) << 8) | self.h_blank_lo;
    }

    /// Get vertical active lines
    pub fn getVActive(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, (self.v_hi >> 4) & 0x0F) << 8) | self.v_active_lo;
    }

    /// Get vertical blanking lines
    pub fn getVBlank(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, self.v_hi & 0x0F) << 8) | self.v_blank_lo;
    }

    /// Get horizontal front porch pixels
    pub fn getHFrontPorch(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, (self.front_sync_hi >> 6) & 0x03) << 8) | self.h_front_porch_lo;
    }

    /// Get horizontal sync pulse width pixels
    pub fn getHSyncPulse(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, (self.front_sync_hi >> 4) & 0x03) << 8) | self.h_sync_pulse_lo;
    }

    /// Get vertical front porch lines
    pub fn getVFrontPorch(self: *align(1) const DetailedRaw) u16 {
        const hi = (self.front_sync_hi >> 2) & 0x03;
        const lo = (self.v_front_sync_lo >> 4) & 0x0F;
        return (@as(u16, hi) << 4) | lo;
    }

    /// Get vertical sync pulse width lines
    pub fn getVSyncPulse(self: *align(1) const DetailedRaw) u16 {
        const hi = self.front_sync_hi & 0x03;
        const lo = self.v_front_sync_lo & 0x0F;
        return (@as(u16, hi) << 4) | lo;
    }

    /// Get horizontal image size in mm
    pub fn getHImageMm(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, (self.image_size_hi >> 4) & 0x0F) << 8) | self.h_image_mm_lo;
    }

    /// Get vertical image size in mm
    pub fn getVImageMm(self: *align(1) const DetailedRaw) u16 {
        return (@as(u16, self.image_size_hi & 0x0F) << 8) | self.v_image_mm_lo;
    }

    /// Get pixel clock in Hz
    pub fn getPixelClockHz(self: *align(1) const DetailedRaw) u64 {
        return @as(u64, self.pixel_clock_10khz) * 10_000;
    }

    /// Check if interlaced
    pub fn isInterlaced(self: *align(1) const DetailedRaw) bool {
        return (self.flags & 0x80) != 0;
    }

    /// Get stereo mode
    pub fn getStereoMode(self: *align(1) const DetailedRaw) StereoMode {
        const stereo_hi = (self.flags >> 5) & 0x03;
        const stereo_lo = self.flags & 0x01;
        
        if (stereo_hi == 0) {
            return .none;
        }
        
        const value = (stereo_hi << 1) | stereo_lo;
        return @enumFromInt(value);
    }

    /// Get signal type
    pub fn getSignalType(self: *align(1) const DetailedRaw) SignalType {
        const bits = (self.flags >> 3) & 0x03;
        return @enumFromInt(bits);
    }

    /// Get digital separate sync info (only valid if signal type is digital_separate)
    pub fn getDigitalSeparateSync(self: *align(1) const DetailedRaw) ?DigitalSeparateSync {
        if (self.getSignalType() != .digital_separate) {
            return null;
        }
        
        return DigitalSeparateSync{
            .vsync_polarity = @enumFromInt((self.flags >> 2) & 0x01),
            .hsync_polarity = @enumFromInt((self.flags >> 1) & 0x01),
        };
    }
};

/// Established timings I & II (3 bytes of bitmaps)
/// These are legacy VGA/SVGA/XGA timings from EDID 1.0
pub const Established = struct {
    // Established timings I (byte 0x23)
    has_720x400_70hz: bool,
    has_720x400_88hz: bool,
    has_640x480_60hz: bool,
    has_640x480_67hz: bool,
    has_640x480_72hz: bool,
    has_640x480_75hz: bool,
    has_800x600_56hz: bool,
    has_800x600_60hz: bool,
    
    // Established timings II (byte 0x24)
    has_800x600_72hz: bool,
    has_800x600_75hz: bool,
    has_832x624_75hz: bool,
    has_1024x768_87hz_interlaced: bool,
    has_1024x768_60hz: bool,
    has_1024x768_70hz: bool,
    has_1024x768_75hz: bool,
    has_1280x1024_75hz: bool,
    
    // Manufacturer timings (byte 0x25, bit 7)
    has_1152x870_75hz: bool,
};

/// Parse established timings from 3 bytes
pub fn parseEstablishedTimings(bytes: *align(1) const [3]u8) Established {
    return Established{
        // Byte 0 (0x23)
        .has_720x400_70hz = (bytes[0] & 0x80) != 0,
        .has_720x400_88hz = (bytes[0] & 0x40) != 0,
        .has_640x480_60hz = (bytes[0] & 0x20) != 0,
        .has_640x480_67hz = (bytes[0] & 0x10) != 0,
        .has_640x480_72hz = (bytes[0] & 0x08) != 0,
        .has_640x480_75hz = (bytes[0] & 0x04) != 0,
        .has_800x600_56hz = (bytes[0] & 0x02) != 0,
        .has_800x600_60hz = (bytes[0] & 0x01) != 0,
        
        // Byte 1 (0x24)
        .has_800x600_72hz = (bytes[1] & 0x80) != 0,
        .has_800x600_75hz = (bytes[1] & 0x40) != 0,
        .has_832x624_75hz = (bytes[1] & 0x20) != 0,
        .has_1024x768_87hz_interlaced = (bytes[1] & 0x10) != 0,
        .has_1024x768_60hz = (bytes[1] & 0x08) != 0,
        .has_1024x768_70hz = (bytes[1] & 0x04) != 0,
        .has_1024x768_75hz = (bytes[1] & 0x02) != 0,
        .has_1280x1024_75hz = (bytes[1] & 0x01) != 0,
        
        // Byte 2 (0x25)
        .has_1152x870_75hz = (bytes[2] & 0x80) != 0,
    };
}

/// Standard timing aspect ratio
pub const StandardAspectRatio = enum(u2) {
    ratio_16_10 = 0,
    ratio_4_3 = 1,
    ratio_5_4 = 2,
    ratio_16_9 = 3,
};

/// Standard timing information (2 bytes)
/// Defined in EDID section 3.9
pub const Standard = struct {
    /// Horizontal resolution
    h_active: u16,
    /// Vertical resolution  
    v_active: u16,
    /// Refresh rate in Hz
    refresh_rate_hz: u8,
    /// Aspect ratio
    aspect_ratio: StandardAspectRatio,
};

/// Parse standard timing from raw bytes
pub fn parseStandardTiming(bytes: *align(1) const [2]u8) ?Standard {
    const byte0 = bytes[0];
    const byte1 = bytes[1];
    
    // 0x0101 means unused
    if (byte0 == 0x01 and byte1 == 0x01) {
        return null;
    }
    
    // Horizontal resolution = (byte0 + 31) * 8
    const h_active = (@as(u16, byte0) + 31) * 8;
    
    // Aspect ratio is bits 7-6
    const aspect_bits = (byte1 >> 6) & 0x03;
    const aspect_ratio: StandardAspectRatio = @enumFromInt(aspect_bits);
    
    // Vertical resolution depends on aspect ratio
    const v_active: u16 = switch (aspect_ratio) {
        .ratio_16_10 => (h_active * 10) / 16,
        .ratio_4_3 => (h_active * 3) / 4,
        .ratio_5_4 => (h_active * 4) / 5,
        .ratio_16_9 => (h_active * 9) / 16,
    };
    
    // Refresh rate = (byte1 & 0x3F) + 60
    const refresh_rate_hz = (byte1 & 0x3F) + 60;
    
    return Standard{
        .h_active = h_active,
        .v_active = v_active,
        .refresh_rate_hz = refresh_rate_hz,
        .aspect_ratio = aspect_ratio,
    };
}

/// High-level detailed timing descriptor
pub const Detailed = struct {
    /// Pixel clock in Hz
    pixel_clock_hz: u64,
    
    /// Horizontal timings (pixels)
    h_active: u16,
    h_blank: u16,
    h_front_porch: u16,
    h_sync_pulse: u16,
    
    /// Vertical timings (lines)
    v_active: u16,
    v_blank: u16,
    v_front_porch: u16,
    v_sync_pulse: u16,
    
    /// Physical display size (mm), 0 if aspect ratio
    h_image_mm: u16,
    v_image_mm: u16,
    
    /// Border pixels/lines
    h_border: u8,
    v_border: u8,
    
    /// Timing properties
    interlaced: bool,
    stereo: StereoMode,
    sync_info: SyncInfo,
    
    /// Calculate horizontal total pixels
    pub fn getHTotal(self: Detailed) u16 {
        return self.h_active + self.h_blank;
    }
    
    /// Calculate vertical total lines
    pub fn getVTotal(self: Detailed) u16 {
        return self.v_active + self.v_blank;
    }
    
    /// Calculate refresh rate in Hz
    pub fn getRefreshRate(self: Detailed) f32 {
        const h_total = self.getHTotal();
        const v_total = self.getVTotal();
        const total_pixels = @as(f32, @floatFromInt(@as(u32, h_total) * v_total));
        
        if (total_pixels == 0) return 0;
        
        const pixel_clock_f = @as(f32, @floatFromInt(self.pixel_clock_hz));
        return pixel_clock_f / total_pixels;
    }
};

/// Display descriptor types (when pixel clock = 0)
pub const DisplayDescriptorTag = enum(u8) {
    product_serial = 0xFF,
    data_string = 0xFE,
    range_limits = 0xFD,
    product_name = 0xFC,
    color_point = 0xFB,
    std_timing_ids = 0xFA,
    dcm_data = 0xF9,
    cvt_timing_codes = 0xF8,
    established_timings_iii = 0xF7,
    dummy = 0x10,
    _,
};

/// Display descriptor (when pixel clock = 0)
pub const DisplayDescriptor = struct {
    tag: DisplayDescriptorTag,
    data: [13]u8, // Bytes 5-17 contain descriptor-specific data
};

/// Parse display descriptor from 18-byte block
pub fn parseDisplayDescriptor(bytes: *align(1) const [18]u8) ?DisplayDescriptor {
    // First 2 bytes must be 0 for display descriptor
    if (bytes[0] != 0 or bytes[1] != 0) {
        return null;
    }
    
    // Byte 2 must be 0 (reserved)
    if (bytes[2] != 0) {
        return null;
    }
    
    // Byte 3 is the descriptor tag
    const tag: DisplayDescriptorTag = @enumFromInt(bytes[3]);
    
    // Byte 4 must be 0 (reserved)
    if (bytes[4] != 0) {
        return null;
    }
    
    // Bytes 5-17 are descriptor data (13 bytes)
    var data: [13]u8 = undefined;
    @memcpy(&data, bytes[5..18]);
    
    return DisplayDescriptor{
        .tag = tag,
        .data = data,
    };
}

/// Extract ASCII string from display descriptor data
/// Returns slice into the data, trimmed of trailing spaces
pub fn extractDescriptorString(data: []const u8) []const u8 {
    var end = data.len;
    
    // Trim trailing spaces and newlines
    while (end > 0) {
        const c = data[end - 1];
        if (c != ' ' and c != '\n' and c != 0) {
            break;
        }
        end -= 1;
    }
    
    return data[0..end];
}

/// Parse detailed timing descriptor from raw bytes
pub fn parseDetailedTiming(raw: *align(1) const DetailedRaw) ?Detailed {
    // Check if this is actually a detailed timing (pixel clock != 0)
    if (raw.pixel_clock_10khz == 0) {
        return null; // This is a display descriptor, not a timing
    }
    
    var timing: Detailed = undefined;
    
    timing.pixel_clock_hz = raw.getPixelClockHz();
    timing.h_active = raw.getHActive();
    timing.h_blank = raw.getHBlank();
    timing.h_front_porch = raw.getHFrontPorch();
    timing.h_sync_pulse = raw.getHSyncPulse();
    timing.v_active = raw.getVActive();
    timing.v_blank = raw.getVBlank();
    timing.v_front_porch = raw.getVFrontPorch();
    timing.v_sync_pulse = raw.getVSyncPulse();
    timing.h_image_mm = raw.getHImageMm();
    timing.v_image_mm = raw.getVImageMm();
    timing.h_border = raw.h_border;
    timing.v_border = raw.v_border;
    timing.interlaced = raw.isInterlaced();
    timing.stereo = raw.getStereoMode();
    
    // Parse sync info based on signal type
    const signal_type = raw.getSignalType();
    timing.sync_info = switch (signal_type) {
        .analog_composite => SyncInfo{
            .analog_composite = @bitCast(@as(u8, (raw.flags >> 1) & 0x03)),
        },
        .bipolar_analog_composite => SyncInfo{
            .bipolar_analog_composite = @bitCast(@as(u8, (raw.flags >> 1) & 0x03)),
        },
        .digital_composite => SyncInfo{ .digital_composite = {} },
        .digital_separate => SyncInfo{
            .digital_separate = raw.getDigitalSeparateSync().?,
        },
    };
    
    return timing;
}

// Tests

test "DetailedRaw size" {
    try testing.expectEqual(@as(usize, 18), @sizeOf(DetailedRaw));
}

test "parse 1920x1080 @ 60Hz timing" {
    // Example: 1920x1080 @ 60Hz (148.5 MHz pixel clock)
    var raw: DetailedRaw = undefined;
    
    // Pixel clock: 148.5 MHz = 14850 in 10kHz units
    raw.pixel_clock_10khz = 14850;
    
    // 1920 pixels active (0x780)
    raw.h_active_lo = 0x80; // Low 8 bits
    // 280 pixels blank (0x118)
    raw.h_blank_lo = 0x18; // Low 8 bits
    // h_hi: upper nibble = 1920 >> 8 = 0x7, lower nibble = 280 >> 8 = 0x1
    raw.h_hi = 0x71;
    
    // 1080 lines active (0x438)
    raw.v_active_lo = 0x38; // Low 8 bits
    // 45 lines blank (0x02D)
    raw.v_blank_lo = 0x2D; // Low 8 bits
    // v_hi: upper nibble = 1080 >> 8 = 0x4, lower nibble = 45 >> 8 = 0x0
    raw.v_hi = 0x40;
    
    // Front porch and sync
    raw.h_front_porch_lo = 88;
    raw.h_sync_pulse_lo = 44;
    raw.v_front_sync_lo = (4 << 4) | 5; // Front porch 4, sync 5
    raw.front_sync_hi = 0;
    
    // Image size: 520mm x 290mm
    raw.h_image_mm_lo = 0x08;
    raw.v_image_mm_lo = 0x22;
    raw.image_size_hi = 0x21;
    
    // No borders
    raw.h_border = 0;
    raw.v_border = 0;
    
    // Flags: not interlaced, digital separate, positive sync both
    raw.flags = 0b00011110; // Digital separate (bits 4-3), h+ v+ (bits 2-1)
    
    const timing = parseDetailedTiming(&raw).?;
    
    try testing.expectEqual(@as(u64, 148_500_000), timing.pixel_clock_hz);
    try testing.expectEqual(@as(u16, 1920), timing.h_active);
    try testing.expectEqual(@as(u16, 280), timing.h_blank);
    try testing.expectEqual(@as(u16, 1080), timing.v_active);
    try testing.expectEqual(@as(u16, 45), timing.v_blank);
    try testing.expect(!timing.interlaced);
    try testing.expectEqual(StereoMode.none, timing.stereo);
    
    // Check calculated values
    try testing.expectEqual(@as(u16, 2200), timing.getHTotal()); // 1920 + 280
    try testing.expectEqual(@as(u16, 1125), timing.getVTotal()); // 1080 + 45
    
    const refresh = timing.getRefreshRate();
    try testing.expect(refresh > 59.9 and refresh < 60.1); // ~60 Hz
}

test "parse returns null for display descriptor" {
    var raw: DetailedRaw = undefined;
    @memset(std.mem.asBytes(&raw), 0);
    
    // Pixel clock = 0 means this is a display descriptor, not timing
    raw.pixel_clock_10khz = 0;
    
    const timing = parseDetailedTiming(&raw);
    try testing.expect(timing == null);
}

test "detailed timing field extraction" {
    var raw: DetailedRaw = undefined;
    
    // Test split field encoding
    // Want h_active = 0xACD, h_blank = 0xBCD
    // h_active_lo = 0xCD (low 8 bits)
    // h_hi = (0xA << 4) | 0xB = 0xAB (h_active high 4 bits in upper nibble, h_blank high 4 bits in lower)
    raw.h_active_lo = 0xCD;
    raw.h_blank_lo = 0xCD;
    raw.h_hi = 0xAB; 
    
    const h_active = raw.getHActive();
    try testing.expectEqual(@as(u16, 0xACD), h_active); // (0xA << 8) | 0xCD
    
    const h_blank = raw.getHBlank();
    try testing.expectEqual(@as(u16, 0xBCD), h_blank); // (0xB << 8) | 0xCD
}

test "standard timing 1920x1080 @ 60Hz" {
    // 1920x1080 @ 60Hz, 16:9
    // H res: 1920 / 8 - 31 = 240 - 31 = 209 (0xD1)
    // Refresh: 60 - 60 = 0
    // Aspect: 16:9 = 3
    const bytes = [2]u8{ 0xD1, 0xC0 }; // 0xC0 = 11 000000 (aspect 3, refresh 0)
    
    const std_timing = parseStandardTiming(&bytes).?;
    
    try testing.expectEqual(@as(u16, 1920), std_timing.h_active);
    try testing.expectEqual(@as(u16, 1080), std_timing.v_active);
    try testing.expectEqual(@as(u8, 60), std_timing.refresh_rate_hz);
    try testing.expectEqual(StandardAspectRatio.ratio_16_9, std_timing.aspect_ratio);
}

test "standard timing unused slot" {
    const bytes = [2]u8{ 0x01, 0x01 };
    const std_timing = parseStandardTiming(&bytes);
    try testing.expect(std_timing == null);
}

test "standard timing different aspect ratios" {
    // 1280x1024 @ 75Hz, 5:4
    // H res: 1280 / 8 - 31 = 160 - 31 = 129 (0x81)
    // Refresh: 75 - 60 = 15 (0x0F)
    // Aspect: 5:4 = 2
    const bytes = [2]u8{ 0x81, 0x8F }; // 0x8F = 10 001111 (aspect 2, refresh 15)
    
    const std_timing = parseStandardTiming(&bytes).?;
    
    try testing.expectEqual(@as(u16, 1280), std_timing.h_active);
    try testing.expectEqual(@as(u16, 1024), std_timing.v_active);
    try testing.expectEqual(@as(u8, 75), std_timing.refresh_rate_hz);
    try testing.expectEqual(StandardAspectRatio.ratio_5_4, std_timing.aspect_ratio);
}

test "established timings parsing" {
    // Set some bits to test parsing
    const bytes = [3]u8{
        0b10100000, // 720x400@70Hz, 640x480@60Hz
        0b00001100, // 1024x768@60Hz, 1024x768@70Hz  
        0b10000000, // 1152x870@75Hz
    };
    
    const timings = parseEstablishedTimings(&bytes);
    
    // Byte 0
    try testing.expect(timings.has_720x400_70hz);
    try testing.expect(!timings.has_720x400_88hz);
    try testing.expect(timings.has_640x480_60hz);
    try testing.expect(!timings.has_640x480_67hz);
    
    // Byte 1
    try testing.expect(!timings.has_800x600_72hz);
    try testing.expect(timings.has_1024x768_60hz);
    try testing.expect(timings.has_1024x768_70hz);
    try testing.expect(!timings.has_1024x768_75hz);
    
    // Byte 2
    try testing.expect(timings.has_1152x870_75hz);
}

test "display descriptor product name" {
    // Build 18-byte descriptor
    var bytes: [18]u8 = undefined;
    bytes[0] = 0;
    bytes[1] = 0;
    bytes[2] = 0;
    bytes[3] = 0xFC; // Product name tag
    bytes[4] = 0;
    // 13 bytes of name data (bytes 5-17)
    const name_data = "Test Monitor ";
    @memcpy(bytes[5..18], name_data);
    
    const desc = parseDisplayDescriptor(&bytes).?;
    
    try testing.expectEqual(DisplayDescriptorTag.product_name, desc.tag);
    
    const name = extractDescriptorString(&desc.data);
    try testing.expectEqualStrings("Test Monitor", name);
}

test "display descriptor serial number" {
    var bytes: [18]u8 = undefined;
    bytes[0] = 0;
    bytes[1] = 0;
    bytes[2] = 0;
    bytes[3] = 0xFF; // Serial number tag
    bytes[4] = 0;
    const serial_data = "ABC1234567890";
    @memcpy(bytes[5..18], serial_data);
    
    const desc = parseDisplayDescriptor(&bytes).?;
    try testing.expectEqual(DisplayDescriptorTag.product_serial, desc.tag);
    
    const serial = extractDescriptorString(&desc.data);
    try testing.expectEqualStrings("ABC1234567890", serial);
}

test "display descriptor returns null for timing" {
    var bytes: [18]u8 = undefined;
    bytes[0] = 0x01; // Non-zero pixel clock = timing descriptor
    bytes[1] = 0x00;
    
    const desc = parseDisplayDescriptor(&bytes);
    try testing.expect(desc == null);
}
