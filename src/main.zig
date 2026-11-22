//! zdeflate: compress or decompress standard input to standard output.
//!
//!   zdeflate [-d] [-f raw|zlib|gzip] [-0 .. -9] < input > output
//!
//! The default is gzip at level 6, like the gzip tool.

const std = @import("std");
const deflate = @import("deflate");

const usage =
    \\usage: zdeflate [-d] [-f raw|zlib|gzip] [-0 .. -9] < input > output
    \\  -d   decompress (default: compress)
    \\  -f   container format (default: gzip)
    \\  -N   compression level 0-9 (default: 6)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    var decompress = false;
    var format: deflate.Format = .gzip;
    var level: u4 = 6;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d")) {
            decompress = true;
        } else if (std.mem.eql(u8, arg, "-f")) {
            const name = args.next() orelse fail(io, "-f needs a format");
            format = std.meta.stringToEnum(deflate.Format, name) orelse fail(io, "unknown format");
        } else if (arg.len == 2 and arg[0] == '-' and arg[1] >= '0' and arg[1] <= '9') {
            level = @intCast(arg[1] - '0');
        } else {
            fail(io, "unknown option");
        }
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const input = try stdin.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(input);

    const output = if (decompress)
        deflate.decompress(gpa, input, format) catch |err| fail(io, @errorName(err))
    else
        try deflate.compress(gpa, input, format, level, null);
    defer gpa.free(output);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try stdout.interface.writeAll(output);
    try stdout.interface.flush();
}

fn fail(io: std.Io, msg: []const u8) noreturn {
    var buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    stderr.interface.print("zdeflate: {s}\n{s}", .{ msg, usage }) catch {};
    stderr.interface.flush() catch {};
    std.process.exit(1);
}
