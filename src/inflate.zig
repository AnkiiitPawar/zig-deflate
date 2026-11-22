//! Decompression of raw DEFLATE data (RFC 1951).

const std = @import("std");
const huffman = @import("huffman.zig");
const format = @import("format.zig");

pub const Error = error{
    UnexpectedEndOfInput,
    InvalidBlockType,
    StoredLengthMismatch,
    TooManyCodes,
    InvalidCodeLengthRepeat,
    MissingEndOfBlock,
    InvalidSymbol,
    DistanceTooFarBack,
    OversubscribedCode,
    IncompleteCode,
    OutOfMemory,
};

/// Reads bits least significant first. The buffer is refilled eight bytes at
/// a time while at least eight remain; bits above `count` are then the next
/// input bits (or zero past the end), which is what a table lookup wants.
const BitReader = struct {
    data: []const u8,
    pos: usize = 0, // next byte not yet in `buf`
    buf: u64 = 0,
    count: u32 = 0, // valid bits in `buf`

    fn refill(r: *BitReader) void {
        if (r.pos + 8 <= r.data.len) {
            const word = std.mem.readInt(u64, r.data[r.pos..][0..8], .little);
            r.buf |= word << @intCast(r.count);
            const take = (63 - r.count) >> 3;
            r.pos += take;
            r.count += take << 3;
        } else {
            while (r.count <= 56 and r.pos < r.data.len) : (r.pos += 1) {
                r.buf |= @as(u64, r.data[r.pos]) << @intCast(r.count);
                r.count += 8;
            }
        }
    }

    fn bits(r: *BitReader, n: u32) Error!u32 {
        if (r.count < n) {
            r.refill();
            if (r.count < n) return error.UnexpectedEndOfInput;
        }
        const v: u32 = @truncate(r.buf & ((@as(u64, 1) << @intCast(n)) - 1));
        r.buf >>= @intCast(n);
        r.count -= n;
        return v;
    }

    fn decode(r: *BitReader, d: *const huffman.Decoder) Error!u16 {
        if (r.count < d.bits) r.refill();
        const entry = d.table[@intCast(r.buf & ((@as(u64, 1) << d.bits) - 1))];
        const len: u32 = entry & 15;
        if (len == 0) return if (r.count < d.bits) error.UnexpectedEndOfInput else error.InvalidSymbol;
        if (len > r.count) return error.UnexpectedEndOfInput;
        r.buf >>= @intCast(len);
        r.count -= len;
        return entry >> 4;
    }

    /// Input bytes used so far; a partly used byte counts as used.
    fn consumed(r: *const BitReader) usize {
        return r.pos - r.count / 8;
    }
};

const Tables = struct {
    lit: huffman.Decoder = .{},
    dist: huffman.Decoder = .{},
    lengths: huffman.Decoder = .{},
};

/// Decompresses the DEFLATE stream at the start of `input`, appending the
/// data to `out`. Returns the number of input bytes the stream occupied, so a
/// container can find its trailer. Back-references cannot reach data that
/// was in `out` before the call.
pub fn inflate(gpa: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) Error!usize {
    const t = try gpa.create(Tables);
    defer gpa.destroy(t);
    var r: BitReader = .{ .data = input };
    const start = out.items.len;
    while (true) {
        const header = try r.bits(3);
        switch (header >> 1) {
            0 => try stored(&r, gpa, out),
            1 => {
                try t.lit.build(&format.fixed_lit_lengths, .literals);
                try t.dist.build(&format.fixed_dist_lengths, .distances);
                try codes(&r, gpa, out, start, &t.lit, &t.dist);
            },
            2 => {
                try dynamicTables(&r, t);
                try codes(&r, gpa, out, start, &t.lit, &t.dist);
            },
            else => return error.InvalidBlockType,
        }
        if (header & 1 != 0) return r.consumed();
    }
}

fn stored(r: *BitReader, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    r.buf >>= @intCast(r.count % 8);
    r.count -= r.count % 8;
    const len = try r.bits(16);
    const nlen = try r.bits(16);
    if (len != ~nlen & 0xffff) return error.StoredLengthMismatch;
    try out.ensureUnusedCapacity(gpa, len);
    var n: usize = len;
    while (n > 0 and r.count >= 8) : (n -= 1) {
        out.appendAssumeCapacity(@truncate(r.buf));
        r.buf >>= 8;
        r.count -= 8;
    }
    if (n == 0) return;
    // The bit buffer is empty, but may hold look-ahead bits of bytes that are
    // about to be copied directly: drop them.
    r.buf = 0;
    if (r.data.len - r.pos < n) return error.UnexpectedEndOfInput;
    out.appendSliceAssumeCapacity(r.data[r.pos..][0..n]);
    r.pos += n;
}

