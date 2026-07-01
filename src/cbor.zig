const std = @import("std");

pub const Error = error{
    OutOfMemory,
    UnexpectedEnd,
    InvalidCbor,
    UnsupportedCbor,
};

const decode_depth_max = 64;
const container_items_max = 1 << 20;
const byte_string_size_max = 1 << 26;
const encoded_input_size_max = 1 << 26;
const decoded_node_count_max = 1 << 20;
const render_output_size_max = 1 << 26;
const encoded_output_size_max = 1 << 26;

pub const Value = union(enum) {
    null,
    boolean: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []u8,
    bytes: []u8,
    array: []Value,
    map: []Entry,

    pub const Entry = struct {
        key: Value,
        value: Value,
    };

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .null, .boolean, .int, .uint, .float => {},
            .string => |s| allocator.free(s),
            .bytes => |b| allocator.free(b),
            .array => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .map => |entries| {
                for (entries) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(entries);
            },
        }
        self.* = .null;
    }
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8)) Encoder {
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn map(self: *Encoder, len: u64) Error!void {
        if (len > container_items_max) return Error.UnsupportedCbor;
        try self.typeLen(5, len);
    }

    pub fn array(self: *Encoder, len: u64) Error!void {
        if (len > container_items_max) return Error.UnsupportedCbor;
        try self.typeLen(4, len);
    }

    pub fn text(self: *Encoder, value: []const u8) Error!void {
        if (value.len > byte_string_size_max) return Error.UnsupportedCbor;
        var header: [9]u8 = undefined;
        const header_len = encodeTypeLen(&header, 3, value.len);
        try self.ensureCanAppend(header_len + value.len);
        self.bytes.appendSliceAssumeCapacity(header[0..header_len]);
        self.bytes.appendSliceAssumeCapacity(value);
    }

    pub fn bytesValue(self: *Encoder, value: []const u8) Error!void {
        if (value.len > byte_string_size_max) return Error.UnsupportedCbor;
        var header: [9]u8 = undefined;
        const header_len = encodeTypeLen(&header, 2, value.len);
        try self.ensureCanAppend(header_len + value.len);
        self.bytes.appendSliceAssumeCapacity(header[0..header_len]);
        self.bytes.appendSliceAssumeCapacity(value);
    }

    pub fn boolean(self: *Encoder, value: bool) Error!void {
        try self.appendByte(if (value) 0xf5 else 0xf4);
    }

    pub fn nil(self: *Encoder) Error!void {
        try self.appendByte(0xf6);
    }

    pub fn signed(self: *Encoder, value: anytype) Error!void {
        const Int = @TypeOf(value);
        switch (@typeInfo(Int)) {
            .int, .comptime_int => {},
            else => @compileError("signed expects an integer"),
        }
        if (value >= 0) {
            try self.typeLen(0, @as(u64, @intCast(value)));
        } else {
            const magnitude: i128 = -1 - @as(i128, value);
            try self.typeLen(1, @as(u64, @intCast(magnitude)));
        }
    }

    pub fn unsigned(self: *Encoder, value: u64) Error!void {
        try self.typeLen(0, value);
    }

    pub fn float(self: *Encoder, value: f64) Error!void {
        var buf: [9]u8 = undefined;
        buf[0] = 0xfb;
        const bits: u64 = @bitCast(value);
        std.mem.writeInt(u64, buf[1..9], bits, .big);
        try self.appendSlice(&buf);
    }

    pub fn fieldText(self: *Encoder, key: []const u8, value: []const u8) Error!void {
        const mark = self.bytes.items.len;
        errdefer self.bytes.shrinkRetainingCapacity(mark);
        try self.text(key);
        try self.text(value);
    }

    pub fn fieldBool(self: *Encoder, key: []const u8, value: bool) Error!void {
        const mark = self.bytes.items.len;
        errdefer self.bytes.shrinkRetainingCapacity(mark);
        try self.text(key);
        try self.boolean(value);
    }

    pub fn fieldUnsigned(self: *Encoder, key: []const u8, value: u64) Error!void {
        const mark = self.bytes.items.len;
        errdefer self.bytes.shrinkRetainingCapacity(mark);
        try self.text(key);
        try self.unsigned(value);
    }

    pub fn fieldSigned(self: *Encoder, key: []const u8, value: anytype) Error!void {
        const mark = self.bytes.items.len;
        errdefer self.bytes.shrinkRetainingCapacity(mark);
        try self.text(key);
        try self.signed(value);
    }

    pub fn fieldFloat(self: *Encoder, key: []const u8, value: f64) Error!void {
        const mark = self.bytes.items.len;
        errdefer self.bytes.shrinkRetainingCapacity(mark);
        try self.text(key);
        try self.float(value);
    }

    fn typeLen(self: *Encoder, major: u8, len: u64) Error!void {
        var buf: [9]u8 = undefined;
        const written = encodeTypeLen(&buf, major, len);
        try self.appendSlice(buf[0..written]);
    }

    fn appendByte(self: *Encoder, value: u8) Error!void {
        try self.ensureCanAppend(1);
        self.bytes.appendAssumeCapacity(value);
    }

    fn appendSlice(self: *Encoder, values: []const u8) Error!void {
        try self.ensureCanAppend(values.len);
        self.bytes.appendSliceAssumeCapacity(values);
    }

    fn ensureCanAppend(self: *Encoder, additional: usize) Error!void {
        const next_len = std.math.add(usize, self.bytes.items.len, additional) catch return Error.UnsupportedCbor;
        if (next_len > encoded_output_size_max) return Error.UnsupportedCbor;
        try self.bytes.ensureTotalCapacityPrecise(self.allocator, next_len);
    }

    fn encodeTypeLen(buf: *[9]u8, major: u8, len: u64) usize {
        std.debug.assert(major < 8);
        if (len < 24) {
            buf[0] = (major << 5) | @as(u8, @intCast(len));
            return 1;
        } else if (len <= std.math.maxInt(u8)) {
            buf[0] = (major << 5) | 24;
            buf[1] = @as(u8, @intCast(len));
            return 2;
        } else if (len <= std.math.maxInt(u16)) {
            buf[0] = (major << 5) | 25;
            std.mem.writeInt(u16, buf[1..3], @as(u16, @intCast(len)), .big);
            return 3;
        } else if (len <= std.math.maxInt(u32)) {
            buf[0] = (major << 5) | 26;
            std.mem.writeInt(u32, buf[1..5], @as(u32, @intCast(len)), .big);
            return 5;
        } else {
            buf[0] = (major << 5) | 27;
            std.mem.writeInt(u64, buf[1..9], len, .big);
            return 9;
        }
    }
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8) Error!Value {
    if (data.len > encoded_input_size_max) return Error.UnsupportedCbor;
    var index: usize = 0;
    var node_budget: usize = decoded_node_count_max;
    var value = try decodeOne(allocator, data, &index, 0, &node_budget);
    errdefer value.deinit(allocator);
    if (index != data.len) return Error.InvalidCbor;
    return value;
}

