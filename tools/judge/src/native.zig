//! Explicitly selected C++ simulation and canonical packed replay. The ordinary
//! official engine remains the default; bot execution stays in game.zig.
const std = @import("std");
const engine = @import("engine.zig");
pub const c = @cImport({
    @cInclude("native.h");
});

pub const Library = struct {
    library: std.DynLib,
    create: @TypeOf(&c.loong_native_create),
    run: @TypeOf(&c.loong_native_run),
    replay: @TypeOf(&c.loong_native_replay),
    error_text: @TypeOf(&c.loong_native_error),
    destroy: @TypeOf(&c.loong_native_destroy),
    cuda_create: ?@TypeOf(&c.loong_native_cuda_create),
    cuda_run: ?@TypeOf(&c.loong_native_cuda_run),
    cuda_result: ?@TypeOf(&c.loong_native_cuda_result),
    cuda_replay: ?@TypeOf(&c.loong_native_cuda_replay),
    cuda_error: ?@TypeOf(&c.loong_native_cuda_error),
    cuda_destroy: ?@TypeOf(&c.loong_native_cuda_destroy),

    pub fn open(path: []const u8) !Library {
        var library = try std.DynLib.open(path);
        errdefer library.close();
        const abi = library.lookup(@TypeOf(&c.loong_native_abi), "loong_native_abi") orelse return error.NativeSymbolMissing;
        if (abi() != 1) return error.NativeAbiMismatch;
        return .{
            .library = library,
            .create = library.lookup(@TypeOf(&c.loong_native_create), "loong_native_create") orelse return error.NativeSymbolMissing,
            .run = library.lookup(@TypeOf(&c.loong_native_run), "loong_native_run") orelse return error.NativeSymbolMissing,
            .replay = library.lookup(@TypeOf(&c.loong_native_replay), "loong_native_replay") orelse return error.NativeSymbolMissing,
            .error_text = library.lookup(@TypeOf(&c.loong_native_error), "loong_native_error") orelse return error.NativeSymbolMissing,
            .destroy = library.lookup(@TypeOf(&c.loong_native_destroy), "loong_native_destroy") orelse return error.NativeSymbolMissing,
            .cuda_create = library.lookup(@TypeOf(&c.loong_native_cuda_create), "loong_native_cuda_create"),
            .cuda_run = library.lookup(@TypeOf(&c.loong_native_cuda_run), "loong_native_cuda_run"),
            .cuda_result = library.lookup(@TypeOf(&c.loong_native_cuda_result), "loong_native_cuda_result"),
            .cuda_replay = library.lookup(@TypeOf(&c.loong_native_cuda_replay), "loong_native_cuda_replay"),
            .cuda_error = library.lookup(@TypeOf(&c.loong_native_cuda_error), "loong_native_cuda_error"),
            .cuda_destroy = library.lookup(@TypeOf(&c.loong_native_cuda_destroy), "loong_native_cuda_destroy"),
        };
    }

    pub fn close(self: *Library) void {
        self.library.close();
    }
};

pub const CallbackBridge = struct {
    callbacks: engine.Callbacks,

    pub fn asC(self: *CallbackBridge) c.LoongNativeCallbacks {
        return .{ .context = self, .reply = reply, .spawn = spawn, .death = death };
    }

    fn reply(context: ?*anyopaque, id: u32, block: [*c]const u8, length: usize, reply_length: [*c]usize) callconv(.c) [*c]const u8 {
        const self: *CallbackBridge = @ptrCast(@alignCast(context.?));
        const text = self.callbacks.reply(self.callbacks.ctx, id, block[0..length]);
        reply_length.* = text.len;
        return text.ptr;
    }

    fn spawn(context: ?*anyopaque, id: u32, init: [*c]const u8, length: usize) callconv(.c) void {
        const self: *CallbackBridge = @ptrCast(@alignCast(context.?));
        self.callbacks.spawn(self.callbacks.ctx, id, init[0..length]);
    }

    fn death(context: ?*anyopaque, id: u32, round: i32, reason: u8) callconv(.c) void {
        const self: *CallbackBridge = @ptrCast(@alignCast(context.?));
        self.callbacks.death(self.callbacks.ctx, id, round, reason);
    }
};

