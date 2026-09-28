//! `loong-judge --engine E run ...`: one sandboxed game from the toolkit's
//! `unswbc run --sandbox` arguments, with the same log lines and replay, and each
//! dragon turn's judge points in `points` columns beside the replay
//! (gamedata/format.md). The harness plays its games through here, and
//! `just judge-fidelity` checks it against the toolkit.

const std = @import("std");
const wt = @import("wasmtime.zig");
const engine = @import("engine.zig");
const bot = @import("bot.zig");
const game = @import("game.zig");
const sync = @import("sync.zig");

const DEBUG_LOGS: i32 = 1;
const DEBUG_INDICATOR: i32 = 2;
const DEBUG_DRAW: i32 = 4;
/// Holds bot output to the judge's limits, as every sandboxed toolkit run does.
const DEBUG_LIMITS: i32 = 16;
const END_REASONS = [_][]const u8{ "by elimination", "on length" };
const DRAW_REASONS = [_][]const u8{ "both teams eliminated", "equal length" };

const Arguments = struct {
    map: []const u8,
    bots: [2][]const u8,
    replay: ?[]const u8 = null,
    no_replay: bool = false,
    sandbox: bool = false,
    debug: i32 = engine.DEBUG_ALL,
    seed: ?u64 = null,
    /// The team names the replay records; the bot paths when not given.
    teams: [2]?[]const u8 = .{ null, null },
};

fn parse(args: []const [:0]const u8) !Arguments {
    var positional: [3][]const u8 = undefined;
    var count: usize = 0;
    var parsed = Arguments{ .map = "", .bots = undefined };
    var no_debug = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            parsed.replay = args[i];
        } else if (std.mem.eql(u8, arg, "--team-a") or std.mem.eql(u8, arg, "--team-b")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            parsed.teams[if (arg[arg.len - 1] == 'a') 0 else 1] = args[i];
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            parsed.seed = try std.fmt.parseInt(u64, args[i], 0);
        } else if (std.mem.eql(u8, arg, "--sandbox")) {
            parsed.sandbox = true;
        } else if (std.mem.eql(u8, arg, "--no-replay")) {
            parsed.no_replay = true;
        } else if (std.mem.eql(u8, arg, "--no-debug")) {
            no_debug = true;
        } else if (std.mem.eql(u8, arg, "--no-logs")) {
            parsed.debug &= ~DEBUG_LOGS;
        } else if (std.mem.eql(u8, arg, "--no-indicator")) {
            parsed.debug &= ~DEBUG_INDICATOR;
        } else if (std.mem.eql(u8, arg, "--no-draw")) {
            parsed.debug &= ~DEBUG_DRAW;
        } else if (arg.len > 1 and arg[0] == '-') {
            // -v and anything else the toolkit knows and the judge does not.
            fail("the judge does not take {s}; play through the toolkit for it", .{arg});
            return error.UnknownFlag;
        } else {
            if (count == positional.len) return error.TooManyArguments;
            positional[count] = arg;
            count += 1;
        }
    }
    if (count != 3) return error.MissingArguments;
    if (no_debug) parsed.debug = 0;
    parsed.debug |= DEBUG_LIMITS;
    parsed.map = positional[0];
    parsed.bots = .{ positional[1], positional[2] };
    return parsed;
}

fn fail(comptime format: []const u8, args: anytype) void {
    std.debug.print("error: " ++ format ++ "\n", args);
}

