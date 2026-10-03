//! loong-judge: plays seeded sandbox games with the official engine and prints one
//! line of figures per game.
//!
//! One game:
//!   loong-judge --engine unswbc_engine.wasm --map arena.map --a a-metered.wasm --b b-metered.wasm
//!               --seed 1 [--name-a bots/a] [--name-b bots/b] [--replay out.replay] [--debug 0]
//! A batch, one job per line of the jobs file (id, map, bot A, bot B, seed, then an
//! optional replay path and team names, tab separated), on N threads:
//!   loong-judge --engine unswbc_engine.wasm --jobs jobs.tsv [--threads N] [--debug 0]
//!
//! A match as `unswbc run --sandbox` plays it, recorded as the match wrapper records it
//! (run.zig), taking the toolkit's arguments after `run`:
//!   loong-judge --engine unswbc_engine.wasm [--log game.log]
//!               [--timeout SECONDS] run --sandbox --seed 1 -o out.replay arena.map a.wasm b.wasm
//! `--log` sends the game's output there, and `--timeout` ends the process with exit
//! code 124 at that wall time.
//!
//! One team answered by another process over a UNIX socket (served.zig), the
//! other team's bot as usual; the served team's bot module is unnecessary:
//!   loong-judge --engine E --map M --a opp.wasm --b opp.wasm --seed 1 --serve SOCKET --serve-team B
//! Both teams may be served, without any bot module:
//!   loong-judge --engine E --map M --seed 1 --serve-a SOCKET_A --serve-b SOCKET_B
//!
//! The organisers' engine against our port of it (harness/zig_judge/reference), turn by
//! turn, over a list of maps (lockstep.zig):
//!   loong-judge --engine unswbc_engine.wasm --lockstep maps.txt --games N [--seed S]
//!
//! Bots are metered here unless they already carry the meter (metering.zig). `--meter`
//! writes a bot's metered module alone, for the fidelity check:
//!   loong-judge --meter bot.wasm --output bot-metered.wasm
//!
//! Inspection replays recorded observations through one bot, from a request file,
//! or with `--inspect -` from request and response paths on standard input:
//!   loong-judge --inspect request.json --a a-metered.wasm --output response.jsonl
//!   loong-judge --inspect - --a a-metered.wasm
//!
//! Figures, tab separated: winner (A, B or -), rounds, reason, A dragons, B dragons,
//! A length, B length, A deaths by cause (W,S,O,H,A), B deaths, A bot failures,
//! B bot failures, A turns, A points p50/mean/max, B turns, B points p50/mean/max,
//! wall ms. Batch lines are prefixed with the job id.

const std = @import("std");
const wt = @import("wasmtime.zig");
const engine = @import("engine.zig");
const native = @import("native.zig");
const bot = @import("bot.zig");
const game = @import("game.zig");
const batch = @import("batch.zig");
const inspection = @import("inspection.zig");
const lockstep = @import("lockstep.zig");
const Served = @import("served.zig").Served;
const run = @import("run.zig");
const metering = @import("metering.zig");
const sync = @import("sync.zig");

/// The exit code of a game `--timeout` ended, as coreutils `timeout` uses.
const TIMED_OUT = 124;

const Options = struct {
    engine_path: ?[]const u8 = null,
    native_library: ?[]const u8 = null,
    charge_first_read: bool = false,
    map_path: ?[]const u8 = null,
    a_path: ?[]const u8 = null,
    b_path: ?[]const u8 = null,
    seed: u64 = 0,
    name_a: ?[]const u8 = null,
    name_b: ?[]const u8 = null,
    replay_path: ?[]const u8 = null,
    debug: i32 = 0,
    jobs_path: ?[]const u8 = null,
    threads: usize = 1,
    cuda_batch: ?usize = null,
    inspection_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    meter_path: ?[]const u8 = null,
    run_at: ?usize = null, // where `run` and the toolkit's arguments begin
    log_path: ?[]const u8 = null,
    timeout_seconds: ?u64 = null,
    lockstep_path: ?[]const u8 = null,
    games: u64 = 1,
    serve_path: ?[]const u8 = null,
    serve_team: u8 = 1,
    serve_paths: [2]?[]const u8 = .{ null, null },
};

