//! Prices a bot module in CPU points, as the judge does: the toolkit's metering.py,
//! a module-to-module pass that charges each block's instructions against an
//! exported global and flags exhaustion. Its output is byte for byte the toolkit's,
//! which `just judge-fidelity` checks, so a bot is metered here rather than by the
//! toolkit's Python.

const std = @import("std");

pub const REMAINING = "wasmer_metering_remaining_points";
pub const EXHAUSTED = "wasmer_metering_points_exhausted";
const INITIAL_POINTS: i64 = std.math.maxInt(i64);
const BULK_BYTES_PER_POINT_SHIFT: i64 = 3;
const SECTION_ORDER = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 10, 11 };
const LOOP: u32 = 0x03;
const FC: u32 = 0xFC << 16;

const Error = error{ Truncated, NoCodeSection, OutOfMemory };

/// Whether a module already carries the meter, as a metered build does.
pub fn isMetered(blob: []const u8) bool {
    return std.mem.indexOf(u8, blob, REMAINING) != null;
}

/// Points per instruction, checked in metering.py's order.
fn cost(code: u32) i64 {
    switch (code) {
        0x6D, 0x6E, 0x6F, 0x70, 0x7F, 0x80, 0x81, 0x82, 0x95, 0xA3 => return 3,
        else => {},
    }
    switch (code) {
        0x28...0x3F, 0x04, 0x0C, 0x0D, 0x0F => return 2,
        else => {},
    }
    switch (code) {
        0x00, 0x01, 0x02, 0x03, 0x05, 0x0B, 0x1A, 0x1B, 0x1C, 0x20...0x24, 0x41...0xC4, 0xD0, 0xD1, 0xD2 => return 1,
        else => {},
    }
    return switch (code) {
        0x25, 0x26, FC | 8, FC | 9, FC | 10, FC | 11, FC | 12, FC | 13, FC | 14, FC | 16, FC | 17 => 10,
        0x40, FC | 15 => 50,
        0x0E => 3,
        0x10 => 4,
        0x11...0x15 => 6,
        else => 2,
    };
}

/// The operator classes a profile splits points into, in its counters' order.
pub const classes = [_][]const u8{ "arithmetic", "locals", "memory", "simd", "calls", "control", "other" };
const MEMORY: u64 = 2;
pub const SIMD: u64 = 3;

/// The class of an instruction, by its place in `classes`.
fn classOf(code: u32) u64 {
    return switch (code >> 16) {
        0xFD => SIMD,
        0xFC => if (code & 0xFFFF <= 7) 0 else MEMORY,
        0xFE => 6,
        else => switch (code) {
            0x10...0x15 => 4,
            0x00...0x0F, 0x18, 0x19, 0x1F => 5,
            0x1A...0x1C, 0x20...0x24 => 1,
            0x25, 0x26, 0x28...0x40 => MEMORY,
            0x41...0xC4 => 0,
            else => 6,
        },
    };
}

fn endsBlock(code: u32) bool {
    return switch (code) {
        0x03, 0x04, 0x05, 0x07...0x15, 0x18 => true,
        else => false,
    };
}

fn bulkLength(code: u32) bool {
    return code == FC | 8 or code == FC | 10 or code == FC | 11;
}

