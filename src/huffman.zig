//! Canonical Huffman codes as DEFLATE uses them (RFC 1951, section 3.2.2):
//! decoding tables built from code lengths, and length-limited codes built
//! from symbol frequencies.

const std = @import("std");

pub const max_bits = 15;

pub const BuildError = error{ OversubscribedCode, IncompleteCode };

/// Which code a table is for. The code-length code must be complete; the
/// literal/length and distance codes may also be a single one-bit code (the
/// rule zlib follows), and any code may be empty.
pub const Kind = enum { code_lengths, literals, distances };

/// A decoding table indexed directly by the next `bits` input bits. DEFLATE
/// packs Huffman codes most significant bit first into an LSB-first bit
/// stream, so each code is stored bit-reversed, in every entry whose low bits
/// match it. Entry = symbol << 4 | code length; length 0 means no code.
pub const Decoder = struct {
    table: [1 << max_bits]u16 = undefined,
    bits: u5 = 1,

    pub fn build(self: *Decoder, lengths: []const u8, kind: Kind) BuildError!void {
        var count: [max_bits + 1]u16 = @splat(0);
        for (lengths) |l| count[l] += 1;
        count[0] = 0;
        var left: i32 = 1; // codes still free at the current length
        var longest: u5 = 0;
        for (1..max_bits + 1) |len| {
            left = (left << 1) - count[len];
            if (left < 0) return error.OversubscribedCode;
            if (count[len] != 0) longest = @intCast(len);
        }
        if (left > 0 and longest != 0 and (kind == .code_lengths or longest != 1)) return error.IncompleteCode;

        self.bits = @max(longest, 1);
        const size = @as(usize, 1) << self.bits;
        @memset(self.table[0..size], 0);
        var next = firstCodes(&count);
        for (lengths, 0..) |l, sym| {
            if (l == 0) continue;
            const rev = reverse(next[l], l);
            next[l] += 1;
            var i: usize = rev;
            while (i < size) : (i += @as(usize, 1) << @intCast(l)) {
                self.table[i] = @intCast((sym << 4) | l);
            }
        }
    }
};

/// The first canonical code of each length (RFC 1951, step 2).
fn firstCodes(count: *const [max_bits + 1]u16) [max_bits + 1]u16 {
    var next: [max_bits + 1]u16 = @splat(0);
    var code: u16 = 0;
    for (1..max_bits + 1) |len| {
        code = (code + count[len - 1]) << 1;
        next[len] = code;
    }
    return next;
}

pub fn reverse(code: u16, len: u8) u16 {
    return @bitReverse(code) >> @intCast(16 - @as(u16, len));
}

/// Code lengths for an encoder. Huffman's algorithm gives optimal lengths;
/// lengths over `limit` are then cut to the limit and the code is repaired as
/// zlib does, by moving leaves down from shallower levels until the Kraft sum
/// is exactly 1 again. DEFLATE needs at least two codes, so with fewer than
/// two used symbols the first unused ones are added with weight 1.
pub fn lengthsFromFrequencies(freqs: []const u32, limit: u4, lengths: []u8) void {
    const max_syms = 320;
    std.debug.assert(freqs.len == lengths.len and freqs.len <= max_syms and freqs.len >= 2);
    @memset(lengths, 0);
    const Leaf = struct { w: u64, s: u16 };
    var leaves: [max_syms]Leaf = undefined;
    var n: usize = 0;
    for (freqs, 0..) |f, s| {
        if (f == 0) continue;
        leaves[n] = .{ .w = f, .s = @intCast(s) };
        n += 1;
    }
    var pad: u16 = 0;
    while (n < 2) : (pad += 1) {
        if (freqs[pad] != 0) continue;
        leaves[n] = .{ .w = 1, .s = pad };
        n += 1;
    }
    // Leaves sorted by weight (ties by symbol). Huffman's merges then come out
    // in non-decreasing weight order, so two queues replace a heap: the
    // sorted leaves, and the internal nodes in the order they are created.
    std.mem.sort(Leaf, leaves[0..n], {}, struct {
        fn lessThan(_: void, a: Leaf, b: Leaf) bool {
            return a.w < b.w or (a.w == b.w and a.s < b.s);
        }
    }.lessThan);
    // Nodes 0..n-1 are the leaves, n..2n-2 the internal nodes; the root is last.
    var weight: [2 * max_syms]u64 = undefined;
    var parent: [2 * max_syms]u16 = undefined;
    for (0..n) |i| weight[i] = leaves[i].w;
    var leaf: usize = 0; // next unmerged leaf
    var inner: usize = n; // next unmerged internal node
    var next: usize = n; // next internal node to create
    while (next < 2 * n - 1) : (next += 1) {
        var pick: [2]usize = undefined;
        for (&pick) |*p| {
            if (leaf < n and (inner >= next or weight[leaf] <= weight[inner])) {
                p.* = leaf;
                leaf += 1;
            } else {
                p.* = inner;
                inner += 1;
            }
        }
        weight[next] = weight[pick[0]] + weight[pick[1]];
        parent[pick[0]] = @intCast(next);
        parent[pick[1]] = @intCast(next);
    }
    // Every parent comes after its children, so depths fill in from the root.
    var depth: [2 * max_syms]u16 = undefined;
    depth[2 * n - 2] = 0;
    var k: usize = 2 * n - 2;
    while (k > 0) {
        k -= 1;
        depth[k] = depth[parent[k]] + 1;
    }
    var bl_count: [max_syms]u32 = @splat(0);
    for (0..n) |i| bl_count[depth[i]] += 1;

    // Cut to the limit. In units where a leaf at the limit counts 1, the
    // Kraft sum must be 2^limit; each repair step moves the deepest leaf
    // above the limit down one level and gives it a leaf from the limit as
    // its sibling, which lowers the sum by exactly 1.
    var d: usize = max_syms - 1;
    while (d > limit) : (d -= 1) {
        bl_count[limit] += bl_count[d];
        bl_count[d] = 0;
    }
    var excess: i64 = -(@as(i64, 1) << limit);
    for (1..@as(usize, limit) + 1) |len| excess += @as(i64, bl_count[len]) << @intCast(limit - len);
    while (excess > 0) : (excess -= 1) {
        var bits: usize = limit - 1;
        while (bl_count[bits] == 0) bits -= 1;
        bl_count[bits] -= 1;
        bl_count[bits + 1] += 2;
        bl_count[limit] -= 1;
    }
    // The longest codes go to the least frequent symbols.
    var i: usize = 0;
    var len: usize = limit;
    while (len > 0) : (len -= 1) {
        for (0..bl_count[len]) |_| {
            lengths[leaves[i].s] = @intCast(len);
            i += 1;
        }
    }
}

