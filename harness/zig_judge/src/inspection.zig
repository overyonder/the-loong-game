//! Replay recorded observations through the WASM sandbox. Annotations, and the
//! state a bot shows from its memory (state.zig), are kept separate from the
//! action reply; no private bot state is manufactured here.
//!
//! `run` answers one request file. `serve` compiles the bot once and answers a
//! request per line of standard input, `REQUEST<TAB>RESPONSE` file paths, with
//! `ok` or `failed` on standard output, so recovering many dragons of one build
//! compiles it once. It first writes `ServerGreeting`, so a client can tell a
//! judge with this mode from one without.
//!
//! A request may ask for checkpoints after some of its untraced turns. Each is a
//! fork of the paused bot (the textbook fork checkpoint: the copy shares every
//! page with the run until one side writes it), reparented to the request's
//! `owner`, which must be a child subreaper, and ended with it. It waits at its
//! path, a FIFO, for `RESUME<TAB>RESPONSE<TAB>REPLY` lines and answers each in
//! a fork of its own, so it can be resumed again: the rest of the dragon's
//! observations from RESUME, records to RESPONSE as a request's are, and on
//! REPLY first `pid N`, the worker to stop if it is no longer wanted, then `ok`
//! or `failed`. The checkpoint writes its own pid to PATH.pid once it is
//! ready.
const std = @import("std");
const wt = @import("wasmtime.zig");
const bot = @import("bot.zig");

pub const ServerGreeting = "inspection-server 1\n";

const Observation = struct { v1: []const u8, v3: []const u8 };
/// `loud_from` and `loud_until` are the first and last observations whose
/// diagnostics are wanted: outside them the bot plays with its diagnostics
/// switched off, when it has said where its switch lies, so a window costs
/// little more than playing past it.
const Request = struct { init: []const u8, name: u32, initial_protocol: u32 = 1, state: bool = false, loud_from: u32 = 0, loud_until: u32 = std.math.maxInt(u32), checkpoints: []const Checkpoint = &.{}, owner: u32 = 0, observations: []Observation };
/// A checkpoint after the observation at `index`, waiting at `path`.
const Checkpoint = struct { index: u32, path: []const u8 };
/// The rest of a dragon's observations, from a checkpoint.
const Resume = struct { state: bool = false, loud_from: u32 = 0, loud_until: u32 = std.math.maxInt(u32), checkpoints: []const Checkpoint = &.{}, observations: []Observation };

/// The process a checkpoint is reparented to.
var checkpoint_owner: std.os.linux.pid_t = 0;

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
    dragon.capture_state = request.value.state;
    const output = try cwd.createFile(io, output_path, .{});
    defer output.close(io);
    var protocol_three = request.value.initial_protocol == 3;
    checkpoint_owner = @intCast(request.value.owner);
    try play(allocator, io, dragon, request.value.observations, request.value.loud_from, request.value.loud_until, request.value.checkpoints, output, &protocol_three);
}

/// Answer each observation in turn, one record each, leaving the checkpoints
/// asked for.
fn play(allocator: std.mem.Allocator, io: std.Io, dragon: *bot.Dragon, observations: []const Observation, loud_from: u32, loud_until: u32, checkpoints: []const Checkpoint, output: std.Io.File, protocol_three: *bool) !void {
    for (observations, 0..) |observation, index| {
        const wanted = index >= loud_from and index <= loud_until;
        // A turn is traced when wanted, or when the bot hasn't yet said where
        // its switch lies, as on its first turn.
        const traced = wanted or !dragon.switchable();
        dragon.diagnose(wanted);
        const reply = dragon.ask(if (protocol_three.*) observation.v3 else observation.v1);
        var lines = std.mem.splitScalar(u8, reply, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "PROTOCOL 3")) protocol_three.* = true;
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
            .traced = traced,
        }, .{});
        defer allocator.free(record);
        // The state and trace the bot had captured this turn (state.zig), as the
        // record's last fields.
        const state: []const u8 = if (dragon.instance) |instance| instance.state_output.items else "";
        const trace: []const u8 = if (dragon.instance) |instance| instance.trace_output.items else "";
        if (state.len > 0 or trace.len > 0) {
            try output.writeStreamingAll(io, record[0 .. record.len - 1]);
            if (state.len > 0) {
                try output.writeStreamingAll(io, ",\"state\":");
                try output.writeStreamingAll(io, state);
            }
            if (trace.len > 0) {
                try output.writeStreamingAll(io, ",\"trace\":");
                try output.writeStreamingAll(io, trace);
            }
            try output.writeStreamingAll(io, "}");
        } else if (dragon.instance != null and dragon.instance.?.state_offered) {
            // The bot shows its state, though this inspection didn't ask for it.
            try output.writeStreamingAll(io, record[0 .. record.len - 1]);
            try output.writeStreamingAll(io, ",\"state_offered\":true}");
        } else try output.writeStreamingAll(io, record);
        try output.writeStreamingAll(io, "\n");
        if (dragon.error_reason != null) return error.InspectionFailed;
        // After an untraced turn only, so a resumed run's first traced turn
        // sends its retained records whole (diagnostics.md).
        if (!traced and checkpoint_owner != 0) for (checkpoints) |checkpoint| {
            if (checkpoint.index == index) leave(allocator, io, dragon, checkpoint.path, output, protocol_three.*);
        };
    }
}

