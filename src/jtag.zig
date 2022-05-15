const std = @import("std");

const log = std.log.scoped(.jtag);

const IO = @import("io.zig");
pub const Error = IO.Error;

const MaxNumDevices = 1000;

const Device = struct {
    id: u32,
    irlen: u32,
};

tap_state: TAPState = .UNKNOWN,
io: IO,
dev_list: [MaxNumDevices]Device = undefined,
num_devices: ?usize = null,
device_index: ?usize = null,
shift_dr_incomplete: bool = false,

const TAPState = enum {
    TEST_LOGIC_RESET,
    RUN_TEST_IDLE,
    SELECT_DR_SCAN,
    CAPTURE_DR,
    SHIFT_DR,
    EXIT1_DR,
    PAUSE_DR,
    EXIT2_DR,
    UPDATE_DR,
    SELECT_IR_SCAN,
    CAPTURE_IR,
    SHIFT_IR,
    EXIT1_IR,
    PAUSE_IR,
    EXIT2_IR,
    UPDATE_IR,
    UNKNOWN,
};

const PostDRState = TAPState.RUN_TEST_IDLE;
const PostIRState = TAPState.RUN_TEST_IDLE;

const Self = @This();

pub fn getChain(self: *Self) Error!usize {
    self.num_devices = null;

    try self.tapTestLogicReset();
    try self.setTapState(.SHIFT_DR);

    const zeroes: [4]u8 = std.mem.zeroes([4]u8);
    var idx: [4]u8 = undefined;
    var num_devices: usize = 0;
    while (num_devices < MaxNumDevices) {
        try self.io.shiftTDITDO(&zeroes, &idx, 32, false);
        const id = std.mem.readIntSliceLittle(u32, &idx);
        if (id != 0 and id != 0xFFFF_FFFF) {
            self.dev_list[num_devices] = Device{
                .id = id,
                .irlen = 0,
            };
            num_devices += 1;
            log.info("Found device: 0x{x:0>8}", .{id});
        }
        else {
            if (id == 0xFFFFFFFF and num_devices > 0) {
            }
            break;
        }
    }
    try self.setTapState(.TEST_LOGIC_RESET);

    self.num_devices = num_devices;
    self.device_index = 0;

    return num_devices;
}

/// void cycleTCK(int n, bool tdi=1);
pub fn cycleTCK(self: *Self, n: usize, tck: u1) Error!void {
    if (self.tap_state == .TEST_LOGIC_RESET) {
        log.err("cycleTCK in TEST_LOGIC_RESET", .{});
    }
    try self.io.shift(tck, n, false);
}

/// void shiftDR(const byte *tdi, byte *tdo, int length, int align=0, bool exit=true);
pub fn shiftDR(self: *Self,
    tdi: ?[*]const u8,
    tdo: ?[*]u8,
    length: usize,
    align_data: usize,
    exit: bool,
) Error!void {
    if (self.device_index == null) {
        log.err("shiftDR: device_index not set", .{});
        return;
    }

    const post = self.device_index.?;

    if (!self.shift_dr_incomplete) {
        var pre: isize = @intCast(isize, self.num_devices.? - self.device_index.? - 1);
        if (align_data > 0) {
            pre = -@intCast(isize, post);
            while (pre <= 0) {
                pre += @intCast(isize, align_data);
            }
        }
        // We can combine the pre bits to reach the target device with
        // the TMS bits to reach the SHIFT-DR state, as the pre bit can be '0'
        try self.setTapState(.SHIFT_DR);
        while (pre != 0) : (pre -= 1) {
            try self.io.tmsSet(0);
        }
    }

    const last = post == 0 and exit;

    if (tdi != null and tdo != null) {
        try self.io.shiftTDITDO(tdi, tdo, length, last);
    }
    else if (tdi != null and tdo == null) {
        try self.io.shiftTDI(tdi, length, last);
    }
    else if (tdi == null and tdo != null) {
        try self.io.shiftTDO(tdo, length, last);
    }
    else {
        try self.io.shift(0, length, last);
    }

    // If TMS is set the the state of the tap changes
    try self.nextTapState(last);

    if (exit) {
        try self.io.shift(0, post, true);
        if (!last) {
            try self.nextTapState(true);
        }
        try self.setTapState(PostDRState);
        self.shift_dr_incomplete = false;
    }
    else {
        self.shift_dr_incomplete = true;
    }
}

