const std = @import("std");
const core = @import("core");

/// Most-recently-focused stack with unique entries.
pub fn Stack(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        entries: std.ArrayList(T) = .empty,
        cursor: ?usize = null,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
        }

        pub fn push(self: *Self, value: T) !void {
            self.truncateForward();
            self.remove(value);
            try self.entries.append(self.allocator, value);
            self.cursor = self.entries.items.len - 1;
        }

        pub fn remove(self: *Self, value: T) void {
            for (self.entries.items, 0..) |entry, index| {
                if (entry != value) continue;
                _ = self.entries.orderedRemove(index);
                self.adjustCursorAfterRemove(index);
                return;
            }
        }

        pub fn current(self: *const Self) ?T {
            const index = self.cursor orelse return null;
            return self.entries.items[index];
        }

        pub fn back(self: *Self) ?T {
            const index = self.cursor orelse return null;
            if (index > 0) self.cursor = index - 1;
            return self.current();
        }

        pub fn peekBack(self: *const Self) ?T {
            const index = self.cursor orelse return null;
            return self.entries.items[index -| 1];
        }

        pub fn forward(self: *Self) ?T {
            const index = self.cursor orelse return null;
            if (index + 1 < self.entries.items.len) self.cursor = index + 1;
            return self.current();
        }

        pub fn peekForward(self: *const Self) ?T {
            const index = self.cursor orelse return null;
            return self.entries.items[@min(index + 1, self.entries.items.len - 1)];
        }

        fn truncateForward(self: *Self) void {
            const index = self.cursor orelse return;
            const retained = index + 1;
            if (retained < self.entries.items.len)
                self.entries.shrinkRetainingCapacity(retained);
        }

        fn adjustCursorAfterRemove(self: *Self, removed: usize) void {
            const index = self.cursor orelse return;
            if (removed == index) {
                if (self.entries.items.len == 0) {
                    self.cursor = null;
                    return;
                }
                self.cursor = @min(removed, self.entries.items.len - 1);
                return;
            }
            if (self.entries.items.len == 0) {
                self.cursor = null;
                return;
            }
            if (removed < index) self.cursor = index - 1;
        }
    };
}

const testing = core.testing;

test "Stack - push keeps entries unique and current" {
    var stack = Stack(u32).init(testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.push(1);

    try testing.expectEqual(@as(usize, 2), stack.entries.items.len);
    try testing.expectEqual(@as(?u32, 1), stack.current());
}

test "Stack - remove and back restore previous entry" {
    var stack = Stack(u32).init(testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    stack.remove(2);

    try testing.expectEqual(@as(?u32, 1), stack.back());
    stack.remove(1);
    try testing.expectEqual(@as(?u32, 3), stack.current());
}

test "Stack - back and forward preserve navigation history" {
    var stack = Stack(u32).init(testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    try testing.expectEqual(@as(?u32, 2), stack.peekBack());
    try testing.expectEqual(@as(?u32, 3), stack.current());
    try testing.expectEqual(@as(?u32, 2), stack.back());
    try testing.expectEqual(@as(?u32, 3), stack.peekForward());
    try testing.expectEqual(@as(?u32, 1), stack.back());
    try testing.expectEqual(@as(?u32, 2), stack.forward());
    try testing.expectEqual(@as(?u32, 3), stack.forward());
}

test "Stack - new focus truncates forward history" {
    var stack = Stack(u32).init(testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    _ = stack.back();
    try stack.push(4);

    try testing.expectEqual(@as(?u32, 4), stack.current());
    try testing.expectEqual(@as(?u32, 4), stack.forward());
    try testing.expectEqualSlices(u32, &.{ 1, 2, 4 }, stack.entries.items);
}

test "Stack - removing current middle preserves back and forward history" {
    var stack = Stack(u32).init(testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    _ = stack.back();
    stack.remove(2);

    try testing.expectEqualSlices(u32, &.{ 1, 3 }, stack.entries.items);
    try testing.expectEqual(@as(?u32, 3), stack.current());
    try testing.expectEqual(@as(?u32, 1), stack.back());
    try testing.expectEqual(@as(?u32, 3), stack.forward());
}