pub const Match = struct {
    allocator: std.mem.Allocator,
    library: *const Library,
    match: *c.LoongNativeMatch,
    callbacks: CallbackBridge,

    pub fn create(allocator: std.mem.Allocator, library: *const Library, callbacks: engine.Callbacks) !*Match {
        const self = try allocator.create(Match);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .library = library, .callbacks = .{ .callbacks = callbacks }, .match = undefined };
        self.match = library.create(self.callbacks.asC()) orelse return error.OutOfMemory;
        return self;
    }

    pub fn destroy(self: *Match) void {
        self.library.destroy(self.match);
        self.allocator.destroy(self);
    }

    fn failed(self: *Match) error{NativeEngineFailed} {
        std.debug.print("native engine failed: {s}\n", .{std.mem.span(self.library.error_text(self.match))});
        return error.NativeEngineFailed;
    }

    pub fn run(self: *Match, map: []const u8, debug: i32, seed: u64) !engine.MatchResult {
        var result: [12]i32 = undefined;
        if (self.library.run(self.match, map.ptr, map.len, debug, seed, &result) != 0) return self.failed();
        return resultFromAbi(result);
    }

    pub fn replay(self: *Match, a: []const u8, b: []const u8) ![]u8 {
        var bytes: [*c]const u8 = null;
        var length: usize = 0;
        if (self.library.replay(self.match, a.ptr, a.len, b.ptr, b.len, &bytes, &length) != 0) return self.failed();
        return self.allocator.dupe(u8, bytes[0..length]);
    }
};

fn resultFromAbi(result: [12]i32) engine.MatchResult {
    return .{
        .rounds = result[0],
        .winner = switch (result[1]) {
            1 => .a,
            2 => .b,
            else => .none,
        },
        .end_reason = result[2],
        .a_dragons = result[3],
        .b_dragons = result[4],
        .a_length = result[5],
        .b_length = result[6],
        .events = result[7],
        .a_queen = result[8],
        .b_queen = result[9],
        .a_longest = result[10],
        .b_longest = result[11],
    };
}

pub const CudaBatch = struct {
    allocator: std.mem.Allocator,
    batch: *c.LoongNativeCudaBatch,
    run_fn: @TypeOf(&c.loong_native_cuda_run),
    result_fn: @TypeOf(&c.loong_native_cuda_result),
    replay_fn: @TypeOf(&c.loong_native_cuda_replay),
    error_fn: @TypeOf(&c.loong_native_cuda_error),
    destroy_fn: @TypeOf(&c.loong_native_cuda_destroy),

    pub fn create(allocator: std.mem.Allocator, library: *const Library, setups: []const c.LoongNativeSetup) !CudaBatch {
        const create_fn = library.cuda_create orelse return error.NativeCudaUnavailable;
        const run_fn = library.cuda_run orelse return error.NativeCudaUnavailable;
        const result_fn = library.cuda_result orelse return error.NativeCudaUnavailable;
        const replay_fn = library.cuda_replay orelse return error.NativeCudaUnavailable;
        const error_fn = library.cuda_error orelse return error.NativeCudaUnavailable;
        const destroy_fn = library.cuda_destroy orelse return error.NativeCudaUnavailable;
        var message: [1024]u8 = @splat(0);
        const batch = create_fn(setups.ptr, setups.len, &message, message.len) orelse {
            std.debug.print("native CUDA create failed: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.NativeCudaFailed;
        };
        return .{ .allocator = allocator, .batch = batch, .run_fn = run_fn, .result_fn = result_fn, .replay_fn = replay_fn, .error_fn = error_fn, .destroy_fn = destroy_fn };
    }

    pub fn destroy(self: *CudaBatch) void {
        self.destroy_fn(self.batch);
    }

    fn failed(self: *CudaBatch) error{NativeCudaFailed} {
        std.debug.print("native CUDA failed: {s}\n", .{std.mem.span(self.error_fn(self.batch))});
        return error.NativeCudaFailed;
    }

    pub fn run(self: *CudaBatch, threads: usize) !void {
        if (threads > std.math.maxInt(u32)) return error.BadCudaThreadCount;
        if (self.run_fn(self.batch, @intCast(threads)) != 0) return self.failed();
    }

    pub fn result(self: *CudaBatch, index: usize) !engine.MatchResult {
        var raw: [12]i32 = undefined;
        if (self.result_fn(self.batch, @intCast(index), &raw) != 0) return self.failed();
        return resultFromAbi(raw);
    }

    pub fn replay(self: *CudaBatch, index: usize, names: [2][]const u8) ![]u8 {
        var bytes: [*c]const u8 = null;
        var length: usize = 0;
        if (self.replay_fn(self.batch, @intCast(index), names[0].ptr, names[0].len, names[1].ptr, names[1].len, &bytes, &length) != 0) return self.failed();
        return self.allocator.dupe(u8, bytes[0..length]);
    }
};
