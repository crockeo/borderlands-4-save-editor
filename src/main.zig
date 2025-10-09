const std = @import("std");

const aes = @import("./aes.zig");
const base85 = @import("./base85.zig");
const bitpack = @import("./bitpack.zig");
const yaml = @import("./yaml.zig");
const zlib = @import("./zlib.zig");

// See if I need to anything special with padding:
//
// From mi5hmash at https://fearlessrevolution.com/viewtopic.php?p=423888&sid=fe45d064352f93da1eade5a3bb791cda#p423888
//
// > Borderlands 4 Save Files are in YAML format.
// > First, they are compressed using zlib, followed by an Adler32 checksum of the uncompressed file and the length of the uncompressed file in bytes.
// > After that, PKCS7 padding is added, and the compressed file is encrypted with AES-ECB using the key below, xor'ed with the SteamID or EpicID to make it unique for each user:

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

    const backpack = (value
        .mapping.get("state").?
        .mapping.get("inventory").?
        .mapping.get("items").?
        .mapping.get("backpack").?
        .mapping);
    var iter = backpack.iterator();
    while (iter.next()) |pair| {
        const serial = pair.value_ptr.mapping.get("serial").?.scalar;
        var serial_no_prefix = serial;
        if (serial_no_prefix.len >= 3 and std.mem.eql(u8, "@Ug", serial_no_prefix[0..3])) {
            serial_no_prefix = serial_no_prefix[3..];
        }
        const decoded_serial = try bitpack.bit_pack_decode(allocator, serial_no_prefix);
        defer allocator.free(decoded_serial);
        std.debug.print("{x}\n", .{decoded_serial});
    }

    // TODO: enable roundtrip, when needed
    // {
    //     var emitter = yaml.Emitter.init();
    //     defer emitter.deinit();
    //
    //     var stdout_buf: [1024]u8 = undefined;
    //     var writer = std.fs.File.stdout().writer(&stdout_buf);
    //     try emitter.emit(&writer.interface, value);
    //     try writer.interface.flush();
    // }
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
    _ = bitpack;
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
