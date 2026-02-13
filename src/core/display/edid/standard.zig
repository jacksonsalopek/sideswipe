//! EDID (Extended Display Identification Data) parser
//!
//! This module implements parsing for EDID as defined in:
//! - VESA Enhanced Extended Display Identification Data (E-EDID) Standard
//!   Release A, Revision 2 (September 25, 2006)
//!   Defines EDID Structure Version 1, Revision 4

const std = @import("std");
const testing = std.testing;

/// Fixed EDID header, defined in section 3.1
const edid_header = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };

/// The size of an EDID block, defined in section 2.2
pub const block_size = 128;

/// EDID parsing errors
pub const Error = error{
    /// EDID data is too small to be valid
    TooSmall,
    /// EDID header does not match expected pattern
    InvalidHeader,
    /// EDID checksum validation failed
    InvalidChecksum,
    /// EDID version is not supported
    UnsupportedVersion,
    /// Memory allocation failed
    OutOfMemory,
};

/// EDID vendor & product identification
pub const VendorProduct = struct {
    /// Three-character manufacturer ID (PnP ID)
    manufacturer: [3]u8,
    /// Product code
    product: u16,
    /// Serial number (0 if unset)
    serial: u32,
    /// Week of manufacture (0 if unset, 1-54 for weeks, 255 for model year)
    manufacture_week: u8,
    /// Year of manufacture (0 if unset)
    manufacture_year: u16,
    /// Model year (0 if unset)
    model_year: u16,
};

/// EDID analog signal level standard
pub const AnalogSignalLevel = enum(u2) {
    /// 0.700 : 0.300 : 1.000 V p-p
    level_0 = 0x00,
    /// 0.714 : 0.286 : 1.000 V p-p
    level_1 = 0x01,
    /// 1.000 : 0.400 : 1.400 V p-p
    level_2 = 0x02,
    /// 0.700 : 0.000 : 0.700 V p-p
    level_3 = 0x03,
};

/// EDID analog video setup
pub const AnalogVideoSetup = enum(u1) {
    /// Blank level equals black level
    blank_level_eq_black = 0,
    /// Blank-to-black setup or pedestal
    blank_to_black_setup = 1,
};

/// EDID analog video input information
pub const VideoInputAnalog = struct {
    signal_level: AnalogSignalLevel,
    video_setup: AnalogVideoSetup,
    separate_sync_h_and_v: bool,
    composite_sync_on_h: bool,
    composite_sync_on_green: bool,
    serrations_on_vsync: bool,
};

/// EDID digital color bit depth
pub const DigitalColorDepth = enum(u3) {
    undefined = 0,
    depth_6 = 1,
    depth_8 = 2,
    depth_10 = 3,
    depth_12 = 4,
    depth_14 = 5,
    depth_16 = 6,
    reserved = 7,
};

/// EDID digital interface type
pub const DigitalInterface = enum(u4) {
    undefined = 0,
    dvi = 1,
    hdmi_a = 2,
    hdmi_b = 3,
    mddi = 4,
    displayport = 5,
    _,
};

/// EDID digital video input information
pub const VideoInputDigital = struct {
    color_depth: DigitalColorDepth,
    interface_type: DigitalInterface,
};

/// EDID video input type
pub const VideoInput = union(enum) {
    analog: VideoInputAnalog,
    digital: VideoInputDigital,
};

/// Main EDID data structure
pub const Edid = struct {
    /// EDID version (typically 1)
    version: u8,
    /// EDID revision (typically 3 or 4)
    revision: u8,
    /// Vendor and product identification
    vendor_product: VendorProduct,
    /// Video input definition
    video_input: VideoInput,
    /// Screen size in centimeters (0 if unset)
    screen_width_cm: u8,
    screen_height_cm: u8,
    /// Display gamma (actual value = (gamma_times_100 + 100) / 100.0)
    /// Value of 0xFF means gamma is defined in an extension block
    gamma_times_100: u8,
    /// Raw EDID data (for extension block parsing)
    raw_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Edid) void {
        self.allocator.free(self.raw_data);
    }
};

