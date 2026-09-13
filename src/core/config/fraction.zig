//! Viewport fraction from a `%` percent, `a/b` ratio, or decimal with `.`.
//!
//! A percent is recognized only when the text ends in `%`. A ratio requires a
//! `/`. A decimal requires a `.`. Integers and words are rejected; nothing is
//! inferred from magnitude.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");
const value = @import("value.zig");

pub const Fraction = struct {
    ratio: f64 = 0,

    /// Parses a TOML string or a float (a decimal already lexed by TOML).
    /// Integers have no `.`, `/`, or `%` and are rejected.
    pub fn fromValue(found: value.Value) ?Fraction {
        return switch (found) {
            .float => |amount| fromRatio(amount),
            .string => |text| parse(text),
            else => null,
        };
    }

    pub fn parse(text: string) ?Fraction {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return null;
        if (trimmed[trimmed.len - 1] == '%') {
            return fromPercent(trimmed[0 .. trimmed.len - 1]);
        }
        if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
            return fromSlash(trimmed, slash);
        }
        if (std.mem.indexOfScalar(u8, trimmed, '.') != null) {
            return fromDecimal(trimmed);
        }
        return null;
    }

    pub fn encode(self: Fraction) value.Value {
        return .{ .float = self.ratio };
    }
};

fn fromPercent(body: string) ?Fraction {
    const amount = parseNumber(std.mem.trim(u8, body, " \t")) orelse return null;
    return fromRatio(amount / 100.0);
}

fn fromSlash(text: string, slash: usize) ?Fraction {
    if (std.mem.indexOfScalar(u8, text[slash + 1 ..], '/') != null) return null;
    const numerator = parseNumber(std.mem.trim(u8, text[0..slash], " \t")) orelse return null;
    const denominator = parseNumber(std.mem.trim(u8, text[slash + 1 ..], " \t")) orelse return null;
    if (denominator == 0) return null;
    return fromRatio(numerator / denominator);
}

fn fromDecimal(text: string) ?Fraction {
    return fromRatio(parseNumber(std.mem.trim(u8, text, " \t")) orelse return null);
}

fn parseNumber(text: string) ?f64 {
    if (text.len == 0) return null;
    const amount = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(amount)) return null;
    return amount;
}

fn fromRatio(ratio: f64) ?Fraction {
    if (!std.math.isFinite(ratio) or ratio <= 0) return null;
    return .{ .ratio = ratio };
}

fn expectRatio(text: string, expected: f64) !void {
    const parsed = Fraction.parse(text) orelse return error.TestExpectedEqual;
    try testing.expectApproxEqAbs(expected, parsed.ratio, 1e-12);
}

fn expectRejected(text: string) !void {
    try testing.expectEqual(@as(?Fraction, null), Fraction.parse(text));
}

test "fraction parses percent only when % is present" {
    try expectRatio("50%", 0.5);
    try expectRatio("100%", 1.0);
    try expectRatio("33.33%", 0.3333);
    try expectRatio("  12.5%  ", 0.125);
    try expectRatio("200%", 2.0);
    try expectRatio("0.5%", 0.005);
    try expectRejected("50");
    try expectRejected("%");
    try expectRejected("50%%");
    try expectRejected("%50");
    try expectRejected("abc%");
    try expectRejected("0%");
    try expectRejected("-10%");
}

test "fraction parses ratio only when a slash is present" {
    try expectRatio("1/2", 0.5);
    try expectRatio("1/3", 1.0 / 3.0);
    try expectRatio("2/3", 2.0 / 3.0);
    try expectRatio("1/1", 1.0);
    try expectRatio("1 / 4", 0.25);
    try expectRatio("3/2", 1.5);
    try expectRatio("1.5/2", 0.75);
    try expectRejected("1/");
    try expectRejected("/2");
    try expectRejected("1/0");
    try expectRejected("0/1");
    try expectRejected("1/2/3");
    try expectRejected("1//2");
    try expectRejected("-1/2");
    try expectRejected("1/-2");
    try expectRejected("a/2");
    try expectRejected("1/b");
}

test "fraction parses decimal only when a period is present" {
    try expectRatio("0.5", 0.5);
    try expectRatio("1.0", 1.0);
    try expectRatio(".5", 0.5);
    try expectRatio("5.", 5.0);
    try expectRatio("1.25", 1.25);
    try expectRatio("33.33", 33.33);
    try expectRejected("1");
    try expectRejected("0");
    try expectRejected("0.0");
    try expectRejected("-0.5");
    try expectRejected("1.2.3");
    try expectRejected(".");
    try expectRejected("half");
    try expectRejected("third");
    try expectRejected("");
    try expectRejected("   ");
    try expectRejected("nan");
    try expectRejected("inf");
    try expectRejected("1e-1");
}

test "fraction mixed markers and non-numeric values are rejected" {
    try expectRejected("1/2%");
    try expectRejected("50%.");
    try expectRejected("1.2/");
    try expectRejected("true");
    try expectRejected("false");
    try expectRejected("1 2");
    try expectRejected("1,2");
    try expectRejected("++0.5");
}

test "fraction fromValue accepts floats and marked strings only" {
    try testing.expectApproxEqAbs(0.5, Fraction.fromValue(.{ .float = 0.5 }).?.ratio, 1e-12);
    try testing.expectApproxEqAbs(1.0 / 3.0, Fraction.fromValue(.{ .string = "1/3" }).?.ratio, 1e-12);
    try testing.expectApproxEqAbs(0.3333, Fraction.fromValue(.{ .string = "33.33%" }).?.ratio, 1e-12);
    try testing.expectEqual(@as(?Fraction, null), Fraction.fromValue(.{ .integer = 1 }));
    try testing.expectEqual(@as(?Fraction, null), Fraction.fromValue(.{ .integer = 50 }));
    try testing.expectEqual(@as(?Fraction, null), Fraction.fromValue(.{ .boolean = true }));
    try testing.expectEqual(@as(?Fraction, null), Fraction.fromValue(.{ .float = 0 }));
    try testing.expectEqual(@as(?Fraction, null), Fraction.fromValue(.{ .float = std.math.inf(f64) }));
    try testing.expectEqual(@as(?Fraction, null), Fraction.fromValue(.{ .string = "half" }));
}
