//! Protocol message builder and parser

const std = @import("std");
const protocol = @import("protocol.zig");
const Type = protocol.Type;
const VarInt = protocol.VarInt;
const ProtocolSpec = protocol.ProtocolSpec;

// Note: RawParsedMessage is now in socket.zig for compatibility

/// Magic bytes for type identification in wire format
pub const Magic = enum(u8) {
    type_uint = 0x01,
    type_int = 0x02,
    type_f32 = 0x03,
    type_seq = 0x04,
    type_object_id = 0x05,
    type_varchar = 0x06,
    type_array = 0x07,
    type_object = 0x08,
    end = 0xFF,

    pub fn toString(self: Magic) []const u8 {
        return switch (self) {
            .type_uint => "UINT",
            .type_int => "INT",
            .type_f32 => "F32",
            .type_seq => "SEQUENCE",
            .type_object_id => "OBJECT_ID",
            .type_varchar => "VARCHAR",
            .type_array => "ARRAY",
            .type_object => "OBJECT",
            .end => "END",
        };
    }
};

/// Message builder for constructing protocol messages
pub const Builder = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, msg_type: Type) !Builder {
        var builder = Builder{
            .data = std.ArrayList(u8){},
            .allocator = allocator,
        };
        try builder.data.append(allocator, @intFromEnum(msg_type));
        return builder;
    }

    pub fn deinit(self: *Builder) void {
        self.data.deinit(self.allocator);
    }

    /// Add a uint32 to the message (with magic byte)
    pub fn addUint32(self: *Builder, value: u32) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_uint));
        const bytes = std.mem.toBytes(value);
        try self.data.appendSlice(self.allocator, &bytes);
    }

    /// Add an int32 to the message (with magic byte)
    pub fn addInt32(self: *Builder, value: i32) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_int));
        const bytes = std.mem.toBytes(value);
        try self.data.appendSlice(self.allocator, &bytes);
    }

    /// Add a float32 to the message (with magic byte)
    pub fn addF32(self: *Builder, value: f32) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_f32));
        const bytes = std.mem.toBytes(value);
        try self.data.appendSlice(self.allocator, &bytes);
    }

    /// Add a sequence number to the message (with magic byte)
    pub fn addSequence(self: *Builder, value: u32) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_seq));
        const bytes = std.mem.toBytes(value);
        try self.data.appendSlice(self.allocator, &bytes);
    }

    /// Add an object ID to the message (with magic byte)
    pub fn addObjectId(self: *Builder, value: u32) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_object_id));
        const bytes = std.mem.toBytes(value);
        try self.data.appendSlice(self.allocator, &bytes);
    }

    /// Add a string to the message (with magic byte and length-prefix)
    pub fn addString(self: *Builder, str: []const u8) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_varchar));
        const len_encoded = try VarInt.encode(self.allocator, str.len);
        defer self.allocator.free(len_encoded);

        try self.data.appendSlice(self.allocator, len_encoded);
        try self.data.appendSlice(self.allocator, str);
    }

    /// Add an array of uint32s (with magic byte)
    pub fn addUint32Array(self: *Builder, values: []const u32) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_array));
        const len_encoded = try VarInt.encode(self.allocator, values.len);
        defer self.allocator.free(len_encoded);

        try self.data.appendSlice(self.allocator, len_encoded);
        for (values) |val| {
            const bytes = std.mem.toBytes(val);
            try self.data.appendSlice(self.allocator, &bytes);
        }
    }

    /// Add an array of strings (with magic byte)
    pub fn addStringArray(self: *Builder, strings: []const []const u8) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.type_array));
        const len_encoded = try VarInt.encode(self.allocator, strings.len);
        defer self.allocator.free(len_encoded);

        try self.data.appendSlice(self.allocator, len_encoded);
        for (strings) |str| {
            // Each string gets its own varchar marker
            const str_len_encoded = try VarInt.encode(self.allocator, str.len);
            defer self.allocator.free(str_len_encoded);
            try self.data.appendSlice(self.allocator, str_len_encoded);
            try self.data.appendSlice(self.allocator, str);
        }
    }

    /// Add raw bytes (no magic)
    pub fn addBytes(self: *Builder, bytes: []const u8) !void {
        try self.data.appendSlice(self.allocator, bytes);
    }

    /// Finalize message with END magic byte
    pub fn finalize(self: *Builder) !void {
        try self.data.append(self.allocator, @intFromEnum(Magic.end));
    }

    /// Finalize and get message bytes (transfers ownership)
    pub fn finish(self: *Builder) ![]u8 {
        try self.finalize();
        return self.data.toOwnedSlice(self.allocator);
    }
};

