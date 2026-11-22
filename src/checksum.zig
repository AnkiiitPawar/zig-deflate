//! The checksums of the zlib and gzip containers.

const std = @import("std");

/// Adler-32 (RFC 1950): two running sums modulo 65521. The sums are reduced
/// every 5552 bytes, the most that can be added before a u32 overflows.
pub fn adler32(data: []const u8) u32 {
    const base: u32 = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, 5552);
        for (rest[0..n]) |byte| {
            a += byte;
            b += a;
        }
        a %= base;
        b %= base;
        rest = rest[n..];
    }
    return (b << 16) | a;
}

/// CRC-32 as gzip uses it (RFC 1952): reflected, polynomial 0xEDB88320,
/// initial and final value 0xFFFFFFFF.
pub fn crc32(data: []const u8) u32 {
    return crc32Update(0, data);
}

pub fn crc32Update(crc: u32, data: []const u8) u32 {
    var c = ~crc;
    for (data) |byte| c = crc_table[@as(u8, @truncate(c)) ^ byte] ^ (c >> 8);
    return ~c;
}

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        t[n] = c;
    }
    break :blk t;
};

test "checksums of known strings" {
    try std.testing.expectEqual(@as(u32, 0x11E60398), adler32("Wikipedia"));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 1), adler32(""));
    try std.testing.expectEqual(@as(u32, 0), crc32(""));
}

test "checksums agree with the standard library on random data" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var buf: [20000]u8 = undefined;
    for ([_]usize{ 0, 1, 5551, 5552, 5553, 20000 }) |n| {
        r.bytes(buf[0..n]);
        try std.testing.expectEqual(std.hash.Adler32.hash(buf[0..n]), adler32(buf[0..n]));
        try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), crc32(buf[0..n]));
    }
}
