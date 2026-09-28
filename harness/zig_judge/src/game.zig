//! One seeded game: the engine's callbacks tied to the dragons' bots, with the
//! outcome figures the harness reads, and for a `run` the log lines and each
//! dragon turn's points that the toolkit's match wrapper records.

const std = @import("std");
const engine = @import("engine.zig");
const bot = @import("bot.zig");
const sync = @import("sync.zig");

pub const Team = enum(u8) { a = 0, b = 1 };

/// Death causes as the engine reports them: wall, self, other dragon, head-to-head, no action.
pub const DEATH_CODES = "WSOHA";
/// The toolkit's wording for each death cause (run.py's DEATH_REASONS).
const DEATH_REASONS = [_][]const u8{ "hit a wall", "hit itself", "hit another dragon", "lost a head-to-head", "no valid action" };
pub const MAX_ROUNDS = 500;

pub const TeamFigures = struct {
    deaths:      [5]u32 = .{ 0, 0, 0, 0, 0 },
    errors:      u32 = 0,       // turns a bot failed: exited, trapped, ran out of points or time
    turns:       u32 = 0,
    points_p50:  i64 = 0,
    points_mean: i64 = 0,
    points_max:  i64 = 0,
};

/// One dragon turn as the toolkit's wrapper records it in the `points` columns.
pub const Turn = struct {
    round:   i32,   // the block's ROUND, or -1
    dragon:  u32,
    points:  u64,
    failure: [2]u32, // the failure text's bounds in `Record.failures`; empty for none
};

/// Every dragon turn's points and failure.
pub const Record = struct {
    turns:    std.ArrayList(Turn) = .empty,
    failures: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        self.turns.deinit(allocator);
        self.failures.deinit(allocator);
    }

    pub fn failure(self: *const Record, turn: Turn) []const u8 {
        return self.failures.items[turn.failure[0]..turn.failure[1]];
    }
};

/// Where a `run` streams its log lines as the game plays.
pub const Echo = struct {
    io:   std.Io,
    file: std.Io.File,

    pub fn print(self: Echo, comptime format: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, format, args) catch return;
        self.file.writeStreamingAll(self.io, text) catch {};
    }
};

pub const Summary = struct {
    result:  engine.MatchResult,
    teams:   [2]TeamFigures,
    replay:  ?[]u8,
    wall_ms: i64,
    /// Each team's nonzero turn points in ascending order, as run.py summarises them.
    points:  [2][]i64,

    pub fn deinit(self: Summary, allocator: std.mem.Allocator) void {
        if (self.replay) |replay| allocator.free(replay);
        for (self.points) |list| allocator.free(list);
    }
};

pub const Setup = struct {
    engine_module: *const engine.EngineModule,
    modules:       [2]*const bot.BotModule,
    map:           []const u8,
    seed:          u64,
    debug:         i32,
    names:         [2][]const u8,
    want_replay:   bool,
    record:        ?*Record = null,
    echo:          ?Echo = null,
};

/// run.py's Progress, printing as it does when stdout is not a terminal.
const Progress = struct {
    round:       i64 = 0,
    start:       i128,
    round_start: i128,

    fn update(self: *Progress, echo: Echo, round: i64, dragons: [2]u32) void {
        if (round == self.round) return;
        const now = sync.monotonicNanos();
        const last = seconds(now - self.round_start);
        self.round_start = now;
        self.round = round;
        if (!(round == 1 or @mod(round, 50) == 0 or round == MAX_ROUNDS)) return;
        const eta = if (round != 0) seconds(now - self.start) / @as(f64, @floatFromInt(round)) * @as(f64, @floatFromInt(MAX_ROUNDS - round)) else 0;
        var last_buf: [24]u8 = undefined;
        var eta_buf: [24]u8 = undefined;
        echo.print("running round {d}/{d} --  last: {s}  eta: {s}  dragons: {d} vs {d}\n", .{ round + 1, MAX_ROUNDS, roundMs(last, &last_buf), elapsed(eta, &eta_buf), dragons[0], dragons[1] });
    }
};

fn seconds(nanos: i128) f64 {
    return @as(f64, @floatFromInt(nanos)) / std.time.ns_per_s;
}

/// run.py's `_elapsed`.
pub fn elapsed(value: f64, buf: []u8) []const u8 {
    if (value < 60) return std.fmt.bufPrint(buf, "{d:.1}s", .{value}) catch "";
    const whole: u64 = @intFromFloat(value);
    return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ whole / 60, whole % 60 }) catch "";
}

fn roundMs(value: f64, buf: []u8) []const u8 {
    if (value < 1) return std.fmt.bufPrint(buf, "{d}ms", .{@as(u64, @intFromFloat(value * 1000))}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1}s", .{value}) catch "";
}

