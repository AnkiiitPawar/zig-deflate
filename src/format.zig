//! The constant tables of the DEFLATE format (RFC 1951, section 3.2.5-3.2.7).

/// Literal/length symbols 257..285: base match length and extra bits.
pub const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
pub const length_extra = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

/// Distance symbols 0..29: base distance and extra bits.
pub const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
pub const dist_extra = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// The order in which a dynamic block sends the code-length code's lengths.
pub const code_length_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// The fixed Huffman code of block type 1: 288 literal/length symbols
/// (286 and 287 take part in the code but never occur) and 30 distance
/// symbols of 5 bits (plus 30 and 31, likewise invalid).
pub const fixed_lit_lengths: [288]u8 = blk: {
    var l: [288]u8 = undefined;
    for (0..144) |i| l[i] = 8;
    for (144..256) |i| l[i] = 9;
    for (256..280) |i| l[i] = 7;
    for (280..288) |i| l[i] = 8;
    break :blk l;
};
pub const fixed_dist_lengths: [32]u8 = @splat(5);

pub const max_match = 258;
pub const min_match = 3;
pub const window_size = 1 << 15;
pub const end_of_block = 256;

/// Length symbol (0-based, i.e. symbol - 257) for each match length 0..258.
pub const length_symbol: [259]u8 = blk: {
    var t: [259]u8 = @splat(0);
    for (0..29) |c| {
        const lo = length_base[c];
        const hi = if (c == 28) 259 else lo + (1 << length_extra[c]);
        for (lo..hi) |len| t[len] = c;
    }
    // 258 has its own symbol, 285, although 284 with extra bits 31 also spells it.
    t[258] = 28;
    break :blk t;
};

/// Distance symbol for distance d, via the zlib trick: one table for d - 1
/// below 256, and one indexed by (d - 1) >> 7 above.
const dist_table: [512]u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [512]u8 = @splat(0);
    for (0..30) |c| {
        const lo: usize = dist_base[c] - 1;
        const hi: usize = lo + (1 << dist_extra[c]);
        for (lo..hi) |x| {
            if (x < 256) t[x] = c else t[256 + (x >> 7)] = c;
        }
    }
    break :blk t;
};

pub fn distSymbol(d: u32) u8 {
    const x = d - 1;
    return if (x < 256) dist_table[x] else dist_table[256 + (x >> 7)];
}

const std = @import("std");

test "length and distance symbols invert the base tables" {
    for (3..259) |len| {
        const c = length_symbol[len];
        try std.testing.expect(len >= length_base[c]);
        if (c < 28) try std.testing.expect(len < length_base[c] + (@as(u32, 1) << length_extra[c]));
    }
    try std.testing.expectEqual(@as(u8, 28), length_symbol[258]);
    try std.testing.expectEqual(@as(u8, 27), length_symbol[257]);
    for (1..32769) |d| {
        const c = distSymbol(@intCast(d));
        try std.testing.expect(d >= dist_base[c]);
        try std.testing.expect(d < dist_base[c] + (@as(u32, 1) << dist_extra[c]));
    }
}