/// Message parser for reading protocol messages
pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    /// Parse message type from raw data
    pub fn parseType(data: []const u8) !Type {
        if (data.len == 0) return error.BufferTooSmall;
        return @enumFromInt(data[0]);
    }

    /// Parse uint32 from data at offset (expects magic byte)
    pub fn parseUint32(data: []const u8, offset: *usize) !u32 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_uint)) return error.InvalidMagicByte;
        offset.* += 1;

        if (offset.* + 4 > data.len) return error.BufferTooSmall;
        const value = std.mem.bytesToValue(u32, data[offset.*..][0..4]);
        offset.* += 4;
        return value;
    }

    /// Parse int32 from data at offset (expects magic byte)
    pub fn parseInt32(data: []const u8, offset: *usize) !i32 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_int)) return error.InvalidMagicByte;
        offset.* += 1;

        if (offset.* + 4 > data.len) return error.BufferTooSmall;
        const value = std.mem.bytesToValue(i32, data[offset.*..][0..4]);
        offset.* += 4;
        return value;
    }

    /// Parse float32 from data at offset (expects magic byte)
    pub fn parseF32(data: []const u8, offset: *usize) !f32 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_f32)) return error.InvalidMagicByte;
        offset.* += 1;

        if (offset.* + 4 > data.len) return error.BufferTooSmall;
        const value = std.mem.bytesToValue(f32, data[offset.*..][0..4]);
        offset.* += 4;
        return value;
    }

    /// Parse sequence number from data at offset (expects magic byte)
    pub fn parseSequence(data: []const u8, offset: *usize) !u32 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_seq)) return error.InvalidMagicByte;
        offset.* += 1;

        if (offset.* + 4 > data.len) return error.BufferTooSmall;
        const value = std.mem.bytesToValue(u32, data[offset.*..][0..4]);
        offset.* += 4;
        return value;
    }

    /// Parse object ID from data at offset (expects magic byte)
    pub fn parseObjectId(data: []const u8, offset: *usize) !u32 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_object_id)) return error.InvalidMagicByte;
        offset.* += 1;

        if (offset.* + 4 > data.len) return error.BufferTooSmall;
        const value = std.mem.bytesToValue(u32, data[offset.*..][0..4]);
        offset.* += 4;
        return value;
    }

    /// Parse string from data at offset (expects magic byte)
    pub fn parseString(data: []const u8, offset: *usize) ![]const u8 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_varchar)) return error.InvalidMagicByte;
        offset.* += 1;

        const len_result = try VarInt.decode(data[offset.*..]);
        offset.* += len_result.consumed;

        if (offset.* + len_result.value > data.len) return error.BufferTooSmall;
        const str = data[offset.* .. offset.* + len_result.value];
        offset.* += len_result.value;

        return str;
    }

    /// Validate and consume END magic byte
    pub fn parseEnd(data: []const u8, offset: *usize) !void {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.end)) return error.MissingEndMagic;
        offset.* += 1;
    }

    /// Parse array of uint32s (expects magic byte)
    pub fn parseUint32Array(self: *Parser, data: []const u8, offset: *usize) ![]u32 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_array)) return error.InvalidMagicByte;
        offset.* += 1;

        const count_result = try VarInt.decode(data[offset.*..]);
        offset.* += count_result.consumed;

        var array = try self.allocator.alloc(u32, count_result.value);
        errdefer self.allocator.free(array);

        for (0..count_result.value) |i| {
            // Array elements don't have magic bytes, just raw u32s
            if (offset.* + 4 > data.len) return error.BufferTooSmall;
            array[i] = std.mem.bytesToValue(u32, data[offset.*..][0..4]);
            offset.* += 4;
        }

        return array;
    }

    /// Parse array of strings (expects magic byte, allocates)
    pub fn parseStringArray(self: *Parser, data: []const u8, offset: *usize) ![][]const u8 {
        if (offset.* >= data.len) return error.BufferTooSmall;
        const magic = data[offset.*];
        if (magic != @intFromEnum(Magic.type_array)) return error.InvalidMagicByte;
        offset.* += 1;

        const count_result = try VarInt.decode(data[offset.*..]);
        offset.* += count_result.consumed;

        var array = try self.allocator.alloc([]const u8, count_result.value);
        errdefer self.allocator.free(array);

        for (0..count_result.value) |i| {
            // Each string in array is length-prefixed (no magic within array)
            const str_len_result = try VarInt.decode(data[offset.*..]);
            offset.* += str_len_result.consumed;

            if (offset.* + str_len_result.value > data.len) return error.BufferTooSmall;
            array[i] = data[offset.* .. offset.* + str_len_result.value];
            offset.* += str_len_result.value;
        }

        return array;
    }
};

// Specific message builders

