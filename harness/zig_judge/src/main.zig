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
const bot = @import("bot.zig");
const game = @import("game.zig");
const batch = @import("batch.zig");
const inspection = @import("inspection.zig");

const Options = struct {
    engine_path: ?[]const u8 = null,
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
    inspection_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
};

fn parseOptions(args: []const [:0]const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingValue;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--engine")) options.engine_path = value else if (std.mem.eql(u8, flag, "--map")) options.map_path = value else if (std.mem.eql(u8, flag, "--a")) options.a_path = value else if (std.mem.eql(u8, flag, "--b")) options.b_path = value else if (std.mem.eql(u8, flag, "--seed")) options.seed = try std.fmt.parseInt(u64, value, 0) else if (std.mem.eql(u8, flag, "--name-a")) options.name_a = value else if (std.mem.eql(u8, flag, "--name-b")) options.name_b = value else if (std.mem.eql(u8, flag, "--replay")) options.replay_path = value else if (std.mem.eql(u8, flag, "--debug")) options.debug = try std.fmt.parseInt(i32, value, 0) else if (std.mem.eql(u8, flag, "--jobs")) options.jobs_path = value else if (std.mem.eql(u8, flag, "--threads")) options.threads = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, flag, "--inspect")) options.inspection_path = value else if (std.mem.eql(u8, flag, "--output")) options.output_path = value else return error.UnknownFlag;
    }
    return options;
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
    if (options.inspection_path) |input| {
        const wasm = options.a_path orelse return error.MissingBotA;
        // `--inspect -` answers a request per line of standard input.
        if (std.mem.eql(u8, input, "-")) return inspection.serve(allocator, io, wasm);
        return inspection.run(allocator, io, wasm, input, options.output_path orelse return error.MissingOutput);
    }
    const engine_path = options.engine_path orelse return error.MissingEngine;
    const engine_bytes = try cwd.readFileAlloc(io, engine_path, allocator, .unlimited);
    defer allocator.free(engine_bytes);

    const engine_host = try wt.newEngine(false);
    defer wt.c.wasm_engine_delete(engine_host);
    const bot_host = try wt.newEngine(true);
    defer wt.c.wasm_engine_delete(bot_host);
    var engine_module = try engine.EngineModule.load(engine_host, engine_bytes);
    defer engine_module.deinit();

    if (options.jobs_path) |jobs_path| {
        const jobs_text = try cwd.readFileAlloc(io, jobs_path, allocator, .unlimited);
        defer allocator.free(jobs_text);
        const jobs = try batch.parseJobs(allocator, jobs_text);
        defer allocator.free(jobs);
        try batch.run(allocator, io, bot_host, &engine_module, jobs, options.threads, options.debug);
        return;
    }

    const map_path = options.map_path orelse return error.MissingMap;
    const a_path = options.a_path orelse return error.MissingBotA;
    const b_path = options.b_path orelse return error.MissingBotB;
    const a_bytes = try cwd.readFileAlloc(io, a_path, allocator, .unlimited);
    defer allocator.free(a_bytes);
    const b_bytes = try cwd.readFileAlloc(io, b_path, allocator, .unlimited);
    defer allocator.free(b_bytes);
    const map = try cwd.readFileAlloc(io, map_path, allocator, .unlimited);
    defer allocator.free(map);
    var module_a = try bot.BotModule.load(allocator, bot_host, a_bytes);
    defer module_a.deinit(allocator);
    var module_b = try bot.BotModule.load(allocator, bot_host, b_bytes);
    defer module_b.deinit(allocator);

    const summary = try game.play(allocator, .{
        .engine_module = &engine_module,
        .modules = .{ &module_a, &module_b },
        .map = map,
        .seed = options.seed,
        .debug = options.debug,
        .names = .{ options.name_a orelse a_path, options.name_b orelse b_path },
        .want_replay = options.replay_path != null,
    });
    defer if (summary.replay) |replay| allocator.free(replay);

    if (options.replay_path) |path| {
        const file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, summary.replay.?);
    }

    var line: [640]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try game.formatFigures(summary, &line));
}