/// Parse EDID data from a byte slice
///
/// The caller owns the returned EDID structure and must call deinit() when done.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) Error!Edid {
    if (data.len < block_size) {
        return Error.TooSmall;
    }

    // Validate header
    if (!std.mem.eql(u8, data[0..8], &edid_header)) {
        return Error.InvalidHeader;
    }

    // Validate checksum
    if (!validateChecksum(data[0..block_size])) {
        return Error.InvalidChecksum;
    }

    // Parse version and revision
    const version = data[0x12];
    const revision = data[0x13];

    if (version != 1) {
        return Error.UnsupportedVersion;
    }

    // Parse vendor/product identification
    const vendor_product = parseVendorProduct(data);

    // Parse video input definition
    const video_input = parseVideoInput(data[0x14]);

    // Parse screen size
    const screen_width_cm = data[0x15];
    const screen_height_cm = data[0x16];

    // Parse gamma
    const gamma_times_100 = data[0x17];

    // Store a copy of the raw data
    const raw_data = try allocator.dupe(u8, data);

    return Edid{
        .version = version,
        .revision = revision,
        .vendor_product = vendor_product,
        .video_input = video_input,
        .screen_width_cm = screen_width_cm,
        .screen_height_cm = screen_height_cm,
        .gamma_times_100 = gamma_times_100,
        .raw_data = raw_data,
        .allocator = allocator,
    };
}

/// Validate EDID block checksum
fn validateChecksum(data: []const u8) bool {
    std.debug.assert(data.len == block_size);
    var sum: u8 = 0;
    for (data) |byte| {
        sum +%= byte;
    }
    return sum == 0;
}

/// Parse vendor and product identification from EDID data
fn parseVendorProduct(data: []const u8) VendorProduct {
    // Manufacturer ID is encoded in bytes 0x08-0x09
    const id_high = data[0x08];
    const id_low = data[0x09];
    const id = (@as(u16, id_high) << 8) | id_low;

    // Extract three 5-bit values (A-Z encoded as 1-26)
    const char1 = @as(u8, @intCast((id >> 10) & 0x1F));
    const char2 = @as(u8, @intCast((id >> 5) & 0x1F));
    const char3 = @as(u8, @intCast(id & 0x1F));

    var manufacturer: [3]u8 = undefined;
    manufacturer[0] = if (char1 > 0) 'A' + char1 - 1 else 0;
    manufacturer[1] = if (char2 > 0) 'A' + char2 - 1 else 0;
    manufacturer[2] = if (char3 > 0) 'A' + char3 - 1 else 0;

    // Product code (little-endian)
    const product = @as(u16, data[0x0A]) | (@as(u16, data[0x0B]) << 8);

    // Serial number (little-endian)
    const serial = @as(u32, data[0x0C]) |
        (@as(u32, data[0x0D]) << 8) |
        (@as(u32, data[0x0E]) << 16) |
        (@as(u32, data[0x0F]) << 24);

    // Manufacture date
    const manufacture_week = data[0x10];
    const manufacture_year_raw = data[0x11];
    const manufacture_year: u16 = if (manufacture_year_raw > 0) @as(u16, 1990) + manufacture_year_raw else 0;

    // Model year is set if week is 0xFF
    const model_year: u16 = if (manufacture_week == 0xFF) manufacture_year else 0;

    return VendorProduct{
        .manufacturer = manufacturer,
        .product = product,
        .serial = serial,
        .manufacture_week = manufacture_week,
        .manufacture_year = manufacture_year,
        .model_year = model_year,
    };
}

/// Parse video input definition
fn parseVideoInput(byte: u8) VideoInput {
    const is_digital = (byte & 0x80) != 0;

    if (is_digital) {
        const color_depth_raw = @as(u3, @intCast((byte >> 4) & 0x07));
        const interface_raw = @as(u4, @intCast(byte & 0x0F));

        return VideoInput{
            .digital = .{
                .color_depth = @enumFromInt(color_depth_raw),
                .interface_type = @enumFromInt(interface_raw),
            },
        };
    } else {
        const signal_level = @as(u2, @intCast((byte >> 5) & 0x03));
        const video_setup = @as(u1, @intCast((byte >> 4) & 0x01));

        return VideoInput{
            .analog = .{
                .signal_level = @enumFromInt(signal_level),
                .video_setup = @enumFromInt(video_setup),
                .separate_sync_h_and_v = (byte & 0x08) != 0,
                .composite_sync_on_h = (byte & 0x04) != 0,
                .composite_sync_on_green = (byte & 0x02) != 0,
                .serrations_on_vsync = (byte & 0x01) != 0,
            },
        };
    }
}

// Tests

test "validate checksum - valid" {
    // Simple EDID block with valid checksum
    var data = [_]u8{0} ** block_size;
    @memcpy(data[0..8], &edid_header);
    // Calculate checksum
    var sum: u8 = 0;
    for (data[0 .. block_size - 1]) |byte| {
        sum +%= byte;
    }
    data[block_size - 1] = 0 -% sum;

    try testing.expect(validateChecksum(&data));
}

