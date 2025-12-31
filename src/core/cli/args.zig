//! Command-line argument parser inspired by hyprutils
//! Supports bool, int, float, and string argument types

const std = @import("std");

/// Type of command-line argument
pub const ArgType = enum {
    bool,
    int,
    float,
    string,
};

/// Value that an argument can hold
pub const ArgValue = union(ArgType) {
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
};

/// Metadata for a registered argument option
const ArgOption = struct {
    name: []const u8,
    abbrev: []const u8,
    description: []const u8,
    arg_type: ArgType,
    value: ?ArgValue,
};

/// Argument parser for command-line options
pub const Parser = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,
    options: std.ArrayList(ArgOption),

    const Self = @This();

    pub const ParseError = error{
        InvalidArgument,
        UnknownArgument,
        MissingValue,
        InvalidValue,
        DuplicateOption,
        EmptyName,
        OutOfMemory,
    };

    /// Initialize a new argument parser with command-line arguments
    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) Self {
        return .{
            .allocator = allocator,
            .args = args,
            .options = std.ArrayList(ArgOption){},
        };
    }

    /// Clean up parser resources
    pub fn deinit(self: *Self) void {
        for (self.options.items) |opt| {
            self.allocator.free(opt.name);
            self.allocator.free(opt.abbrev);
            self.allocator.free(opt.description);
            if (opt.value) |val| {
                if (val == .string) {
                    self.allocator.free(val.string);
                }
            }
        }
        self.options.deinit(self.allocator);
    }

    /// Register a boolean option (flag)
    pub fn registerBoolOption(self: *Self, name: []const u8, abbrev: []const u8, description: []const u8) ParseError!void {
        try self.registerOption(name, abbrev, description, .bool);
    }

    /// Register an integer option
    pub fn registerIntOption(self: *Self, name: []const u8, abbrev: []const u8, description: []const u8) ParseError!void {
        try self.registerOption(name, abbrev, description, .int);
    }

    /// Register a float option
    pub fn registerFloatOption(self: *Self, name: []const u8, abbrev: []const u8, description: []const u8) ParseError!void {
        try self.registerOption(name, abbrev, description, .float);
    }

    /// Register a string option
    pub fn registerStringOption(self: *Self, name: []const u8, abbrev: []const u8, description: []const u8) ParseError!void {
        try self.registerOption(name, abbrev, description, .string);
    }

    /// Internal method to register an option
    fn registerOption(self: *Self, name: []const u8, abbrev: []const u8, description: []const u8, arg_type: ArgType) ParseError!void {
        if (name.len == 0) {
            return ParseError.EmptyName;
        }

        // Check for duplicates
        for (self.options.items) |opt| {
            if (std.mem.eql(u8, opt.name, name) or (abbrev.len > 0 and std.mem.eql(u8, opt.abbrev, abbrev))) {
                return ParseError.DuplicateOption;
            }
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        
        const abbrev_copy = try self.allocator.dupe(u8, abbrev);
        errdefer self.allocator.free(abbrev_copy);
        
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);

        try self.options.append(self.allocator, .{
            .name = name_copy,
            .abbrev = abbrev_copy,
            .description = desc_copy,
            .arg_type = arg_type,
            .value = null,
        });
    }

    /// Parse the command-line arguments
    pub fn parse(self: *Self) ParseError!void {
        var i: usize = 1; // Skip program name
        while (i < self.args.len) : (i += 1) {
            const arg = self.args[i];
            
            var option_name: []const u8 = undefined;
            var is_long = false;

            if (std.mem.startsWith(u8, arg, "--")) {
                option_name = arg[2..];
                is_long = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                option_name = arg[1..];
            } else {
                return ParseError.InvalidArgument;
            }

            // Find the option
            var opt_idx: ?usize = null;
            for (self.options.items, 0..) |opt, idx| {
                if ((is_long and std.mem.eql(u8, opt.name, option_name)) or
                    (!is_long and std.mem.eql(u8, opt.abbrev, option_name)))
                {
                    opt_idx = idx;
                    break;
                }
            }

            if (opt_idx == null) {
                return ParseError.UnknownArgument;
            }

            const opt = &self.options.items[opt_idx.?];

            switch (opt.arg_type) {
                .bool => {
                    opt.value = ArgValue{ .bool = true };
                },
                .int => {
                    i += 1;
                    if (i >= self.args.len) {
                        return ParseError.MissingValue;
                    }
                    const value = std.fmt.parseInt(i64, self.args[i], 10) catch {
                        return ParseError.InvalidValue;
                    };
                    opt.value = ArgValue{ .int = value };
                },
                .float => {
                    i += 1;
                    if (i >= self.args.len) {
                        return ParseError.MissingValue;
                    }
                    const value = std.fmt.parseFloat(f64, self.args[i]) catch {
                        return ParseError.InvalidValue;
                    };
                    opt.value = ArgValue{ .float = value };
                },
                .string => {
                    i += 1;
                    if (i >= self.args.len) {
                        return ParseError.MissingValue;
                    }
                    const value = try self.allocator.dupe(u8, self.args[i]);
                    opt.value = ArgValue{ .string = value };
                },
            }
        }
    }

    /// Get a boolean option value
    pub fn getBool(self: *Self, name: []const u8) ?bool {
        for (self.options.items) |opt| {
            if (std.mem.eql(u8, opt.name, name) or std.mem.eql(u8, opt.abbrev, name)) {
                if (opt.value) |val| {
                    if (val == .bool) {
                        return val.bool;
                    }
                }
                return null;
            }
        }
        return null;
    }

    /// Get an integer option value
    pub fn getInt(self: *Self, name: []const u8) ?i64 {
        for (self.options.items) |opt| {
            if (std.mem.eql(u8, opt.name, name) or std.mem.eql(u8, opt.abbrev, name)) {
                if (opt.value) |val| {
                    if (val == .int) {
                        return val.int;
                    }
                }
                return null;
            }
        }
        return null;
    }

    /// Get a float option value
    pub fn getFloat(self: *Self, name: []const u8) ?f64 {
        for (self.options.items) |opt| {
            if (std.mem.eql(u8, opt.name, name) or std.mem.eql(u8, opt.abbrev, name)) {
                if (opt.value) |val| {
                    if (val == .float) {
                        return val.float;
                    }
                }
                return null;
            }
        }
        return null;
    }

    /// Get a string option value
    pub fn getString(self: *Self, name: []const u8) ?[]const u8 {
        for (self.options.items) |opt| {
            if (std.mem.eql(u8, opt.name, name) or std.mem.eql(u8, opt.abbrev, name)) {
                if (opt.value) |val| {
                    if (val == .string) {
                        return val.string;
                    }
                }
                return null;
            }
        }
        return null;
    }

    /// Generate a formatted help description
    pub fn getDescription(self: *Self, header: []const u8, max_width: ?usize) ![]const u8 {
        const width = max_width orelse 80;
        var output = std.ArrayList(u8){};
        errdefer output.deinit(self.allocator);

        const writer = output.writer(self.allocator);

        // Header
        try writer.print("┏ {s}\n", .{header});
        try writer.writeAll("┣");
        var i: usize = 0;
        while (i < width) : (i += 1) {
            try writer.writeAll("━");
        }
        try writer.writeAll("┓\n");

        // Calculate column widths
        var max_name_width: usize = 0;
        var max_abbrev_width: usize = 0;
        
        for (self.options.items) |opt| {
            max_name_width = @max(max_name_width, opt.name.len + 3); // "--" prefix + space
            if (opt.abbrev.len > 0) {
                const type_str = getTypeString(opt.arg_type);
                max_abbrev_width = @max(max_abbrev_width, opt.abbrev.len + 2 + type_str.len + 1); // "-" prefix + space + type
            }
        }

        // Write options
        for (self.options.items) |opt| {
            try writer.writeAll("┣--");
            try writer.writeAll(opt.name);
            
            const name_padding = max_name_width - opt.name.len - 2; // -2 for "--"
            try writePadding(writer, name_padding);

            if (opt.abbrev.len > 0) {
                try writer.writeAll(" -");
                try writer.writeAll(opt.abbrev);
                try writer.writeAll(" ");
                try writer.writeAll(getTypeString(opt.arg_type));
                
                const type_str = getTypeString(opt.arg_type);
                const abbrev_padding = max_abbrev_width - opt.abbrev.len - 2 - type_str.len - 1;
                try writePadding(writer, abbrev_padding);
            } else {
                try writePadding(writer, max_abbrev_width);
            }

            try writer.writeAll(" | ");
            try writer.writeAll(opt.description);
            
            // Account for Unicode box-drawing character width (┃ takes 2 display columns but is 3 bytes)
            const used = max_name_width + max_abbrev_width + 3 + opt.description.len;
            const unicode_border_width = 2; // ┃ displays as 2 columns
            if (used < width) {
                try writePadding(writer, width - used - unicode_border_width + 1);
            }
            try writer.writeAll(" ┃\n");
        }

        // Footer
        try writer.writeAll("┗");
        i = 0;
        while (i < width) : (i += 1) {
            try writer.writeAll("━");
        }
        try writer.writeAll("┛\n");

        return output.toOwnedSlice(self.allocator);
    }

    fn getTypeString(arg_type: ArgType) []const u8 {
        return switch (arg_type) {
            .bool => "",
            .int => "[int]",
            .float => "[float]",
            .string => "[str]",
        };
    }

    fn writePadding(writer: anytype, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try writer.writeAll(" ");
        }
    }
};