const Reader = struct {
    b: []const u8,
    i: usize,

    fn byte(self: *Reader) Error!u8 {
        if (self.i >= self.b.len) return error.Truncated;
        defer self.i += 1;
        return self.b[self.i];
    }

    fn skip(self: *Reader, n: usize) Error!void {
        if (self.i + n > self.b.len) return error.Truncated;
        self.i += n;
    }

    fn uleb(self: *Reader) Error!u64 {
        var value: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try self.byte();
            if (shift < 64) value |= @as(u64, b & 0x7F) << @intCast(shift);
            if (b & 0x80 == 0) return value;
            shift += 7;
        }
    }

    fn sleb(self: *Reader) Error!void {
        while ((try self.byte()) & 0x80 != 0) {}
    }

    fn blocktype(self: *Reader) Error!void {
        if (self.i >= self.b.len) return error.Truncated;
        switch (self.b[self.i]) {
            0x40, 0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F => self.i += 1,
            else => try self.sleb(),
        }
    }

    fn memarg(self: *Reader) Error!void {
        const alignment = try self.uleb();
        if (alignment & 0x40 != 0) _ = try self.uleb();
        _ = try self.uleb();
    }

    /// The next instruction's code: the opcode, or prefix << 16 | subopcode.
    fn op(self: *Reader) Error!u32 {
        const code = try self.byte();
        switch (code) {
            0x02, 0x03, 0x04, 0x06, 0x1F => {
                try self.blocktype();
                if (code == 0x1F) {
                    const n = try self.uleb();
                    for (0..n) |_| {
                        const kind = try self.byte();
                        if (kind == 0x00 or kind == 0x01) _ = try self.uleb();
                        _ = try self.uleb();
                    }
                }
            },
            0x07, 0x08, 0x09, 0x0C, 0x0D, 0x10, 0x12, 0x14, 0x15, 0x18, 0x20...0x26, 0x3F, 0x40, 0xD2 => _ = try self.uleb(),
            0x11, 0x13 => {
                _ = try self.uleb();
                _ = try self.uleb();
            },
            0x0E => {
                const n = try self.uleb();
                for (0..n + 1) |_| _ = try self.uleb();
            },
            0x1C => try self.skip(@intCast(try self.uleb())),
            0x28...0x3E => try self.memarg(),
            0x41, 0x42 => try self.sleb(),
            0x43 => try self.skip(4),
            0x44 => try self.skip(8),
            0xD0 => try self.blocktype(),
            0xFC => {
                const sub: u32 = @truncate(try self.uleb());
                switch (sub) {
                    8, 10, 12, 14 => {
                        _ = try self.uleb();
                        _ = try self.uleb();
                    },
                    9, 11, 13, 15, 16, 17 => _ = try self.uleb(),
                    else => {},
                }
                return FC | sub;
            },
            0xFD => {
                const sub: u32 = @truncate(try self.uleb());
                switch (sub) {
                    0...11, 92, 93 => try self.memarg(),
                    12, 13 => try self.skip(16),
                    21...34 => try self.skip(1),
                    84...91 => {
                        try self.memarg();
                        try self.skip(1);
                    },
                    else => {},
                }
                return (0xFD << 16) | sub;
            },
            0xFE => {
                const sub: u32 = @truncate(try self.uleb());
                switch (sub) {
                    0, 1, 2, 0x10...0x4E => try self.memarg(),
                    3 => try self.skip(1),
                    else => {},
                }
                return (0xFE << 16) | sub;
            },
            else => {},
        }
        return code;
    }
};

const Section = struct { id: u8, body: usize, end: usize, head: usize };

fn sections(allocator: std.mem.Allocator, blob: []const u8) Error![]Section {
    var list: std.ArrayList(Section) = .empty;
    errdefer list.deinit(allocator);
    var r = Reader{ .b = blob, .i = 8 };
    while (r.i < blob.len) {
        const head = r.i;
        const id = try r.byte();
        const size: usize = @intCast(try r.uleb());
        if (r.i + size > blob.len) return error.Truncated;
        try list.append(allocator, .{ .id = id, .body = r.i, .end = r.i + size, .head = head });
        r.i += size;
    }
    return list.toOwnedSlice(allocator);
}

const Out = struct {
    list: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn bytes(self: *Out, data: []const u8) Error!void {
        try self.list.appendSlice(self.allocator, data);
    }

    fn byte(self: *Out, b: u8) Error!void {
        try self.list.append(self.allocator, b);
    }

    fn uleb(self: *Out, value: u64) Error!void {
        var v = value;
        while (true) {
            const b: u8 = @truncate(v & 0x7F);
            v >>= 7;
            if (v != 0) try self.byte(b | 0x80) else return self.byte(b);
        }
    }

    fn sleb(self: *Out, value: i64) Error!void {
        var v = value;
        while (true) {
            const b: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7F);
            v >>= 7;
            const done = (v == 0 and b & 0x40 == 0) or (v == -1 and b & 0x40 != 0);
            try self.byte(if (done) b else b | 0x80);
            if (done) return;
        }
    }

    fn check(self: *Out, rem: u64, exh: u64) Error!void {
        try self.byte(0x23);
        try self.uleb(rem);
        try self.bytes("\x42\x00\x53\x04\x40\x41\x01\x24");
        try self.uleb(exh);
        try self.bytes("\x00\x0b");
    }

    fn charge(self: *Out, rem: u64, points: i64) Error!void {
        try self.byte(0x23);
        try self.uleb(rem);
        try self.byte(0x42);
        try self.sleb(points);
        try self.bytes("\x7d\x24");
        try self.uleb(rem);
    }

    /// Add `points` to the profile counter `global`.
    fn tally(self: *Out, global: u64, points: i64) Error!void {
        try self.byte(0x23);
        try self.uleb(global);
        try self.byte(0x42);
        try self.sleb(points);
        try self.bytes("\x7c\x24");
        try self.uleb(global);
    }

    /// Add a bulk operation's length charge, as `chargeLength` takes it, to
    /// the profile counter `global`.
    fn tallyLength(self: *Out, global: u64, scratch: u64) Error!void {
        try self.byte(0x23);
        try self.uleb(global);
        try self.byte(0x23);
        try self.uleb(scratch);
        try self.bytes("\xad\x42");
        try self.sleb(BULK_BYTES_PER_POINT_SHIFT);
        try self.bytes("\x88\x7c\x24");
        try self.uleb(global);
    }

    fn chargeLength(self: *Out, rem: u64, scratch: u64) Error!void {
        try self.byte(0x24);
        try self.uleb(scratch);
        try self.byte(0x23);
        try self.uleb(scratch);
        try self.byte(0x23);
        try self.uleb(rem);
        try self.byte(0x23);
        try self.uleb(scratch);
        try self.bytes("\xad\x42");
        try self.sleb(BULK_BYTES_PER_POINT_SHIFT);
        try self.bytes("\x88\x7d\x24");
        try self.uleb(rem);
    }
};