fn decodeOne(
    allocator: std.mem.Allocator,
    data: []const u8,
    index: *usize,
    depth: usize,
    node_budget: *usize,
) Error!Value {
    if (depth > decode_depth_max) return Error.UnsupportedCbor;
    if (node_budget.* == 0) return Error.UnsupportedCbor;
    node_budget.* -= 1;
    const initial = try readByte(data, index);
    const major = initial >> 5;
    const info = initial & 0x1f;
    switch (major) {
        0 => return .{ .uint = try readLen(data, index, info) },
        1 => {
            const n = try readLen(data, index, info);
            if (n > @as(u64, @intCast(std.math.maxInt(i64)))) return Error.UnsupportedCbor;
            const signed_value = -1 - @as(i64, @intCast(n));
            return .{ .int = signed_value };
        },
        2 => {
            const len = try readLen(data, index, info);
            if (len > byte_string_size_max) return Error.UnsupportedCbor;
            const slice = try readBytes(data, index, len);
            const copy = allocator.dupe(u8, slice) catch return Error.OutOfMemory;
            return .{ .bytes = copy };
        },
        3 => {
            const len = try readLen(data, index, info);
            if (len > byte_string_size_max) return Error.UnsupportedCbor;
            const slice = try readBytes(data, index, len);
            const copy = allocator.dupe(u8, slice) catch return Error.OutOfMemory;
            return .{ .string = copy };
        },
        4 => {
            const len_u64 = try readLen(data, index, info);
            if (len_u64 > std.math.maxInt(usize)) return Error.UnsupportedCbor;
            if (len_u64 > container_items_max) return Error.UnsupportedCbor;
            const len: usize = @intCast(len_u64);
            const items = allocator.alloc(Value, len) catch return Error.OutOfMemory;
            errdefer allocator.free(items);
            var filled: usize = 0;
            errdefer for (items[0..filled]) |*item| item.deinit(allocator);
            while (filled < len) : (filled += 1) {
                items[filled] = try decodeOne(allocator, data, index, depth + 1, node_budget);
            }
            return .{ .array = items };
        },
        5 => {
            const len_u64 = try readLen(data, index, info);
            if (len_u64 > std.math.maxInt(usize)) return Error.UnsupportedCbor;
            if (len_u64 > container_items_max) return Error.UnsupportedCbor;
            const len: usize = @intCast(len_u64);
            const entries = allocator.alloc(Value.Entry, len) catch return Error.OutOfMemory;
            errdefer allocator.free(entries);
            var filled: usize = 0;
            errdefer for (entries[0..filled]) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            };
            while (filled < len) : (filled += 1) {
                var key = try decodeOne(allocator, data, index, depth + 1, node_budget);
                const entry_value = decodeOne(allocator, data, index, depth + 1, node_budget) catch |err| {
                    key.deinit(allocator);
                    return err;
                };
                entries[filled] = .{ .key = key, .value = entry_value };
            }
            return .{ .map = entries };
        },
        6 => {
            const tag = try readLen(data, index, info);
            var inner = try decodeOne(allocator, data, index, depth + 1, node_budget);
            if (tag == 91) {
                switch (inner) {
                    .bytes => |bytes| {
                        inner = .{ .string = bytes };
                    },
                    else => {},
                }
            }
            return inner;
        },
        7 => return decodeSimpleFloat(allocator, data, index, info),
        else => return Error.InvalidCbor,
    }
}

