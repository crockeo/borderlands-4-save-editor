const std = @import("std");
const c = @cImport({
    @cInclude("zlib.h");
});

const CHUNK = 16384;

pub const ZLibError = error{
    MemoryError,
    DataError,
    VersionError,
    StreamError,
    IoError,
};

pub const CompressionLevel = enum(c_int) {
    best = 9,
    default = -1,
    none = 0,
    speed = 1,
};

pub fn compress(reader: *std.io.Reader, writer: *std.io.Writer, level: CompressionLevel) ZLibError!void {
    var stream: c.z_stream = .{
        .@"opaque" = null,
        .zalloc = null,
        .zfree = null,
    };

    if (c.deflateInit(&stream, @intFromEnum(level)) != c.Z_OK) {
        return error.StreamError;
    }
    defer _ = c.deflateEnd(&stream);

    var ret: c_int = undefined;
    var in: [CHUNK]u8 = undefined;
    var out: [CHUNK]u8 = undefined;
    var flush: c_int = undefined;
    while (flush != c.Z_FINISH) {
        const bytes_read = reader.readSliceShort(&in) catch {
            return error.IoError;
        };

        stream.avail_in = @intCast(bytes_read);
        flush = if (bytes_read == 0) c.Z_FINISH else c.Z_NO_FLUSH;
        stream.next_in = &in;

        ret = try compress_chunk(&stream, &out, writer, flush);
        std.debug.assert(stream.avail_in == 0); // all input will be used
    }
    std.debug.assert(ret == c.Z_STREAM_END); // stream will be complete
}

pub fn decompress(reader: *std.io.Reader, writer: *std.io.Writer) ZLibError!void {
    var stream: c.z_stream = .{
        .@"opaque" = null,
        .avail_in = 0,
        .next_in = null,
        .zalloc = null,
        .zfree = null,
    };
    if (c.inflateInit(&stream) != c.Z_OK) {
        return error.StreamError;
    }
    defer _ = c.inflateEnd(&stream);

    var ret: c_int = undefined;
    var in: [CHUNK]u8 = undefined;
    var out: [CHUNK]u8 = undefined;
    while (ret != c.Z_STREAM_END) {
        const bytes_read = reader.readSliceShort(&in) catch {
            return error.IoError;
        };
        if (bytes_read == 0) {
            break;
        }

        stream.avail_in = @intCast(bytes_read);
        stream.next_in = &in;

        ret = try decompress_chunk(&stream, &out, writer);
    }

    if (ret != c.Z_STREAM_END) {
        return error.DataError;
    }
}

fn compress_chunk(stream: [*c]c.z_stream, out: *[CHUNK]u8, writer: *std.io.Writer, flush: c_int) ZLibError!c_int {
    var ret: c_int = undefined;
    while (true) {
        stream.*.avail_out = CHUNK;
        stream.*.next_out = out;
        ret = c.deflate(stream, flush);
        std.debug.assert(ret != c.Z_STREAM_ERROR); // state not clobbered

        const have = CHUNK - stream.*.avail_out;
        writer.writeAll(out[0..have]) catch {
            return error.IoError;
        };

        if (stream.*.avail_out != 0)
            break;
    }
    return ret;
}

fn decompress_chunk(stream: [*c]c.z_stream, out: *[CHUNK]u8, writer: *std.io.Writer) ZLibError!c_int {
    var ret: c_int = undefined;
    while (true) {
        stream.*.avail_out = CHUNK;
        stream.*.next_out = out;
        ret = c.inflate(stream, c.Z_NO_FLUSH);
        std.debug.assert(ret != c.Z_STREAM_ERROR); // state not clobbered

        switch (ret) {
            c.Z_NEED_DICT => {
                return error.DataError;
            },
            c.Z_DATA_ERROR => {
                return error.DataError;
            },
            c.Z_MEM_ERROR => {
                return error.MemoryError;
            },
            else => {},
        }

        const have = CHUNK - stream.*.avail_out;
        writer.writeAll(out[0..have]) catch {
            return error.IoError;
        };

        if (stream.*.avail_out != 0)
            break;
    }
    return ret;
}

test "compression_roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const message = "this is a message";
    const compressed_message = blk: {
        var reader = std.io.Reader.fixed(message);

        var output = std.io.Writer.Allocating.init(allocator);
        errdefer output.deinit();

        try compress(&reader, &output.writer, .default);
        break :blk try output.toOwnedSlice();
    };

    const decompressed_message = blk: {
        var reader = std.io.Reader.fixed(compressed_message);

        var output = std.io.Writer.Allocating.init(allocator);
        errdefer output.deinit();

        try decompress(&reader, &output.writer);
        break :blk try output.toOwnedSlice();
    };

    try std.testing.expectEqualStrings(message, decompressed_message);
}
