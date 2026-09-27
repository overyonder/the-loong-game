//! The organisers' game engine, compiled to WebAssembly and shipped with the toolkit
//! as unswbc_engine.wasm. It owns every rule and writes the replay; the judge only
//! serves its three imports: bot_spawn, bot_reply and log.

const std = @import("std");
const wt = @import("wasmtime.zig");
const c = wt.c;

pub const DEBUG_ALL: i32 = 15;

pub const Winner = enum { none, a, b };

pub const MatchResult = struct {
    rounds:     i32,
    winner:     Winner,
    end_reason: i32,
    a_dragons:  i32,
    b_dragons:  i32,
    a_length:   i32,
    b_length:   i32,
    events:     i32,
};

/// What a match needs from its host: a reply for a dragon's turn, a spawn and a death.
pub const Callbacks = struct {
    ctx:   *anyopaque,
    reply: *const fn (ctx: *anyopaque, dragon_id: u32, block: []const u8) []const u8,
    spawn: *const fn (ctx: *anyopaque, dragon_id: u32, init: []const u8) void,
    death: *const fn (ctx: *anyopaque, dragon_id: u32, round: i32, reason: u8) void,
};

pub const EngineModule = struct {
    engine: *c.wasm_engine_t,
    module: *c.wasmtime_module_t,

    pub fn load(engine: *c.wasm_engine_t, bytes: []const u8) !EngineModule {
        return .{ .engine = engine, .module = try wt.compileModule(engine, bytes) };
    }

    pub fn deinit(self: *EngineModule) void {
        c.wasmtime_module_delete(self.module);
    }
};

