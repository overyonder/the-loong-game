//! An inspected bot's state read straight from its memory
//! (tools/viewer/diagnostics.md, "State from memory"). The bot keeps a
//! table of the regions its state occupies and a schema describing their types,
//! and names both on a `LOG LOONG_STATE` line when it wants its state seen. The
//! judge copies every region at that moment, while the guest waits in the write,
//! and records the table and what changed since the last capture, in whole
//! 64-byte blocks, as JSON for the turn's inspection record. The table is a u32
//! count, then per region its address, bytes, schema type, elements and the
//! address of the field that refers to it (0 for a root), all little-endian u32.
const std = @import("std");

/// Changes are sent in whole blocks of this many bytes.
const BLOCK = 64;
const ENTRY = 20;

pub const Regions = struct {
    /// Each region's bytes as last captured, by its address, so a region
    /// keeps its copy however the table's order changes.
    last: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    listed: std.AutoHashMapUnmanaged(u32, void) = .empty,
    schema_sent: bool = false,

    pub fn deinit(self: *Regions, allocator: std.mem.Allocator) void {
        var copies = self.last.valueIterator();
        while (copies.next()) |bytes| allocator.free(bytes.*);
        self.last.deinit(allocator);
        self.listed.deinit(allocator);
    }

    /// Capture the regions `table` lists in `memory` into `out` as a JSON
    /// object: the schema the first time; every region as [address, bytes,
    /// type, elements, owner]; and the bytes that changed since the last
    /// capture, or all of a region new at its address, as [address, offset,
    /// base64]. A table or region outside memory is left out, and a region no
    /// longer listed is forgotten.
    pub fn capture(self: *Regions, allocator: std.mem.Allocator, memory: []const u8, table: u32, schema: [2]u32, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        const count = std.mem.readInt(u32, (slice(memory, table, 4) orelse return)[0..4], .little);
        const entries = slice(memory, table +| 4, count *| ENTRY) orelse return;
        try out.appendSlice(allocator, "{");
        if (!self.schema_sent) {
            if (slice(memory, schema[0], schema[1])) |text| {
                try out.appendSlice(allocator, "\"schema\":");
                const quoted = try std.json.Stringify.valueAlloc(allocator, text, .{});
                defer allocator.free(quoted);
                try out.appendSlice(allocator, quoted);
                try out.appendSlice(allocator, ",");
                self.schema_sent = true;
            }
        }
        try out.appendSlice(allocator, "\"regions\":[");
        var listed: usize = 0;
        for (0..count) |index| {
            const entry = entries[ENTRY * index ..][0..ENTRY];
            const address = std.mem.readInt(u32, entry[0..4], .little);
            const bytes = std.mem.readInt(u32, entry[4..8], .little);
            if (slice(memory, address, bytes) == null) continue;
            try out.print(allocator, "{s}[{d},{d},{d},{d},{d}]", .{
                if (listed == 0) "" else ",",
                address,
                bytes,
                std.mem.readInt(u32, entry[8..12], .little),
                std.mem.readInt(u32, entry[12..16], .little),
                std.mem.readInt(u32, entry[16..20], .little),
            });
            listed += 1;
        }
        try out.appendSlice(allocator, "],\"changes\":[");
        self.listed.clearRetainingCapacity();
        var changes: usize = 0;
        for (0..count) |index| {
            const entry = entries[ENTRY * index ..][0..ENTRY];
            const address = std.mem.readInt(u32, entry[0..4], .little);
            const bytes = std.mem.readInt(u32, entry[4..8], .little);
            const now = slice(memory, address, bytes) orelse continue;
            // A region listed twice, through two references, is sent once.
            if ((try self.listed.getOrPut(allocator, address)).found_existing) continue;
            const known = self.last.getPtr(address);
            if (known == null or known.?.len != bytes) {
                if (known) |copy| allocator.free(copy.*);
                try self.last.put(allocator, address, try allocator.dupe(u8, now));
                if (bytes > 0) {
                    try appendChange(allocator, out, address, 0, now, changes);
                    changes += 1;
                }
                continue;
            }
            const last = known.?.*;
            // Runs of changed blocks, each sent whole.
            var start: usize = 0;
            while (start < bytes) {
                const end = @min(start + BLOCK, bytes);
                if (std.mem.eql(u8, last[start..end], now[start..end])) {
                    start = end;
                    continue;
                }
                var stop = end;
                while (stop < bytes) {
                    const next = @min(stop + BLOCK, bytes);
                    if (std.mem.eql(u8, last[stop..next], now[stop..next])) break;
                    stop = next;
                }
                try appendChange(allocator, out, address, start, now[start..stop], changes);
                changes += 1;
                @memcpy(last[start..stop], now[start..stop]);
                start = stop;
            }
        }
        // Forget the regions no longer listed.
        var stale: std.ArrayList(u32) = .empty;
        defer stale.deinit(allocator);
        var addresses = self.last.keyIterator();
        while (addresses.next()) |address| {
            if (!self.listed.contains(address.*)) try stale.append(allocator, address.*);
        }
        for (stale.items) |address| {
            if (self.last.fetchRemove(address)) |removed| allocator.free(removed.value);
        }
        try out.appendSlice(allocator, "]}");
    }
};

fn slice(memory: []const u8, address: u32, bytes: u32) ?[]const u8 {
    if (@as(u64, address) + bytes > memory.len) return null;
    return memory[address..][0..bytes];
}

fn appendChange(allocator: std.mem.Allocator, out: *std.ArrayList(u8), address: u32, offset: usize, bytes: []const u8, index: usize) !void {
    const encoder = std.base64.standard.Encoder;
    try out.print(allocator, "{s}[{d},{d},\"", .{ if (index == 0) "" else ",", address, offset });
    const start = out.items.len;
    try out.resize(allocator, start + encoder.calcSize(bytes.len));
    _ = encoder.encode(out.items[start..], bytes);
    try out.appendSlice(allocator, "\"]");
}