/// Meter one function body. With `profile`, its first profile counter's
/// global, each block's points also go to the counter of each class they
/// were spent in; the meter charges exactly what it charges without.
fn instrumentBody(out: *Out, blob: []const u8, start: usize, end: usize, rem: u64, exh: u64, scratch: u64, profile: ?u64) Error!void {
    var r = Reader{ .b = blob[0..end], .i = start };
    const locals = try r.uleb();
    for (0..locals) |_| {
        _ = try r.uleb();
        try r.skip(1);
    }
    try out.bytes(blob[start..r.i]);
    try out.check(rem, exh);
    var acc: i64 = 0;
    var by_class: [classes.len]i64 = @splat(0);
    while (r.i < end) {
        const at = r.i;
        const code = try r.op();
        acc += cost(code);
        by_class[classOf(code)] += cost(code);
        if (endsBlock(code) and acc > 0) {
            try out.charge(rem, acc);
            acc = 0;
            if (profile) |first| {
                for (by_class, 0..) |points, class| {
                    if (points > 0) try out.tally(first + class, points);
                }
            }
            by_class = @splat(0);
        }
        if (bulkLength(code)) {
            try out.chargeLength(rem, scratch);
            if (profile) |first| try out.tallyLength(first + MEMORY, scratch);
        }
        try out.bytes(blob[at..r.i]);
        if (code == LOOP) try out.check(rem, exh);
    }
}

fn importedGlobals(blob: []const u8, start: usize, end: usize) Error!u64 {
    var total: u64 = 0;
    var r = Reader{ .b = blob[0..end], .i = start };
    const n = try r.uleb();
    for (0..n) |_| {
        try r.skip(@intCast(try r.uleb()));
        try r.skip(@intCast(try r.uleb()));
        const kind = try r.byte();
        switch (kind) {
            0 => _ = try r.uleb(),
            1 => {
                try r.skip(1);
                const limits = try r.byte();
                _ = try r.uleb();
                if (limits != 0) _ = try r.uleb();
            },
            2 => {
                const limits = try r.byte();
                _ = try r.uleb();
                if (limits & 1 != 0) _ = try r.uleb();
            },
            else => {
                total += 1;
                try r.skip(2);
            },
        }
    }
    return total;
}

/// Functions an import section brings in.
fn importedFunctions(blob: []const u8, start: usize, end: usize) Error!usize {
    var total: usize = 0;
    var r = Reader{ .b = blob[0..end], .i = start };
    const n = try r.uleb();
    for (0..n) |_| {
        try r.skip(@intCast(try r.uleb()));
        try r.skip(@intCast(try r.uleb()));
        switch (try r.byte()) {
            0 => {
                total += 1;
                _ = try r.uleb();
            },
            1 => {
                try r.skip(1);
                const limits = try r.byte();
                _ = try r.uleb();
                if (limits != 0) _ = try r.uleb();
            },
            2 => {
                const limits = try r.byte();
                _ = try r.uleb();
                if (limits & 1 != 0) _ = try r.uleb();
            },
            3 => try r.skip(2),
            else => _ = try r.uleb(),
        }
    }
    return total;
}

fn orderOf(id: u8) usize {
    return std.mem.indexOfScalar(u8, &SECTION_ORDER, id) orelse 0;
}

/// Where a profiled module keeps its counters: `classes.len` i64 globals per
/// defined function, function by function in code-section order, exported
/// as `p0`, `p1` and on.
pub const Profile = struct {
    /// Defined functions.
    functions: usize = 0,
    /// Imported functions, which come first in the index space.
    imported_functions: usize = 0,
};

/// The metered module; the caller frees it.
pub fn instrument(allocator: std.mem.Allocator, blob: []const u8) Error![]u8 {
    return instrumentWith(allocator, blob, null);
}

/// The metered module with a profile's counters, as `profile` then describes;
/// the caller frees it. Its meter charges exactly what `instrument`'s does.
pub fn instrumentProfiled(allocator: std.mem.Allocator, blob: []const u8, profile: *Profile) Error![]u8 {
    return instrumentWith(allocator, blob, profile);
}

