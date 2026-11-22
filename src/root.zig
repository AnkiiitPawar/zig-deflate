//! DEFLATE compression and decompression with the zlib and gzip formats,
//! written from RFC 1950, 1951 and 1952 with no dependencies beyond the Zig
//! standard library (whose own DEFLATE code is not used).

const std = @import("std");

pub const checksum = @import("checksum.zig");
pub const huffman = @import("huffman.zig");
pub const format = @import("format.zig");
pub const inflate = @import("inflate.zig");
pub const deflate = @import("deflate.zig");
pub const container = @import("container.zig");

pub const Format = container.Format;
pub const Stats = deflate.Stats;
pub const compress = container.compress;
pub const decompress = container.decompress;

test {
    std.testing.refAllDecls(@This());
}

/// Test inputs of different character: incompressible, text-like, long
/// runs, and short repeats at every distance up to the window size.
fn sample(gpa: std.mem.Allocator, kind: usize, len: usize, seed: u64) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const buf = try gpa.alloc(u8, len);
    switch (kind) {
        0 => r.bytes(buf),
        1 => {
            const words = [_][]const u8{ "the ", "lattice ", "of ", "Huffman ", "codes ", "and ", "a ", "window ", "\n" };
            var i: usize = 0;
            while (i < len) {
                const word = words[r.uintLessThan(usize, words.len)];
                const n = @min(word.len, len - i);
                @memcpy(buf[i..][0..n], word[0..n]);
                i += n;
            }
        },
        2 => {
            var i: usize = 0;
            while (i < len) {
                const run = @min(len - i, 1 + r.uintLessThan(usize, 300));
                @memset(buf[i..][0..run], r.uintLessThan(u8, 4));
                i += run;
            }
        },
        else => {
            r.bytes(buf[0..@min(len, 64)]);
            for (@min(len, 64)..len) |i| {
                const back = 1 + r.uintLessThan(usize, @min(i, 32768));
                buf[i] = if (r.uintLessThan(u8, 8) == 0) r.int(u8) else buf[i - back];
            }
        },
    }
    return buf;
}

test "round trip at every level, in every format, for many inputs" {
    const gpa = std.testing.allocator;
    const lengths = [_]usize{ 0, 1, 2, 3, 4, 257, 258, 259, 1000, 65535, 65536, 70000, 200_000 };
    var seed: u64 = 0;
    for (lengths) |len| {
        for (0..4) |kind| {
            seed += 1;
            const data = try sample(gpa, kind, len, seed);
            defer gpa.free(data);
            for (0..10) |level| {
                for ([_]Format{ .raw, .zlib, .gzip }) |f| {
                    // The level is irrelevant to the container; skip some combinations.
                    if (f != .raw and level % 3 != 0) continue;
                    var stats: Stats = .{};
                    const z = try compress(gpa, data, f, @intCast(level), &stats);
                    defer gpa.free(z);
                    const back = try decompress(gpa, z, f);
                    defer gpa.free(back);
                    try std.testing.expectEqualSlices(u8, data, back);
                    if (level == 0) try std.testing.expectEqual(@as(u32, 0), stats.fixed + stats.dynamic);
                }
            }
        }
    }
}

test "random data falls back to stored blocks; text gets dynamic codes" {
    const gpa = std.testing.allocator;
    const noise = try sample(gpa, 0, 100_000, 99);
    defer gpa.free(noise);
    var s1: Stats = .{};
    const z1 = try compress(gpa, noise, .raw, 6, &s1);
    defer gpa.free(z1);
    try std.testing.expect(s1.stored > 0 and s1.dynamic == 0);
    try std.testing.expect(z1.len < noise.len + noise.len / 1000);

    const text = try sample(gpa, 1, 100_000, 7);
    defer gpa.free(text);
    var s2: Stats = .{};
    const z2 = try compress(gpa, text, .raw, 6, &s2);
    defer gpa.free(z2);
    try std.testing.expect(s2.dynamic > 0 and s2.stored == 0);
    try std.testing.expect(z2.len * 3 < text.len);
}

test "higher levels never compress worse on these inputs" {
    const gpa = std.testing.allocator;
    const data = try sample(gpa, 3, 300_000, 5);
    defer gpa.free(data);
    var last: usize = std.math.maxInt(usize);
    for ([_]u4{ 1, 6, 9 }) |level| {
        const z = try compress(gpa, data, .raw, level, null);
        defer gpa.free(z);
        try std.testing.expect(z.len <= last);
        last = z.len;
    }
}

test "every truncation of a valid stream is rejected, never accepted or crashed on" {
    const gpa = std.testing.allocator;
    const data = try sample(gpa, 1, 5000, 3);
    defer gpa.free(data);
    for ([_]Format{ .raw, .zlib, .gzip }) |f| {
        const z = try compress(gpa, data, f, 6, null);
        defer gpa.free(z);
        for (0..z.len) |n| {
            if (decompress(gpa, z[0..n], f)) |back| {
                gpa.free(back);
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }
}

test "random corruption never crashes the decoder" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const data = try sample(gpa, 3, 20_000, 4);
    defer gpa.free(data);
    const z = try compress(gpa, data, .raw, 9, null);
    defer gpa.free(z);
    const copy = try gpa.dupe(u8, z);
    defer gpa.free(copy);
    for (0..3000) |_| {
        @memcpy(copy, z);
        for (0..1 + r.uintLessThan(usize, 4)) |_| copy[r.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << r.int(u3);
        if (decompress(gpa, copy, .raw)) |back| gpa.free(back) else |_| {}
    }
}