// Tests (inspired by hyprutils test suite)
test "Parser - basic parsing with bool and float" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "--hello", "--value", "0.2" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerBoolOption("hello", "h", "Says hello");
    try parser.registerBoolOption("hello2", "", "Says hello 2");
    try parser.registerFloatOption("value", "v", "Sets a valueeeeeee");
    try parser.registerIntOption("longlonglonglongintopt", "l", "Long long option");

    try parser.parse();

    // Test getting values
    try testing.expect(parser.getBool("hello") != null and parser.getBool("hello").? == true);
    try testing.expect(parser.getBool("hello2") == null or parser.getBool("hello2").? == false);
    try testing.expect(parser.getFloat("value") != null);
    const val = parser.getFloat("value").?;
    try testing.expect(@abs(val - 0.2) < 0.0001);
}

test "Parser - description generation format" {
    const testing = std.testing;
    const args = [_][]const u8{"app"};
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerBoolOption("hello", "h", "Says hello");
    try parser.registerBoolOption("hello2", "", "Says hello 2");
    try parser.registerFloatOption("value", "v", "Sets a valueeeeeee");

    const description = try parser.getDescription("My description", null);
    defer testing.allocator.free(description);

    // Verify structure
    try testing.expect(std.mem.indexOf(u8, description, "┏ My description") != null);
    try testing.expect(std.mem.indexOf(u8, description, "┣━") != null);
    try testing.expect(std.mem.indexOf(u8, description, "┗━") != null);
    try testing.expect(std.mem.indexOf(u8, description, "--hello") != null);
    try testing.expect(std.mem.indexOf(u8, description, "-h") != null);
    try testing.expect(std.mem.indexOf(u8, description, "[float]") != null);
}

