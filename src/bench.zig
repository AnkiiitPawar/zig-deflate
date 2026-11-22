//! Measurement helper for the scripts in scripts/.
//!
//!   zdeflate-bench FILE...          CSV of size and speed at levels 1, 6, 9
//!   zdeflate-bench --inflate PACK   decode every raw stream in PACK (each
//!                                   a little-endian u32 length, then the
//!                                   bytes) and print one line per stream:
//!                                   "ok CONSUMED LENGTH CRC32" or "err NAME"

const std = @import("std");
const deflate = @import("deflate");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    if (args.len == 3 and std.mem.eql(u8, args[1], "--inflate")) {
        try inflatePack(gpa, io, args[2], w);
    } else {
        try w.writeAll("file,level,in_bytes,out_bytes,compress_mb_s,decompress_mb_s,stored,fixed,dynamic\n");
        for (args[1..]) |path| try benchFile(gpa, io, path, w);
    }
    try w.flush();
}

fn seconds(io: std.Io, t0: std.Io.Timestamp) f64 {
    const d = t0.untilNow(io, .awake);
    return @as(f64, @floatFromInt(d.nanoseconds)) / 1e9;
}

/// Best of several runs, repeated until about a second has been spent.
fn benchFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, w: *std.Io.Writer) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(data);
    for ([_]u4{ 1, 6, 9 }) |level| {
        var stats: deflate.Stats = .{};
        var best_c: f64 = std.math.inf(f64);
        var z: []u8 = &.{};
        defer gpa.free(z);
        var spent: f64 = 0;
        var runs: usize = 0;
        while (runs < 3 or (spent < 1.0 and runs < 20)) : (runs += 1) {
            gpa.free(z);
            stats = .{};
            const t0 = std.Io.Timestamp.now(io, .awake);
            z = try deflate.compress(gpa, data, .raw, level, &stats);
            const t = seconds(io, t0);
            best_c = @min(best_c, t);
            spent += t;
        }
        var best_d: f64 = std.math.inf(f64);
        spent = 0;
        runs = 0;
        while (runs < 3 or (spent < 1.0 and runs < 50)) : (runs += 1) {
            const t0 = std.Io.Timestamp.now(io, .awake);
            const back = try deflate.decompress(gpa, z, .raw);
            const t = seconds(io, t0);
            defer gpa.free(back);
            if (!std.mem.eql(u8, back, data)) return error.RoundTripFailed;
            best_d = @min(best_d, t);
            spent += t;
        }
        const mb = @as(f64, @floatFromInt(data.len)) / 1e6;
        try w.print("{s},{d},{d},{d},", .{ std.fs.path.basename(path), level, data.len, z.len });
        try w.print("{d:.2},{d:.2},{d},{d},{d}\n", .{ mb / best_c, mb / best_d, stats.stored, stats.fixed, stats.dynamic });
    }
}

fn inflatePack(gpa: std.mem.Allocator, io: std.Io, path: []const u8, w: *std.Io.Writer) !void {
    const pack = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(pack);
    var pos: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    while (pos + 4 <= pack.len) {
        const len = std.mem.readInt(u32, pack[pos..][0..4], .little);
        pos += 4;
        const stream = pack[pos..][0..len];
        pos += len;
        out.clearRetainingCapacity();
        if (deflate.inflate.inflate(gpa, stream, &out)) |used| {
            try w.print("ok {d} {d} {x:0>8}\n", .{ used, out.items.len, deflate.checksum.crc32(out.items) });
        } else |err| {
            try w.print("err {s}\n", .{@errorName(err)});
        }
    }
}
