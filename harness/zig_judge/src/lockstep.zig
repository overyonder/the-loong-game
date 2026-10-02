//! `loong-judge --engine E --lockstep MAPS --games N [--seed S]`: plays the
//! organisers' engine and our port of it (harness/zig_judge/reference) side by side.
//! Each turn both must hand the same dragon the same block, byte for byte.
//! Both then get the same reply, chosen from a hash of the block so that games
//! cover moves, sprints, splits (valid and not), both sonar forms, protocol
//! changes and actions the engine rejects. MAPS lists one map file a line.
//! Game i plays map i mod the list with seed S + i. A game stops at its first
//! difference, which is printed with both blocks.

const std = @import("std");
const engine = @import("engine.zig");

extern fn loong_port_create(map: [*]const u8, length: usize, seed: u64, err: [*]u8, capacity: usize) ?*anyopaque;
extern fn loong_port_next(port: *anyopaque, block: [*]u8, capacity: usize, length: *usize) i32;
extern fn loong_port_apply(port: *anyopaque, reply: [*]const u8, length: usize) void;
extern fn loong_port_result(port: *const anyopaque, out: *[10]i32) void;
extern fn loong_port_destroy(port: *anyopaque) void;

const Pair = struct {
    port: *anyopaque,
    seed: u64,
    map: []const u8,
    turns: u64 = 0,
    failed: bool = false,
    block: [1 << 17]u8 = undefined,
    reply: [1024]u8 = undefined,
};

fn mix(value: u64) u64 {
    var z = value +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

const DIRS = "NESW";

/// What the policy reads from a block: the facing, the length, and which of
/// the four steps are plainly fatal (kelp or a body next to the head).
const View = struct {
    facing: usize = 0,
    length: u64 = 2,
    blocked: [4]bool = .{ false, false, false, false },
    room: [4]usize = .{ 0, 0, 0, 0 },
};

fn read(block: []const u8) View {
    var view = View{};
    var lines = std.mem.splitScalar(u8, block, '\n');
    var tiles: [49][2]i64 = undefined;
    var tile_count: usize = 0;
    var bodies: [512][2]i64 = undefined;
    var body_count: usize = 0;
    var edges: [15][]const u8 = undefined;
    var edge_count: usize = 0;
    var messages: usize = 0;
    var stage: enum { header, messages, tiles, bodies, edges } = .header;
    var bodies_left: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const first = fields.next() orelse continue;
        switch (stage) {
            .header => {
                if (std.mem.eql(u8, first, "DIR")) {
                    const d = if (fields.next()) |t| t[0] else @as(u8, 'N');
                    view.facing = std.mem.indexOfScalar(u8, DIRS, d) orelse 0;
                } else if (std.mem.eql(u8, first, "LENGTH")) {
                    view.length = std.fmt.parseInt(u64, fields.next() orelse "2", 10) catch 2;
                } else if (std.mem.eql(u8, first, "NUM_MSGS")) {
                    messages = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch 0;
                    stage = .messages;
                }
            },
            .messages => {
                if (messages > 0) {
                    messages -= 1;
                    continue;
                }
                stage = .tiles;
                if (std.mem.eql(u8, first, "ECHOES")) continue;
                tiles[0] = .{ std.fmt.parseInt(i64, first, 10) catch 0, std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0 };
                tile_count = 1;
            },
            .tiles => {
                if (std.mem.eql(u8, first, "DRAGON_BODIES")) {
                    bodies_left = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch 0;
                    stage = if (bodies_left == 0) .edges else .bodies;
                    continue;
                }
                if (tile_count < 49) {
                    tiles[tile_count] = .{ std.fmt.parseInt(i64, first, 10) catch 0, std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0 };
                    tile_count += 1;
                }
            },
            .bodies => {
                _ = fields.next(); // the dragon's ID
                const x = std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0;
                const y = std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0;
                if (body_count < bodies.len) {
                    bodies[body_count] = .{ x, y };
                    body_count += 1;
                }
                bodies_left -= 1;
                if (bodies_left == 0) stage = .edges;
            },
            .edges => {
                if (edge_count < edges.len) {
                    edges[edge_count] = line;
                    edge_count += 1;
                }
            },
        }
    }
    if (tile_count < 49 or edge_count < 15) return view;
    // The view as a 7x7 grid: which cells hold a body, and which cell edges
    // are kelp or portals (a portal's far side is out of view, so it counts as
    // a wall for room but not for the step itself).
    var occupied = [_]bool{false} ** 49;
    for (bodies[0..body_count]) |segment| {
        for (tiles, 0..) |tile, i| {
            if (tile[0] == segment[0] and tile[1] == segment[1]) occupied[i] = true;
        }
    }
    var horizontal: [8][7]u8 = undefined; // north side of row r, south side of row 6 in r = 7
    var vertical: [7][8]u8 = undefined; // west side of column c, east side of column 6 in c = 7
    for (0..15) |r| {
        var tokens = std.mem.tokenizeScalar(u8, edges[r], ' ');
        var c: usize = 0;
        while (tokens.next()) |token| : (c += 1) {
            const kind: u8 = if (token[0] == 'w') 'w' else if (token[0] == '.') '.' else 'p';
            if (r < 8 and c < 7) horizontal[r][c] = kind else if (r >= 8 and c < 8) vertical[r - 8][c] = kind;
        }
    }
    const dx = [4]i64{ 0, 1, 0, -1 };
    const dy = [4]i64{ -1, 0, 1, 0 };
    const Wall = struct {
        fn kind(h: *const [8][7]u8, v: *const [7][8]u8, col: usize, row: usize, d: usize) u8 {
            return switch (d) {
                0 => h[row][col],
                2 => h[row + 1][col],
                3 => v[row][col],
                else => v[row][col + 1],
            };
        }
    };
    for (0..4) |d| {
        const edge = Wall.kind(&horizontal, &vertical, 3, 3, d);
        const target: usize = @intCast((3 + dy[d]) * 7 + (3 + dx[d]));
        if (edge == 'w' or (edge == '.' and occupied[target])) {
            view.blocked[d] = true;
            continue;
        }
        if (edge == 'p') {
            view.room[d] = 1;
            continue;
        }
        // Room: cells reachable from the target inside the view.
        var seen = occupied;
        seen[24] = true;
        var queue: [49]usize = undefined;
        var head: usize = 0;
        var tail: usize = 1;
        queue[0] = target;
        seen[target] = true;
        while (head < tail) : (head += 1) {
            const cell = queue[head];
            const col = cell % 7;
            const row = cell / 7;
            for (0..4) |e| {
                const nc = @as(i64, @intCast(col)) + dx[e];
                const nr = @as(i64, @intCast(row)) + dy[e];
                if (nc < 0 or nc > 6 or nr < 0 or nr > 6) continue;
                if (Wall.kind(&horizontal, &vertical, col, row, e) != '.') continue;
                const next: usize = @intCast(nr * 7 + nc);
                if (seen[next]) continue;
                seen[next] = true;
                queue[tail] = next;
                tail += 1;
            }
        }
        view.room[d] = tail;
    }
    return view;
}

