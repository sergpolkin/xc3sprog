const std = @import("std");

const c = @cImport({
    @cInclude("ftdi.h");
});

const IO = @import("../io.zig");
const Error = IO.Error;

const log = std.log.scoped(.ftdi);

const UsbVendor = 0x0403;
const UsbProduct = 0x6014;

const TX_BUF_LEN = 4096;

ctx: *c.ftdi_context = undefined,
bptr: usize = 0,
tx_buf: [TX_BUF_LEN]u8 = undefined,

const Self = @This();

pub fn getIO(self: *Self) IO {
    return IO.init(self, open, close, tmsTx, xfer);
}

pub fn open(self: *Self) Error!void {
    const ftdi_opts = .{};
    self.ctx = try ftdiOpen(ftdi_opts);
    try mpsseInit(self);
}

pub fn close(self: *Self) Error!void {
    try self.mpsseDeinit();
    self.ftdiClose();
}

pub fn xfer(
    self: *Self,
    tdi: ?[*]const u8,
    tdo: ?[*]u8,
    length: usize,
    last: bool,
) Error!void {
    const tdi_flags = if (tdi != null) c.MPSSE_DO_WRITE else 0;
    const tdo_flags = if (tdo != null) c.MPSSE_DO_READ | c.MPSSE_READ_NEG else 0;
    var send_ptr: [*]const u8 = tdi orelse unreachable;
    var read_ptr: [*]u8 = tdo orelse unreachable;
    var rem: usize = if (last) length - 1 else length;
    var buflen: usize = TX_BUF_LEN - 3;

    if (rem / 8 > buflen) {
        while (rem / 8 > buflen) {
            var buf: [4]u8 = undefined;
            buf[0] = @intCast(u8, c.MPSSE_LSB | c.MPSSE_WRITE_NEG | tdi_flags | tdo_flags);
            buf[1] = @intCast(u8, (buflen - 1) & 0xFF);
            buf[2] = @intCast(u8, ((buflen - 1) >> 8) & 0xFF);
            try self.mpsseAddCommand(buf[0..3]);

            if (tdi != null) {
                try self.mpsseAddCommand(send_ptr[0..buflen]);
                send_ptr += buflen;
            }
            rem -= buflen * 8;
            if (tdo != null) {
                try self.mpsseRead(read_ptr[0..buflen]);
                read_ptr += buflen;
            }
        }
    }
    const rembits = rem % 8;
    rem = rem - rembits;
    std.debug.assert(rem % 8 == 0);
    buflen = rem / 8;
    if (rem > 0) {
        var buf: [4]u8 = undefined;
        buf[0] = @intCast(u8, c.MPSSE_LSB | c.MPSSE_WRITE_NEG | tdi_flags | tdo_flags);
        buf[1] = @intCast(u8, (buflen - 1) & 0xFF);
        buf[2] = @intCast(u8, ((buflen - 1) >> 8) & 0xFF);
        try self.mpsseAddCommand(buf[0..3]);

        if (tdi != null) {
            try self.mpsseAddCommand(send_ptr[0..buflen]);
            send_ptr += buflen;
        }
    }
    if (buflen >= (TX_BUF_LEN - 4)) {
        // No space for the last data. Send and evenually read
        // As we handle whole bytes, we can use the receiv buffer direct
        if (tdo != null) {
            try self.mpsseRead(read_ptr[0..buflen]);
            read_ptr += buflen;
        }
        buflen = 0;
    }
    if (rembits > 0) {
        var buf: [4]u8 = undefined;
        buf[0] = @intCast(u8, c.MPSSE_BITMODE | c.MPSSE_LSB | c.MPSSE_WRITE_NEG | tdi_flags | tdo_flags);
        buf[1] = @intCast(u8, rembits - 1);
        try self.mpsseAddCommand(buf[0..2]);

        if (tdi != null) {
            try self.mpsseAddCommand(send_ptr[0..1]);
        }
        buflen += 1;
    }
    if (last) {
        var lastbit: bool = false;
        if (tdo != null) {
            lastbit = send_ptr[0] & (@as(u8, 1) << @intCast(u3, rembits)) != 0;
        }
        var buf: [4]u8 = undefined;
        buf[0] = @intCast(u8, c.MPSSE_WRITE_TMS | c.MPSSE_BITMODE | c.MPSSE_LSB | c.MPSSE_WRITE_NEG | tdo_flags);
        buf[1] = 0;
        buf[2] = if (lastbit) 0x81 else 1;
        try self.mpsseAddCommand(buf[0..3]);
        buflen += 1;
    }
    if (tdo != null) {
        if (!last) {
            try self.mpsseRead(read_ptr[0..buflen]);
            if (rembits > 0) {
                // last bits for incomplete byte must get shifted down
                read_ptr[buflen-1] = read_ptr[buflen-1] >> @intCast(u3, 8 - rembits);
            }
        }
        else {
            // we need to handle the last bit. It's much faster to
            // read into an extra buffer than to issue two USB reads
            var rbuf: [TX_BUF_LEN]u8 = undefined;
            try self.mpsseRead(rbuf[0..buflen]);
            if (rembits == 0) {
                rbuf[buflen-1] = if (rbuf[buflen-1] & 0x80 != 0) 1 else 0;
            }
            else {
                // TDO Bits are shifted downwards, so align them
                // We only shift TMS once, so the relevant bit is bit 7 (0x80)
                rbuf[buflen-2] = rbuf[buflen-2] >> @intCast(u3, 8 - rembits);
                rbuf[buflen-2] |= (rbuf[buflen-1] & 0x80) >> @intCast(u3, 7 - rembits);
                buflen -= 1;
            }
            std.mem.copy(u8, read_ptr[0..buflen], rbuf[0..buflen]);
        }
    }
}

