//! Wire object abstraction for RPC-style method calls

const std = @import("std");
const core = @import("core");
const protocol = @import("protocol.zig");
const message = @import("message.zig");
const Type = protocol.Type;
const Magic = message.Magic;

/// Wire object interface
pub const Wire = struct {
    id: u32,
    protocol_name: []const u8,
    version: u32,
    allocator: std.mem.Allocator,
    listeners: std.ArrayList(?*const anyopaque),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: u32, protocol_name: []const u8, version: u32) Self {
        return .{
            .id = id,
            .protocol_name = protocol_name,
            .version = version,
            .allocator = allocator,
            .listeners = std.ArrayList(?*const anyopaque){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.listeners.deinit(self.allocator);
    }

    /// Register a listener callback for a method ID
    pub fn listen(self: *Self, method_id: u32, callback: *const anyopaque) !void {
        // Ensure listeners array is large enough
        while (self.listeners.items.len <= method_id) {
            try self.listeners.append(self.allocator, null);
        }
        self.listeners.items[method_id] = callback;
    }

    /// Check if a method has a listener
    pub fn hasListener(self: *const Self, method_id: u32) bool {
        if (method_id >= self.listeners.items.len) return false;
        return self.listeners.items[method_id] != null;
    }
};

/// Call builder for encoding RPC calls
pub const Call = struct {
    builder: message.Builder,
    object_id: u32,
    method_id: u32,
    fds: std.ArrayList(std.posix.fd_t),

    pub fn init(allocator: std.mem.Allocator, object_id: u32, method_id: u32) !Call {
        var builder = try message.Builder.init(allocator, .generic_protocol_message);

        // Add object ID
        try builder.addObjectId(object_id);

        // Add method ID
        try builder.addUint32(method_id);

        return .{
            .builder = builder,
            .object_id = object_id,
            .method_id = method_id,
            .fds = std.ArrayList(std.posix.fd_t){},
        };
    }

    pub fn deinit(self: *Call) void {
        self.builder.deinit();
        self.fds.deinit(self.builder.allocator);
    }

    /// Add sequence number (for methods that return values)
    pub fn addSeq(self: *Call, seq: u32) !void {
        try self.builder.addSequence(seq);
    }

    /// Add uint32 parameter
    pub fn addUint(self: *Call, value: u32) !void {
        try self.builder.addUint32(value);
    }

    /// Add int32 parameter
    pub fn addInt(self: *Call, value: i32) !void {
        try self.builder.addInt32(value);
    }

    /// Add float32 parameter
    pub fn addFloat(self: *Call, value: f32) !void {
        try self.builder.addF32(value);
    }

    /// Add string parameter
    pub fn addString(self: *Call, value: []const u8) !void {
        try self.builder.addString(value);
    }

    /// Add file descriptor parameter
    pub fn addFd(self: *Call, fd: std.posix.fd_t) !void {
        // Add FD magic marker
        try self.builder.data.append(self.builder.allocator, @intFromEnum(Magic.type_object)); // Using type_object for FD
        // Store FD to be sent with message
        try self.fds.append(self.builder.allocator, fd);
    }

    /// Add array of uint32s
    pub fn addUintArray(self: *Call, values: []const u32) !void {
        try self.builder.addUint32Array(values);
    }

    /// Add array of strings
    pub fn addStringArray(self: *Call, values: []const []const u8) !void {
        try self.builder.addStringArray(values);
    }

    /// Finish building and get message data
    pub fn finish(self: *Call) !struct { data: []u8, fds: []std.posix.fd_t } {
        const data = try self.builder.finish();
        const fds = try self.fds.toOwnedSlice(self.builder.allocator);
        return .{ .data = data, .fds = fds };
    }
};

/// Call parser for decoding received RPC calls
pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    /// Parse a generic protocol message
    pub fn parse(self: *Parser, data: []const u8) !ParsedCall {
        const parsed = try message.parseGenericProtocolMessage(data);

        return ParsedCall{
            .object_id = parsed.object_id,
            .method_id = parsed.method_id,
            .payload = parsed.payload,
            .allocator = self.allocator,
            .offset = 0,
        };
    }
};