fn decodeSimpleFloat(
    allocator: std.mem.Allocator,
    data: []const u8,
    index: *usize,
    info: u8,
) Error!Value {
    _ = allocator;
    return switch (info) {
        20 => .{ .boolean = false },
        21 => .{ .boolean = true },
        22 => .null,
        26 => blk: {
            const bytes = try readBytes(data, index, 4);
            const bits = std.mem.readInt(u32, bytes[0..4], .big);
            break :blk .{ .float = @as(f64, @floatCast(@as(f32, @bitCast(bits)))) };
        },
        27 => blk: {
            const bytes = try readBytes(data, index, 8);
            const bits = std.mem.readInt(u64, bytes[0..8], .big);
            break :blk .{ .float = @bitCast(bits) };
        },
        else => Error.UnsupportedCbor,
    };
}

fn readByte(data: []const u8, index: *usize) Error!u8 {
    if (index.* >= data.len) return Error.UnexpectedEnd;
    const byte = data[index.*];
    index.* += 1;
    return byte;
}

fn readLen(data: []const u8, index: *usize, info: u8) Error!u64 {
    return switch (info) {
        0...23 => info,
        24 => try readByte(data, index),
        25 => blk: {
            const bytes = try readBytes(data, index, 2);
            break :blk std.mem.readInt(u16, bytes[0..2], .big);
        },
        26 => blk: {
            const bytes = try readBytes(data, index, 4);
            break :blk std.mem.readInt(u32, bytes[0..4], .big);
        },
        27 => blk: {
            const bytes = try readBytes(data, index, 8);
            break :blk std.mem.readInt(u64, bytes[0..8], .big);
        },
        else => Error.UnsupportedCbor,
    };
}