pub fn tmsTx(self: *Self, pat: []const u8, flush: bool) Error!void {
    var buf = [3]u8{
        c.MPSSE_WRITE_TMS | c.MPSSE_WRITE_NEG | c.MPSSE_LSB | c.MPSSE_BITMODE,
        0, 0,
    };
    var j: usize = 0;
    var len: u8 = @intCast(u8, pat.len);
    while (len > 0) {
        buf[1] = if (len > 6) 5 else len - 1;
        buf[2] = 0x80;
        var i: usize = 0;
        while (i < buf[1] + 1) : (i += 1) {
            const cond = pat[j>>3] & (@as(u8, 1) << @intCast(u3, j & 7));
            buf[2] |= if (cond != 0) (@as(u8, 1) << @intCast(u3, i)) else 0;
            j += 1;
        }
        len -= buf[1] + 1;
        try self.mpsseAddCommand(&buf);
    }
    if (flush) try self.mpsseSend();
}

const FtdiOptions = struct {
    usb_vendor: u16 = UsbVendor,
    usb_product: u16 = UsbProduct,
    usb_description: ?[]const u8 = null,
    usb_serial: ?[]const u8 = null,
    interface: c.ftdi_interface = c.INTERFACE_ANY,
};

fn ftdiOpen(opts: FtdiOptions) Error!*c.ftdi_context {
    var r: isize = undefined;
    const ctx = c.ftdi_new();
    // Set interface
    r = c.ftdi_set_interface(ctx, opts.interface);
    if (r != 0) {
        log.err("ftdi_set_interface: {s}", .{c.ftdi_get_error_string(ctx)});
        return error.IOFail;
    }
    // Open device
    r = c.ftdi_usb_open_desc(ctx,
        opts.usb_vendor, opts.usb_product,
        if (opts.usb_description) |desc| desc.ptr else null,
        if (opts.usb_serial) |serial| serial.ptr else null,
    );
    if (r != 0) {
        log.err("ftdi_usb_open_desc: {s}", .{c.ftdi_get_error_string(ctx)});
        return error.IOFail;
    }
    r = c.ftdi_set_bitmode(ctx, 0, c.BITMODE_RESET);
    if (r != 0) {
        log.err("ftdi_set_bitmode: {s}", .{c.ftdi_get_error_string(ctx)});
        return error.IOFail;
    }
    r = c.ftdi_usb_purge_buffers(ctx);
    if (r != 0) {
        log.err("ftdi_usb_purge_buffers: {s}", .{c.ftdi_get_error_string(ctx)});
        return error.IOFail;
    }
    r = c.ftdi_set_latency_timer(ctx, 1);
    if (r != 0) {
        log.err("ftdi_set_latency_timer: {s}", .{c.ftdi_get_error_string(ctx)});
        return error.IOFail;
    }
    r = c.ftdi_set_bitmode(ctx, 0xfb, c.BITMODE_MPSSE);
    if (r != 0) {
        log.err("ftdi_set_bitmode: {s}", .{c.ftdi_get_error_string(ctx)});
        return error.IOFail;
    }
    return ctx;
}

