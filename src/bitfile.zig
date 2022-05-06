const std = @import("std");

ncd_filename: ?[]const u8 = null,
part_name: ?[]const u8 = null,
date: ?[]const u8 = null,
time: ?[]const u8 = null,
payload: ?[]const u8 = null,

const Self = @This();

const ParseError = error {
    InvalidLength,
    InvalidFieldType,
};

pub fn parse(buf: []const u8) ParseError!Self {
    var bitfile: Self = .{};
    // Skip the header, first 13 bytes
    const HeaderLength = 13;
    if (buf.len < HeaderLength) return error.InvalidLength;
    var data = buf[HeaderLength..];
    parse_fields: while (true) {
        if (data.len == 0) return error.InvalidLength;
        const field = try Field.parse(data);
        switch (field.typ) {
            .NCDFilename => bitfile.ncd_filename = field.data,
            .PartName => bitfile.part_name = field.data,
            .Date => bitfile.date = field.data,
            .Time => bitfile.time = field.data,
            .Payload => {
                bitfile.payload = field.data;
                break :parse_fields;
            },
        }
        // Next field
        data = data[3+field.data.len..];
    }
    return bitfile;
}

const FieldType = enum(u8) {
    NCDFilename = 'a',
    PartName = 'b',
    Date = 'c',
    Time = 'd',
    Payload = 'e',
};

const Field = struct {
    typ: FieldType,
    data: []const u8,

    fn parse(buf: []const u8) !Field {
        const typ = buf[0];
        switch (typ) {
            'a' ... 'd' => {
                if (buf[1..].len < 2) return error.InvalidLength;
                const length = std.mem.readIntBig(u16, buf[1..3]);
                const data = buf[3..];
                if (data.len < length) return error.InvalidLength;
                return Field {
                    .typ = @intToEnum(FieldType, typ),
                    .data = data[0..length],
                };
            },
            'e' => {
                if (buf[1..].len < 4) return error.InvalidLength;
                const length = std.mem.readIntBig(u32, buf[1..5]);
                const data = buf[5..];
                if (data.len < length) return error.InvalidLength;
                return Field {
                    .typ = @intToEnum(FieldType, typ),
                    .data = data[0..length],
                };
            },
            else => return error.InvalidFieldType,
        }
    }
};
