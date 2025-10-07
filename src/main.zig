const std = @import("std");

const aes = @import("./aes.zig");
const base85 = @import("./base85.zig");
const yaml = @import("./yaml.zig");
const zlib = @import("./zlib.zig");

const BASE_KEY = [_]u8{
    0x35, 0xEC, 0x33, 0x77, 0xF3, 0x5D, 0xB0, 0xEA,
    0xBE, 0x6B, 0x83, 0x11, 0x54, 0x03, 0xEB, 0xFB,
    0x27, 0x25, 0x64, 0x2E, 0xD5, 0x49, 0x06, 0x29,
    0x05, 0x78, 0xBD, 0x60, 0xBA, 0x4A, 0xA7, 0x87,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const contents = try std.fs.cwd().readFileAlloc(allocator, "saves/76561198009258085/Profiles/client/1.sav", std.math.maxInt(usize));
    defer allocator.free(contents);

    var key: [BASE_KEY.len]u8 = undefined;
    const steam_id = 76561198009258085;
    derive_key(&key, steam_id);
    const aes_ecb = aes.AesEcb.init(key);

    const decrypted_contents = try aes_ecb.decrypt(allocator, contents);
    defer allocator.free(decrypted_contents);

    const decompressed_contents = blk: {
        var reader = std.io.Reader.fixed(decrypted_contents);

        var output = std.io.Writer.Allocating.init(allocator);
        errdefer output.deinit();

        try zlib.decompress(&reader, &output.writer);
        break :blk try output.toOwnedSlice();
    };
    defer allocator.free(decompressed_contents);

    var value = blk: {
        var parser = yaml.Parser.init();
        defer parser.deinit();
        var reader = std.io.Reader.fixed(decompressed_contents);
        break :blk try parser.parse(allocator, &reader);
    };
    defer value.deinit(allocator);

    const emitted_value = blk: {
        var emitter = yaml.Emitter.init();
        defer emitter.deinit();
        var writer = std.io.Writer.Allocating.init(allocator);
        errdefer writer.deinit();
        try emitter.emit(&writer.writer, value);
        break :blk try writer.toOwnedSlice();
    };
    defer allocator.free(emitted_value);

    std.debug.print("{s}\n", .{emitted_value});
}

fn derive_key(buf: *[BASE_KEY.len]u8, steam_id: u64) void {
    std.mem.copyForwards(u8, buf, &BASE_KEY);
    const segments: [8]u8 = @bitCast(steam_id);
    for (0..8) |i| {
        buf[i] ^= segments[i];
    }
}

test {
    _ = aes;
    _ = base85;
    _ = yaml;
    _ = zlib;
}

test "encrypt_decrypt_round_trip__no_padding" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const key: [32]u8 = undefined;
    const aes_ecb = aes.AesEcb.init(key);

    // Extra space on the end is load bearing 😅
    // We need it because this tests the case
    // where we don't have to support padding.
    const original_contents = "Hello world, this is a message. ";

    const encrypted_contents = try aes_ecb.encrypt(allocator, original_contents);
    defer allocator.free(encrypted_contents);

    const decrypted_contents = try aes_ecb.decrypt(allocator, encrypted_contents);
    defer allocator.free(decrypted_contents);

    try std.testing.expectEqualStrings(original_contents, decrypted_contents);
}