/// run.py's `_points`: millions to one decimal from 100,000, else grouped digits.
fn formatPoints(value: i64, buf: []u8) []const u8 {
    if (value >= 100_000) return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(value)) / 1e6}) catch "";
    var digits: [24]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "";
    var n: usize = 0;
    for (plain, 0..) |ch, i| {
        if (i > 0 and ch != '-' and (plain.len - i) % 3 == 0 and plain[i - 1] != '-') {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

fn percentile(ordered: []const i64, q: i64) i64 {
    const n: i64 = @intCast(ordered.len);
    const rank = -@divFloor(-q * n, 100) - 1;
    return ordered[@intCast(@max(0, rank))];
}

/// The `points` columns: each dragon turn's judge points and failure.
fn writePoints(allocator: std.mem.Allocator, io: std.Io, path: []const u8, record: *const game.Record) !void {
    const Column = struct { name: []const u8, code: u8, count: u64, data: []const u8 };
    var rounds: std.ArrayList(u8) = .empty;
    defer rounds.deinit(allocator);
    var dragons: std.ArrayList(u8) = .empty;
    defer dragons.deinit(allocator);
    var points: std.ArrayList(u8) = .empty;
    defer points.deinit(allocator);
    var ends: std.ArrayList(u8) = .empty;
    defer ends.deinit(allocator);
    var failures: std.ArrayList(u8) = .empty;
    defer failures.deinit(allocator);
    try ends.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, 0)));
    for (record.turns.items) |turn| {
        try rounds.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(i32, turn.round)));
        try dragons.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, turn.dragon)));
        try points.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, turn.points)));
        try failures.appendSlice(allocator, record.failure(turn));
        try ends.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, failures.items.len)));
    }
    const version = std.mem.toBytes(std.mem.nativeToLittle(u32, 1));
    const turns = record.turns.items.len;
    const columns = [_]Column{
        .{ .name = "meta.version", .code = 5, .count = 1, .data = &version },
        .{ .name = "turn.round", .code = 6, .count = turns, .data = rounds.items },
        .{ .name = "turn.dragon", .code = 5, .count = turns, .data = dragons.items },
        .{ .name = "turn.points", .code = 7, .count = turns, .data = points.items },
        .{ .name = "turn.failure", .code = 1, .count = failures.items.len, .data = failures.items },
        .{ .name = "turn.failure#", .code = 7, .count = turns + 1, .data = ends.items },
    };
    const header_bytes = 64;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var directory: std.ArrayList(u8) = .empty;
    defer directory.deinit(allocator);
    for (columns) |column| {
        const offset: u64 = header_bytes + body.items.len;
        try body.appendSlice(allocator, column.data);
        try body.appendNTimes(allocator, 0, (8 - column.data.len % 8) % 8);
        var entry = [_]u8{0} ** 80;
        @memcpy(entry[0..column.name.len], column.name);
        entry[48] = column.code;
        std.mem.writeInt(u64, entry[56..64], column.count, .little);
        std.mem.writeInt(u64, entry[64..72], offset, .little);
        try directory.appendSlice(allocator, &entry);
    }
    var header = [_]u8{0} ** header_bytes;
    @memcpy(header[0..8], "LOONGCOL");
    std.mem.writeInt(u32, header[8..12], 1, .little);
    std.mem.writeInt(u32, header[12..16], columns.len, .little);
    std.mem.writeInt(u64, header[16..24], header_bytes + body.items.len, .little);
    std.mem.writeInt(u64, header[24..32], header_bytes + body.items.len + directory.items.len, .little);
    @memcpy(header[32..][0.."points".len], "points");
    // Written beside the path and renamed over it, so readers never see part.
    const partial = try std.fmt.allocPrint(allocator, "{s}.partial", .{path});
    defer allocator.free(partial);
    const cwd = std.Io.Dir.cwd();
    {
        const file = try cwd.createFile(io, partial, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, &header);
        try file.writeStreamingAll(io, body.items);
        try file.writeStreamingAll(io, directory.items);
    }
    try cwd.rename(partial, cwd, path, io);
}

/// `replay`'s points file: the replay path with its suffix replaced by `.points.cols`.
fn pointsPath(allocator: std.mem.Allocator, replay: []const u8) ![]u8 {
    const base = std.fs.path.basename(replay);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem_end = replay.len - base.len + dot;
    return std.fmt.allocPrint(allocator, "{s}.points.cols", .{replay[0..stem_end]});
}