/// Build SUP message ("VAX" handshake initiation)
pub fn buildSupMessage(allocator: std.mem.Allocator) ![]u8 {
    var builder = try Builder.init(allocator, .sup);
    defer builder.deinit();

    try builder.addString("VAX");
    return try builder.finish();
}

/// Build HANDSHAKE_BEGIN message
pub fn buildHandshakeBegin(allocator: std.mem.Allocator, versions: []const u32) ![]u8 {
    var builder = try Builder.init(allocator, .handshake_begin);
    defer builder.deinit();

    try builder.addUint32Array(versions);
    return try builder.finish();
}

/// Build HANDSHAKE_ACK message
pub fn buildHandshakeAck(allocator: std.mem.Allocator, version: u32) ![]u8 {
    var builder = try Builder.init(allocator, .handshake_ack);
    defer builder.deinit();

    try builder.addUint32(version);
    return try builder.finish();
}

/// Build HANDSHAKE_PROTOCOLS message
pub fn buildHandshakeProtocols(allocator: std.mem.Allocator, protocols: []const []const u8) ![]u8 {
    var builder = try Builder.init(allocator, .handshake_protocols);
    defer builder.deinit();

    try builder.addStringArray(protocols);
    return try builder.finish();
}

/// Build BIND_PROTOCOL message
pub fn buildBindProtocol(allocator: std.mem.Allocator, seq: u32, protocol_spec: []const u8) ![]u8 {
    var builder = try Builder.init(allocator, .bind_protocol);
    defer builder.deinit();

    try builder.addUint32(seq);
    try builder.addString(protocol_spec);
    return try builder.finish();
}

/// Build NEW_OBJECT message
pub fn buildNewObject(allocator: std.mem.Allocator, object_id: u32, seq: u32) ![]u8 {
    var builder = try Builder.init(allocator, .new_object);
    defer builder.deinit();

    try builder.addUint32(object_id);
    try builder.addUint32(seq);
    return try builder.finish();
}

/// Build ROUNDTRIP_REQUEST message
pub fn buildRoundtripRequest(allocator: std.mem.Allocator, seq: u32) ![]u8 {
    var builder = try Builder.init(allocator, .roundtrip_request);
    defer builder.deinit();

    try builder.addUint32(seq);
    return try builder.finish();
}

/// Build ROUNDTRIP_DONE message
pub fn buildRoundtripDone(allocator: std.mem.Allocator, seq: u32) ![]u8 {
    var builder = try Builder.init(allocator, .roundtrip_done);
    defer builder.deinit();

    try builder.addUint32(seq);
    return try builder.finish();
}

/// Build GENERIC_PROTOCOL_MESSAGE
pub fn buildGenericProtocolMessage(allocator: std.mem.Allocator, object_id: u32, method_id: u32, data: []const u8) ![]u8 {
    var builder = try Builder.init(allocator, .generic_protocol_message);
    defer builder.deinit();

    try builder.addObjectId(object_id);
    try builder.addUint32(method_id);

    if (data.len > 0) {
        try builder.addBytes(data);
    }

    return try builder.finish();
}

/// Parse GENERIC_PROTOCOL_MESSAGE
pub fn parseGenericProtocolMessage(data: []const u8) !struct { object_id: u32, method_id: u32, payload: []const u8 } {
    if (data.len == 0) return error.BufferTooSmall;
    if (data[0] != @intFromEnum(Type.generic_protocol_message)) return error.InvalidType;

    var offset: usize = 1;
    const object_id = try Parser.parseObjectId(data, &offset);
    const method_id = try Parser.parseUint32(data, &offset);

    // Remaining data (before END magic) is the payload
    const payload_start = offset;

    // Find END magic
    var payload_end = offset;
    while (payload_end < data.len and data[payload_end] != @intFromEnum(Magic.end)) {
        payload_end += 1;
    }

    const payload = if (payload_end > payload_start) data[payload_start..payload_end] else &[_]u8{};

    return .{
        .object_id = object_id,
        .method_id = method_id,
        .payload = payload,
    };
}

// Tests
test "Builder - basic uint32 with magic" {
    const testing = std.testing;

    var builder = try Builder.init(testing.allocator, .handshake_ack);
    defer builder.deinit();

    try builder.addUint32(42);
    const msg = try builder.finish();
    defer testing.allocator.free(msg);

    // 1 byte type + 1 byte magic + 4 bytes uint32 + 1 byte end magic = 7
    try testing.expectEqual(@as(usize, 7), msg.len);
    try testing.expectEqual(@as(u8, @intFromEnum(Type.handshake_ack)), msg[0]);
    try testing.expectEqual(@as(u8, @intFromEnum(Magic.type_uint)), msg[1]);
    try testing.expectEqual(@as(u8, @intFromEnum(Magic.end)), msg[msg.len - 1]);
}

