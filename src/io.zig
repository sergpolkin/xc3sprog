const std = @import("std");

const IO = @This();

const BlockSize = 65536;
const ChunkSize = 128;
const TickCount = 2048;

ptr: *anyopaque,
vtable: *const VTable,

tms_buf: [ChunkSize]u8 = undefined,
tms_len: usize = 0,

pub const VTable = struct {
    open: openProto,
    close: closeProto,
    tmsTx: tmsTxProto,
    xfer: xferProto,
};

const openProto = fn (ptr: *anyopaque) Error!void;
const closeProto = fn (ptr: *anyopaque) Error!void;
const tmsTxProto = fn (ptr: *anyopaque, pat: []const u8, flush: bool) Error!void;
const xferProto = fn (ptr: *anyopaque, tdi: ?[*]const u8, tdo: ?[*]u8, length: usize, last: bool) Error!void;

pub const Error = error{ IOFail };

pub fn init(
    pointer: anytype,
    comptime openFn: fn (ptr: @TypeOf(pointer)) Error!void,
    comptime closeFn: fn (ptr: @TypeOf(pointer)) Error!void,
    comptime tmsTxFn: fn (ptr: @TypeOf(pointer), pat: []const u8, flush: bool) Error!void,
    comptime xferFn: fn (ptr: @TypeOf(pointer), tdi: ?[*]const u8, tdo: ?[*]u8, length: usize, last: bool) Error!void,
) IO {
    const Ptr = @TypeOf(pointer);
    const ptr_info = @typeInfo(Ptr);

    std.debug.assert(ptr_info == .Pointer); // Must be a pointer
    std.debug.assert(ptr_info.Pointer.size == .One); // Must be a single-item pointer

    const alignment = ptr_info.Pointer.alignment;

    const gen = struct {
        fn openImpl(ptr: *anyopaque) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, openFn, .{self});
        }

        fn closeImpl(ptr: *anyopaque) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, closeFn, .{self});
        }

        fn tmsTxImpl(ptr: *anyopaque, pat: []const u8, flush: bool) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, tmsTxFn, .{self, pat, flush});
        }

        fn xferImpl(ptr: *anyopaque, tdi: ?[*]const u8, tdo: ?[*]u8, length: usize, last: bool) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, xferFn, .{self, tdi, tdo, length, last});
        }

        const vtable = VTable {
            .open = openImpl,
            .close = closeImpl,
            .tmsTx = tmsTxImpl,
            .xfer = xferImpl,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn open(io: *IO) Error!void {
    try io.vtable.open(io.ptr);
}

pub fn close(io: *IO) Error!void {
    try io.vtable.close(io.ptr);
}

pub fn tmsSet(io: *IO, val: u1) Error!void {
    if (io.tms_len + 1 > ChunkSize * 8) {
        try io.tmsFlush(false);
    }
    if (val != 0) {
        io.tms_buf[io.tms_len/8] |= (@as(u8, 1) << @intCast(u3, io.tms_len & 7));
    }
    io.tms_len += 1;
}

pub fn tmsFlush(io: *IO, force: bool) Error!void {
    if (io.tms_len != 0) {
        const tmsTx = io.vtable.tmsTx;
        try tmsTx(io.ptr, io.tms_buf[0..io.tms_len], force);
    }
    std.mem.set(u8, &io.tms_buf, 0);
    io.tms_len = 0;
}

pub fn shiftTDITDO(io: *IO, tdi: ?[*]const u8, tdo: ?[*]u8, length: usize, last: bool) Error!void {
    if (length == 0) return;
    try io.tmsFlush(false);
    try io.vtable.xfer(io.ptr, tdi, tdo, length, last);
}

pub fn shiftTDI(io: *IO, tdi: ?[*]const u8, length: usize, last: bool) Error!void {
    try io.shiftTDITDO(tdi, null, length, last);
}

pub fn shiftTDO(io: *IO, tdo: ?[*]u8, length: usize, last: bool) Error!void {
    try io.shiftTDITDO(null, tdo, length, last);
}

pub fn shift(io: *IO, tdi: u1, length: usize, last: bool) Error!void {
    const ones   = [_]u8{0xFF} ** ChunkSize;
    const zeroes = [_]u8{0x00} ** ChunkSize;
    const block = if (tdi == 1) ones else zeroes;
    io.tmsFlush(false);
    var len: usize = length;
    while (len > ChunkSize * 8) {
        try io.vtable.xfer(io.ptr, block, null, ChunkSize * 8, false);
        len -= ChunkSize * 8;
    }
    try io.shiftTDITDO(block, null, len, last);
}