fn readBytes(data: []const u8, index: *usize, len_u64: u64) Error![]const u8 {
    if (len_u64 > std.math.maxInt(usize)) return Error.UnsupportedCbor;
    const len: usize = @intCast(len_u64);
    if (index.* > data.len) return Error.UnexpectedEnd;
    if (data.len - index.* < len) return Error.UnexpectedEnd;
    const start = index.*;
    index.* += len;
    return data[start..][0..len];
}

pub fn appendJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: Value) Error!void {
    const mark = out.items.len;
    errdefer out.shrinkRetainingCapacity(mark);
    try appendJsonDepth(allocator, out, value, 0);
}

fn appendJsonDepth(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: Value, depth: usize) Error!void {
    if (depth > decode_depth_max) return Error.UnsupportedCbor;
    switch (value) {
        .null => try appendJsonSlice(allocator, out, "null"),
        .boolean => |b| try appendJsonSlice(allocator, out, if (b) "true" else "false"),
        .int => |n| try appendFmt(allocator, out, "{}", .{n}),
        .uint => |n| try appendFmt(allocator, out, "{}", .{n}),
        .float => |f| {
            if (std.math.isNan(f)) {
                try appendJsonSlice(allocator, out, "NaN");
            } else if (std.math.isPositiveInf(f)) {
                try appendJsonSlice(allocator, out, "Infinity");
            } else if (std.math.isNegativeInf(f)) {
                try appendJsonSlice(allocator, out, "-Infinity");
            } else {
                try appendFmt(allocator, out, "{d}", .{f});
            }
        },
        .string => |s| try appendJsonString(allocator, out, s),
        .bytes => |bytes| {
            try appendJsonSlice(allocator, out, "[");
            for (bytes, 0..) |byte, i| {
                if (i != 0) try appendJsonSlice(allocator, out, ",");
                try appendFmt(allocator, out, "{}", .{byte});
            }
            try appendJsonSlice(allocator, out, "]");
        },
        .array => |items| {
            try appendJsonSlice(allocator, out, "[");
            for (items, 0..) |item, i| {
                if (i != 0) try appendJsonSlice(allocator, out, ",");
                try appendJsonDepth(allocator, out, item, depth + 1);
            }
            try appendJsonSlice(allocator, out, "]");
        },
        .map => |entries| {
            try appendJsonSlice(allocator, out, "{");
            for (entries, 0..) |entry, i| {
                if (i != 0) try appendJsonSlice(allocator, out, ",");
                switch (entry.key) {
                    .string => |s| try appendJsonString(allocator, out, s),
                    else => try appendJsonDepth(allocator, out, entry.key, depth + 1),
                }
                try appendJsonSlice(allocator, out, ":");
                try appendJsonDepth(allocator, out, entry.value, depth + 1);
            }
            try appendJsonSlice(allocator, out, "}");
        },
    }
}

fn appendJsonSlice(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) Error!void {
    const next_len = std.math.add(usize, out.items.len, text.len) catch return Error.UnsupportedCbor;
    if (next_len > render_output_size_max) return Error.UnsupportedCbor;
    try out.ensureTotalCapacityPrecise(allocator, next_len);
    out.appendSliceAssumeCapacity(text);
}

fn appendJsonByte(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) Error!void {
    const next_len = std.math.add(usize, out.items.len, 1) catch return Error.UnsupportedCbor;
    if (next_len > render_output_size_max) return Error.UnsupportedCbor;
    try out.ensureTotalCapacityPrecise(allocator, next_len);
    out.appendAssumeCapacity(byte);
}