/// void shiftIR(const byte *tdi, byte *tdo=0);
pub fn shiftIR(self: *Self, tdi: ?[*]const u8, tdo: ?[*]u8) Error!void {
    if (self.device_index == null) {
        log.err("shiftIR: device_index not set", .{});
        return;
    }

    try self.setTapState(.SHIFT_IR);

    // Calculate number of pre BYPASS bits
    const pre = pre: {
        var pre: usize = 0;
        var i: usize = self.device_index.? + 1;
        while (i < self.num_devices.?) : (i += 1) {
            pre += self.dev_list[i].irlen;
        }
        break :pre pre;
    };

    // Calculate number of post BYPASS bits
    const post = post: {
        var post: usize = 0;
        var i: usize = 0;
        while (i < self.device_index.?) : (i += 1) {
            post += self.dev_list[i].irlen;
        }
        break :post post;
    };

    const length = self.dev_list[self.device_index.?].irlen;
    const last = post == 0;

    try self.io.shift(1, pre, false);

    if (tdo != null) {
        try self.io.shiftTDITDO(tdi, tdo, length, last);
    }
    else {
        try self.io.shiftTDI(tdi, length, last);
    }

    try self.io.shift(1, post, true);

    try self.nextTapState(true);
    try self.setTapState(PostIRState);
}