/// A reply chosen from the block's hash; the same block always gets the same reply.
fn choose(pair: *Pair, block: []const u8) []const u8 {
    const h = mix(std.hash.Wyhash.hash(pair.seed, block));
    const view = read(block);
    var out = std.Io.Writer.fixed(&pair.reply);
    // Odd seeds play recklessly; even seeds play carefully, so their games
    // reach the round limit and the unit limit.
    const careful = pair.seed % 2 == 0;
    const roll = if (careful) 100 + h % 900 else h % 1000;
    var open: [4]usize = undefined;
    var open_count: usize = 0;
    for (0..4) |d| {
        if (d != (view.facing + 2) % 4 and !view.blocked[d]) {
            open[open_count] = d;
            open_count += 1;
        }
    }
    var roomiest: usize = if (open_count > 0) open[(h >> 16) % open_count] else 0;
    for (open[0..open_count]) |d| {
        if (view.room[d] > view.room[roomiest]) roomiest = d;
    }
    const step = if (open_count == 0) (h >> 8) % 4 else if (careful) roomiest else if (!view.blocked[view.facing] and (h >> 12) % 10 < 6) view.facing else open[(h >> 16) % open_count];
    // Rare mistakes, so games last: a reply the engine rejects, any split, then
    // splits it accepts, then sprints.
    if (roll < 2) {
        out.print("MOVE X\n", .{}) catch {};
    } else if (roll < 6) {
        out.print("SPLIT {d}\n", .{(h >> 20) % (view.length + 1)}) catch {};
    } else if ((roll < 40 and view.length >= 4) or (careful and roll < 130 and view.length >= 6)) {
        out.print("SPLIT {d}\n", .{2 + (h >> 20) % (view.length - 3)}) catch {};
    } else if (roll < 70 or (careful and roll < 135)) {
        out.print("MOVE {c}", .{DIRS[step]}) catch {};
        const extra = 1 + (h >> 24) % 2;
        for (0..extra) |k| out.print("{c}", .{DIRS[(h >> @intCast(28 + 2 * k)) % 4]}) catch {};
        out.print("\n", .{}) catch {};
    } else {
        out.print("MOVE {c}\n", .{DIRS[step]}) catch {};
    }
    const sonar = (h >> 40) % 100;
    if (sonar < 25) {
        for (0..4) |d| {
            if ((h >> @intCast(44 + d)) & 1 == 1) out.print("SONAR {c} {d}\n", .{ DIRS[d], mix(h +% d) }) catch {};
        }
    } else if (sonar < 32) {
        out.print("SONAR {d}\n", .{mix(h) & 0xFFFF_FFFF}) catch {};
    }
    if ((h >> 50) % 100 < 8) out.print("PROTOCOL 3\n", .{}) catch {};
    if ((h >> 57) % 16 == 0) out.print("LOG lockstep\n", .{}) catch {};
    out.print("ENDTURN\n", .{}) catch {};
    return out.buffered();
}