test "Parser - parse fails on unknown argument" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "--hello", "--value", "0.2" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    // Register different options than what's in args
    try parser.registerBoolOption("hello2", "e", "Says hello 2");
    try parser.registerFloatOption("value", "v", "Sets a valueeeeeee");
    try parser.registerIntOption("longlonglonglongintopt", "l", "Long long option");

    // Should fail because --hello is not registered
    const result = parser.parse();
    try testing.expectError(Parser.ParseError.UnknownArgument, result);
}

test "Parser - parse fails on missing value for option" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "--hello", "--value" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerBoolOption("hello2", "e", "Says hello 2");
    try parser.registerFloatOption("value", "v", "Sets a valueeeeeee");
    try parser.registerIntOption("longlonglonglongintopt", "l", "Long long option");

    // Should fail because --value needs a value but none is provided
    const result = parser.parse();
    try testing.expectError(Parser.ParseError.UnknownArgument, result);
}

test "Parser - string and int parsing with short forms" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "--value", "hi", "-w", "2" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerStringOption("value", "v", "Sets a valueeeeeee");
    try parser.registerIntOption("value2", "w", "Sets a valueeeeeee 2");

    try parser.parse();

    const str_val = parser.getString("value");
    const int_val = parser.getInt("value2");

    try testing.expect(str_val != null and std.mem.eql(u8, str_val.?, "hi"));
    try testing.expect(int_val != null and int_val.? == 2);
}