fn dynamicTables(r: *BitReader, t: *Tables) Error!void {
    const hlit = try r.bits(5) + 257;
    const hdist = try r.bits(5) + 1;
    const hclen = try r.bits(4) + 4;
    if (hlit > 286 or hdist > 30) return error.TooManyCodes;
    var cl: [19]u8 = @splat(0);
    for (format.code_length_order[0..hclen]) |sym| cl[sym] = @intCast(try r.bits(3));
    try t.lengths.build(&cl, .code_lengths);

    // Literal/length and distance code lengths form one sequence: a run may
    // cross from one to the other.
    var lengths: [286 + 30]u8 = undefined;
    const total = hlit + hdist;
    var i: usize = 0;
    while (i < total) {
        const sym = try r.decode(&t.lengths);
        if (sym < 16) {
            lengths[i] = @intCast(sym);
            i += 1;
            continue;
        }
        var value: u8 = 0;
        const run: usize = switch (sym) {
            16 => blk: {
                if (i == 0) return error.InvalidCodeLengthRepeat;
                value = lengths[i - 1];
                break :blk 3 + try r.bits(2);
            },
            17 => 3 + try r.bits(3),
            18 => 11 + try r.bits(7),
            else => return error.InvalidSymbol,
        };
        if (i + run > total) return error.InvalidCodeLengthRepeat;
        @memset(lengths[i..][0..run], value);
        i += run;
    }
    if (lengths[format.end_of_block] == 0) return error.MissingEndOfBlock;
    try t.lit.build(lengths[0..hlit], .literals);
    try t.dist.build(lengths[hlit..total], .distances);
}

fn codes(
    r: *BitReader,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    start: usize,
    lit: *const huffman.Decoder,
    dist: *const huffman.Decoder,
) Error!void {
    while (true) {
        const sym = try r.decode(lit);
        if (sym < 256) {
            try out.append(gpa, @intCast(sym));
            continue;
        }
        if (sym == format.end_of_block) return;
        if (sym > 285) return error.InvalidSymbol;
        const ls = sym - 257;
        const length: usize = format.length_base[ls] + try r.bits(format.length_extra[ls]);
        const ds = try r.decode(dist);
        if (ds > 29) return error.InvalidSymbol;
        const distance: usize = format.dist_base[ds] + try r.bits(format.dist_extra[ds]);
        if (distance > out.items.len - start) return error.DistanceTooFarBack;
        try out.ensureUnusedCapacity(gpa, length);
        const from = out.items.len - distance;
        if (distance >= length) {
            // No overlap: one block copy.
            out.appendSliceAssumeCapacity(out.items[from..][0..length]);
        } else {
            // The copy reads bytes it has just written (a run).
            for (0..length) |k| out.appendAssumeCapacity(out.items[from + k]);
        }
    }
}

test "inflate a stored block" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // BFINAL = 1, BTYPE = 00, then LEN = 5, NLEN = ~5 and the bytes.
    const stream = [_]u8{ 0x01, 0x05, 0x00, 0xfa, 0xff, 'h', 'e', 'l', 'l', 'o', 0xaa };
    try std.testing.expectEqual(@as(usize, 10), try inflate(gpa, &stream, &out));
    try std.testing.expectEqualStrings("hello", out.items);
}

test "inflate fixed and dynamic blocks made by zlib" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // zlib.compress(b"hello hello hello hello", 9)[2:-4]: one fixed block
    // with a back-reference that overlaps itself (length 18, distance 6).
    const fixed = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x27, 0x01 };
    _ = try inflate(gpa, &fixed, &out);
    try std.testing.expectEqualStrings("hello hello hello hello", out.items);
}

test "inflate rejects malformed streams" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const cases = .{
        .{ [_]u8{0x07}, error.InvalidBlockType }, // BTYPE = 11
        .{ [_]u8{ 0x01, 0x05, 0x00, 0xfb, 0xff }, error.StoredLengthMismatch },
        .{ [_]u8{ 0x01, 0x05, 0x00, 0xfa, 0xff, 'h' }, error.UnexpectedEndOfInput },
        .{ [_]u8{}, error.UnexpectedEndOfInput },
        // Fixed block whose first symbol is a match: nothing to copy from.
        .{ [_]u8{ 0x03, 0x02 }, error.DistanceTooFarBack },
    };
    inline for (cases) |c| {
        out.clearRetainingCapacity();
        const input = c[0];
        try std.testing.expectError(c[1], inflate(gpa, &input, &out));
    }
}