fn reply(ctx: *anyopaque, dragon_id: u32, block: []const u8) []const u8 {
    const pair: *Pair = @ptrCast(@alignCast(ctx));
    if (pair.failed) return "";
    var length: usize = 0;
    const id = loong_port_next(pair.port, &pair.block, pair.block.len, &length);
    const ours = pair.block[0..length];
    if (id != @as(i32, @intCast(dragon_id)) or !std.mem.eql(u8, ours, block)) {
        pair.failed = true;
        std.debug.print("{s} seed {d}: turn {d} differs. The engine's dragon {d}:\n{s}\nOur dragon {d}:\n{s}\n", .{ pair.map, pair.seed, pair.turns, dragon_id, block, id, ours });
        return "";
    }
    const text = choose(pair, block);
    loong_port_apply(pair.port, text.ptr, text.len);
    pair.turns += 1;
    return text;
}

fn spawn(ctx: *anyopaque, dragon_id: u32, init: []const u8) void {
    _ = ctx;
    _ = dragon_id;
    _ = init;
}

fn death(ctx: *anyopaque, dragon_id: u32, round: i32, reason: u8) void {
    _ = ctx;
    _ = dragon_id;
    _ = round;
    _ = reason;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, module: *const engine.EngineModule, maps_path: []const u8, games: u64, first_seed: u64) !u8 {
    const cwd = std.Io.Dir.cwd();
    const list = try cwd.readFileAlloc(io, maps_path, allocator, .unlimited);
    defer allocator.free(list);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var names = std.mem.tokenizeAny(u8, list, "\r\n");
    while (names.next()) |name| try paths.append(allocator, name);
    if (paths.items.len == 0) return error.NoMaps;

    var passed: u64 = 0;
    var failed: u64 = 0;
    var skipped: u64 = 0;
    var turns: u64 = 0;
    const pair = try allocator.create(Pair);
    defer allocator.destroy(pair);
    for (0..games) |i| {
        const path = paths.items[i % paths.items.len];
        const map = try cwd.readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(map);
        const seed = first_seed + i;
        var why: [256]u8 = undefined;
        @memset(&why, 0);
        const port = loong_port_create(map.ptr, map.len, seed, &why, why.len) orelse {
            std.debug.print("{s}: skipped, {s}\n", .{ path, std.mem.sliceTo(&why, 0) });
            skipped += 1;
            continue;
        };
        defer loong_port_destroy(port);
        pair.* = .{ .port = port, .seed = seed, .map = path };
        const match = try engine.Match.create(allocator, module, .{ .ctx = pair, .reply = reply, .spawn = spawn, .death = death });
        defer match.destroy();
        const result = try match.run(map, 0, seed);
        turns += pair.turns;
        if (!pair.failed) {
            var length: usize = 0;
            if (loong_port_next(port, &pair.block, pair.block.len, &length) >= 0) {
                std.debug.print("{s} seed {d}: the engine ended the game and ours did not\n", .{ path, seed });
                pair.failed = true;
            }
        }
        var ours: [10]i32 = undefined;
        loong_port_result(port, &ours);
        const winner: i32 = switch (result.winner) {
            .none => 0,
            .a => 1,
            .b => 2,
        };
        if (!pair.failed and (result.rounds + 1 != ours[0] or winner != ours[1] or result.end_reason != ours[2] or result.a_dragons != ours[3] or result.a_length != ours[5] or result.b_dragons != ours[6] or result.b_length != ours[8] or ours[9] != 0)) {
            pair.failed = true;
            std.debug.print("{s} seed {d}: results differ. The engine: rounds {d}, winner {d}, reason {d}, dragons {d} and {d}, lengths {d} and {d}. Ours: {any}\n", .{ path, seed, result.rounds, winner, result.end_reason, result.a_dragons, result.b_dragons, result.a_length, result.b_length, ours });
        }
        if (pair.failed) failed += 1 else passed += 1;
        std.debug.print("{s} seed {d}: {s}, {d} turns, {d} rounds\n", .{ path, seed, if (pair.failed) "DIFFERS" else "same", pair.turns, result.rounds });
    }
    std.debug.print("lockstep: {d} games the same, {d} differ, {d} skipped, {d} turns compared\n", .{ passed, failed, skipped, turns });
    return if (failed == 0 and skipped == 0 and passed > 0) 0 else 1;
}