/// Parsed method call with iterative parameter extraction
pub const ParsedCall = struct {
    object_id: u32,
    method_id: u32,
    payload: []const u8,
    allocator: std.mem.Allocator,
    offset: usize,

    /// Parse next uint32 parameter
    pub fn nextUint(self: *ParsedCall) !u32 {
        return try message.Parser.parseUint32(self.payload, &self.offset);
    }

    /// Parse next int32 parameter
    pub fn nextInt(self: *ParsedCall) !i32 {
        return try message.Parser.parseInt32(self.payload, &self.offset);
    }

    /// Parse next float32 parameter
    pub fn nextFloat(self: *ParsedCall) !f32 {
        return try message.Parser.parseF32(self.payload, &self.offset);
    }

    /// Parse next string parameter
    pub fn nextString(self: *ParsedCall) ![]const u8 {
        return try message.Parser.parseString(self.payload, &self.offset);
    }

    /// Parse next sequence number
    pub fn nextSeq(self: *ParsedCall) !u32 {
        return try message.Parser.parseSequence(self.payload, &self.offset);
    }

    /// Parse next object ID
    pub fn nextObjectId(self: *ParsedCall) !u32 {
        return try message.Parser.parseObjectId(self.payload, &self.offset);
    }

    /// Check if we've consumed all parameters (should see END magic)
    pub fn isComplete(self: *const ParsedCall) bool {
        if (self.offset >= self.payload.len) return true;
        return self.payload[self.offset] == @intFromEnum(Magic.end);
    }
};

const testing = core.testing;

// Tests
test "Wire - basic creation" {
    var obj = Wire.init(testing.allocator, 1, "test_protocol", 1);
    defer obj.deinit();

    try testing.expectEqual(@as(u32, 1), obj.id);
    try testing.expectEqualStrings("test_protocol", obj.protocol_name);
    try testing.expectEqual(@as(u32, 1), obj.version);
}

test "Wire - listener registration" {
    var obj = Wire.init(testing.allocator, 1, "test_protocol", 1);
    defer obj.deinit();

    const dummy_callback: *const anyopaque = @ptrCast(&obj);
    try obj.listen(0, dummy_callback);

    try testing.expect(obj.hasListener(0));
    try testing.expectFalse(obj.hasListener(1));
}

test "Call - build simple call" {
    var call = try Call.init(testing.allocator, 100, 5);
    defer call.deinit();

    try call.addUint(42);
    try call.addString("test");

    const result = try call.finish();
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.fds);

    try testing.expectEqual(@as(usize, 0), result.fds.len);
    try testing.expect(result.data.len > 0);
}

test "Call - with file descriptor" {
    var call = try Call.init(testing.allocator, 100, 5);
    defer call.deinit();

    try call.addFd(42);

    const result = try call.finish();
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.fds);

    try testing.expectEqual(@as(usize, 1), result.fds.len);
    try testing.expectEqual(@as(i32, 42), result.fds[0]);
}

test "Parser - parse and extract params" {
    // Build a call
    var call = try Call.init(testing.allocator, 100, 5);
    defer call.deinit();

    try call.addUint(42);
    try call.addString("hello");

    const result = try call.finish();
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.fds);

    // Parse it back
    var parser = Parser.init(testing.allocator);
    var parsed = try parser.parse(result.data);

    try testing.expectEqual(@as(u32, 100), parsed.object_id);
    try testing.expectEqual(@as(u32, 5), parsed.method_id);

    const uint_val = try parsed.nextUint();
    try testing.expectEqual(@as(u32, 42), uint_val);

    const str_val = try parsed.nextString();
    try testing.expectEqualStrings("hello", str_val);

    try testing.expect(parsed.isComplete());
}

test "Call - with arrays" {
    var call = try Call.init(testing.allocator, 200, 10);
    defer call.deinit();

    const uint_arr = [_]u32{ 1, 2, 3, 4 };
    try call.addUintArray(&uint_arr);

    const str_arr = [_][]const u8{ "one", "two", "three" };
    try call.addStringArray(&str_arr);

    const result = try call.finish();
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.fds);

    try testing.expect(result.data.len > 0);
}
