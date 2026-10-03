//! A team whose turns another process answers over a UNIX socket, such as the
//! external policy process. The judge connects, and for
//! each game sends, one message a line and its text after:
//!   GAME <seed> <A or B>        the game and the team served
//!   SPAWN <id> <bytes>          a served dragon's init block follows
//!   TURN <id> <bytes>           its turn block follows; the reply is `<bytes>\n` then the reply text
//!   DEATH <id>                  the dragon died
//!   END <A, B or -> <rounds>    the winner and the rounds played

const std = @import("std");

pub const Served = struct {
    team: u8, // 0 is A, 1 is B
    fd: c_int,
    reply: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    failed: bool = false,

    pub fn connect(allocator: std.mem.Allocator, path: []const u8, team: u8) !Served {
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = std.c.close(fd);
        var address = std.mem.zeroes(std.c.sockaddr.un);
        address.family = std.c.AF.UNIX;
        if (path.len >= address.path.len) return error.PathTooLong;
        @memcpy(address.path[0..path.len], path);
        if (std.c.connect(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.un)) != 0) return error.Connect;
        return .{ .team = team, .fd = fd, .allocator = allocator };
    }

    pub fn close(self: *Served) void {
        _ = std.c.close(self.fd);
        self.reply.deinit(self.allocator);
    }

    fn write(self: *Served, bytes: []const u8) void {
        var sent: usize = 0;
        while (sent < bytes.len and !self.failed) {
            const n = std.c.write(self.fd, bytes[sent..].ptr, bytes.len - sent);
            if (n <= 0) self.failed = true else sent += @intCast(n);
        }
    }

    fn header(self: *Served, comptime format: []const u8, args: anytype) void {
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, format, args) catch return;
        self.write(text);
    }

    fn readByte(self: *Served) ?u8 {
        var byte: [1]u8 = undefined;
        if (self.failed or std.c.read(self.fd, &byte, 1) != 1) {
            self.failed = true;
            return null;
        }
        return byte[0];
    }

    pub fn game(self: *Served, seed: u64) void {
        self.header("GAME {d} {c}\n", .{ seed, "AB"[self.team] });
    }

    pub fn spawn(self: *Served, id: u32, init: []const u8) void {
        self.header("SPAWN {d} {d}\n", .{ id, init.len });
        self.write(init);
    }

    pub fn death(self: *Served, id: u32) void {
        self.header("DEATH {d}\n", .{id});
    }

    pub fn end(self: *Served, winner: u8, rounds: i32) void {
        self.header("END {c} {d}\n", .{ winner, rounds });
    }

    /// The served dragon's reply to its turn block; empty if the server is gone,
    /// which the engine treats as no action.
    pub fn turn(self: *Served, id: u32, block: []const u8) []const u8 {
        self.header("TURN {d} {d}\n", .{ id, block.len });
        self.write(block);
        var length: usize = 0;
        while (self.readByte()) |byte| {
            if (byte == '\n') break;
            if (byte < '0' or byte > '9') {
                self.failed = true;
                return "";
            }
            length = length * 10 + (byte - '0');
        }
        if (self.failed) return "";
        self.reply.resize(self.allocator, length) catch return "";
        var got: usize = 0;
        while (got < length) {
            const n = std.c.read(self.fd, self.reply.items[got..].ptr, length - got);
            if (n <= 0) {
                self.failed = true;
                return "";
            }
            got += @intCast(n);
        }
        return self.reply.items;
    }
};
