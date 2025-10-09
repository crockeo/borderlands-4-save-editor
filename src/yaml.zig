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

const StackValue = struct {
    pending_key: ?[]const u8,
    value: Value,
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

        var stack = std.ArrayList(StackValue).empty;
        defer stack.deinit(allocator);

        var event: c.yaml_event_t = undefined;
        while (true) {
            if (c.yaml_parser_parse(&self.parser, &event) == 0) {
                return error.OhMeOhMy;
            }
            defer c.yaml_event_delete(&event);

            switch (event.type) {
                c.YAML_MAPPING_START_EVENT => {
                    try stack.append(allocator, .{
                        .pending_key = null,
                        .value = .{ .mapping = std.StringHashMap(Value).init(allocator) },
                    });
                },
                c.YAML_SCALAR_EVENT => {
                    const value = Value{
                        .scalar = try allocator.dupe(u8, event.data.scalar.value[0..event.data.scalar.length]),
                    };
                    if (stack.items.len == 0) {
                        return value;
                    }

                    var stack_head = &stack.items[stack.items.len - 1];
                    switch (stack_head.value) {
                        .mapping => |*mapping| {
                            if (stack_head.pending_key) |key| {
                                try mapping.put(key, value);
                                stack_head.pending_key = null;
                            } else {
                                stack_head.pending_key = value.scalar;
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
                    try stack.append(allocator, .{
                        .pending_key = null,
                        .value = .{ .sequence = std.ArrayList(Value).empty },
                    });
                },
                c.YAML_MAPPING_END_EVENT, c.YAML_SEQUENCE_END_EVENT => {
                    const value = stack.pop() orelse return error.UnexpectedEndOfStream;
                    if (value.pending_key != null) {
                        return error.ExtraPendingKey;
                    }
                    if (stack.items.len == 0) {
                        return value.value;
                    }

                    const stack_head = &stack.items[stack.items.len - 1];
                    switch (stack_head.value) {
                        .mapping => |*mapping| {
                            if (stack_head.pending_key) |key| {
                                try mapping.put(key, value.value);
                                stack_head.pending_key = null;
                            } else {
                                return error.MissingMappingKey;
                            }
                        },
                        .sequence => |*sequence| {
                            try sequence.append(allocator, value.value);
                        },
                        else => {
                            return error.InvalidYamlStack;
                        },
                    }
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
        return stack.items[0].value;
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

        self.emit_impl(&event, value);

        _ = c.yaml_stream_end_event_initialize(&event);
        _ = c.yaml_emitter_emit(&self.emitter, &event);
    }

    fn emit_impl(self: *Self, event: *c.yaml_event_t, value: Value) void {
        switch (value) {
            .mapping => |mapping| {
                _ = c.yaml_mapping_start_event_initialize(event, null, null, 1, c.YAML_ANY_MAPPING_STYLE);
                _ = c.yaml_emitter_emit(&self.emitter, event);

                var iter = mapping.iterator();
                while (iter.next()) |pair| {
                    _ = c.yaml_scalar_event_initialize(
                        event,
                        null,
                        null,
                        pair.key_ptr.ptr,
                        @intCast(pair.key_ptr.len),
                        1,
                        1,
                        c.YAML_ANY_SCALAR_STYLE,
                    );
                    _ = c.yaml_emitter_emit(&self.emitter, event);
                    self.emit_impl(event, pair.value_ptr.*);
                }

                _ = c.yaml_mapping_end_event_initialize(event);
                _ = c.yaml_emitter_emit(&self.emitter, event);
            },
            .scalar => |scalar| {
                _ = c.yaml_scalar_event_initialize(event, null, null, scalar.ptr, @intCast(scalar.len), 1, 1, c.YAML_ANY_SCALAR_STYLE);
                _ = c.yaml_emitter_emit(&self.emitter, event);
            },
            .sequence => |sequence| {
                _ = c.yaml_sequence_start_event_initialize(event, null, null, 1, c.YAML_ANY_SEQUENCE_STYLE);
                _ = c.yaml_emitter_emit(&self.emitter, event);

                for (sequence.items) |sequence_value| {
                    self.emit_impl(event, sequence_value);
                }

                _ = c.yaml_sequence_end_event_initialize(event);
                _ = c.yaml_emitter_emit(&self.emitter, event);
            },
            .null_value => {},
        }
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

    try std.testing.expectEqualStrings("value", value.mapping.get("key").?.scalar);
}

test "parse_nested_mapping" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var parser = Parser.init();
    defer parser.deinit();

    var value = blk: {
        var reader = std.io.Reader.fixed(
            \\key1:
            \\  subkey1: "value1"
            \\key2:
            \\  subkey2: "value2"
        );
        break :blk try parser.parse(allocator, &reader);
    };
    defer value.deinit(allocator);

    const value1 = value.mapping.get("key1").?.mapping.get("subkey1").?.scalar;
    const value2 = value.mapping.get("key2").?.mapping.get("subkey2").?.scalar;
    try std.testing.expectEqualStrings("value1", value1);
    try std.testing.expectEqualStrings("value2", value2);
}

test "parse_sequence_of_mappings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var parser = Parser.init();
    defer parser.deinit();

    var value = blk: {
        var reader = std.io.Reader.fixed(
            \\parent:
            \\- subkey: value1
            \\- subkey: value2
            \\another_key: another_value
        );
        break :blk try parser.parse(allocator, &reader);
    };
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings(
        "value1",
        (value
            .mapping.get("parent").?
            .sequence.items[0]
            .mapping.get("subkey").?
            .scalar),
    );
    try std.testing.expectEqualStrings(
        "value2",
        (value
            .mapping.get("parent").?
            .sequence.items[1]
            .mapping.get("subkey").?
            .scalar),
    );
    try std.testing.expectEqualStrings(
        "another_value",
        (value
            .mapping.get("another_key").?
            .scalar),
    );
}
