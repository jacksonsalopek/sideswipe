//! DisplayID Product Identification Data Block

const std = @import("std");
const testing = std.testing;

/// Product identification block (v1 and v2)
pub const Id = struct {
    /// Vendor ID (3 characters, same as EDID PNP ID)
    vendor: [3]u8,
    
    /// Product code
    product_code: u16,
    
    /// Serial number
    serial_number: u32,
    
    /// Model year
    model_year: u16,
    
    /// Model number string (if present)
    model_string: ?[]const u8,
    
    /// Parse from data block payload
    pub fn parse(data: []const u8) ?Id {
        // Minimum: 12 bytes
        if (data.len < 12) return null;
        
        // Bytes 0-2: Vendor (3-letter code)
        var vendor: [3]u8 = undefined;
        @memcpy(&vendor, data[0..3]);
        
        // Bytes 3-4: Product code (little-endian)
        const product_code = @as(u16, data[3]) | (@as(u16, data[4]) << 8);
        
        // Bytes 5-8: Serial number (little-endian)
        const serial_number = @as(u32, data[5]) |
            (@as(u32, data[6]) << 8) |
            (@as(u32, data[7]) << 16) |
            (@as(u32, data[8]) << 24);
        
        // Bytes 9: Week of manufacture
        // Bytes 10-11: Model year (little-endian)
        const model_year = @as(u16, data[10]) | (@as(u16, data[11]) << 8);
        
        // Bytes 12+: Model string (null-terminated, optional)
        var model_string: ?[]const u8 = null;
        if (data.len > 12) {
            const string_data = data[12..];
            var end: usize = 0;
            for (string_data) |byte| {
                if (byte == 0) break;
                end += 1;
            }
            if (end > 0) {
                model_string = string_data[0..end];
            }
        }
        
        return Id{
            .vendor = vendor,
            .product_code = product_code,
            .serial_number = serial_number,
            .model_year = model_year,
            .model_string = model_string,
        };
    }
};

// Tests

test "product ID parsing - basic" {
    var data: [12]u8 = undefined;
    
    // Vendor: "DEL"
    data[0] = 'D';
    data[1] = 'e';
    data[2] = 'l';
    
    // Product code: 0x1234
    data[3] = 0x34;
    data[4] = 0x12;
    
    // Serial: 0x12345678
    data[5] = 0x78;
    data[6] = 0x56;
    data[7] = 0x34;
    data[8] = 0x12;
    
    // Week
    data[9] = 15;
    
    // Year: 2023
    data[10] = 0xE7;
    data[11] = 0x07;
    
    const product = Id.parse(&data).?;
    
    try testing.expectEqualStrings("Del", &product.vendor);
    try testing.expectEqual(@as(u16, 0x1234), product.product_code);
    try testing.expectEqual(@as(u32, 0x12345678), product.serial_number);
    try testing.expectEqual(@as(u16, 2023), product.model_year);
    try testing.expect(product.model_string == null);
}

test "product ID parsing - with model string" {
    var data: [20]u8 = undefined;
    @memcpy(data[0..3], "SAM");
    data[3] = 0;
    data[4] = 0;
    @memset(data[5..12], 0);
    @memcpy(data[12..], "U28E590\x00");
    
    const product = Id.parse(&data).?;
    
    try testing.expectEqualStrings("SAM", &product.vendor);
    try testing.expectEqualStrings("U28E590", product.model_string.?);
}