fn ftdiClose(self: *Self) void {
    _ = c.ftdi_usb_close(self.ctx);
    _ = c.ftdi_deinit(self.ctx);
}

fn mpsseInit(self: *Self) Error!void {
    var dbus_data: u8 = 0;
    var dbus_en: u8   = 0xb;
    var cbus_data: u8 = 0;
    var cbus_en: u8   = 0;

    var buf = [_]u8 {
        c.SET_BITS_LOW,  0x00, 0x0b,
        c.TCK_DIVISOR,   0x05, 0x00,
        c.SET_BITS_HIGH, 0x00, 0x00,
    };

    buf[1] |= dbus_data;
    buf[2] |= dbus_en;
    buf[7] = cbus_data;
    buf[8] = cbus_en;

    try self.mpsseAddCommand(&buf);
    try self.mpsseSend();
}

fn mpsseDeinit(self: *Self) Error!void {
    const buf = [_]u8{
        c.SET_BITS_LOW, 0xFF, 0x00,
        c.SET_BITS_HIGH, 0xFF, 0x00,
        c.LOOPBACK_START,
        c.MPSSE_DO_READ | c.MPSSE_READ_NEG |
        c.MPSSE_DO_WRITE | c.MPSSE_WRITE_NEG |
        c.MPSSE_LSB,
        0x04, 0x00,
        0xAA, 0x55, 0x00, 0xFF, 0xAA,
        c.LOOPBACK_END,
    };
    try self.mpsseAddCommand(&buf);

    var rbuf: [5]u8 = undefined;
    try self.mpsseRead(&rbuf);
    log.debug("loopback {}", .{std.fmt.fmtSliceHexLower(&rbuf)});

    _ = c.ftdi_set_bitmode(self.ctx, 0, c.BITMODE_RESET);
}

fn mpsseAddCommand(self: *Self, buf: []const u8) Error!void {
    if (self.bptr + buf.len + 1 >= self.tx_buf.len) try self.mpsseSend();
    std.mem.copy(u8, self.tx_buf[self.bptr..], buf);
    self.bptr += buf.len;
}

fn mpsseSend(self: *Self) Error!void {
    if (self.bptr == 0) return;
    const r = c.ftdi_write_data(self.ctx, &self.tx_buf, @intCast(i32, self.bptr));
    if (r != self.bptr) {
        log.err("ftdi_write_data: {s}", .{c.ftdi_get_error_string(self.ctx)});
        return error.IOFail;
    }
    self.bptr = 0;
}

fn mpsseRead(self: *Self, buf: []u8) Error!void {
    try self.mpsseAddCommand(&[_]u8{c.SEND_IMMEDIATE});
    try self.mpsseSend();

    var tries: usize = 1000;
    var read: usize = 0;
    while (read < buf.len and tries != 0) : (tries -= 1) {
        const r = c.ftdi_read_data(self.ctx, &buf[read], @intCast(i32, buf.len));
        if (r >= 0) {
            read += @intCast(usize, r);
        }
        else {
            log.err("ftdi_read_data: {s}", .{c.ftdi_get_error_string(self.ctx)});
            return error.IOFail;
        }
    }
    if (tries == 0) {
        log.err("ftdi_read_data all tries expierd", .{});
        return error.IOFail;
    }
}
