//! The zlib (RFC 1950) and gzip (RFC 1952) formats around raw DEFLATE.

const std = @import("std");
const deflate = @import("deflate.zig");
const inflate = @import("inflate.zig");
const checksum = @import("checksum.zig");

pub const Format = enum { raw, zlib, gzip };

pub const CompressError = deflate.Error;

pub const DecompressError = inflate.Error || error{
    BadHeader,
    UnsupportedMethod,
    PresetDictionary,
    ChecksumMismatch,
    LengthMismatch,
    TrailingData,
};

/// Compresses `data` at `level` (0-9) and returns the stream; the caller owns it.
pub fn compress(gpa: std.mem.Allocator, data: []const u8, format: Format, level: u4, stats: ?*deflate.Stats) CompressError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (format) {
        .raw => try deflate.compress(gpa, data, level, &out, stats),
        .zlib => {
            // CMF: method 8 (deflate), 32 KiB window. FLG: the level hint in
            // the top two bits (as zlib sets it), then a check value that
            // makes the 16-bit header a multiple of 31.
            const cmf: u8 = 0x78;
            const hint: u8 = if (level < 2) 0 else if (level < 6) 1 else if (level == 6) 2 else 3;
            var flg: u8 = hint << 6;
            flg += @intCast((31 - (@as(u16, cmf) << 8 | flg) % 31) % 31);
            try out.appendSlice(gpa, &.{ cmf, flg });
            try deflate.compress(gpa, data, level, &out, stats);
            var trailer: [4]u8 = undefined;
            std.mem.writeInt(u32, &trailer, checksum.adler32(data), .big);
            try out.appendSlice(gpa, &trailer);
        },
        .gzip => {
            // No name or timestamp; XFL as gzip sets it for levels 9 and 1;
            // OS 255 = unknown.
            const xfl: u8 = if (level == 9) 2 else if (level == 1) 4 else 0;
            try out.appendSlice(gpa, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, xfl, 255 });
            try deflate.compress(gpa, data, level, &out, stats);
            var trailer: [8]u8 = undefined;
            std.mem.writeInt(u32, trailer[0..4], checksum.crc32(data), .little);
            std.mem.writeInt(u32, trailer[4..8], @truncate(data.len), .little);
            try out.appendSlice(gpa, &trailer);
        },
    }
    return out.toOwnedSlice(gpa);
}

/// Decompresses a whole stream and returns the data; the caller owns it.
/// gzip input may hold several members, which are concatenated, and zero
/// padding after them.
pub fn decompress(gpa: std.mem.Allocator, data: []const u8, format: Format) DecompressError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (format) {
        .raw => {
            const used = try inflate.inflate(gpa, data, &out);
            if (used != data.len) return error.TrailingData;
        },
        .zlib => {
            if (data.len < 2) return error.UnexpectedEndOfInput;
            const cmf = data[0];
            const flg = data[1];
            if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return error.BadHeader;
            if (cmf & 15 != 8 or cmf >> 4 > 7) return error.UnsupportedMethod;
            if (flg & 0x20 != 0) return error.PresetDictionary;
            const end = 2 + try inflate.inflate(gpa, data[2..], &out);
            if (data.len < end + 4) return error.UnexpectedEndOfInput;
            if (std.mem.readInt(u32, data[end..][0..4], .big) != checksum.adler32(out.items)) return error.ChecksumMismatch;
            if (data.len > end + 4) return error.TrailingData;
        },
        .gzip => {
            var pos: usize = 0;
            while (true) {
                pos += try gzipMember(gpa, data[pos..], &out);
                while (pos < data.len and data[pos] == 0) pos += 1;
                if (pos == data.len) break;
            }
        },
    }
    return out.toOwnedSlice(gpa);
}

