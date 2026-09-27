//! Replay recorded observations through the WASM sandbox. Annotations are kept
//! separate from the action reply; no private bot state is manufactured here.
const std = @import("std");
const wt = @import("wasmtime.zig");
const bot = @import("bot.zig");

const Observation = struct { v1: []const u8, v3: []const u8 };
const Request = struct { init: []const u8, name: u32, initial_protocol: u32 = 1, observations: []Observation };

pub fn run(allocator: std.mem.Allocator, io: std.Io, wasm_path: []const u8, input_path: []const u8, output_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, wasm_path, allocator, .unlimited);
    defer allocator.free(bytes);
    const input = try cwd.readFileAlloc(io, input_path, allocator, .unlimited);
    defer allocator.free(input);
    const request = try std.json.parseFromSlice(Request, allocator, input, .{});
    defer request.deinit();
    const host = try wt.newEngine(true);
    defer wt.c.wasm_engine_delete(host);
    var module = try bot.BotModule.load(allocator, host, bytes);
    defer module.deinit(allocator);
    module.inspection_enabled = true;
    const dragon = try bot.Dragon.create(allocator, &module, "a", 0, request.value.name, request.value.init);
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
