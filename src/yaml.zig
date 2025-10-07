const std = @import("std");
const c = @cImport({
    @cInclude("yaml.h");
});

pub const Pair = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    const Self = @This();

    mapping: std.StringHashMap(Value),
    scalar: []const u8,
    sequence: std.ArrayList(Value),
    null_value: struct {},

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .mapping => |*mapping| {
                var iterator = mapping.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                mapping.deinit();
            },
            .scalar => |scalar| {
                allocator.free(scalar);
            },
            .sequence => |*sequence| {
                for (sequence.items) |*value| {
                    value.deinit(allocator);
                }
                sequence.deinit(allocator);
            },
            .null_value => {},
        }
    }
};

pub const Parser = struct {
    const Self = @This();

    parser: c.yaml_parser_t,

    pub fn init() Self {
        var self = Self{ .parser = undefined };
        // TODO: error handling?
        _ = c.yaml_parser_initialize(&self.parser);
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn parse(self: *Self, allocator: std.mem.Allocator, reader: *std.io.Reader) !Value {
        c.yaml_parser_set_input(&self.parser, read_handler, @ptrCast(reader));

        var stack = std.ArrayList(Value).empty;
        defer stack.deinit(allocator);

        var event: c.yaml_event_t = undefined;
        var pending_key: ?[]const u8 = null;
        defer {
            if (pending_key) |key| {
                allocator.free(key);
            }
        }

        while (true) {
            if (c.yaml_parser_parse(&self.parser, &event) == 0) {
                return error.OhMeOhMy;
            }
            defer c.yaml_event_delete(&event);

            switch (event.type) {
                c.YAML_MAPPING_START_EVENT => {
                    try stack.append(allocator, .{
                        .mapping = std.StringHashMap(Value).init(allocator),
                    });
                },
                c.YAML_SCALAR_EVENT => {
                    const value = Value{
                        .scalar = try allocator.dupe(u8, event.data.scalar.value[0..event.data.scalar.length]),
                    };
                    if (stack.items.len == 0) {
                        return value;
                    }

                    switch (stack.items[stack.items.len - 1]) {
                        .mapping => |*mapping| {
                            if (pending_key) |key| {
                                try mapping.put(key, value);
                                pending_key = null;
                            } else {
                                pending_key = value.scalar;
                            }
                        },
                        .sequence => |*sequence| {
                            try sequence.append(allocator, value);
                        },
                        else => {
                            return error.InvalidYamlStack;
                        },
                    }
                },
                c.YAML_SEQUENCE_START_EVENT => {
                    try stack.append(allocator, .{ .sequence = std.ArrayList(Value).empty });
                },
                c.YAML_MAPPING_END_EVENT | c.YAML_SEQUENCE_END_EVENT => {
                    const value = stack.pop() orelse return error.UnexpectedEndOfStream;
                    if (stack.items.len == 0) {
                        return value;
                    }
                    switch (stack.items[stack.items.len - 1]) {
                        .mapping => |*mapping| {
                            if (pending_key) |key| {
                                try mapping.put(key, value);
                            } else {
                                return error.MissingMappingKey;
                            }
                        },
                        .sequence => |*sequence| {
                            try sequence.append(allocator, value);
                        },
                        else => {
                            return error.InvalidYamlStack;
                        },
                    }

                    pending_key = null;
                },
                c.YAML_STREAM_END_EVENT => {
                    break;
                },
                else => {},
            }
        }

        if (stack.items.len != 1) {
            return error.UnexpectedEndOfStream;
        }
        return stack.items[0];
    }
};

fn read_handler(ctx: ?*anyopaque, buffer: [*c]u8, size: usize, length: [*c]usize) callconv(.c) c_int {
    var reader: *std.io.Reader = @ptrCast(@alignCast(ctx));
    length.* = reader.readSliceShort(buffer[0..size]) catch {
        return 0;
    };
    return 1;
}

pub const Emitter = struct {
    const Self = @This();

    emitter: c.yaml_emitter_t,

    pub fn init() Self {
        var self = Self{ .emitter = undefined };
        _ = c.yaml_emitter_initialize(&self.emitter);
        return self;
    }

    pub fn deinit(self: *Self) void {
        c.yaml_emitter_delete(&self.emitter);
    }

    pub fn emit(self: *Self, writer: *std.io.Writer, value: Value) !void {
        c.yaml_emitter_set_output(&self.emitter, write_handler, @ptrCast(writer));

        var event: c.yaml_event_t = undefined;
        _ = c.yaml_stream_start_event_initialize(&event, c.YAML_UTF8_ENCODING);
        _ = c.yaml_emitter_emit(&self.emitter, &event);

        // TODO: walk values and emit them here

        _ = c.yaml_stream_end_event_initialize(&event);
        _ = c.yaml_emitter_emit(&self.emitter, &event);

        _ = value;
    }
};

fn write_handler(ctx: ?*anyopaque, buffer: [*c]u8, size: usize) callconv(.c) c_int {
    var writer: *std.io.Writer = @ptrCast(@alignCast(ctx));
    writer.writeAll(buffer[0..size]) catch {
        return 0;
    };
    return 1;
}

test "parse_scalar" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var parser = Parser.init();
    defer parser.deinit();

    var value = blk: {
        var reader = std.io.Reader.fixed("\"string value\"");
        break :blk try parser.parse(allocator, &reader);
    };
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("string value", value.scalar);
}

test "parse_sequence" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var parser = Parser.init();
    defer parser.deinit();

    var value = blk: {
        var reader = std.io.Reader.fixed(
            \\- first string
            \\- second string
        );
        break :blk try parser.parse(allocator, &reader);
    };
    defer value.deinit(allocator);

    const sequence = try value.sequence.toOwnedSlice(allocator);
    try std.testing.expectEqualStrings("first string", sequence[0].scalar);
    try std.testing.expectEqualStrings("second string", sequence[1].scalar);
}

test "parse_mapping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var parser = Parser.init();
    defer parser.deinit();

    var value = blk: {
        var reader = std.io.Reader.fixed(
            \\key: value
        );
        break :blk try parser.parse(allocator, &reader);
    };
    defer value.deinit(allocator);

    const sub_value = value.mapping.get("key") orelse return error.ExpectedKey;
    try std.testing.expectEqualStrings("value", sub_value.scalar);
}
