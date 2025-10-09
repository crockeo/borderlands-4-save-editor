const std = @import("std");

const CHARSET: [85]u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=!$%&*()[]{}~`^_<>?#;".*;
var CHAR_MAP: [256]i8 = undefined;
var CHAR_MAP_INIT = false;

fn get_char_map() *const [256]i8 {
    if (CHAR_MAP_INIT) {
        return &CHAR_MAP;
    }
    for (0..256) |i| CHAR_MAP[i] = -1;
    for (0.., &CHARSET) |i, char| {
        CHAR_MAP[char] = @intCast(i);
    }
    CHAR_MAP_INIT = true;
    return &CHAR_MAP;
}

pub fn bit_pack_decode(allocator: std.mem.Allocator, serial: []const u8) ![]u8 {
    const char_map = get_char_map();
    const payload = blk: {
        if (serial.len >= 3 and std.mem.eql(u8, "@Ug", serial[0..3])) {
            break :blk serial[3..];
        }
        break :blk serial;
    };

    const num_valid_chars = blk: {
        var num_valid_chars: usize = 0;
        for (payload) |char| {
            if (char_map[char] >= 0) {
                num_valid_chars += 1;
            }
        }
        break :blk num_valid_chars;
    };

    const byte_count = blk: {
        const bit_count = num_valid_chars * 6;
        var byte_count = bit_count / 8;
        if (bit_count % 8 != 0) {
            byte_count += 1;
        }
        break :blk byte_count;
    };

    var result = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(result);
    @memset(result, 0);

    var bit_offset: usize = 0;
    for (payload) |char| {
        if (char_map[char] < 0) {
            continue;
        }
        const value: u8 = @intCast(char_map[char]);
        const byte_index = bit_offset / 8;
        const bit_position: u3 = @intCast(bit_offset % 8);

        switch (bit_position) {
            0 => {
                result[byte_index] |= (value & 0b111111) << 2;
            },
            2 => {
                result[byte_index] |= value & 0b111111;
            },
            4 => {
                result[byte_index] |= (value & 0b111100) >> 2;
                if (result.len > byte_index + 1) {
                    result[byte_index + 1] |= (value & 0b11) << 6;
                }
            },
            6 => {
                result[byte_index] |= (value & 0b110000) >> 4;
                if (result.len > byte_index + 1) {
                    result[byte_index + 1] |= (value & 0b1111) << 4;
                }
            },
            else => {
                return error.InvalidEncoding;
            },
        }

        bit_offset += 6;
    }
    return result;
}

test "bitpack_simple" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const result = try bit_pack_decode(allocator, "A");
    defer allocator.free(result);

    try std.testing.expectEqual(result[0], 0);
}

test "bitpack_double" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const result = try bit_pack_decode(allocator, "BA");
    defer allocator.free(result);

    try std.testing.expectEqual(0b00000100, result[0]);
    try std.testing.expectEqual(0b00000000, result[1]);
}

test "bitpack_complicated" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const result = try bit_pack_decode(allocator, "BBBB");
    defer allocator.free(result);

    try std.testing.expectEqual(0b00000100, result[0]);
    try std.testing.expectEqual(0b00010000, result[1]);
    try std.testing.expectEqual(0b01000001, result[2]);
}

test "bitpack_generated" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const result = try bit_pack_decode(allocator, "^Ig0S(");
    defer allocator.free(result);

    const expected_bytes = [_]u8{
        0b00111000,
        0b10001000,
        0b00110100,
        0b01001000,
        0b01100000,
    };
    try std.testing.expectEqualSlices(u8, &expected_bytes, result);
}
