//! DEFLATE compression (RFC 1951). LZ77 matching on hash chains, with zlib's
//! greedy parser for levels 1-3 and its lazy parser for levels 4-9, then
//! Huffman coding: every block is written stored, with the fixed code, or
//! with a dynamic code of its own, whichever is smallest.

const std = @import("std");
const huffman = @import("huffman.zig");
const format = @import("format.zig");

const window = format.window_size;
const hash_bits = 15;
const block_tokens = 1 << 14;
/// A 3-byte match further back than this costs more than three literals.
const too_far = 4096;

const Config = struct { good: u16, lazy: u16, nice: u16, chain: u16 };

/// zlib's configuration_table (deflate.c). For the greedy levels 1-3,
/// `lazy` is instead the longest match whose positions are all added to the
/// hash chains; longer matches are skipped over.
const configs = [10]Config{
    .{ .good = 0, .lazy = 0, .nice = 0, .chain = 0 }, // stored only
    .{ .good = 4, .lazy = 4, .nice = 8, .chain = 4 },
    .{ .good = 4, .lazy = 5, .nice = 16, .chain = 8 },
    .{ .good = 4, .lazy = 6, .nice = 32, .chain = 32 },
    .{ .good = 4, .lazy = 4, .nice = 16, .chain = 16 },
    .{ .good = 8, .lazy = 16, .nice = 32, .chain = 32 },
    .{ .good = 8, .lazy = 16, .nice = 128, .chain = 128 },
    .{ .good = 8, .lazy = 32, .nice = 128, .chain = 256 },
    .{ .good = 32, .lazy = 128, .nice = 258, .chain = 1024 },
    .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
};

/// How many blocks of each type a call wrote.
pub const Stats = struct { stored: u32 = 0, fixed: u32 = 0, dynamic: u32 = 0 };

pub const Error = error{ OutOfMemory, InputTooLarge };

/// Compresses `data` into a raw DEFLATE stream appended to `out`, at a level
/// from 0 (stored blocks only) to 9 (slowest, smallest).
pub fn compress(gpa: std.mem.Allocator, data: []const u8, level: u4, out: *std.ArrayList(u8), stats: ?*Stats) Error!void {
    std.debug.assert(level <= 9);
    // Hash chains store positions + 1 in 32 bits.
    if (data.len >= std.math.maxInt(u32)) return error.InputTooLarge;
    var w: BitWriter = .{ .gpa = gpa, .out = out };
    var local: Stats = .{};
    const s = stats orelse &local;
    if (level == 0) {
        s.stored += try storedBlocks(&w, data, true);
        return w.finish();
    }
    const c = try gpa.create(Compressor);
    defer gpa.destroy(c);
    c.init(data, configs[level], &w, s);
    if (level <= 3) try c.greedy() else try c.lazy();
    try c.flushBlock(true);
    try w.finish();
}

const BitWriter = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    buf: u64 = 0,
    count: u32 = 0, // pending bits in `buf`, always below 32 between calls

    fn put(w: *BitWriter, value: u32, n: u32) error{OutOfMemory}!void {
        w.buf |= @as(u64, value) << @intCast(w.count);
        w.count += n;
        if (w.count >= 32) {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @truncate(w.buf), .little);
            try w.out.appendSlice(w.gpa, &bytes);
            w.buf >>= 32;
            w.count -= 32;
        }
    }

    /// Writes out the pending bits, padding the last byte with zeros.
    fn alignToByte(w: *BitWriter) error{OutOfMemory}!void {
        while (w.count > 0) {
            try w.out.append(w.gpa, @truncate(w.buf));
            w.buf >>= 8;
            w.count -|= 8;
        }
    }

    fn finish(w: *BitWriter) error{OutOfMemory}!void {
        try w.alignToByte();
    }
};

