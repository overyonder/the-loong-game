//! One seeded game: the engine's callbacks tied to the dragons' bots, with the
//! outcome figures the harness reads.

const std = @import("std");
const engine = @import("engine.zig");
const bot = @import("bot.zig");
const sync = @import("sync.zig");

pub const Team = enum(u8) { a = 0, b = 1 };

/// Death causes as the engine reports them: wall, self, other dragon, head-to-head, no action.
pub const DEATH_CODES = "WSOHA";

pub const TeamFigures = struct {
    deaths:      [5]u32 = .{ 0, 0, 0, 0, 0 },
    errors:      u32 = 0,       // turns a bot failed: exited, trapped, ran out of points or time
    turns:       u32 = 0,
    points_p50:  i64 = 0,
    points_mean: i64 = 0,
    points_max:  i64 = 0,
};

pub const Summary = struct {
    result:  engine.MatchResult,
    teams:   [2]TeamFigures,
    replay:  ?[]u8,
    wall_ms: i64,
};

pub const Setup = struct {
    engine_module: *const engine.EngineModule,
    modules:       [2]*const bot.BotModule,
    map:           []const u8,
    seed:          u64,
    debug:         i32,
    names:         [2][]const u8,
    want_replay:   bool,
};

const Game = struct {
    allocator: std.mem.Allocator,
    setup:     Setup,
    keys:      [2][18]u8,
    dragons:   std.AutoHashMap(u32, *bot.Dragon),
    points:    [2]std.ArrayList(i64),
    figures:   [2]TeamFigures,

    fn spawn(ctx: *anyopaque, dragon_id: u32, init: []const u8) void {
        const self: *Game = @ptrCast(@alignCast(ctx));
        const team = teamOf(init);
        const index = @intFromEnum(team);
        const dragon = bot.Dragon.create(self.allocator, self.setup.modules[index], &self.keys[index], index, dragon_id, init) catch return;
        self.dragons.put(dragon_id, dragon) catch dragon.destroy();
    }

    fn reply(ctx: *anyopaque, dragon_id: u32, block: []const u8) []const u8 {
        const self: *Game = @ptrCast(@alignCast(ctx));
        const dragon = self.dragons.get(dragon_id) orelse return "";
        const out = dragon.ask(block);
        const figures = &self.figures[dragon.team];
        if (dragon.error_reason != null) figures.errors += 1;
        if (dragon.instance) |inst| {
            const live = inst.live();
            if (live.points > 0) self.points[dragon.team].append(self.allocator, live.points) catch {};
        }
        return out;
    }

    fn death(ctx: *anyopaque, dragon_id: u32, round: i32, reason: u8) void {
        _ = round;
        const self: *Game = @ptrCast(@alignCast(ctx));
        const entry = self.dragons.fetchRemove(dragon_id) orelse return;
        if (std.mem.indexOfScalar(u8, DEATH_CODES, reason)) |code| self.figures[entry.value.team].deaths[code] += 1;
        entry.value.destroy();
    }
};

fn teamOf(init: []const u8) Team {
    var lines = std.mem.splitScalar(u8, init, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "TEAM")) continue;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = words.next();
        const word = words.next() orelse break;
        return if (std.mem.eql(u8, word, "B")) .b else .a;
    }
    return .a;
}

/// Plays one game to its end and returns its figures; the replay is the caller's to free.
pub fn play(allocator: std.mem.Allocator, setup: Setup) !Summary {
    var game = Game{
        .allocator = allocator,
        .setup = setup,
        .keys = undefined,
        .dragons = std.AutoHashMap(u32, *bot.Dragon).init(allocator),
        .points = .{ .empty, .empty },
        .figures = .{ .{}, .{} },
    };
    defer game.dragons.deinit();
    defer for (&game.points) |*list| list.deinit(allocator);
    // A team's random_get key: the seed as sixteen hex digits, a dash and the team's letter.
    _ = try std.fmt.bufPrint(&game.keys[0], "{x:0>16}-a", .{setup.seed});
    _ = try std.fmt.bufPrint(&game.keys[1], "{x:0>16}-b", .{setup.seed});

    const started = sync.monotonicNanos();
    const match = try engine.Match.create(allocator, setup.engine_module, .{
        .ctx = &game,
        .reply = Game.reply,
        .spawn = Game.spawn,
        .death = Game.death,
    });
    defer match.destroy();

    const result = try match.run(setup.map, setup.debug, setup.seed);
    const replay: ?[]u8 = if (setup.want_replay) try match.replay(setup.names[0], setup.names[1]) else null;

    var it = game.dragons.valueIterator();
    while (it.next()) |dragon| dragon.*.destroy();
    game.dragons.clearRetainingCapacity();

    var summary = Summary{ .result = result, .teams = game.figures, .replay = replay, .wall_ms = @intCast(@divTrunc(sync.monotonicNanos() - started, std.time.ns_per_ms)) };
    for (&summary.teams, 0..) |*figures, i| {
        const points = game.points[i].items;
        figures.turns = @intCast(points.len);
        if (points.len == 0) continue;
        std.mem.sort(i64, points, {}, std.sort.asc(i64));
        var total: i64 = 0;
        for (points) |p| total += p;
        figures.points_p50 = points[points.len / 2];
        figures.points_mean = @divTrunc(total, @as(i64, @intCast(points.len)));
        figures.points_max = points[points.len - 1];
    }
    return summary;
}

/// One tab-separated line of figures: winner (A, B or -), rounds, reason, A dragons,
/// B dragons, A length, B length, A deaths by cause (W,S,O,H,A), B deaths, A bot
/// failures, B bot failures, A turns, A points p50/mean/max, B turns, B points, wall ms.
pub fn formatFigures(summary: Summary, buf: []u8) ![]const u8 {
    const r = summary.result;
    const a = summary.teams[0];
    const b = summary.teams[1];
    return std.fmt.bufPrint(buf,
        "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d},{d},{d},{d},{d}\t{d},{d},{d},{d},{d}\t{d}\t{d}\t{d}\t{d}/{d}/{d}\t{d}\t{d}/{d}/{d}\t{d}\n",
        .{
            switch (r.winner) { .a => "A", .b => "B", .none => "-" },
            r.rounds + 1, r.end_reason, r.a_dragons, r.b_dragons, r.a_length, r.b_length,
            a.deaths[0], a.deaths[1], a.deaths[2], a.deaths[3], a.deaths[4],
            b.deaths[0], b.deaths[1], b.deaths[2], b.deaths[3], b.deaths[4],
            a.errors, b.errors,
            a.turns, a.points_p50, a.points_mean, a.points_max,
            b.turns, b.points_p50, b.points_mean, b.points_max,
            summary.wall_ms,
        });
}