fn parseOptions(args: []const [:0]const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "run")) {
            options.run_at = i;
            break;
        }
        if (std.mem.eql(u8, args[i], "--charge-first-read")) {
            options.charge_first_read = true;
            i -= 1;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--serve-a") or std.mem.eql(u8, flag, "--serve-b")) {
            options.serve_paths[if (flag[flag.len - 1] == 'a') 0 else 1] = value;
            continue;
        }
        if (std.mem.eql(u8, flag, "--native-library")) {
            options.native_library = value;
            continue;
        }
        if (std.mem.eql(u8, flag, "--cuda-batch")) {
            options.cuda_batch = try std.fmt.parseInt(usize, value, 10);
            if (options.cuda_batch.? == 0) return error.BadCudaBatchSize;
            continue;
        }
        if (std.mem.eql(u8, flag, "--engine")) options.engine_path = value else if (std.mem.eql(u8, flag, "--map")) options.map_path = value else if (std.mem.eql(u8, flag, "--a")) options.a_path = value else if (std.mem.eql(u8, flag, "--b")) options.b_path = value else if (std.mem.eql(u8, flag, "--seed")) options.seed = try std.fmt.parseInt(u64, value, 0) else if (std.mem.eql(u8, flag, "--name-a")) options.name_a = value else if (std.mem.eql(u8, flag, "--name-b")) options.name_b = value else if (std.mem.eql(u8, flag, "--replay")) options.replay_path = value else if (std.mem.eql(u8, flag, "--debug")) options.debug = try std.fmt.parseInt(i32, value, 0) else if (std.mem.eql(u8, flag, "--jobs")) options.jobs_path = value else if (std.mem.eql(u8, flag, "--threads")) options.threads = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, flag, "--inspect")) options.inspection_path = value else if (std.mem.eql(u8, flag, "--output")) options.output_path = value else if (std.mem.eql(u8, flag, "--meter")) options.meter_path = value else if (std.mem.eql(u8, flag, "--log")) options.log_path = value else if (std.mem.eql(u8, flag, "--timeout")) options.timeout_seconds = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, flag, "--lockstep")) options.lockstep_path = value else if (std.mem.eql(u8, flag, "--games")) options.games = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, flag, "--serve")) options.serve_path = value else if (std.mem.eql(u8, flag, "--serve-team")) options.serve_team = if (std.mem.eql(u8, value, "A") or std.mem.eql(u8, value, "a")) 0 else 1 else return error.UnknownFlag;
    }
    if (options.serve_path) |path| {
        if (options.serve_paths[0] != null or options.serve_paths[1] != null) return error.ConflictingServedTeams;
        options.serve_paths[options.serve_team] = path;
    }
    return options;
}