/// Fork the paused bot into a checkpoint at `path`; the run plays on at once.
fn leave(allocator: std.mem.Allocator, io: std.Io, dragon: *bot.Dragon, path: []const u8, output: std.Io.File, protocol_three: bool) void {
    const linux = std.os.linux;
    const first = linux.fork();
    if (linux.errno(first) != .SUCCESS) return;
    if (first != 0) {
        var status: u32 = 0;
        _ = linux.waitpid(@intCast(first), &status, 0);
        return;
    }
    // The middle process ends at once, so the checkpoint is reparented to its
    // owner, and from then on ends with it.
    if (linux.fork() != 0) linux.exit_group(0);
    var waited: u32 = 0;
    while (linux.getppid() != checkpoint_owner) : (waited += 1) {
        if (waited > 1000) linux.exit_group(0);
        const pause = linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&pause, null);
    }
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);
    if (linux.getppid() != checkpoint_owner) linux.exit_group(0);
    _ = linux.close(output.handle);
    wait(allocator, io, dragon, path, protocol_three) catch {};
    linux.exit_group(0);
}

/// A checkpoint's life: resume each request in a fork of its own.
fn wait(allocator: std.mem.Allocator, io: std.Io, dragon: *bot.Dragon, path: []const u8, protocol_three: bool) !void {
    const linux = std.os.linux;
    const quiet = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(quiet) == .SUCCESS) {
        _ = linux.dup2(@intCast(quiet), 0);
        _ = linux.dup2(@intCast(quiet), 1);
        _ = linux.close(@intCast(quiet));
    }
    // Its workers are reaped by the kernel.
    const ignore = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(linux.SIG.CHLD, &ignore, null);
    const fifo = try allocator.dupeZ(u8, path);
    _ = linux.unlink(fifo);
    if (linux.errno(linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return error.Checkpoint;
    // Opened read-write, it never reads end-of-file between resumes.
    const control = linux.open(fifo, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(control) != .SUCCESS) return error.Checkpoint;
    var named: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&named, "{d}\n", .{linux.getpid()});
    const pid_path = try std.fmt.allocPrintSentinel(allocator, "{s}.pid", .{path}, 0);
    const pid_file = linux.open(pid_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (linux.errno(pid_file) != .SUCCESS) return error.Checkpoint;
    _ = linux.write(@intCast(pid_file), pid_text.ptr, pid_text.len);
    _ = linux.close(@intCast(pid_file));
    var pending: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const got = linux.read(@intCast(control), &buffer, buffer.len);
        if (linux.errno(got) == .INTR) continue;
        if (linux.errno(got) != .SUCCESS or got == 0) return;
        try pending.appendSlice(allocator, buffer[0..got]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            if (linux.fork() == 0) {
                work(allocator, io, dragon, pending.items[0..newline], protocol_three);
                linux.exit_group(0);
            }
            pending.replaceRangeAssumeCapacity(0, newline + 1, &.{});
        }
    }
}

/// A worker resumed from a checkpoint: `RESUME<TAB>RESPONSE<TAB>REPLY`.
fn work(allocator: std.mem.Allocator, io: std.Io, dragon: *bot.Dragon, line: []const u8, protocol_three: bool) void {
    const linux = std.os.linux;
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);
    var fields = std.mem.splitScalar(u8, line, '\t');
    const resume_path = fields.next() orelse return;
    const response_path = fields.next() orelse return;
    const reply_path = allocator.dupeZ(u8, fields.next() orelse return) catch return;
    const reply = linux.open(reply_path, .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(reply) != .SUCCESS) return;
    var named: [32]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&named, "pid {d}\n", .{linux.getpid()}) catch return;
    _ = linux.write(@intCast(reply), pid_text.ptr, pid_text.len);
    const ok = resumed(allocator, io, dragon, resume_path, response_path, protocol_three);
    const verdict: []const u8 = if (ok) "ok\n" else "failed\n";
    _ = linux.write(@intCast(reply), verdict.ptr, verdict.len);
}

fn resumed(allocator: std.mem.Allocator, io: std.Io, dragon: *bot.Dragon, resume_path: []const u8, response_path: []const u8, protocol_three: bool) bool {
    const cwd = std.Io.Dir.cwd();
    const input = cwd.readFileAlloc(io, resume_path, allocator, .unlimited) catch return false;
    const request = std.json.parseFromSlice(Resume, allocator, input, .{}) catch return false;
    // The resumed run's records start a new reader's: its state capture
    // starts whole.
    dragon.capture_state = request.value.state;
    if (dragon.instance) |instance| {
        instance.capture_state = request.value.state;
        instance.forgetState();
    }
    const output = cwd.createFile(io, response_path, .{}) catch return false;
    var three = protocol_three;
    play(allocator, io, dragon, request.value.observations, request.value.loud_from, request.value.loud_until, request.value.checkpoints, output, &three) catch return false;
    return true;
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
    // A server ends with the recovery that started it, however that ends: an
    // orphan would wait on its pipes for ever, holding its memory.
    if (@import("builtin").os.tag == .linux) {
        const linux = std.os.linux;
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);
        if (linux.getppid() == 1) return;
    }
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
