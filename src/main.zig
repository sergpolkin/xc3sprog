const std = @import("std");
const log = std.log;

pub const log_level: std.log.Level = .debug;

const Bitfile = @import("bitfile.zig");
const IO = @import("io.zig");
const Ftdi = @import("io/ftdi.zig");
const Jtag = @import("jtag.zig");

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() anyerror!void {
    var ftdi = Ftdi{};

    var io = ftdi.getIO();
    try io.open();

    var jtag = Jtag{ .io = io };

    const n = try jtag.getChain();
    log.info("JTAG chain length: {}", .{n});

    try io.close();
}

fn bitfile_main() anyerror!void {
    const alloc = general_purpose_allocator.allocator();
    defer _ = general_purpose_allocator.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(alloc);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    const bitfile_path = getBitfilePath(args) orelse {
        log.err("expected bitfile path", .{});
        return;
    };
    log.info("bitfile_path: {s}", .{bitfile_path});

    const bitfile_content = bitfile_content: {
        const fd = try std.fs.openFileAbsolute(bitfile_path, .{});
        defer fd.close();
        break :bitfile_content try fd.readToEndAlloc(arena, 128 * 1024 * 1024);
    };

    const bitfile = try Bitfile.parse(bitfile_content);

    if (bitfile.ncd_filename) |ncd_filename|
        log.info("NCD filename: \"{s}\"", .{ncd_filename});
    if (bitfile.part_name) |part_name|
        log.info("Part name: \"{s}\"", .{part_name});
    if (bitfile.date) |date|
        log.info("Date: \"{s}\"", .{date});
    if (bitfile.time) |time|
        log.info("Time: \"{s}\"", .{time});
    if (bitfile.payload) |payload|
        log.info("Payload length {} bytes", .{payload.len});
}

fn getBitfilePath(args: []const []const u8) ?[]const u8 {
    const env_bitfile_path = std.os.getenv("BITFILE");
    if (env_bitfile_path) |bitfile_path| return bitfile_path;
    return if (args.len > 1) args[1] else null;
}