pub const Match = struct {
    allocator:  std.mem.Allocator,
    store:      *c.wasmtime_store_t,
    context:    *c.wasmtime_context_t,
    linker:     *c.wasmtime_linker_t,
    instance:   c.wasmtime_instance_t,
    memory:     c.wasmtime_memory_t,
    alloc_fn:   c.wasmtime_func_t,
    free_fn:    c.wasmtime_func_t,
    run_fn:     c.wasmtime_func_t,
    replay_fn:  c.wasmtime_func_t,
    replay_ptr: c.wasmtime_func_t,
    error_fn:   c.wasmtime_func_t,
    callbacks:  Callbacks,
    long_reply: ?[]u8 = null,   // a reply the engine's buffer could not hold, kept for its retry
    message:    [1024]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, module: *const EngineModule, callbacks: Callbacks) !*Match {
        const self = try allocator.create(Match);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .store = undefined,
            .context = undefined,
            .linker = undefined,
            .instance = undefined,
            .memory = undefined,
            .alloc_fn = undefined,
            .free_fn = undefined,
            .run_fn = undefined,
            .replay_fn = undefined,
            .replay_ptr = undefined,
            .error_fn = undefined,
            .callbacks = callbacks,
        };
        self.store = c.wasmtime_store_new(module.engine, null, null) orelse return error.Wasmtime;
        self.context = c.wasmtime_store_context(self.store).?;

        // The engine's WASI: nothing inherited, so its notices about map defects go nowhere.
        const wasi = c.wasi_config_new();
        if (wasi == null) return error.Wasmtime;
        try check(c.wasmtime_context_set_wasi(self.context, wasi), self);

        self.linker = c.wasmtime_linker_new(module.engine) orelse return error.Wasmtime;
        try check(c.wasmtime_linker_define_wasi(self.linker), self);

        const reply_type = wt.functype(&.{ .i32, .i32, .i32, .i32, .i32 }, &.{.i32});
        defer c.wasm_functype_delete(reply_type);
        const log_type = wt.functype(&.{ .i32, .i32, .i32 }, &.{});
        defer c.wasm_functype_delete(log_type);
        const spawn_type = wt.functype(&.{ .i32, .i32, .i32 }, &.{});
        defer c.wasm_functype_delete(spawn_type);
        try check(c.wasmtime_linker_define_func(self.linker, "unswbc", 6, "bot_reply", 9, reply_type, botReply, self, null), self);
        try check(c.wasmtime_linker_define_func(self.linker, "unswbc", 6, "log", 3, log_type, botDeath, self, null), self);
        try check(c.wasmtime_linker_define_func(self.linker, "unswbc", 6, "bot_spawn", 9, spawn_type, botSpawn, self, null), self);

        var trap: ?*c.wasm_trap_t = null;
        try check(c.wasmtime_linker_instantiate(self.linker, self.context, module.module, &self.instance, &trap), self);
        if (trap != null) {
            std.debug.print("engine trapped: {s}\n", .{wt.takeTrapMessage(trap, &self.message)});
            return error.Wasmtime;
        }

        self.memory = (try self.exportOf("memory")).of.memory;
        self.alloc_fn = (try self.exportOf("ubc_alloc")).of.func;
        self.free_fn = (try self.exportOf("ubc_free")).of.func;
        self.run_fn = (try self.exportOf("ubc_run")).of.func;
        self.replay_fn = (try self.exportOf("ubc_replay")).of.func;
        self.replay_ptr = (try self.exportOf("ubc_replay_ptr")).of.func;
        self.error_fn = (try self.exportOf("ubc_error")).of.func;
        var initialize: c.wasmtime_extern_t = undefined;
        if (c.wasmtime_instance_export_get(self.context, &self.instance, "_initialize", 11, &initialize)) {
            _ = try self.call(&initialize.of.func, &.{}, 0);
        }
        return self;
    }

    pub fn destroy(self: *Match) void {
        if (self.long_reply) |reply| self.allocator.free(reply);
        c.wasmtime_linker_delete(self.linker);
        c.wasmtime_store_delete(self.store);
        self.allocator.destroy(self);
    }

    fn exportOf(self: *Match, name: []const u8) !c.wasmtime_extern_t {
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(self.context, &self.instance, name.ptr, name.len, &item)) {
            std.debug.print("engine lacks export {s}\n", .{name});
            return error.Wasmtime;
        }
        return item;
    }

    /// Calls an engine export with i32 arguments and returns its first i32 result, if any.
    fn call(self: *Match, func: *const c.wasmtime_func_t, args: []const i32, nresults: usize) !i32 {
        var vals: [8]c.wasmtime_val_t = undefined;
        for (args, 0..) |arg, i| vals[i] = wt.i32Val(arg);
        var results: [1]c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try check(c.wasmtime_func_call(self.context, func, &vals, args.len, &results, nresults, &trap), self);
        if (trap != null) {
            std.debug.print("engine trapped: {s}\n", .{wt.takeTrapMessage(trap, &self.message)});
            return error.Wasmtime;
        }
        return if (nresults > 0) results[0].of.i32 else 0;
    }

    fn memoryData(self: *Match, context: *c.wasmtime_context_t) []u8 {
        const data = c.wasmtime_memory_data(context, &self.memory);
        const size = c.wasmtime_memory_data_size(context, &self.memory);
        return data[0..size];
    }

    /// Plays the match to its end; the callbacks fire from inside this call.
    pub fn run(self: *Match, map: []const u8, debug: i32, seed: u64) !MatchResult {
        const map_ptr = try self.call(&self.alloc_fn, &.{@intCast(map.len)}, 1);
        @memcpy(self.memoryData(self.context)[@intCast(map_ptr)..][0..map.len], map);
        const out_ptr = try self.call(&self.alloc_fn, &.{32}, 1);

        var args = [_]c.wasmtime_val_t{
            wt.i32Val(map_ptr), wt.i32Val(@intCast(map.len)), wt.i32Val(debug),
            wt.i64Val(@bitCast(seed)), wt.i32Val(out_ptr),
        };
        var results: [1]c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try check(c.wasmtime_func_call(self.context, &self.run_fn, &args, args.len, &results, 1, &trap), self);
        if (trap != null) {
            std.debug.print("engine trapped: {s}\n", .{wt.takeTrapMessage(trap, &self.message)});
            return error.Wasmtime;
        }
        if (results[0].of.i32 != 0) {
            std.debug.print("engine failed: {s}\n", .{try self.errorText()});
            return error.EngineFailed;
        }
        const raw = self.memoryData(self.context)[@intCast(out_ptr)..][0..32];
        var values: [8]i32 = undefined;
        for (&values, 0..) |*value, i| value.* = std.mem.readInt(i32, raw[i * 4 ..][0..4], .little);
        return .{
            .rounds = values[0],
            .winner = switch (values[1]) { 1 => .a, 2 => .b, else => .none },
            .end_reason = values[2],
            .a_dragons = values[3],
            .b_dragons = values[4],
            .a_length = values[5],
            .b_length = values[6],
            .events = values[7],
        };
    }

    /// The replay of the match just run, as the engine serialises it.
    pub fn replay(self: *Match, team_a: []const u8, team_b: []const u8) ![]u8 {
        var ptrs: [2]i32 = undefined;
        for ([_][]const u8{ team_a, team_b }, 0..) |name, i| {
            ptrs[i] = try self.call(&self.alloc_fn, &.{@intCast(name.len)}, 1);
            @memcpy(self.memoryData(self.context)[@intCast(ptrs[i])..][0..name.len], name);
        }
        const size = try self.call(&self.replay_fn, &.{ ptrs[0], @intCast(team_a.len), ptrs[1], @intCast(team_b.len) }, 1);
        for (ptrs) |ptr| _ = try self.call(&self.free_fn, &.{ptr}, 0);
        if (size < 0) {
            std.debug.print("engine failed: {s}\n", .{try self.errorText()});
            return error.EngineFailed;
        }
        const base = try self.call(&self.replay_ptr, &.{}, 1);
        return self.allocator.dupe(u8, self.memoryData(self.context)[@intCast(base)..][0..@intCast(size)]);
    }

    fn errorText(self: *Match) ![]const u8 {
        const ptr: usize = @intCast(try self.call(&self.error_fn, &.{}, 1));
        const memory = self.memoryData(self.context);
        var end = ptr;
        while (end < memory.len and memory[end] != 0) end += 1;
        const n = @min(end - ptr, self.message.len);
        @memcpy(self.message[0..n], memory[ptr .. ptr + n]);
        return self.message[0..n];
    }
};