/// Writes `bytes` as stored blocks of at most 65,535 bytes; returns how many.
fn storedBlocks(w: *BitWriter, bytes: []const u8, final: bool) error{OutOfMemory}!u32 {
    var rest = bytes;
    var blocks: u32 = 0;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 65535));
        const last = final and n == rest.len;
        try w.put(@intFromBool(last), 3); // BTYPE 00
        try w.alignToByte();
        var header: [4]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], n, .little);
        std.mem.writeInt(u16, header[2..4], ~n, .little);
        try w.out.appendSlice(w.gpa, &header);
        try w.out.appendSlice(w.gpa, rest[0..n]);
        rest = rest[n..];
        blocks += 1;
        if (rest.len == 0) return blocks;
    }
}

/// Bits that `storedBlocks` would write for n bytes, starting `bit` bits
/// into a byte.
fn storedBits(n: usize, bit: u32) u64 {
    const chunks: u64 = @max(1, (n + 65534) / 65535);
    const first_pad = (8 - (bit + 3) % 8) % 8;
    return 8 * @as(u64, n) + chunks * (3 + 32) + first_pad + (chunks - 1) * 5;
}

const Match = struct { len: usize = 0, dist: usize = 0 };

const Compressor = struct {
    data: []const u8,
    cfg: Config,
    w: *BitWriter,
    stats: *Stats,
    head: [1 << hash_bits]u32, // most recent position + 1 with each hash; 0 = none
    prev: [window]u32, // the previous position + 1 with the same hash
    tokens: [block_tokens]u32, // literal: the byte; match: distance << 16 | length
    ntokens: usize,
    block_start: usize, // first input byte of the current block
    covered: usize, // input bytes covered by tokens so far
    lit_freq: [286]u32,
    dist_freq: [30]u32,
    fixed_lit_code: [288]u16,
    fixed_dist_code: [32]u16,

    fn init(c: *Compressor, data: []const u8, cfg: Config, w: *BitWriter, stats: *Stats) void {
        c.data = data;
        c.cfg = cfg;
        c.w = w;
        c.stats = stats;
        @memset(&c.head, 0);
        @memset(&c.prev, 0);
        c.ntokens = 0;
        c.block_start = 0;
        c.covered = 0;
        @memset(&c.lit_freq, 0);
        @memset(&c.dist_freq, 0);
        huffman.codesFromLengths(&format.fixed_lit_lengths, &c.fixed_lit_code);
        huffman.codesFromLengths(&format.fixed_dist_lengths, &c.fixed_dist_code);
    }

    /// zlib's hash of the three bytes at p (hash_bits = 15, shift 5).
    inline fn hash(c: *const Compressor, p: usize) usize {
        const d = c.data;
        return ((@as(usize, d[p]) << 10) ^ (@as(usize, d[p + 1]) << 5) ^ d[p + 2]) & ((1 << hash_bits) - 1);
    }

    /// Adds position p to its hash chain; returns the previous chain head.
    inline fn insert(c: *Compressor, p: usize) u32 {
        const h = c.hash(p);
        const old = c.head[h];
        c.prev[p & (window - 1)] = old;
        c.head[h] = @intCast(p + 1);
        return old;
    }

    /// The longest match for position `pos` that is longer than `prev_len`,
    /// following the hash chain from `head`. Distances stay below the window
    /// size, so every chain link read is one written for that position.
    fn longestMatch(c: *const Compressor, pos: usize, head: u32, prev_len: usize) Match {
        const d = c.data;
        const max_len = @min(format.max_match, d.len - pos);
        var best: usize = @max(prev_len, format.min_match - 1);
        if (best >= max_len) return .{};
        var best_dist: usize = 0;
        var chain: u32 = c.cfg.chain;
        if (prev_len >= c.cfg.good) chain >>= 2;
        const nice = @min(c.cfg.nice, max_len);
        const limit = if (pos >= window) pos - window + 1 else 0;
        var cand = head;
        while (cand != 0) {
            const m = cand - 1;
            if (m < limit) break;
            // Cheap rejections first: the byte that would make the match
            // longer than the best, then the first two bytes.
            if (d[m + best] == d[pos + best] and d[m] == d[pos] and d[m + 1] == d[pos + 1]) {
                const len = matchLength(d, m, pos, max_len);
                if (len > best) {
                    best = len;
                    best_dist = pos - m;
                    if (len >= nice) break;
                }
            }
            chain -= 1;
            if (chain == 0) break;
            cand = c.prev[m & (window - 1)];
        }
        return if (best_dist == 0) .{} else .{ .len = best, .dist = best_dist };
    }

    /// zlib's deflate_fast: take the longest match at each position.
    fn greedy(c: *Compressor) Error!void {
        const d = c.data;
        var pos: usize = 0;
        while (pos < d.len) {
            var m: Match = .{};
            if (pos + format.min_match <= d.len) {
                const head = c.insert(pos);
                if (head != 0) m = c.longestMatch(pos, head, 0);
            }
            if (m.len >= format.min_match) {
                try c.match(m);
                if (m.len <= c.cfg.lazy) {
                    for (pos + 1..pos + m.len) |p| {
                        if (p + format.min_match <= d.len) _ = c.insert(p);
                    }
                }
                pos += m.len;
            } else {
                try c.literal(d[pos]);
                pos += 1;
            }
        }
    }

    /// zlib's deflate_slow: a match found at one position is emitted only if
    /// the next position does not have a longer one.
    fn lazy(c: *Compressor) Error!void {
        const d = c.data;
        var pos: usize = 0;
        var prev: Match = .{}; // the best match at pos - 1
        var pending = false; // d[pos - 1] has not been emitted yet
        while (pos < d.len) {
            var cur: Match = .{};
            if (pos + format.min_match <= d.len) {
                const head = c.insert(pos);
                if (head != 0 and prev.len < c.cfg.lazy) {
                    cur = c.longestMatch(pos, head, prev.len);
                    if (cur.len == format.min_match and cur.dist > too_far) cur = .{};
                }
            }
            if (prev.len >= format.min_match and cur.len <= prev.len) {
                try c.match(prev);
                const end = pos - 1 + prev.len;
                for (pos + 1..end) |p| {
                    if (p + format.min_match <= d.len) _ = c.insert(p);
                }
                pos = end;
                prev = .{};
                pending = false;
            } else {
                if (pending) try c.literal(d[pos - 1]);
                pending = true;
                prev = cur;
                pos += 1;
            }
        }
        if (pending) try c.literal(d[pos - 1]);
    }

    fn literal(c: *Compressor, byte: u8) Error!void {
        c.tokens[c.ntokens] = byte;
        c.ntokens += 1;
        c.lit_freq[byte] += 1;
        c.covered += 1;
        if (c.ntokens == block_tokens) try c.flushBlock(false);
    }

    fn match(c: *Compressor, m: Match) Error!void {
        c.tokens[c.ntokens] = @intCast(m.dist << 16 | m.len);
        c.ntokens += 1;
        c.lit_freq[257 + @as(usize, format.length_symbol[m.len])] += 1;
        c.dist_freq[format.distSymbol(@intCast(m.dist))] += 1;
        c.covered += m.len;
        if (c.ntokens == block_tokens) try c.flushBlock(false);
    }

    /// Writes the tokens collected so far as one block (or several stored
    /// ones), in the cheapest of the three encodings.
    fn flushBlock(c: *Compressor, final: bool) Error!void {
        c.lit_freq[format.end_of_block] = 1;
        var lit_len: [286]u8 = undefined;
        var dist_len: [30]u8 = undefined;
        huffman.lengthsFromFrequencies(&c.lit_freq, 15, &lit_len);
        huffman.lengthsFromFrequencies(&c.dist_freq, 15, &dist_len);
        var hlit: usize = 286;
        while (hlit > 257 and lit_len[hlit - 1] == 0) hlit -= 1;
        var hdist: usize = 30;
        while (hdist > 1 and dist_len[hdist - 1] == 0) hdist -= 1;

        // The code lengths, run-length coded with symbols 16-18.
        var all: [286 + 30]u8 = undefined;
        @memcpy(all[0..hlit], lit_len[0..hlit]);
        @memcpy(all[hlit..][0..hdist], dist_len[0..hdist]);
        var runs: [286 + 30]Run = undefined;
        var cl_freq: [19]u32 = @splat(0);
        const nruns = runLengths(all[0 .. hlit + hdist], &runs, &cl_freq);
        var cl_len: [19]u8 = undefined;
        huffman.lengthsFromFrequencies(&cl_freq, 7, &cl_len);
        var hclen: usize = 19;
        while (hclen > 4 and cl_len[format.code_length_order[hclen - 1]] == 0) hclen -= 1;

        // Size in bits of each way to write the block.
        var dynamic_bits: u64 = 3 + 5 + 5 + 4 + 3 * hclen;
        for (runs[0..nruns]) |r| dynamic_bits += cl_len[r.sym] + runExtraBits(r.sym);
        dynamic_bits += c.dataBits(&lit_len, &dist_len);
        const fixed_bits = 3 + c.dataBits(format.fixed_lit_lengths[0..286], format.fixed_dist_lengths[0..30]);
        const raw = c.data[c.block_start..c.covered];
        const stored_bits = storedBits(raw.len, c.w.count);

        if (stored_bits <= fixed_bits and stored_bits <= dynamic_bits) {
            c.stats.stored += try storedBlocks(c.w, raw, final);
        } else if (fixed_bits <= dynamic_bits) {
            try c.w.put(@as(u32, @intFromBool(final)) | 1 << 1, 3);
            try c.writeTokens(&c.fixed_lit_code, &format.fixed_lit_lengths, &c.fixed_dist_code, &format.fixed_dist_lengths);
            c.stats.fixed += 1;
        } else {
            try c.w.put(@as(u32, @intFromBool(final)) | 2 << 1, 3);
            try c.w.put(@intCast(hlit - 257), 5);
            try c.w.put(@intCast(hdist - 1), 5);
            try c.w.put(@intCast(hclen - 4), 4);
            for (format.code_length_order[0..hclen]) |sym| try c.w.put(cl_len[sym], 3);
            var cl_code: [19]u16 = undefined;
            huffman.codesFromLengths(&cl_len, &cl_code);
            for (runs[0..nruns]) |r| {
                try c.w.put(cl_code[r.sym], cl_len[r.sym]);
                try c.w.put(r.extra, runExtraBits(r.sym));
            }
            var lit_code: [286]u16 = undefined;
            var dist_code: [30]u16 = undefined;
            huffman.codesFromLengths(&lit_len, &lit_code);
            huffman.codesFromLengths(&dist_len, &dist_code);
            try c.writeTokens(&lit_code, &lit_len, &dist_code, &dist_len);
            c.stats.dynamic += 1;
        }
        c.ntokens = 0;
        c.block_start = c.covered;
        @memset(&c.lit_freq, 0);
        @memset(&c.dist_freq, 0);
    }

    fn dataBits(c: *const Compressor, lit_len: []const u8, dist_len: []const u8) u64 {
        var bits: u64 = 0;
        for (c.lit_freq, 0..) |f, s| {
            bits += @as(u64, f) * lit_len[s];
            if (s > format.end_of_block) bits += @as(u64, f) * format.length_extra[s - 257];
        }
        for (c.dist_freq, 0..) |f, s| bits += @as(u64, f) * (dist_len[s] + @as(u64, format.dist_extra[s]));
        return bits;
    }

    fn writeTokens(c: *Compressor, lit_code: []const u16, lit_len: []const u8, dist_code: []const u16, dist_len: []const u8) Error!void {
        for (c.tokens[0..c.ntokens]) |t| {
            const dist = t >> 16;
            if (dist == 0) {
                try c.w.put(lit_code[t], lit_len[t]);
                continue;
            }
            const len = t & 0xffff;
            const ls = format.length_symbol[len];
            try c.w.put(lit_code[257 + @as(usize, ls)], lit_len[257 + @as(usize, ls)]);
            try c.w.put(len - format.length_base[ls], format.length_extra[ls]);
            const ds = format.distSymbol(dist);
            try c.w.put(dist_code[ds], dist_len[ds]);
            try c.w.put(dist - format.dist_base[ds], format.dist_extra[ds]);
        }
        try c.w.put(lit_code[format.end_of_block], lit_len[format.end_of_block]);
    }
};