fn setTapState(self: *Self, state: TAPState) Error!void {
    while (self.tap_state != state) {
        const NextState = struct {
            tms: u1,
            state: TAPState,
        };
        const next: NextState = switch (self.tap_state) {
            .TEST_LOGIC_RESET => switch (state) {
                .TEST_LOGIC_RESET,
                => NextState{ .tms = 1, .state = .TEST_LOGIC_RESET, },
                else
                => NextState{ .tms = 0, .state = .RUN_TEST_IDLE, },
            },

            .RUN_TEST_IDLE => switch (state) {
                .RUN_TEST_IDLE,
                => NextState{ .tms = 0, .state = .RUN_TEST_IDLE, },
                else
                => NextState{ .tms = 1, .state = .SELECT_DR_SCAN, },
            },

            .SELECT_DR_SCAN => switch (state) {
                .CAPTURE_DR,
                .SHIFT_DR,
                .EXIT1_DR,
                .PAUSE_DR,
                .EXIT2_DR,
                .UPDATE_DR,
                => NextState{ .tms = 0, .state = .CAPTURE_DR, },
                else
                => NextState{ .tms = 1, .state = .SELECT_IR_SCAN, },
            },

            .CAPTURE_DR => switch (state) {
                .SHIFT_DR,
                => NextState{ .tms = 0, .state = .SHIFT_DR, },
                else
                => NextState{ .tms = 1, .state = .EXIT1_DR, },
            },

            .SHIFT_DR => switch (state) {
                .SHIFT_DR,
                => NextState{ .tms = 0, .state = .SHIFT_DR, },
                else
                => NextState{ .tms = 1, .state = .EXIT1_DR, },
            },

            .EXIT1_DR => switch (state) {
                .PAUSE_DR,
                .EXIT2_DR,
                .SHIFT_DR,
                .EXIT1_DR,
                => NextState{ .tms = 0, .state = .PAUSE_DR, },
                else
                => NextState{ .tms = 1, .state = .UPDATE_DR, },
            },

            .PAUSE_DR => switch (state) {
                .PAUSE_DR,
                => NextState{ .tms = 0, .state = .PAUSE_DR, },
                else
                => NextState{ .tms = 1, .state = .EXIT2_DR, },
            },

            .EXIT2_DR => switch (state) {
                .SHIFT_DR,
                .EXIT1_DR,
                .PAUSE_DR,
                => NextState{ .tms = 0, .state = .SHIFT_DR, },
                else
                => NextState{ .tms = 1, .state = .UPDATE_DR, },
            },

            .UPDATE_DR => switch (state) {
                .RUN_TEST_IDLE,
                => NextState{ .tms = 0, .state = .RUN_TEST_IDLE, },
                else
                => NextState{ .tms = 1, .state = .SELECT_DR_SCAN, },
            },

            .SELECT_IR_SCAN => switch (state) {
                .CAPTURE_IR,
                .SHIFT_IR,
                .EXIT1_IR,
                .PAUSE_IR,
                .EXIT2_IR,
                .UPDATE_IR,
                => NextState{ .tms = 0, .state = .CAPTURE_IR, },
                else
                => NextState{ .tms = 1, .state = .TEST_LOGIC_RESET, },
            },

            .CAPTURE_IR => switch (state) {
                .SHIFT_IR,
                => NextState{ .tms = 0, .state = .SHIFT_IR, },
                else
                => NextState{ .tms = 1, .state = .EXIT1_IR, },
            },

            .SHIFT_IR => switch (state) {
                .SHIFT_IR,
                => NextState{ .tms = 0, .state = .SHIFT_IR, },
                else
                => NextState{ .tms = 1, .state = .EXIT1_IR, },
            },

            .EXIT1_IR => switch (state) {
                .PAUSE_IR,
                .EXIT2_IR,
                .SHIFT_IR,
                .EXIT1_IR,
                => NextState{ .tms = 0, .state = .PAUSE_IR, },
                else
                => NextState{ .tms = 1, .state = .UPDATE_IR, },
            },

            .PAUSE_IR => switch (state) {
                .PAUSE_IR,
                => NextState{ .tms = 0, .state = .PAUSE_IR, },
                else
                => NextState{ .tms = 1, .state = .EXIT2_IR, },
            },

            .EXIT2_IR => switch (state) {
                .SHIFT_IR,
                .EXIT1_IR,
                .PAUSE_IR,
                => NextState{ .tms = 0, .state = .SHIFT_IR, },
                else
                => NextState{ .tms = 1, .state = .UPDATE_IR, },
            },

            .UPDATE_IR => switch (state) {
                .RUN_TEST_IDLE,
                => NextState{ .tms = 0, .state = .RUN_TEST_IDLE, },
                else
                => NextState{ .tms = 1, .state = .SELECT_DR_SCAN, },
            },

            else => state: {
                try self.tapTestLogicReset();
                break :state NextState{ .tms = 1, .state = self.tap_state };
            },
        };
        log.debug("TAP state: {s: <16} -> {s: <16} TMS: {}", .{
            @tagName(self.tap_state),
            @tagName(next.state),
            next.tms,
        });
        self.tap_state = next.state;
        try self.io.tmsSet(next.tms);
    }
}

/// After shift data into the DR or IR we goto the next state
/// This function should only be called from the end of a shift function
fn nextTapState(self: *Self, tms: bool) Error!void {
    if (self.tap_state == .SHIFT_DR) {
        // If TMS was set then goto next state
        if (tms) self.tap_state = .EXIT1_DR;
    }
    else if(self.tap_state == .SHIFT_IR) {
        // If TMS was set then goto next state
        if (tms) self.tap_state = .EXIT1_IR;
    }
    else {
        log.err("nextTapState: Unexpected state {s}", .{@tagName(self.tap_state)});
        try self.tapTestLogicReset();
    }
}

fn tapTestLogicReset(self: *Self) Error!void {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try self.io.tmsSet(1);
    }
    self.tap_state = .TEST_LOGIC_RESET;
    try self.io.tmsFlush(true);
}
