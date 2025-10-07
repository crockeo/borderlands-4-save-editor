const std = @import("std");
const c = @cImport({
    @cInclude("yaml.h");
});

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

    pub fn parse(self: *Self, reader: *std.io.Reader) !void {
        c.yaml_parser_set_input(&self.parser, read_handler, @ptrCast(reader));
        var event: c.yaml_event_t = undefined;
        while (true) {
            if (c.yaml_parser_parse(&self.parser, &event) == 0) {
                return error.OhMeOhMy;
            }
            defer c.yaml_event_delete(&event);

            switch (event.type) {
                c.YAML_SCALAR_EVENT => {},
                c.YAML_SEQUENCE_START_EVENT => {},
                c.YAML_MAPPING_START_EVENT => {},
                c.YAML_SEQUENCE_END_EVENT => {},
                c.YAML_STREAM_END_EVENT => {
                    break;
                },
                else => {},
            }
        }
    }
};

fn read_handler(ctx: ?*anyopaque, buffer: [*c]u8, size: usize, length: [*c]usize) callconv(.c) c_int {
    var reader: *std.io.Reader = @ptrCast(@alignCast(ctx));
    length.* = reader.readSliceShort(buffer[0..size]) catch {
        return 0;
    };
    return 1;
}
