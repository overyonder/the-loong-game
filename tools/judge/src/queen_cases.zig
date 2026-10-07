//! Independently calculated queen-rule examples for the existing lockstep host.
//! The oracle still runs the complete match and supplies every turn block.
const std = @import("std");
const engine = @import("engine.zig");

pub const Case = struct {
    name: []const u8,
    first_team: u1 = 0,
    lengths: [6]u8 = .{ 5, 5, 0, 0, 0, 0 },
    first: [6][]const u8 = .{ "MOVE E", "MOVE E", "MOVE E", "MOVE E", "MOVE E", "MOVE E" },
    last: ?[]const u8 = null,
    terrain: []const u8 = "",
    after_first: ?i32 = null,
    queens: ?[2]i32 = null,
    winner: ?engine.Winner = null,
    rounds: ?i32 = null,
    reason: ?i32 = null,

    pub fn initialCount(self: Case) usize {
        var count: usize = 0;
        for (self.lengths) |length| if (length > 0) {
            count += 1;
        };
        return count;
    }

    pub fn mapText(self: Case, allocator: std.mem.Allocator) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        try text.appendSlice(allocator, "MAP 64 64\nUNIT_LIMIT 64\n");
        try text.print(allocator, "TILE_COUNT {d}\nEDGE_COUNT {d}\nDRAGON_COUNT {d}\n", .{
            std.mem.count(u8, self.terrain, "TILE "), std.mem.count(u8, self.terrain, "EDGE "), self.initialCount(),
        });
        try text.appendSlice(allocator, self.terrain);
        for (self.lengths, 0..) |length, id| {
            if (length == 0) break;
            try text.print(allocator, "DRAGON {d} {d}", .{ (id % 2) ^ self.first_team, length });
            for (0..length) |segment| try text.print(allocator, " {d} {d}", .{ (96 - segment) % 64, 5 + 8 * id });
            try text.appendSlice(allocator, "\n");
        }
        try text.appendSlice(allocator, "END\n");
        return text.toOwnedSlice(allocator);
    }

    pub fn action(self: Case, round: i32, id: u32) []const u8 {
        if (round == 499) if (self.last) |last| return last;
        if (round == 0) {
            if (id < self.initialCount()) return self.first[id];
            // A split child moves out of its parent's row before looping east.
            return "MOVE S";
        }
        return "MOVE E";
    }

    pub fn matchesResult(self: Case, result: engine.MatchResult) bool {
        if (self.queens) |queens| if (result.a_queen != queens[self.first_team] or result.b_queen != queens[1 - @as(usize, self.first_team)]) return false;
        if (self.winner) |winner| {
            const expected: engine.Winner = if (self.first_team == 0) winner else switch (winner) {
                .a => .b,
                .b => .a,
                .none => .none,
            };
            if (result.winner != expected) return false;
        }
        if (self.rounds) |rounds| if (result.rounds != rounds) return false;
        if (self.reason) |reason| if (result.end_reason != reason) return false;
        return true;
    }
};