fn check(err: ?*c.wasmtime_error_t, match: *Match) !void {
    if (err == null) return;
    std.debug.print("engine error: {s}\n", .{wt.takeErrorMessage(err, &match.message)});
    return error.Wasmtime;
}

fn botReply(env: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize) callconv(.c) ?*c.wasm_trap_t {
    _ = nargs;
    _ = nresults;
    const match: *Match = @ptrCast(@alignCast(env.?));
    const context: *c.wasmtime_context_t = c.wasmtime_caller_context(caller).?;
    const dragon_id: u32 = @bitCast(args[0].of.i32);
    const ptr: usize = @intCast(@as(u32, @bitCast(args[1].of.i32)));
    const length: usize = @intCast(@as(u32, @bitCast(args[2].of.i32)));
    const out: usize = @intCast(@as(u32, @bitCast(args[3].of.i32)));
    const cap: usize = @intCast(@as(u32, @bitCast(args[4].of.i32)));

    var reply: []const u8 = undefined;
    var owned = false;
    if (match.long_reply) |kept| {
        reply = kept;
        owned = true;
        match.long_reply = null;
    } else {
        const block = match.memoryData(context)[ptr .. ptr + length];
        reply = match.callbacks.reply(match.callbacks.ctx, dragon_id, block);
    }
    defer if (owned) match.allocator.free(@constCast(reply));
    // Too long for the buffer: the engine grows it and asks again.
    if (reply.len > cap) {
        if (!owned) match.long_reply = match.allocator.dupe(u8, reply) catch null;
        results[0] = wt.i32Val(@intCast(reply.len));
        return null;
    }
    @memcpy(match.memoryData(context)[out..][0..reply.len], reply);
    results[0] = wt.i32Val(@intCast(reply.len));
    return null;
}

fn botDeath(env: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize) callconv(.c) ?*c.wasm_trap_t {
    _ = caller;
    _ = nargs;
    _ = results;
    _ = nresults;
    const match: *Match = @ptrCast(@alignCast(env.?));
    match.callbacks.death(match.callbacks.ctx, @bitCast(args[0].of.i32), args[1].of.i32, @truncate(@as(u32, @bitCast(args[2].of.i32))));
    return null;
}

fn botSpawn(env: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize) callconv(.c) ?*c.wasm_trap_t {
    _ = nargs;
    _ = results;
    _ = nresults;
    const match: *Match = @ptrCast(@alignCast(env.?));
    const context: *c.wasmtime_context_t = c.wasmtime_caller_context(caller).?;
    const ptr: usize = @intCast(@as(u32, @bitCast(args[1].of.i32)));
    const length: usize = @intCast(@as(u32, @bitCast(args[2].of.i32)));
    const init = match.memoryData(context)[ptr .. ptr + length];
    match.callbacks.spawn(match.callbacks.ctx, @bitCast(args[0].of.i32), init);
    return null;
}