fn appendFmt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    const text = std.fmt.allocPrint(allocator, fmt, args) catch return Error.OutOfMemory;
    defer allocator.free(text);
    try appendJsonSlice(allocator, out, text);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try appendJsonByte(allocator, out, '"');
    for (s) |byte| {
        switch (byte) {
            '"' => try appendJsonSlice(allocator, out, "\\\""),
            '\\' => try appendJsonSlice(allocator, out, "\\\\"),
            '\n' => try appendJsonSlice(allocator, out, "\\n"),
            '\r' => try appendJsonSlice(allocator, out, "\\r"),
            '\t' => try appendJsonSlice(allocator, out, "\\t"),
            0...8, 11...12, 14...0x1f => try appendFmt(allocator, out, "\\u{x:0>4}", .{byte}),
            else => try appendJsonByte(allocator, out, byte),
        }
    }
    try appendJsonByte(allocator, out, '"');
}

test "CBOR round-trips simple values" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var enc = Encoder.init(allocator, &bytes);
    try enc.array(3);
    try enc.signed(-1);
    try enc.text("hi");
    try enc.boolean(true);

    var value = try decode(allocator, bytes.items);
    defer value.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), value.array.len);
}

test "CBOR rejects trailing data without leaking decoded value" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.InvalidCbor, decode(allocator, &.{ 0x01, 0x02 }));
}

test "CBOR map decode cleans key when value is truncated" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.UnexpectedEnd, decode(allocator, &.{ 0xa1, 0x61, 'a' }));
}

test "CBOR encoder rejects oversized primitive lengths without mutation" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var enc = Encoder.init(allocator, &bytes);

    try std.testing.expectError(Error.UnsupportedCbor, enc.array(container_items_max + 1));
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectError(Error.UnsupportedCbor, enc.map(container_items_max + 1));
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);

    const one: u8 = 0;
    const huge = @as([*]const u8, @ptrCast(&one))[0 .. byte_string_size_max + 1];
    try std.testing.expectError(Error.UnsupportedCbor, enc.text(huge));
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectError(Error.UnsupportedCbor, enc.bytesValue(huge));
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
}

test "CBOR encoder enforces aggregate output cap before allocation" {
    const allocator = std.testing.allocator;
    var backing: [1]u8 = undefined;
    var bytes: std.ArrayList(u8) = .{
        .items = @as([*]u8, @ptrCast(&backing))[0..encoded_output_size_max],
        .capacity = encoded_output_size_max,
    };
    var enc = Encoder.init(allocator, &bytes);
    try std.testing.expectError(Error.UnsupportedCbor, enc.nil());
    try std.testing.expectEqual(@as(usize, encoded_output_size_max), bytes.items.len);
}

test "CBOR field writers roll back partial mutation on allocation failure" {
    var key_storage: [4]u8 = undefined;
    var key_fba = std.heap.FixedBufferAllocator.init(&key_storage);
    var key_bytes: std.ArrayList(u8) = .empty;
    var key_encoder = Encoder.init(key_fba.allocator(), &key_bytes);
    try key_encoder.text("a");
    try std.testing.expectEqual(@as(usize, 2), key_bytes.items.len);

    var storage: [4]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fba.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    var enc = Encoder.init(allocator, &bytes);

    try std.testing.expectError(Error.OutOfMemory, enc.fieldText("a", "value-too-large"));
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
}

const CborHeader = struct {
    bytes: [9]u8,
    len: usize,

    fn slice(self: *const CborHeader) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn cborHeader(comptime major: u8, len: u64) CborHeader {
    comptime std.debug.assert(major < 8);
    var header: CborHeader = .{ .bytes = undefined, .len = 0 };
    if (len <= std.math.maxInt(u32)) {
        header.bytes[0] = (major << 5) | 26;
        std.mem.writeInt(u32, header.bytes[1..5], @as(u32, @intCast(len)), .big);
        header.len = 5;
        return header;
    }
    header.bytes[0] = (major << 5) | 27;
    std.mem.writeInt(u64, header.bytes[1..9], len, .big);
    header.len = 9;
    return header;
}

test "CBOR decode rejects over-cap declared lengths before payload allocation" {
    const allocator = std.testing.allocator;
    const bytes_header = cborHeader(2, byte_string_size_max + 1);
    try std.testing.expectError(Error.UnsupportedCbor, decode(allocator, bytes_header.slice()));
    const text_header = cborHeader(3, byte_string_size_max + 1);
    try std.testing.expectError(Error.UnsupportedCbor, decode(allocator, text_header.slice()));
    const array_header = cborHeader(4, container_items_max + 1);
    try std.testing.expectError(Error.UnsupportedCbor, decode(allocator, array_header.slice()));
    const map_header = cborHeader(5, container_items_max + 1);
    try std.testing.expectError(Error.UnsupportedCbor, decode(allocator, map_header.slice()));
}

test "CBOR encoder successful appends keep capacity within encoded cap" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var enc = Encoder.init(allocator, &bytes);
    try enc.text("abc");
    try std.testing.expectEqual(@as(usize, 4), bytes.items.len);
    try std.testing.expect(bytes.capacity <= encoded_output_size_max);
    try std.testing.expectEqual(bytes.items.len, bytes.capacity);
}

