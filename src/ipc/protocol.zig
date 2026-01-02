//! Protocol implementation

const std = @import("std");

/// Current protocol version
pub const PROTOCOL_VERSION: u32 = 1;

/// Message types for protocol
pub const Type = enum(u8) {
    invalid = 0,

    /// Sent by client to initiate handshake (params: str -> "VAX")
    sup = 1,

    /// Sent by server after SUP (params: arr(uint) -> versions supported)
    handshake_begin = 2,

    /// Sent by client to confirm protocol version (params: uint -> version chosen)
    handshake_ack = 3,

    /// Sent by server to advertise supported protocols (params: arr(str) -> protocols)
    handshake_protocols = 4,

    /// Sent by client to bind to protocol spec (params: uint -> seq, str -> protocol spec)
    bind_protocol = 10,

    /// Sent by server to acknowledge bind (params: uint -> object handle ID, uint -> seq)
    new_object = 11,

    /// Sent by server for fatal protocol error (params: uint -> object ID, uint -> error idx, varchar -> error msg)
    fatal_protocol_error = 12,

    /// Sent by client to initiate roundtrip (params: uint -> sequence)
    roundtrip_request = 13,

    /// Sent by server to finalize roundtrip (params: uint -> sequence)
    roundtrip_done = 14,

    /// Generic protocol message, bidirectional (params: uint -> object ID, uint -> method ID, data...)
    generic_protocol_message = 100,

    pub fn toString(self: Type) []const u8 {
        return switch (self) {
            .invalid => "INVALID",
            .sup => "SUP",
            .handshake_begin => "HANDSHAKE_BEGIN",
            .handshake_ack => "HANDSHAKE_ACK",
            .handshake_protocols => "HANDSHAKE_PROTOCOLS",
            .bind_protocol => "BIND_PROTOCOL",
            .new_object => "NEW_OBJECT",
            .fatal_protocol_error => "FATAL_PROTOCOL_ERROR",
            .roundtrip_request => "ROUNDTRIP_REQUEST",
            .roundtrip_done => "ROUNDTRIP_DONE",
            .generic_protocol_message => "GENERIC_PROTOCOL_MESSAGE",
        };
    }
};

/// VarInt encoding/decoding utilities
pub const VarInt = struct {
    /// Encode a size_t as varint
    pub fn encode(allocator: std.mem.Allocator, num: usize) ![]u8 {
        var data = try allocator.alloc(u8, 4);
        data[0] = @as(u8, @truncate((num << 25) >> 25)) | 0x80;
        data[1] = @as(u8, @truncate((num << 18) >> 25)) | 0x80;
        data[2] = @as(u8, @truncate((num << 11) >> 25)) | 0x80;
        data[3] = @as(u8, @truncate((num << 4) >> 25)) | 0x80;

        // Trim trailing 0x80 bytes
        var len: usize = 4;
        while (len > 1 and data[len - 1] == 0x80) {
            len -= 1;
        }
        data = try allocator.realloc(data, len);
        data[len - 1] &= ~@as(u8, 0x80);

        return data;
    }

    /// Decode varint from buffer, returns (value, bytes_consumed)
    pub fn decode(data: []const u8) !struct { value: usize, consumed: usize } {
        var rolling: usize = 0;
        var i: usize = 0;
        const len = data.len;

        if (len == 0) return error.BufferTooSmall;

        while (i < len) : (i += 1) {
            const byte = data[i];
            rolling += (@as(usize, byte & 0x7F) << @intCast(i * 7));

            if ((byte & 0x80) == 0) {
                return .{ .value = rolling, .consumed = i + 1 };
            }
        }

        return error.IncompleteVarInt;
    }
};

/// Protocol specification identifier
pub const ProtocolSpec = struct {
    name: []const u8,
    version: u32,

    pub fn format(self: ProtocolSpec, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s}@{d}", .{ self.name, self.version });
    }

    pub fn parse(spec_str: []const u8) !ProtocolSpec {
        const at_pos = std.mem.indexOf(u8, spec_str, "@") orelse return error.InvalidProtocolSpec;
        const name = spec_str[0..at_pos];
        const version_str = spec_str[at_pos + 1 ..];
        const version = try std.fmt.parseInt(u32, version_str, 10);

        return .{
            .name = name,
            .version = version,
        };
    }
};

// Tests
test "VarInt - encode and decode" {
    const testing = std.testing;

    // Test small number
    const encoded = try VarInt.encode(testing.allocator, 42);
    defer testing.allocator.free(encoded);

    const decoded = try VarInt.decode(encoded);
    try testing.expectEqual(@as(usize, 42), decoded.value);
    try testing.expectEqual(encoded.len, decoded.consumed);
}

test "VarInt - encode large number" {
    const testing = std.testing;

    const encoded = try VarInt.encode(testing.allocator, 16384);
    defer testing.allocator.free(encoded);

    const decoded = try VarInt.decode(encoded);
    try testing.expectEqual(@as(usize, 16384), decoded.value);
}

test "VarInt - decode incomplete" {
    const testing = std.testing;

    const incomplete = [_]u8{0x80}; // Has continuation bit but no more bytes
    const result = VarInt.decode(&incomplete);
    try testing.expectError(error.IncompleteVarInt, result);
}

test "VarInt - decode empty buffer" {
    const testing = std.testing;

    const empty: []const u8 = &[_]u8{};
    const result = VarInt.decode(empty);
    try testing.expectError(error.BufferTooSmall, result);
}

test "Type - toString" {
    const testing = std.testing;

    try testing.expectEqualStrings("SUP", Type.sup.toString());
    try testing.expectEqualStrings("HANDSHAKE_BEGIN", Type.handshake_begin.toString());
    try testing.expectEqualStrings("GENERIC_PROTOCOL_MESSAGE", Type.generic_protocol_message.toString());
}

test "ProtocolSpec - format and parse" {
    const testing = std.testing;

    const spec = ProtocolSpec{
        .name = "hyprland_compositor",
        .version = 1,
    };

    const formatted = try spec.format(testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("hyprland_compositor@1", formatted);

    const parsed = try ProtocolSpec.parse(formatted);
    try testing.expectEqualStrings(spec.name, parsed.name);
    try testing.expectEqual(spec.version, parsed.version);
}

test "ProtocolSpec - parse invalid" {
    const testing = std.testing;

    const invalid = "no_version_separator";
    const result = ProtocolSpec.parse(invalid);
    try testing.expectError(error.InvalidProtocolSpec, result);
}

test "VarInt - roundtrip various values" {
    const testing = std.testing;

    const values = [_]usize{ 0, 1, 127, 128, 255, 256, 16383, 16384, 65535 };

    for (values) |val| {
        const encoded = try VarInt.encode(testing.allocator, val);
        defer testing.allocator.free(encoded);

        const decoded = try VarInt.decode(encoded);
        try testing.expectEqual(val, decoded.value);
    }
}
