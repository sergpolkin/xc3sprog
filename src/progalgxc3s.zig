const std = @import("std");
const log = std.log.scoped(.progalgxc3s);

const Jtag = @import("jtag.zig");
pub const Error = Jtag.Error;

const JPROGRAM    = [_]u8 { 0xcb, 0xff };
const CFG_IN      = [_]u8 { 0xc5, 0xff };
const JSHUTDOWN   = [_]u8 { 0xcd, 0xff };
const JSTART      = [_]u8 { 0xcc, 0xff };
const ISC_PROGRAM = [_]u8 { 0xd1, 0xff };
const ISC_ENABLE  = [_]u8 { 0xd0, 0xff };
const ISC_DISABLE = [_]u8 { 0xd6, 0xff };
const BYPASS      = [_]u8 { 0xff, 0xff };
const ISC_DNA     = [_]u8 { 0x31 };

// For XC6S family
const TCK_LEN = 12;

fn flowEnable(jtag: *Jtag) Error!void {
    const zeroes = [1]u8{0};
    try jtag.shiftIR(&ISC_ENABLE, null);
    try jtag.shiftDR(&zeroes, null, 5, 0, true);
    try jtag.cycleTCK(TCK_LEN, 1);
}

fn flowDisable(jtag: *Jtag) Error!void {
    const zeroes = [1]u8{0};
    try jtag.shiftIR(&ISC_DISABLE, null);
    try jtag.cycleTCK(TCK_LEN, 1);
    try jtag.shiftIR(&BYPASS, null);
    try jtag.shiftDR(&zeroes, null, 1, 0, true);
    try jtag.cycleTCK(1, 1);
}

fn flowProgram(jtag: *Jtag, prog: []const u8) Error!void {
    const zeroes = [1]u8{0};
    try jtag.shiftIR(&JSHUTDOWN, null);
    try jtag.cycleTCK(TCK_LEN, 1);
    try jtag.shiftIR(&CFG_IN, null);
    try jtag.shiftDR(prog.ptr, null, prog.len * 8, 0, true);
    try jtag.cycleTCK(1, 1);
    try jtag.shiftIR(&JSTART, null);
    try jtag.cycleTCK(2*TCK_LEN, 1);
    try jtag.shiftIR(&BYPASS, null);
    try jtag.shiftDR(&zeroes, null, 1, 0, true);
    try jtag.cycleTCK(1, 1);
}

fn readDNA(jtag: *Jtag) Error!u64 {
    var buf: [8]u8 = undefined;
    try jtag.shiftIR(&ISC_ENABLE, null);
    try jtag.shiftIR(&ISC_DNA, null);
    try jtag.shiftDR(null, &buf, 64, 0, true);
    try jtag.cycleTCK(1, 1);
    return std.mem.readIntSliceBig(u64, &buf);
}

pub fn arrayProgram(jtag: *Jtag, prog: []const u8) Error!void {
    var tries: usize = 0;

    try flowEnable(jtag);

    try jtag.shiftIR(&JPROGRAM, null);
    tries = 10;
    while (tries > 0) : (tries -= 1) {
        var buf: [1]u8 = undefined;
        try jtag.shiftIR(&CFG_IN, &buf);
        if (buf[0] & 0x10 != 0) break;
    }
    if (tries == 0) {
        log.err("JPROGRAM", .{});
        return Error.IOFail;
    }

    const dna = try readDNA(jtag);
    if (dna == 0xFFFF_FFFF_FFFF_FFFF) log.err("Error read DNA", .{})
    else log.info("DNA is 0x{x:0>16}", .{dna});

    try flowProgram(jtag, prog);

    try flowDisable(jtag);

    tries = 10;
    while (tries > 0) : (tries -= 1) {
        var buf: [1]u8 = undefined;
        try jtag.shiftIR(&BYPASS, &buf);
        if (buf[0] & 0x23 == 0x21) break;
        log.debug("INSTRUCTION_CAPTURE is 0x{x:0>2}", .{buf[0]});
        std.time.sleep(std.time.ns_per_ms);
    }
    if (tries == 0) {
        log.err("BYPASS", .{});
        return Error.IOFail;
    }
}