test "validate checksum - invalid" {
    var data = [_]u8{0} ** block_size;
    @memcpy(data[0..8], &edid_header);
    data[block_size - 1] = 0xFF; // Wrong checksum

    try testing.expect(!validateChecksum(&data));
}

test "parse vendor product" {
    var data = [_]u8{0} ** block_size;

    // Set manufacturer ID: "ABC" -> 0x0443 (1,2,3 in 5-bit fields)
    // Bits 15-10: A=1 (00001), Bits 9-5: B=2 (00010), Bits 4-0: C=3 (00011)
    // Binary: 00001 00010 00011 = 0000100010 00011 = 0x0443
    data[0x08] = 0x04;
    data[0x09] = 0x43;

    // Set product code: 0x1234 (little-endian)
    data[0x0A] = 0x34;
    data[0x0B] = 0x12;

    // Set serial: 0x12345678
    data[0x0C] = 0x78;
    data[0x0D] = 0x56;
    data[0x0E] = 0x34;
    data[0x0F] = 0x12;

    // Set manufacture date: week 10, year 2020 (30 years after 1990)
    data[0x10] = 10;
    data[0x11] = 30;

    const vp = parseVendorProduct(&data);

    try testing.expectEqualStrings("ABC", &vp.manufacturer);
    try testing.expectEqual(@as(u16, 0x1234), vp.product);
    try testing.expectEqual(@as(u32, 0x12345678), vp.serial);
    try testing.expectEqual(@as(u8, 10), vp.manufacture_week);
    try testing.expectEqual(@as(u16, 2020), vp.manufacture_year);
    try testing.expectEqual(@as(u16, 0), vp.model_year);
}

test "parse video input - digital" {
    // Digital, 8-bit color depth, HDMI-A interface
    const byte: u8 = 0x80 | (2 << 4) | 2;
    const vi = parseVideoInput(byte);

    try testing.expect(vi == .digital);
    try testing.expectEqual(DigitalColorDepth.depth_8, vi.digital.color_depth);
    try testing.expectEqual(DigitalInterface.hdmi_a, vi.digital.interface_type);
}

test "parse video input - analog" {
    // Analog, level 1, blank-to-black setup, with separate sync
    const byte: u8 = 0x00 | (1 << 5) | (1 << 4) | 0x08;
    const vi = parseVideoInput(byte);

    try testing.expect(vi == .analog);
    try testing.expectEqual(AnalogSignalLevel.level_1, vi.analog.signal_level);
    try testing.expectEqual(AnalogVideoSetup.blank_to_black_setup, vi.analog.video_setup);
    try testing.expect(vi.analog.separate_sync_h_and_v);
    try testing.expect(!vi.analog.composite_sync_on_h);
}

test "parse - minimal valid EDID" {
    var data = [_]u8{0} ** block_size;

    // Header
    @memcpy(data[0..8], &edid_header);

    // Manufacturer ID: "TST"
    data[0x08] = 0xA5; // 10100 10100 10100 -> T, T, T (shifted properly)
    data[0x09] = 0x34; // Actually encodes "TST" properly

    // Product: 0x0001
    data[0x0A] = 0x01;
    data[0x0B] = 0x00;

    // Version 1.4
    data[0x12] = 1;
    data[0x13] = 4;

    // Video input: Digital, 8-bit, DisplayPort
    data[0x14] = 0x80 | (2 << 4) | 5;

    // Screen size: 50cm x 30cm
    data[0x15] = 50;
    data[0x16] = 30;

    // Gamma: 2.20 -> (220 - 100) = 120
    data[0x17] = 120;

    // Calculate checksum
    var sum: u8 = 0;
    for (data[0 .. block_size - 1]) |byte| {
        sum +%= byte;
    }
    data[block_size - 1] = 0 -% sum;

    var edid = try parse(testing.allocator, &data);
    defer edid.deinit();

    try testing.expectEqual(@as(u8, 1), edid.version);
    try testing.expectEqual(@as(u8, 4), edid.revision);
    try testing.expectEqual(@as(u8, 50), edid.screen_width_cm);
    try testing.expectEqual(@as(u8, 30), edid.screen_height_cm);
    try testing.expectEqual(@as(u8, 120), edid.gamma_times_100);
    try testing.expect(edid.video_input == .digital);
}

test "parse - header validation" {
    var data = [_]u8{0xFF} ** block_size;
    try testing.expectError(Error.InvalidHeader, parse(testing.allocator, &data));
}

test "parse - too small" {
    const data = [_]u8{0} ** 64;
    try testing.expectError(Error.TooSmall, parse(testing.allocator, &data));
}