test "Parser - parse fails on invalid argument format" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "e" }; // Missing - or --
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerStringOption("value", "v", "Sets a valueeeeeee");
    try parser.registerStringOption("value2", "w", "Sets a valueeeeeee 2");

    const result = parser.parse();
    try testing.expectError(Parser.ParseError.InvalidArgument, result);
}

test "Parser - duplicate name registration fails" {
    const testing = std.testing;
    const args = [_][]const u8{"app"};
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerStringOption("aa", "v", "Sets a valueeeeeee");
    const result = parser.registerStringOption("aa", "w", "Sets a valueeeeeee 2");
    
    try testing.expectError(Parser.ParseError.DuplicateOption, result);
}

test "Parser - duplicate abbrev registration fails" {
    const testing = std.testing;
    const args = [_][]const u8{"app"};
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerStringOption("bb", "b", "Sets a valueeeeeee");
    const result = parser.registerStringOption("cc", "b", "Sets a valueeeeeee 2");
    
    try testing.expectError(Parser.ParseError.DuplicateOption, result);
}

test "Parser - empty name registration fails" {
    const testing = std.testing;
    const args = [_][]const u8{"app"};
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    const result = parser.registerFloatOption("", "a", "Sets a valueeeeeee 2");
    
    try testing.expectError(Parser.ParseError.EmptyName, result);
}

test "Parser - option without abbrev works" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "--verbose" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerBoolOption("verbose", "", "Enable verbose");
    try parser.parse();

    try testing.expect(parser.getBool("verbose") != null and parser.getBool("verbose").? == true);
}

test "Parser - mixed long and short forms" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "-v", "--count", "42", "-o", "test.txt" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerBoolOption("verbose", "v", "Verbose");
    try parser.registerIntOption("count", "c", "Count");
    try parser.registerStringOption("output", "o", "Output file");
    try parser.parse();

    try testing.expect(parser.getBool("verbose").? == true);
    try testing.expect(parser.getInt("count").? == 42);
    try testing.expect(std.mem.eql(u8, parser.getString("output").?, "test.txt"));
}

test "Parser - get by abbrev works" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "-v" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerBoolOption("verbose", "v", "Verbose");
    try parser.parse();

    // Should be able to get by either name or abbrev
    try testing.expect(parser.getBool("verbose").? == true);
    try testing.expect(parser.getBool("v").? == true);
}

test "Parser - invalid int value fails" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "--count", "notanumber" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerIntOption("count", "c", "Count");
    
    const result = parser.parse();
    try testing.expectError(Parser.ParseError.InvalidValue, result);
}

test "Parser - invalid float value fails" {
    const testing = std.testing;
    const args = [_][]const u8{ "app", "--ratio", "notafloat" };
    
    var parser = Parser.init(testing.allocator, &args);
    defer parser.deinit();

    try parser.registerFloatOption("ratio", "r", "Ratio");
    
    const result = parser.parse();
    try testing.expectError(Parser.ParseError.InvalidValue, result);
}