fn gzipMember(gpa: std.mem.Allocator, data: []const u8, out: *std.ArrayList(u8)) DecompressError!usize {
    if (data.len < 10) return error.UnexpectedEndOfInput;
    if (data[0] != 0x1f or data[1] != 0x8b) return error.BadHeader;
    if (data[2] != 8) return error.UnsupportedMethod;
    const flg = data[3];
    if (flg & 0xe0 != 0) return error.BadHeader; // reserved bits
    var pos: usize = 10;
    if (flg & 4 != 0) { // FEXTRA
        if (data.len < pos + 2) return error.UnexpectedEndOfInput;
        pos += 2 + @as(usize, std.mem.readInt(u16, data[pos..][0..2], .little));
        if (pos > data.len) return error.UnexpectedEndOfInput;
    }
    for ([_]u8{ 8, 16 }) |bit| { // FNAME, FCOMMENT: zero-terminated
        if (flg & bit == 0) continue;
        const zero = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse return error.UnexpectedEndOfInput;
        pos = zero + 1;
    }
    if (flg & 2 != 0) { // FHCRC: the low 16 bits of the header's CRC-32
        if (data.len < pos + 2) return error.UnexpectedEndOfInput;
        const crc16: u16 = @truncate(checksum.crc32(data[0..pos]));
        if (std.mem.readInt(u16, data[pos..][0..2], .little) != crc16) return error.ChecksumMismatch;
        pos += 2;
    }
    const start = out.items.len;
    pos += try inflate.inflate(gpa, data[pos..], out);
    if (data.len < pos + 8) return error.UnexpectedEndOfInput;
    const member = out.items[start..];
    if (std.mem.readInt(u32, data[pos..][0..4], .little) != checksum.crc32(member)) return error.ChecksumMismatch;
    if (std.mem.readInt(u32, data[pos + 4 ..][0..4], .little) != @as(u32, @truncate(member.len))) return error.LengthMismatch;
    return pos + 8;
}

test "zlib header bytes match zlib's for each level" {
    const gpa = std.testing.allocator;
    const expected = [_][2]u8{ .{ 0x78, 0x01 }, .{ 0x78, 0x01 }, .{ 0x78, 0x5e }, .{ 0x78, 0x5e }, .{ 0x78, 0x5e }, .{ 0x78, 0x5e }, .{ 0x78, 0x9c }, .{ 0x78, 0xda }, .{ 0x78, 0xda }, .{ 0x78, 0xda } };
    for (expected, 0..) |e, level| {
        const z = try compress(gpa, "abc", .zlib, @intCast(level), null);
        defer gpa.free(z);
        try std.testing.expectEqualSlices(u8, &e, z[0..2]);
    }
}

test "gzip with header fields, two members and padding" {
    const gpa = std.testing.allocator;
    // Member 1 has FNAME, FCOMMENT, FEXTRA and FHCRC set, built by hand
    // around a stored block holding "abc".
    var m1: std.ArrayList(u8) = .empty;
    defer m1.deinit(gpa);
    try m1.appendSlice(gpa, &.{ 0x1f, 0x8b, 8, 4 | 8 | 16 | 2, 0, 0, 0, 0, 0, 3 });
    try m1.appendSlice(gpa, &.{ 3, 0, 'x', 'y', 'z' }); // XLEN = 3
    try m1.appendSlice(gpa, "name\x00comment\x00");
    var hcrc: [2]u8 = undefined;
    std.mem.writeInt(u16, &hcrc, @truncate(checksum.crc32(m1.items)), .little);
    try m1.appendSlice(gpa, &hcrc);
    try m1.appendSlice(gpa, &.{ 1, 3, 0, 0xfc, 0xff, 'a', 'b', 'c' });
    var tr: [8]u8 = undefined;
    std.mem.writeInt(u32, tr[0..4], checksum.crc32("abc"), .little);
    std.mem.writeInt(u32, tr[4..8], 3, .little);
    try m1.appendSlice(gpa, &tr);
    const m2 = try compress(gpa, "defdefdef", .gzip, 6, null);
    defer gpa.free(m2);
    const both = try std.mem.concat(gpa, u8, &.{ m1.items, m2, &.{ 0, 0, 0 } });
    defer gpa.free(both);
    const plain = try decompress(gpa, both, .gzip);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("abcdefdefdef", plain);

    // A flipped bit in the data must fail the CRC.
    both[m1.items.len - 9] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decompress(gpa, both, .gzip));
}

test "zlib checks the header, the dictionary flag and the Adler-32" {
    const gpa = std.testing.allocator;
    const z = try compress(gpa, "hello, hello, hello", .zlib, 6, null);
    defer gpa.free(z);
    const plain = try decompress(gpa, z, .zlib);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("hello, hello, hello", plain);
    z[z.len - 1] ^= 0x40;
    try std.testing.expectError(error.ChecksumMismatch, decompress(gpa, z, .zlib));
    try std.testing.expectError(error.BadHeader, decompress(gpa, &.{ 0x78, 0x9d, 3, 0 }, .zlib));
    try std.testing.expectError(error.PresetDictionary, decompress(gpa, &.{ 0x78, 0xbb, 3, 0 }, .zlib));
}