/// Length of the common prefix of d[a..] and d[b..], up to max_len (a < b,
/// b + max_len <= d.len), compared eight bytes at a time.
inline fn matchLength(d: []const u8, a: usize, b: usize, max_len: usize) usize {
    var len: usize = 0;
    while (len + 8 <= max_len) : (len += 8) {
        const x = std.mem.readInt(u64, d[a + len ..][0..8], .little) ^ std.mem.readInt(u64, d[b + len ..][0..8], .little);
        if (x != 0) return len + @ctz(x) / 8;
    }
    while (len < max_len and d[a + len] == d[b + len]) len += 1;
    return len;
}

/// One symbol of the run-length coded code lengths: 0-15 a length, 16 the
/// previous length 3-6 times, 17 zero 3-10 times, 18 zero 11-138 times.
const Run = struct { sym: u8, extra: u8 = 0 };

fn runExtraBits(sym: u8) u32 {
    return switch (sym) {
        16 => 2,
        17 => 3,
        18 => 7,
        else => 0,
    };
}

fn runLengths(lengths: []const u8, runs: []Run, freq: *[19]u32) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < lengths.len) {
        const l = lengths[i];
        var run: usize = 1;
        while (i + run < lengths.len and lengths[i + run] == l) run += 1;
        i += run;
        if (l == 0) {
            while (run >= 11) {
                const k = @min(run, 138);
                runs[n] = .{ .sym = 18, .extra = @intCast(k - 11) };
                n += 1;
                run -= k;
            }
            if (run >= 3) {
                runs[n] = .{ .sym = 17, .extra = @intCast(run - 3) };
                n += 1;
                run = 0;
            }
        } else {
            runs[n] = .{ .sym = l };
            n += 1;
            run -= 1;
            while (run >= 3) {
                const k = @min(run, 6);
                runs[n] = .{ .sym = 16, .extra = @intCast(k - 3) };
                n += 1;
                run -= k;
            }
        }
        while (run > 0) : (run -= 1) {
            runs[n] = .{ .sym = l };
            n += 1;
        }
    }
    for (runs[0..n]) |r| freq[r.sym] += 1;
    return n;
}

test "run-length coding of code lengths" {
    var runs: [64]Run = undefined;
    var freq: [19]u32 = @splat(0);
    const lengths = [_]u8{ 8, 8, 8, 8, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 5 };
    const n = runLengths(&lengths, &runs, &freq);
    // 8, then 7 repeats as 16(6) + one more 8; 16 zeros as 18(16); 5, 5.
    const expected = [_]Run{ .{ .sym = 8 }, .{ .sym = 16, .extra = 3 }, .{ .sym = 8 }, .{ .sym = 18, .extra = 5 }, .{ .sym = 5 }, .{ .sym = 5 } };
    try std.testing.expectEqual(expected.len, n);
    for (expected, runs[0..n]) |e, r| {
        try std.testing.expectEqual(e.sym, r.sym);
        try std.testing.expectEqual(e.extra, r.extra);
    }
}