fn instrumentWith(allocator: std.mem.Allocator, blob: []const u8, profile: ?*Profile) Error![]u8 {
    const all = try sections(allocator, blob);
    defer allocator.free(all);
    var found: [13]?Section = @splat(null);
    for (all) |s| {
        if (s.id < found.len and found[s.id] == null) found[s.id] = s;
    }

    const imported = if (found[2]) |s| try importedGlobals(blob, s.body, s.end) else 0;
    var defined: u64 = 0;
    var gbody: []const u8 = "";
    if (found[6]) |s| {
        var r = Reader{ .b = blob[0..s.end], .i = s.body };
        defined = try r.uleb();
        gbody = blob[r.i..s.end];
    }
    const rem = imported + defined;
    const exh = rem + 1;
    const scratch = rem + 2;
    const code = found[10] orelse return error.NoCodeSection;
    const functions: u64 = blk: {
        var r = Reader{ .b = blob[0..code.end], .i = code.body };
        break :blk try r.uleb();
    };
    const counters: u64 = if (profile != null) functions * classes.len else 0;

    var globals_section = Out{ .allocator = allocator };
    defer globals_section.list.deinit(allocator);
    try globals_section.uleb(defined + 3 + counters);
    try globals_section.bytes(gbody);
    try globals_section.bytes("\x7e\x01\x42");
    try globals_section.sleb(INITIAL_POINTS);
    try globals_section.bytes("\x0b\x7f\x01\x41\x00\x0b\x7f\x01\x41\x00\x0b");
    for (0..counters) |_| try globals_section.bytes("\x7e\x01\x42\x00\x0b");

    var exported: u64 = 0;
    var ebody: []const u8 = "";
    if (found[7]) |s| {
        var r = Reader{ .b = blob[0..s.end], .i = s.body };
        exported = try r.uleb();
        ebody = blob[r.i..s.end];
    }
    var exports_section = Out{ .allocator = allocator };
    defer exports_section.list.deinit(allocator);
    try exports_section.uleb(exported + 2 + counters);
    try exports_section.bytes(ebody);
    try exports_section.uleb(REMAINING.len);
    try exports_section.bytes(REMAINING);
    try exports_section.byte(0x03);
    try exports_section.uleb(rem);
    try exports_section.uleb(EXHAUSTED.len);
    try exports_section.bytes(EXHAUSTED);
    try exports_section.byte(0x03);
    try exports_section.uleb(exh);
    var name_buffer: [24]u8 = undefined;
    for (0..counters) |counter| {
        const name = std.fmt.bufPrint(&name_buffer, "p{d}", .{counter}) catch unreachable;
        try exports_section.uleb(name.len);
        try exports_section.bytes(name);
        try exports_section.byte(0x03);
        try exports_section.uleb(scratch + 1 + counter);
    }
    if (profile) |layout| layout.* = .{
        .functions = functions,
        .imported_functions = if (found[2]) |s| try importedFunctions(blob, s.body, s.end) else 0,
    };

    var code_section = Out{ .allocator = allocator };
    defer code_section.list.deinit(allocator);
    var body = Out{ .allocator = allocator };
    defer body.list.deinit(allocator);
    var r = Reader{ .b = blob[0..code.end], .i = code.body };
    const n = try r.uleb();
    try code_section.uleb(n);
    for (0..n) |index| {
        const size: usize = @intCast(try r.uleb());
        if (r.i + size > code.end) return error.Truncated;
        body.list.clearRetainingCapacity();
        try instrumentBody(&body, blob, r.i, r.i + size, rem, exh, scratch,
            if (profile != null) scratch + 1 + index * classes.len else null);
        try code_section.uleb(body.list.items.len);
        try code_section.bytes(body.list.items);
        r.i += size;
    }

    var out = Out{ .allocator = allocator };
    errdefer out.list.deinit(allocator);
    try out.bytes(blob[0..8]);
    var written: [13]bool = @splat(false);
    for (all) |s| {
        // A module without globals or exports gets them before the first later section.
        for ([_]u8{ 6, 7 }) |missing| {
            if (found[missing] != null or written[missing]) continue;
            if (s.id != 0 and orderOf(s.id) > orderOf(missing)) {
                const section = if (missing == 6) globals_section.list.items else exports_section.list.items;
                try out.byte(missing);
                try out.uleb(section.len);
                try out.bytes(section);
                written[missing] = true;
            }
        }
        if (s.id == 0) {
            try out.bytes(blob[s.head..s.end]);
        } else {
            const section = switch (s.id) {
                6 => globals_section.list.items,
                7 => exports_section.list.items,
                10 => code_section.list.items,
                else => blob[s.body..s.end],
            };
            try out.byte(s.id);
            try out.uleb(section.len);
            try out.bytes(section);
        }
        if (s.id < written.len) written[s.id] = true;
    }
    return out.list.toOwnedSlice(allocator);
}
