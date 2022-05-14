const std = @import("std");

const log = std.log.scoped(.jtag);

const IO = @import("io.zig");
const Error = IO.Error;

const MaxNumDevices = 1000;

tap_state: TAPState = .UNKNOWN,
io: IO,
num_devices: ?usize = null,

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

const Self = @This();

fn tapTestLogicReset(self: *Self) Error!void {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try self.io.tmsSet(1);
    }
    self.tap_state = .TEST_LOGIC_RESET;
    try self.io.tmsFlush(true);
}

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
        if (id != 0 and id != 0xFFFFFFFF) {
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

    return num_devices;
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
        self.tap_state = next.state;
        try self.io.tmsSet(next.tms);
        log.debug("TAP state: {s}, TMS: {}", .{@tagName(next.state), next.tms});
    }
    // TODO `pre` loop
}