/// Canonical codes for the given lengths, bit-reversed for an LSB-first writer.
pub fn codesFromLengths(lengths: []const u8, codes: []u16) void {
    var count: [max_bits + 1]u16 = @splat(0);
    for (lengths) |l| count[l] += 1;
    count[0] = 0;
    var next = firstCodes(&count);
    for (lengths, 0..) |l, s| {
        if (l == 0) continue;
        codes[s] = reverse(next[l], l);
        next[l] += 1;
    }
}

fn kraftIsOne(lengths: []const u8) bool {
    var sum: u64 = 0;
    for (lengths) |l| {
        if (l != 0) sum += @as(u64, 1) << @intCast(max_bits - l);
    }
    return sum == 1 << max_bits;
}

test "Huffman lengths respect the limit and form a complete prefix code" {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var freqs: [286]u32 = undefined;
    var lengths: [286]u8 = undefined;
    var dec: Decoder = .{};
    var limited: usize = 0;
    for (0..300) |trial| {
        // Frequencies spread over many powers of two make deep trees, so the
        // length limit is exercised as well as the ordinary case.
        const spread: u5 = @intCast(1 + trial % 31);
        for (&freqs) |*f| {
            f.* = if (r.uintLessThan(u32, 4) == 0) 0 else @as(u32, 1) << r.uintLessThan(u5, spread);
        }
        if (trial % 50 == 0) @memset(freqs[1..], 0); // a single used symbol
        lengthsFromFrequencies(&freqs, 15, &lengths);
        var longest: u8 = 0;
        for (lengths, freqs) |l, f| {
            try std.testing.expect(l <= 15);
            if (f != 0) try std.testing.expect(l != 0);
            longest = @max(longest, l);
        }
        if (longest == 15) limited += 1;
        try std.testing.expect(kraftIsOne(&lengths));
        try dec.build(&lengths, .code_lengths);
    }
    try std.testing.expect(limited > 10);
}

test "Huffman lengths are optimal when no limit applies" {
    // Frequencies 1, 1, 2, 4, 8: the optimal code has lengths 4, 4, 3, 2, 1.
    const freqs = [_]u32{ 1, 1, 2, 4, 8 };
    var lengths: [5]u8 = undefined;
    lengthsFromFrequencies(&freqs, 15, &lengths);
    try std.testing.expectEqualSlices(u8, &.{ 4, 4, 3, 2, 1 }, &lengths);
    // With a limit of 3 the same frequencies need a complete code of depth 3.
    lengthsFromFrequencies(&freqs, 3, &lengths);
    try std.testing.expect(kraftIsOne(&lengths));
    for (lengths) |l| try std.testing.expect(l >= 1 and l <= 3);
}

test "decoder rejects over-subscribed and incomplete codes" {
    var dec: Decoder = .{};
    try std.testing.expectError(error.OversubscribedCode, dec.build(&.{ 1, 1, 1 }, .literals));
    try std.testing.expectError(error.IncompleteCode, dec.build(&.{ 1, 2 }, .literals));
    // A single one-bit code is allowed for distances, not for code lengths.
    try dec.build(&.{ 0, 1, 0 }, .distances);
    try std.testing.expectError(error.IncompleteCode, dec.build(&.{ 0, 1, 0 }, .code_lengths));
    try dec.build(&.{ 0, 0, 0 }, .distances); // empty: allowed, any symbol then fails
    try dec.build(&.{ 2, 1, 3, 3 }, .code_lengths);
}

test "canonical codes follow RFC 1951's example" {
    // Section 3.2.2: lengths (3, 3, 3, 3, 3, 2, 4, 4) give the codes
    // 010, 011, 100, 101, 110, 00, 1110, 1111.
    const lengths = [_]u8{ 3, 3, 3, 3, 3, 2, 4, 4 };
    const expected = [_]u16{ 0b010, 0b011, 0b100, 0b101, 0b110, 0b00, 0b1110, 0b1111 };
    var codes: [8]u16 = undefined;
    codesFromLengths(&lengths, &codes);
    for (codes, expected, lengths) |c, e, l| try std.testing.expectEqual(reverse(e, l), c);
}
