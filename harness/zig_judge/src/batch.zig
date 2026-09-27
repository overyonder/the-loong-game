//! Many games in one process: workers take jobs from a shared list, compiled modules
//! and maps are loaded once and shared, and each finished game prints one line.

const std = @import("std");
const wt = @import("wasmtime.zig");
const engine = @import("engine.zig");
const bot = @import("bot.zig");
const game = @import("game.zig");
const sync = @import("sync.zig");

/// One line of a jobs file: id, map, bot A, bot B, seed, then optionally a replay
/// path and the two team names, all tab separated.
pub const Job = struct {
    id:     []const u8,
    map:    []const u8,
    a:      []const u8,
    b:      []const u8,
    seed:   u64,
    replay: ?[]const u8,
    name_a: ?[]const u8,
    name_b: ?[]const u8,
};

pub fn parseJobs(allocator: std.mem.Allocator, text: []const u8) ![]Job {
    var jobs: std.ArrayList(Job) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse return error.BadJob;
        const map = fields.next() orelse return error.BadJob;
        const a = fields.next() orelse return error.BadJob;
        const b = fields.next() orelse return error.BadJob;
        const seed_text = fields.next() orelse return error.BadJob;
        const replay = fields.next();
        const name_a = fields.next();
        const name_b = fields.next();
        try jobs.append(allocator, .{
            .id = id,
            .map = map,
            .a = a,
            .b = b,
            .seed = try std.fmt.parseInt(u64, seed_text, 0),
            .replay = if (replay) |r| (if (r.len > 0) r else null) else null,
            .name_a = if (name_a) |n| (if (n.len > 0) n else null) else null,
            .name_b = if (name_b) |n| (if (n.len > 0) n else null) else null,
        });
    }
    return jobs.toOwnedSlice(allocator);
}

/// Files and compiled modules shared by every worker, loaded on first use.
const Shared = struct {
    allocator: std.mem.Allocator,
    io:        std.Io,
    wasm:      *wt.c.wasm_engine_t,
    modules:   std.StringHashMap(*bot.BotModule),
    maps:      std.StringHashMap([]u8),
    mutex:     sync.Mutex,

    fn module(self: *Shared, path: []const u8) !*bot.BotModule {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.modules.get(path)) |found| return found;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(bytes);
        const loaded = try self.allocator.create(bot.BotModule);
        loaded.* = try bot.BotModule.load(self.allocator, self.wasm, bytes);
        try self.modules.put(path, loaded);
        return loaded;
    }

    fn map(self: *Shared, path: []const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.maps.get(path)) |found| return found;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        try self.maps.put(path, bytes);
        return bytes;
    }
};

const Worker = struct {
    shared:        *Shared,
    engine_module: *const engine.EngineModule,
    jobs:          []const Job,
    next:          *std.atomic.Value(usize),
    debug:         i32,
    stdout:        *sync.Mutex,

    fn run(self: *Worker) void {
        while (true) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.jobs.len) return;
            const job = self.jobs[index];
            var line: [640]u8 = undefined;
            const text = self.play(job, &line) catch |err| blk: {
                break :blk std.fmt.bufPrint(&line, "{s}\terror\t{s}\n", .{ job.id, @errorName(err) }) catch "error\n";
            };
            self.stdout.lock();
            defer self.stdout.unlock();
            std.Io.File.stdout().writeStreamingAll(self.shared.io, text) catch {};
        }
    }

    fn play(self: *Worker, job: Job, line: []u8) ![]const u8 {
        const module_a = try self.shared.module(job.a);
        const module_b = try self.shared.module(job.b);
        const map = try self.shared.map(job.map);
        const summary = try game.play(self.shared.allocator, .{
            .engine_module = self.engine_module,
            .modules = .{ module_a, module_b },
            .map = map,
            .seed = job.seed,
            .debug = self.debug,
            .names = .{ job.name_a orelse job.a, job.name_b orelse job.b },
            .want_replay = job.replay != null,
        });
        defer if (summary.replay) |replay| self.shared.allocator.free(replay);
        if (job.replay) |path| {
            const file = try std.Io.Dir.cwd().createFile(self.shared.io, path, .{});
            defer file.close(self.shared.io);
            try file.writeStreamingAll(self.shared.io, summary.replay.?);
        }
        const figures = try game.formatFigures(summary, line[job.id.len + 1 ..]);
        @memcpy(line[0..job.id.len], job.id);
        line[job.id.len] = '\t';
        return line[0 .. job.id.len + 1 + figures.len];
    }
};

/// Runs every job on `threads` workers and returns once all have printed.
pub fn run(allocator: std.mem.Allocator, io: std.Io, wasm: *wt.c.wasm_engine_t, engine_module: *const engine.EngineModule, jobs: []const Job, threads: usize, debug: i32) !void {
    var shared = Shared{
        .allocator = allocator,
        .io = io,
        .wasm = wasm,
        .modules = std.StringHashMap(*bot.BotModule).init(allocator),
        .maps = std.StringHashMap([]u8).init(allocator),
        .mutex = sync.Mutex.init(),
    };
    defer {
        var modules = shared.modules.valueIterator();
        while (modules.next()) |loaded| {
            loaded.*.deinit(allocator);
            allocator.destroy(loaded.*);
        }
        shared.modules.deinit();
        var maps = shared.maps.valueIterator();
        while (maps.next()) |bytes| allocator.free(bytes.*);
        shared.maps.deinit();
        shared.mutex.deinit();
    }
    var next = std.atomic.Value(usize).init(0);
    var stdout = sync.Mutex.init();
    defer stdout.deinit();

    const count = @max(1, @min(threads, jobs.len));
    const workers = try allocator.alloc(Worker, count);
    defer allocator.free(workers);
    const handles = try allocator.alloc(std.Thread, count);
    defer allocator.free(handles);
    for (workers, 0..) |*worker, i| {
        worker.* = .{ .shared = &shared, .engine_module = engine_module, .jobs = jobs, .next = &next, .debug = debug, .stdout = &stdout };
        handles[i] = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (handles) |handle| handle.join();
}
