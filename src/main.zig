const std = @import("std");
const log = std.log;

pub const log_level: std.log.Level = .info;

const Bitfile = @import("bitfile.zig");
const IO = @import("io.zig");
const Ftdi = @import("io/ftdi.zig");
const Jtag = @import("jtag.zig");
const arrayProgram = @import("progalgxc3s.zig").arrayProgram;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() anyerror!void {
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

    var bitfile_content = bitfile_content: {
        const fd = try std.fs.openFileAbsolute(bitfile_path, .{});
        defer fd.close();
        break :bitfile_content try fd.readToEndAlloc(arena, 128 * 1024 * 1024);
    };

    const doBitReverse = true;

    const bitfile = try Bitfile.parse(bitfile_content, doBitReverse);

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

    if (bitfile.payload) |payload| {
        var ftdi = Ftdi{};

        var io = ftdi.getIO();
        try io.open();
        defer io.close() catch {};

        var jtag = Jtag{ .io = io };

        const chain_length = try jtag.getChain();
        log.info("JTAG chain length: {}", .{chain_length});

        if (chain_length > 0) {
            const dev = &jtag.dev_list[0];
            const family = getFamily(dev.id);
            const manufacturer = getManufacturer(dev.id);
            log.info("family: 0x{x:0>2}", .{family});
            log.info("manufacturer: 0x{x:0>3}", .{manufacturer});

            if (family != 0x20 and manufacturer != 0x049) {
                log.err("Expect XC6S family", .{});
                return;
            }

            // Set irlen for XC6S family
            dev.irlen = 6;

            try arrayProgram(&jtag, payload);
        }
    }
}

fn getBitfilePath(args: []const []const u8) ?[]const u8 {
    const env_bitfile_path = std.os.getenv("BITFILE");
    if (env_bitfile_path) |bitfile_path| return bitfile_path;
    return if (args.len > 1) args[1] else null;
}

fn getFamily(id: u32) u8 {
    return @intCast(u8, (id >> 21) & 0x7f);
}

fn getManufacturer(id: u32) u16 {
    return @intCast(u16, (id >> 1) & 0x3ff);
}
