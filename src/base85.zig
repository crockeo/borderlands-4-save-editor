const std = @import("std");

const CHARS: [85]u8 = "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstu";

pub fn encode_ascii85(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        // Check for all-zero group
        if (i + 4 <= data.len and
            data[i] == 0 and data[i + 1] == 0 and
            data[i + 2] == 0 and data[i + 3] == 0)
        {
            try result.append(allocator, 'z');
            i += 4;
            continue;
        }

        // Collect up to 4 bytes for a group
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        var group_len: usize = 0;
        while (group_len < 4 and i < data.len) {
            bytes[group_len] = data[i];
            group_len += 1;
            i += 1;
        }

        // Convert 4 bytes to 32-bit value (big-endian)
        var value: u32 = 0;
        for (bytes) |b| {
            value = (value << 8) | b;
        }

        // Convert to 5 base-85 digits
        var digits: [5]u8 = undefined;
        var temp = value;
        var j: usize = 5;
        while (j > 0) {
            j -= 1;
            digits[j] = @intCast(temp % 85);
            temp /= 85;
        }

        // Encode digits as ASCII characters
        const output_len = if (group_len < 4) group_len + 1 else 5;
        for (digits[0..output_len]) |digit| {
            try result.append(allocator, digit + '!');
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn decode_ascii85(allocator: std.mem.Allocator, contents: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < contents.len) {
        // Skip whitespace
        if (std.ascii.isWhitespace(contents[i])) {
            i += 1;
            continue;
        }

        // Handle special 'z' case (all zeros)
        if (contents[i] == 'z') {
            try result.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
            i += 1;
            continue;
        }

        // Collect a group of up to 5 characters
        var group: [5]u8 = .{ 'u', 'u', 'u', 'u', 'u' }; // Default padding
        var group_len: usize = 0;

        while (group_len < 5 and i < contents.len) {
            if (std.ascii.isWhitespace(contents[i])) {
                i += 1;
                continue;
            }
            if (contents[i] == 'z') {
                return error.InvalidEncoding; // z in middle of group
            }
            if (contents[i] < '!' or contents[i] > 'u') {
                return error.InvalidEncoding;
            }
            group[group_len] = contents[i];
            group_len += 1;
            i += 1;
        }

        if (group_len == 0) break;

        // Convert 5 base-85 digits to 32-bit value
        var value: u64 = 0;
        for (group[0..5]) |c| {
            value = value * 85 + (c - '!');
        }

        // Check for overflow
        if (value > 0xFFFFFFFF) {
            return error.InvalidEncoding;
        }

        // Convert 32-bit value to 4 bytes (big-endian)
        const bytes = [_]u8{
            @intCast((value >> 24) & 0xFF),
            @intCast((value >> 16) & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast(value & 0xFF),
        };

        // For incomplete groups, only output the correct number of bytes
        const output_len = if (group_len < 5) group_len - 1 else 4;
        try result.appendSlice(allocator, bytes[0..output_len]);
    }

    return result.toOwnedSlice(allocator);
}

test "base85 encode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const contents = "this is a test";
    const encoded_contents = try encode_ascii85(allocator, contents);
    defer allocator.free(encoded_contents);

    try std.testing.expectEqualStrings("FD,B0+DGm>@3BZ'F*%", encoded_contents);
}

test "base85 decode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const contents = "FD,B0+DGm>@3BZ'F*%";
    const decoded_contents = try decode_ascii85(allocator, contents);
    defer allocator.free(decoded_contents);

    try std.testing.expectEqualStrings("this is a test", decoded_contents);
}

test "base85 roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const contents = "this is a test";

    const encoded_contents = try encode_ascii85(allocator, contents);
    defer allocator.free(encoded_contents);

    const decoded_contents = try decode_ascii85(allocator, encoded_contents);
    defer allocator.free(decoded_contents);

    try std.testing.expectEqualStrings(contents, decoded_contents);
}