fn endAfter(seconds: u64) void {
    var left = sync.c.struct_timespec{ .tv_sec = @intCast(seconds), .tv_nsec = 0 };
    while (sync.c.nanosleep(&left, &left) != 0) {}
    std.c._exit(TIMED_OUT);
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args) catch |err| {
        std.debug.print("usage: loong-judge --engine E (--map M --a A.wasm --b B.wasm --seed N [--name-a S --name-b S --replay P] | --jobs J [--threads N]) [--debug D] ({s})\n", .{@errorName(err)});
        return err;
    };
    if (options.meter_path) |input| {
        const bytes = try cwd.readFileAlloc(io, input, allocator, .unlimited);
        defer allocator.free(bytes);
        const metered = try metering.instrument(allocator, bytes);
        defer allocator.free(metered);
        const output = try cwd.createFile(io, options.output_path orelse return error.MissingOutput, .{});
        defer output.close(io);
        return output.writeStreamingAll(io, metered);
    }
    if (options.inspection_path) |input| {
        const wasm = options.a_path orelse return error.MissingBotA;
        // `--inspect -` answers a request per line of standard input.
        if (std.mem.eql(u8, input, "-")) return inspection.serve(allocator, io, wasm);
        return inspection.run(allocator, io, wasm, input, options.output_path orelse return error.MissingOutput);
    }
    bot.charge_first_read = options.charge_first_read;
    var native_library = if (options.native_library) |path| try native.Library.open(path) else null;
    defer if (native_library) |*library| library.close();
    const selected_native = if (native_library) |*library| library else null;
    if (options.cuda_batch != null and selected_native == null) return error.NativeCudaRequiresLibrary;
    const engine_path = options.engine_path orelse return error.MissingEngine;
    if (options.run_at) |at| {
        // A runner reads the game from its log and its exit: 124 when the wall limit ended it.
        if (options.log_path) |path| {
            const log = try cwd.createFile(io, path, .{});
            _ = std.c.dup2(log.handle, 1);
            _ = std.c.dup2(log.handle, 2);
        }
        if (options.timeout_seconds) |seconds| _ = try std.Thread.spawn(.{}, endAfter, .{seconds});
        const code = try run.main(allocator, io, engine_path, args[at + 1 ..], selected_native, if (options.cuda_batch != null) options.threads else null);
        std.process.exit(code);
    }
    const engine_bytes = try cwd.readFileAlloc(io, engine_path, allocator, .unlimited);
    defer allocator.free(engine_bytes);

    const engine_host = try wt.newEngine(false);
    defer wt.c.wasm_engine_delete(engine_host);
    const bot_host = try wt.newEngine(true);
    defer wt.c.wasm_engine_delete(bot_host);
    var engine_module = try engine.EngineModule.load(engine_host, engine_bytes);
    defer engine_module.deinit();

    if (options.lockstep_path) |maps| {
        if (selected_native != null) return error.NativeLockstepUsesReferencePort;
        std.process.exit(try lockstep.run(allocator, io, &engine_module, maps, options.games, options.seed));
    }
    if (options.jobs_path) |jobs_path| {
        const jobs_text = try cwd.readFileAlloc(io, jobs_path, allocator, .unlimited);
        defer allocator.free(jobs_text);
        const jobs = try batch.parseJobs(allocator, jobs_text);
        defer allocator.free(jobs);
        if (options.cuda_batch) |size| {
            try batch.runCuda(allocator, io, bot_host, &engine_module, jobs, options.threads, options.debug, selected_native.?, size);
        } else {
            try batch.run(allocator, io, bot_host, &engine_module, jobs, options.threads, options.debug, selected_native);
        }
        return;
    }

    const map_path = options.map_path orelse return error.MissingMap;
    if (options.timeout_seconds) |seconds| _ = try std.Thread.spawn(.{}, endAfter, .{seconds});
    const map = try cwd.readFileAlloc(io, map_path, allocator, .unlimited);
    defer allocator.free(map);
    const bot_paths = [2]?[]const u8{ options.a_path, options.b_path };
    var modules: [2]?bot.BotModule = .{ null, null };
    defer for (&modules) |*optional| if (optional.*) |*module| module.deinit(allocator);
    var served: [2]?Served = .{ null, null };
    defer for (&served) |*optional| if (optional.*) |*connection| connection.close();
    for (options.serve_paths, 0..) |path, index| {
        if (path) |socket| {
            served[index] = try Served.connect(allocator, socket, @intCast(index));
        } else {
            const bot_path = bot_paths[index] orelse return if (index == 0) error.MissingBotA else error.MissingBotB;
            const bytes = try cwd.readFileAlloc(io, bot_path, allocator, .unlimited);
            defer allocator.free(bytes);
            modules[index] = try bot.BotModule.load(allocator, bot_host, bytes);
        }
    }
    const summary = try game.play(allocator, .{
        .engine_module = &engine_module,
        .native_library = selected_native,
        .native_cuda_threads = if (options.cuda_batch != null) options.threads else null,
        .policies = .{
            if (served[0]) |*s| .{ .served = s } else .{ .bot = &modules[0].? },
            if (served[1]) |*s| .{ .served = s } else .{ .bot = &modules[1].? },
        },
        .map = map,
        .seed = options.seed,
        .debug = options.debug,
        .names = .{ options.name_a orelse options.a_path orelse "served-A", options.name_b orelse options.b_path orelse "served-B" },
        .want_replay = options.replay_path != null,
    });
    defer summary.deinit(allocator);

    if (options.replay_path) |path| {
        const file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, summary.replay.?);
    }

    var line: [640]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try game.formatFigures(summary, &line));
}