/// Plays the game and returns the process exit code, as `unswbc run` would.
pub fn main(allocator: std.mem.Allocator, io: std.Io, engine_path: []const u8, args: []const [:0]const u8) !u8 {
    const arguments = parse(args) catch |err| {
        fail("usage: loong-judge --engine E run --sandbox [--seed N] [-o REPLAY | --no-replay] [--no-debug] [--team-a NAME --team-b NAME] MAP A.wasm B.wasm ({s})", .{@errorName(err)});
        return 2;
    };
    if (!arguments.sandbox) {
        fail("the judge plays in its sandbox only: pass --sandbox, or play through the toolkit", .{});
        return 2;
    }
    if (arguments.replay != null and arguments.no_replay) {
        fail("--no-replay cannot be used with -o", .{});
        return 1;
    }
    const replay_path = arguments.replay;
    if (!arguments.no_replay) {
        const path = replay_path orelse {
            fail("the judge needs -o FILE.replay or --no-replay", .{});
            return 1;
        };
        if (std.mem.lastIndexOfScalar(u8, std.fs.path.basename(path), '.') == null) {
            fail("the judge needs -o FILE.replay, not a folder", .{});
            return 1;
        }
    }
    const cwd = std.Io.Dir.cwd();
    const stdout = std.Io.File.stdout();
    const echo = game.Echo{ .io = io, .file = stdout };

    // A stale points file must not outlive the game that replaces its replay.
    var points_path: ?[]u8 = null;
    defer if (points_path) |path| allocator.free(path);
    if (replay_path) |path| {
        points_path = try pointsPath(allocator, path);
        cwd.deleteFile(io, points_path.?) catch {};
    }

    std.Io.Dir.cwd().access(io, arguments.map, .{}) catch {
        fail("not found: {s}", .{arguments.map});
        return 1;
    };
    var wasm: [2][]u8 = undefined;
    for (arguments.bots, 0..) |path, i| {
        if (!std.mem.endsWith(u8, path, ".wasm")) {
            fail("the judge plays compiled .wasm bots only: {s}", .{path});
            return 1;
        }
        wasm[i] = cwd.readFileAlloc(io, path, allocator, .unlimited) catch {
            fail("not found: {s}", .{path});
            return 1;
        };
    }
    defer for (wasm) |bytes| allocator.free(bytes);

    echo.print("loaded wasm vs wasm in the judge's sandbox\n", .{});
    const seed = arguments.seed orelse blk: {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        break :blk std.mem.readInt(u64, &bytes, .little);
    };
    echo.print("seed 0x{x:0>16}\n", .{seed});

    const engine_bytes = cwd.readFileAlloc(io, engine_path, allocator, .unlimited) catch {
        fail("not found: {s}", .{engine_path});
        return 1;
    };
    defer allocator.free(engine_bytes);
    const map = try cwd.readFileAlloc(io, arguments.map, allocator, .unlimited);
    defer allocator.free(map);
    const engine_host = try wt.newEngine(false);
    defer wt.c.wasm_engine_delete(engine_host);
    const bot_host = try wt.newEngine(true);
    defer wt.c.wasm_engine_delete(bot_host);
    var engine_module = try engine.EngineModule.load(engine_host, engine_bytes);
    defer engine_module.deinit();
    var module_a = try bot.BotModule.load(allocator, bot_host, wasm[0]);
    defer module_a.deinit(allocator);
    const same = std.mem.eql(u8, arguments.bots[0], arguments.bots[1]);
    var module_b = if (same) module_a else try bot.BotModule.load(allocator, bot_host, wasm[1]);
    defer if (!same) module_b.deinit(allocator);

    var record = game.Record{};
    defer record.deinit(allocator);
    const started = sync.monotonicNanos();
    const summary = game.play(allocator, .{
        .engine_module = &engine_module,
        .modules = .{ &module_a, &module_b },
        .map = map,
        .seed = seed,
        .debug = arguments.debug,
        .names = .{ arguments.teams[0] orelse arguments.bots[0], arguments.teams[1] orelse arguments.bots[1] },
        .want_replay = !arguments.no_replay,
        .record = &record,
        .echo = echo,
    }) catch |err| {
        fail("{s}: {s}", .{ arguments.map, @errorName(err) });
        return 1;
    };
    defer summary.deinit(allocator);

    const result = summary.result;
    const rounds = result.rounds + 1;
    const reasons = if (result.winner == .none) &DRAW_REASONS else &END_REASONS;
    const reason = if (result.end_reason >= 0 and result.end_reason < reasons.len) reasons[@intCast(result.end_reason)] else "over";
    var took_buf: [24]u8 = undefined;
    const took = game.elapsed(@as(f64, @floatFromInt(sync.monotonicNanos() - started)) / std.time.ns_per_s, &took_buf);
    switch (result.winner) {
        .none => echo.print("draw after {d} rounds ({s}) ({s})\n", .{ rounds, reason, took }),
        .a => echo.print("team A wins after {d} rounds ({s}) ({s})\n", .{ rounds, reason, took }),
        .b => echo.print("team B wins after {d} rounds ({s}) ({s})\n", .{ rounds, reason, took }),
    }
    for (summary.points, [_][]const u8{ "A", "B" }) |ordered, team| {
        if (ordered.len == 0) continue;
        var total: i64 = 0;
        for (ordered) |p| total += p;
        var bufs: [4][32]u8 = undefined;
        echo.print("team {s} points per turn: p50 {s}  p99 {s}  mean {s}  max {s}  ({d} turns)\n", .{
            team,
            formatPoints(percentile(ordered, 50), &bufs[0]),
            formatPoints(percentile(ordered, 99), &bufs[1]),
            formatPoints(@divFloor(total, @as(i64, @intCast(ordered.len))), &bufs[2]),
            formatPoints(ordered[ordered.len - 1], &bufs[3]),
            ordered.len,
        });
    }

    const path = replay_path orelse {
        echo.print("skipped writing replay\n", .{});
        return 0;
    };
    if (std.fs.path.dirname(path)) |parent| cwd.createDirPath(io, parent) catch {};
    const file = cwd.createFile(io, path, .{}) catch |err| {
        fail("cannot write the replay to {s}: {s}", .{ path, @errorName(err) });
        return 1;
    };
    defer file.close(io);
    try file.writeStreamingAll(io, summary.replay.?);
    echo.print("wrote replay: {s}\n", .{path});
    for (record.turns.items) |turn| {
        if (turn.points != 0) {
            try writePoints(allocator, io, points_path.?, &record);
            break;
        }
    }
    return 0;
}
