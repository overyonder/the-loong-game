//! Replay recorded observations through the WASM sandbox. Annotations are kept
//! separate from the action reply; no private bot state is manufactured here.
//!
//! `run` answers one request file. `serve` compiles the bot once and answers a
//! request per line of standard input, `REQUEST<TAB>RESPONSE` file paths, with
//! `ok` or `failed` on standard output, so recovering many dragons of one build
//! compiles it once. It first writes `ServerGreeting`, so a client can tell a
//! judge with this mode from one without.
const std = @import("std");
const wt = @import("wasmtime.zig");
const bot = @import("bot.zig");

pub const ServerGreeting = "inspection-server 1\n";

const Observation = struct { v1: []const u8, v3: []const u8 };
const Request = struct { init: []const u8, name: u32, initial_protocol: u32 = 1, observations: []Observation };

/// One dragon's observations in a fresh instance of the loaded module, one
/// response record per observation. Fails where the bot does.
fn answer(allocator: std.mem.Allocator, io: std.Io, module: *bot.BotModule, input_path: []const u8, output_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(io, input_path, allocator, .unlimited);
    defer allocator.free(input);
    const request = try std.json.parseFromSlice(Request, allocator, input, .{});
    defer request.deinit();
    const dragon = try bot.Dragon.create(allocator, module, "a", 0, request.value.name, request.value.init);
    defer dragon.destroy();
    const output = try cwd.createFile(io, output_path, .{});
    defer output.close(io);
    var protocol_three = request.value.initial_protocol == 3;
    for (request.value.observations) |observation| {
        const reply = dragon.ask(if (protocol_three) observation.v3 else observation.v1);
        var lines = std.mem.splitScalar(u8, reply, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "PROTOCOL 3")) protocol_three = true;
        }
        const points = if (dragon.instance) |instance| instance.live().points else 0;
        const memory = if (dragon.instance) |instance| instance.live().memory else 0;
        const annotations: []const u8 = if (dragon.instance) |instance| instance.annotation_output.items else "";
        const record = try std.json.Stringify.valueAlloc(allocator, .{
            .reply = reply,
            .annotations = annotations,
            .failure = dragon.error_reason,
            .points = points,
            .memory = memory,
        }, .{});
        defer allocator.free(record);
        try output.writeStreamingAll(io, record);
        try output.writeStreamingAll(io, "\n");
        if (dragon.error_reason != null) return error.InspectionFailed;
    }
}

fn load(allocator: std.mem.Allocator, io: std.Io, host: *wt.c.wasm_engine_t, wasm_path: []const u8) !bot.BotModule {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasm_path, allocator, .unlimited);
    defer allocator.free(bytes);
    var module = try bot.BotModule.load(allocator, host, bytes);
    module.inspection_enabled = true;
    return module;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, input_path: []const u8, output_path: []const u8) !void {
    const host = try wt.newEngine(true);
    defer wt.c.wasm_engine_delete(host);
    var module = try load(allocator, io, host, wasm_path);
    defer module.deinit(allocator);
    try answer(allocator, io, &module, input_path, output_path);
}

pub fn serve(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8) !void {
    var out_buffer: [64]u8 = undefined;
    var replies = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    try replies.interface.writeAll(ServerGreeting);
    try replies.interface.flush();
    const host = try wt.newEngine(true);
    defer wt.c.wasm_engine_delete(host);
    var module = try load(allocator, io, host, wasm_path);
    defer module.deinit(allocator);
    var in_buffer: [16384]u8 = undefined;
    var requests = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    while (try requests.interface.takeDelimiter('\n')) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.MalformedRequest;
        const input_path = try allocator.dupe(u8, line[0..tab]);
        defer allocator.free(input_path);
        const output_path = try allocator.dupe(u8, line[tab + 1 ..]);
        defer allocator.free(output_path);
        answer(allocator, io, &module, input_path, output_path) catch |err| switch (err) {
            error.InspectionFailed => {
                try replies.interface.writeAll("failed\n");
                try replies.interface.flush();
                continue;
            },
            else => return err,
        };
        try replies.interface.writeAll("ok\n");
        try replies.interface.flush();
    }
}