const Game = struct {
    allocator: std.mem.Allocator,
    setup:     Setup,
    keys:      [2][18]u8,
    dragons:   std.AutoHashMap(u32, *bot.Dragon),
    teams:     std.AutoHashMap(u32, Team),   // every dragon ever spawned, as run.py's `teams`
    points:    [2]std.ArrayList(i64),
    figures:   [2]TeamFigures,
    progress:  Progress,

    fn spawn(ctx: *anyopaque, dragon_id: u32, init: []const u8) void {
        const self: *Game = @ptrCast(@alignCast(ctx));
        const team = teamOf(init);
        const index = @intFromEnum(team);
        self.teams.put(dragon_id, team) catch {};
        const dragon = bot.Dragon.create(self.allocator, self.setup.modules[index], &self.keys[index], index, dragon_id, init) catch return;
        self.dragons.put(dragon_id, dragon) catch dragon.destroy();
    }

    fn teamLetter(self: *Game, dragon_id: u32) []const u8 {
        const team = self.teams.get(dragon_id) orelse return "?";
        return if (team == .b) "B" else "A";
    }

    fn reply(ctx: *anyopaque, dragon_id: u32, block: []const u8) []const u8 {
        const self: *Game = @ptrCast(@alignCast(ctx));
        const round = roundOf(block);
        if (self.setup.echo) |echo| {
            if (round >= 0) {
                var alive = [2]u32{ 0, 0 };
                var it = self.dragons.keyIterator();
                while (it.next()) |id| alive[if (self.teams.get(id.*) == .b) 1 else 0] += 1;
                self.progress.update(echo, round, alive);
            }
        }
        const dragon = self.dragons.get(dragon_id) orelse {
            self.recordTurn(round, dragon_id, 0, null);
            return "";
        };
        const out = dragon.ask(block);
        const figures = &self.figures[dragon.team];
        if (dragon.error_reason) |why| {
            figures.errors += 1;
            if (self.setup.echo) |echo| {
                if (round >= 0)
                    echo.print("round {d}: bot {d} (team {s}) {s}\n", .{ round, dragon_id, self.teamLetter(dragon_id), why })
                else
                    echo.print("round ?: bot {d} (team {s}) {s}\n", .{ dragon_id, self.teamLetter(dragon_id), why });
            }
        }
        if (dragon.instance) |inst| {
            const live = inst.live();
            if (live.points > 0) self.points[dragon.team].append(self.allocator, live.points) catch {};
        }
        self.recordTurn(round, dragon_id, dragon.points, dragon.error_reason);
        return out;
    }

    fn recordTurn(self: *Game, round: i64, dragon_id: u32, points: i64, failure: ?[]const u8) void {
        const record = self.setup.record orelse return;
        const start: u32 = @intCast(record.failures.items.len);
        if (failure) |text| record.failures.appendSlice(self.allocator, text) catch {};
        record.turns.append(self.allocator, .{
            .round = @intCast(round),
            .dragon = dragon_id,
            .points = @intCast(@max(points, 0)),
            .failure = .{ start, @intCast(record.failures.items.len) },
        }) catch {};
    }

    fn death(ctx: *anyopaque, dragon_id: u32, round: i32, reason: u8) void {
        const self: *Game = @ptrCast(@alignCast(ctx));
        const code = std.mem.indexOfScalar(u8, DEATH_CODES, reason);
        if (self.setup.echo) |echo|
            echo.print("round {d}: bot {d} (team {s}) died: {s}\n", .{ round, dragon_id, self.teamLetter(dragon_id), if (code) |i| DEATH_REASONS[i] else "died" });
        const entry = self.dragons.fetchRemove(dragon_id) orelse return;
        if (code) |i| self.figures[entry.value.team].deaths[i] += 1;
        entry.value.destroy();
    }
};

/// The round a turn block names in its first line, or -1.
fn roundOf(block: []const u8) i64 {
    const line = block[0 .. std.mem.indexOfScalar(u8, block, '\n') orelse block.len];
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    const first = words.next() orelse return -1;
    if (!std.mem.eql(u8, first, "ROUND")) return -1;
    return std.fmt.parseInt(i64, words.next() orelse return -1, 10) catch -1;
}

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

/// Plays one game to its end and returns its figures; the caller deinits the summary.
pub fn play(allocator: std.mem.Allocator, setup: Setup) !Summary {
    const started = sync.monotonicNanos();
    var game = Game{
        .allocator = allocator,
        .setup = setup,
        .keys = undefined,
        .dragons = std.AutoHashMap(u32, *bot.Dragon).init(allocator),
        .teams = std.AutoHashMap(u32, Team).init(allocator),
        .points = .{ .empty, .empty },
        .figures = .{ .{}, .{} },
        .progress = .{ .start = started, .round_start = started },
    };
    defer game.dragons.deinit();
    defer game.teams.deinit();
    errdefer for (&game.points) |*list| list.deinit(allocator);
    // A team's random_get key: the seed as sixteen hex digits, a dash and the team's letter.
    _ = try std.fmt.bufPrint(&game.keys[0], "{x:0>16}-a", .{setup.seed});
    _ = try std.fmt.bufPrint(&game.keys[1], "{x:0>16}-b", .{setup.seed});

    const match = try engine.Match.create(allocator, setup.engine_module, .{
        .ctx = &game,
        .reply = Game.reply,
        .spawn = Game.spawn,
        .death = Game.death,
    });
    defer match.destroy();

    const result = match.run(setup.map, setup.debug, setup.seed);
    var it = game.dragons.valueIterator();
    while (it.next()) |dragon| dragon.*.destroy();
    game.dragons.clearRetainingCapacity();
    const outcome = try result;
    const replay: ?[]u8 = if (setup.want_replay) try match.replay(setup.names[0], setup.names[1]) else null;

    var summary = Summary{ .result = outcome, .teams = game.figures, .replay = replay, .wall_ms = @intCast(@divTrunc(sync.monotonicNanos() - started, std.time.ns_per_ms)), .points = undefined };
    for (&summary.teams, 0..) |*figures, i| {
        const points = try game.points[i].toOwnedSlice(allocator);
        summary.points[i] = points;
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