test "CBOR JSON render successful appends keep capacity within render cap" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendJson(allocator, &out, .null);
    try std.testing.expect(out.capacity <= render_output_size_max);
    try std.testing.expectEqual(out.items.len, out.capacity);
}

test "CBOR render rejects aggregate output cap without mutation" {
    const allocator = std.testing.allocator;
    var backing: [1]u8 = undefined;
    var out: std.ArrayList(u8) = .{
        .items = @as([*]u8, @ptrCast(&backing))[0..render_output_size_max],
        .capacity = render_output_size_max,
    };
    try std.testing.expectError(Error.UnsupportedCbor, appendJson(allocator, &out, .null));
    try std.testing.expectEqual(@as(usize, render_output_size_max), out.items.len);
}

fn nestedArrayValue(allocator: std.mem.Allocator, depth: usize) Error!Value {
    if (depth == 0) return .null;
    const items = allocator.alloc(Value, 1) catch return Error.OutOfMemory;
    errdefer allocator.free(items);
    items[0] = try nestedArrayValue(allocator, depth - 1);
    return .{ .array = items };
}

test "CBOR render rejects depth over cap" {
    const allocator = std.testing.allocator;
    var value = try nestedArrayValue(allocator, decode_depth_max + 1);
    defer value.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try std.testing.expectError(Error.UnsupportedCbor, appendJson(allocator, &out, value));
}

test "CBOR decode rejects encoded input over cap before reading" {
    const allocator = std.testing.allocator;
    const one: u8 = 0xf6;
    const huge = @as([*]const u8, @ptrCast(&one))[0 .. encoded_input_size_max + 1];
    try std.testing.expectError(Error.UnsupportedCbor, decode(allocator, huge));
}

test "CBOR decode rejects depth over cap" {
    const allocator = std.testing.allocator;
    var data: [decode_depth_max + 2]u8 = undefined;
    for (data[0 .. data.len - 1]) |*byte| byte.* = 0x81;
    data[data.len - 1] = 0xf6;
    try std.testing.expectError(Error.UnsupportedCbor, decode(allocator, &data));
}

test "CBOR decode rejects exhausted decoded-node budget" {
    const allocator = std.testing.allocator;
    var index: usize = 0;
    var node_budget: usize = 0;
    try std.testing.expectError(Error.UnsupportedCbor, decodeOne(allocator, &.{0xf6}, &index, 0, &node_budget));
}

test "CBOR render rolls back cap-crossing partial writes" {
    const allocator = std.testing.allocator;
    const storage = try allocator.alloc(u8, render_output_size_max);
    defer allocator.free(storage);
    @memset(storage, 0xaa);

    var out: std.ArrayList(u8) = .{
        .items = storage[0 .. render_output_size_max - 1],
        .capacity = render_output_size_max,
    };
    const original_len = out.items.len;
    const original_last = out.items[original_len - 1];
    var empty: [0]u8 = .{};

    try std.testing.expectError(Error.UnsupportedCbor, appendJson(allocator, &out, .{ .string = &empty }));
    try std.testing.expectEqual(original_len, out.items.len);
    try std.testing.expectEqual(original_last, out.items[original_len - 1]);
}
