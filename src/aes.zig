const std = @import("std");
const c = @cImport({
    @cInclude("openssl/aes.h");
});

pub const AesEcb = struct {
    const Self = @This();

    decrypt_key: c.AES_KEY,
    encrypt_key: c.AES_KEY,

    pub fn init(key: [32]u8) Self {
        var self = Self{
            .decrypt_key = undefined,
            .encrypt_key = undefined,
        };
        _ = c.AES_set_decrypt_key(&key, 256, &self.decrypt_key);
        _ = c.AES_set_encrypt_key(&key, 256, &self.encrypt_key);
        return self;
    }

    pub fn decrypt_block(self: *const Self, in: *const [16]u8, out: *[16]u8) void {
        c.AES_decrypt(in.ptr, out.ptr, &self.decrypt_key);
    }

    pub fn decrypt(self: *const Self, allocator: std.mem.Allocator, in: []const u8) ![]const u8 {
        if (in.len % 16 != 0) {
            return error.InvalidLayout;
        }

        var out = try allocator.alloc(u8, in.len);
        errdefer allocator.free(out);

        for (0..in.len / 16) |i| {
            const in_chunk: *const [16]u8 = in[i * 16 ..][0..16];
            const out_chunk: *[16]u8 = out[i * 16 ..][0..16];
            self.decrypt_block(in_chunk, out_chunk);
        }

        return out;
    }

    pub fn encrypt_block(self: *const Self, in: *const [16]u8, out: *[16]u8) void {
        c.AES_encrypt(in.ptr, out.ptr, &self.encrypt_key);
    }

    pub fn encrypt(self: *const Self, allocator: std.mem.Allocator, in: []const u8) ![]const u8 {
        if (in.len % 16 != 0) {
            return error.InvalidLayout;
        }

        var out = try allocator.alloc(u8, in.len);
        errdefer allocator.free(out);

        for (0..in.len / 16) |i| {
            const in_chunk: *const [16]u8 = in[i * 16 ..][0..16];
            const out_chunk: *[16]u8 = out[i * 16 ..][0..16];
            self.encrypt_block(in_chunk, out_chunk);
        }

        return out;
    }
};