test "Builder - string with magic" {
    const testing = std.testing;

    var builder = try Builder.init(testing.allocator, .sup);
    defer builder.deinit();

    try builder.addString("VAX");
    const msg = try builder.finish();
    defer testing.allocator.free(msg);

    try testing.expect(msg.len > 5); // Type + magic + length + "VAX" + end
    try testing.expectEqual(@as(u8, @intFromEnum(Type.sup)), msg[0]);
    try testing.expectEqual(@as(u8, @intFromEnum(Magic.type_varchar)), msg[1]);
    try testing.expectEqual(@as(u8, @intFromEnum(Magic.end)), msg[msg.len - 1]);
}

test "Parser - parseUint32 with magic" {
    const testing = std.testing;

    var builder = try Builder.init(testing.allocator, .handshake_ack);
    defer builder.deinit();
    try builder.addUint32(42);
    const msg = try builder.finish();
    defer testing.allocator.free(msg);

    var offset: usize = 1; // Skip message type
    const value = try Parser.parseUint32(msg, &offset);

    try testing.expectEqual(@as(u32, 42), value);
}

test "buildSupMessage" {
    const testing = std.testing;

    const msg = try buildSupMessage(testing.allocator);
    defer testing.allocator.free(msg);

    const msg_type = try Parser.parseType(msg);
    try testing.expectEqual(Type.sup, msg_type);
}

test "buildHandshakeBegin" {
    const testing = std.testing;

    const versions = [_]u32{ 1, 2, 3 };
    const msg = try buildHandshakeBegin(testing.allocator, &versions);
    defer testing.allocator.free(msg);

    const msg_type = try Parser.parseType(msg);
    try testing.expectEqual(Type.handshake_begin, msg_type);
}

test "Parser - parseString with magic" {
    const testing = std.testing;

    var builder = try Builder.init(testing.allocator, .sup);
    defer builder.deinit();
    try builder.addString("test");
    const msg = try builder.finish();
    defer testing.allocator.free(msg);

    var offset: usize = 1; // Skip message type
    const str = try Parser.parseString(msg, &offset);

    try testing.expectEqualStrings("test", str);
}

test "GenericProtocolMessage - build and parse" {
    const testing = std.testing;

    const payload = "test payload data";
    const msg = try buildGenericProtocolMessage(testing.allocator, 123, 456, payload);
    defer testing.allocator.free(msg);

    try testing.expectEqual(@as(u8, @intFromEnum(Type.generic_protocol_message)), msg[0]);

    const parsed = try parseGenericProtocolMessage(msg);
    try testing.expectEqual(@as(u32, 123), parsed.object_id);
    try testing.expectEqual(@as(u32, 456), parsed.method_id);
    try testing.expectEqualStrings(payload, parsed.payload);
}

test "Builder - int32 with magic" {
    const testing = std.testing;

    var builder = try Builder.init(testing.allocator, .generic_protocol_message);
    defer builder.deinit();

    try builder.addInt32(-42);
    const msg = try builder.finish();
    defer testing.allocator.free(msg);

    var offset: usize = 1;
    const value = try Parser.parseInt32(msg, &offset);
    try testing.expectEqual(@as(i32, -42), value);
}

test "Builder - f32 with magic" {
    const testing = std.testing;

    var builder = try Builder.init(testing.allocator, .generic_protocol_message);
    defer builder.deinit();

    try builder.addF32(3.14159);
    const msg = try builder.finish();
    defer testing.allocator.free(msg);

    var offset: usize = 1;
    const value = try Parser.parseF32(msg, &offset);
    try testing.expectApproxEqAbs(@as(f32, 3.14159), value, 0.00001);
}

test "Builder - sequence and object_id with magic" {
    const testing = std.testing;

    var builder = try Builder.init(testing.allocator, .generic_protocol_message);
    defer builder.deinit();

    try builder.addSequence(100);
    try builder.addObjectId(200);
    const msg = try builder.finish();
    defer testing.allocator.free(msg);

    var offset: usize = 1;
    const seq = try Parser.parseSequence(msg, &offset);
    const obj_id = try Parser.parseObjectId(msg, &offset);

    try testing.expectEqual(@as(u32, 100), seq);
    try testing.expectEqual(@as(u32, 200), obj_id);
}

test "Magic - toString" {
    const testing = std.testing;

    try testing.expectEqualStrings("UINT", Magic.type_uint.toString());
    try testing.expectEqualStrings("VARCHAR", Magic.type_varchar.toString());
    try testing.expectEqualStrings("SEQUENCE", Magic.type_seq.toString());
    try testing.expectEqualStrings("END", Magic.end.toString());
}