pub const cases = [_]Case{
    .{ .name = "length-2-free", .lengths = .{ 2, 2, 0, 0, 0, 0 }, .after_first = 2 },
    .{ .name = "length-2-paid-before-pearl", .lengths = .{ 2, 2, 0, 0, 0, 0 }, .first = .{ "MOVE EE", "MOVE E", "", "", "", "" }, .terrain = "TILE 34 5 1 1\n", .after_first = 0, .queens = .{ 0, 2 }, .winner = .b, .rounds = 0, .reason = 0 },
    .{ .name = "length-4-paid", .lengths = .{ 4, 4, 0, 0, 0, 0 }, .first = .{ "MOVE EE", "MOVE E", "", "", "", "" }, .after_first = 3 },
    .{ .name = "length-5-free", .first = .{ "MOVE EE", "MOVE E", "", "", "", "" }, .after_first = 5 },
    .{ .name = "length-8-paid", .lengths = .{ 8, 8, 0, 0, 0, 0 }, .first = .{ "MOVE EEE", "MOVE E", "", "", "", "" }, .after_first = 7 },
    .{ .name = "length-9-free", .lengths = .{ 9, 9, 0, 0, 0, 0 }, .first = .{ "MOVE EEE", "MOVE E", "", "", "", "" }, .after_first = 9 },
    .{ .name = "length-9-paid", .lengths = .{ 9, 9, 0, 0, 0, 0 }, .first = .{ "MOVE EEEE", "MOVE E", "", "", "", "" }, .after_first = 8 },
    .{ .name = "pearl-does-not-grow-free-budget", .lengths = .{ 4, 4, 0, 0, 0, 0 }, .first = .{ "MOVE EEE", "MOVE E", "", "", "", "" }, .terrain = "TILE 33 5 1 1\n", .after_first = 3 },
    .{ .name = "pearl-on-paid-step", .lengths = .{ 4, 4, 0, 0, 0, 0 }, .first = .{ "MOVE EE", "MOVE E", "", "", "", "" }, .terrain = "TILE 34 5 1 1\n", .after_first = 4 },
    .{ .name = "oversprint-dies", .first = .{ "MOVE EEEEEE", "MOVE E", "", "", "", "" }, .after_first = 0, .winner = .b, .rounds = 0, .reason = 0 },
    .{ .name = "free-steps-retain-colliding-tail", .first = .{ "MOVE NESW", "MOVE E", "", "", "", "" }, .after_first = 0, .winner = .b, .rounds = 0 },
    .{ .name = "kelp-in-free-sprint", .first = .{ "MOVE EE", "MOVE E", "", "", "", "" }, .terrain = "EDGE 748 1 -1\n", .after_first = 0, .winner = .b, .rounds = 0 },
    .{ .name = "portal-in-free-sprint", .first = .{ "MOVE EE", "MOVE E", "", "", "", "" }, .terrain = "EDGE 748 2 0\nEDGE 763 2 0\n", .after_first = 5 },
    .{ .name = "reply-longer-than-inline-array", .lengths = .{ 48, 48, 0, 0, 0, 0 }, .first = .{ "MOVE EEEEEEEEEEEEEEEEEE", "MOVE E", "", "", "", "" }, .after_first = 42 },
    .{ .name = "queen-beats-longer-ordinary", .lengths = .{ 3, 2, 4, 8, 0, 0 }, .queens = .{ 3, 2 }, .winner = .a, .rounds = 499, .reason = 1 },
    .{ .name = "queen-split-child-is-ordinary", .lengths = .{ 8, 5, 0, 0, 0, 0 }, .first = .{ "SPLIT 6", "MOVE E", "", "", "", "" }, .after_first = 2, .queens = .{ 2, 5 }, .winner = .b, .rounds = 499 },
    .{ .name = "dead-queen-slot-reused-by-child", .lengths = .{ 2, 2, 6, 2, 0, 0 }, .first = .{ "MOVE X", "MOVE E", "SPLIT 2", "MOVE E", "", "" }, .after_first = 0, .queens = .{ 0, 2 }, .winner = .b, .rounds = 499 },
    .{ .name = "both-queens-dead-longest-breaks-tie", .lengths = .{ 2, 2, 5, 4, 0, 0 }, .first = .{ "MOVE X", "MOVE X", "MOVE E", "MOVE E", "", "" }, .queens = .{ 0, 0 }, .winner = .a, .rounds = 499 },
    .{ .name = "equal-queens-longest-breaks-tie", .lengths = .{ 2, 2, 5, 4, 0, 0 }, .queens = .{ 2, 2 }, .winner = .a, .rounds = 499 },
    .{ .name = "equal-queens-and-longest-total-breaks-tie", .lengths = .{ 2, 2, 5, 5, 3, 2 }, .queens = .{ 2, 2 }, .winner = .a, .rounds = 499 },
    .{ .name = "all-three-tied-draw", .lengths = .{ 2, 2, 5, 5, 3, 3 }, .queens = .{ 2, 2 }, .winner = .none, .rounds = 499 },
    .{ .name = "round-500-elimination-before-score", .lengths = .{ 6, 2, 0, 0, 0, 0 }, .last = "MOVE X", .queens = .{ 0, 0 }, .winner = .none, .rounds = 499, .reason = 0 },
};

// A thin fixture exporter lets GPU/text parity consume these exact scripts.
// Build this file as an executable; the judge imports only Case and cases.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedOutputDirectory;
    const directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer directory.close(init.io);
    var table: std.ArrayList(u8) = .empty;
    try table.appendSlice(allocator, "map\tseed\tinitial_count\tfirst0\tfirst1\tfirst2\tfirst3\tfirst4\tfirst5\tlast\n");
    for (cases, 0..) |original, index| {
        for (0..2) |first_team| {
            var scripted = original;
            scripted.first_team = @intCast(first_team);
            const name = try std.fmt.allocPrint(allocator, "{s}-{d}.map", .{ scripted.name, first_team });
            const map = try directory.createFile(init.io, name, .{});
            defer map.close(init.io);
            try map.writeStreamingAll(init.io, try scripted.mapText(allocator));
            try table.print(allocator, "{s}\t{d}\t{d}", .{ name, index, scripted.initialCount() });
            for (scripted.first) |action| try table.print(allocator, "\t{s}", .{action});
            try table.print(allocator, "\t{s}\n", .{scripted.last orelse ""});
        }
    }
    const manifest = try directory.createFile(init.io, "cases.tsv", .{});
    defer manifest.close(init.io);
    try manifest.writeStreamingAll(init.io, table.items);
}
