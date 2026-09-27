//! A bot's stdout, framed the way the judge frames it (`judge/sandbox/src/stdio/stdout.rs
//! feed_bytes`, as the toolkit's turn.py ports it): READY is swallowed in any phase,
//! lines count only while armed, ENDTURN ends the turn and the rest of that write is
//! never seen.

const std = @import("std");

pub const BUFFER_LIMIT: usize = 10 * 1024;
const TERMINATOR = "ENDTURN";
const PARK = "\x00UNSWBC PARK";
const REPLACEMENT = "\xEF\xBF\xBD";

pub const Framer = struct {
    armed:    bool = false,
    done:     bool = false,
    park_at:  ?i64 = null,
    out_len:  usize = 0,
    line_len: usize = 0,
    out:      [BUFFER_LIMIT]u8 = undefined,
    line:     [BUFFER_LIMIT]u8 = undefined,

    pub fn arm(self: *Framer) void {
        self.out_len = 0;
        self.line_len = 0;
        self.armed = true;
        self.done = false;
        self.park_at = null;
    }

    /// Feeds one write; returns true when it carried ENDTURN.
    pub fn feed(self: *Framer, chunk: []const u8) bool {
        for (chunk) |byte| {
            if (byte != '\n') {
                if (self.line_len < BUFFER_LIMIT) {
                    self.line[self.line_len] = byte;
                    self.line_len += 1;
                }
                continue;
            }
            var line: []const u8 = self.line[0..self.line_len];
            self.line_len = 0;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (std.mem.eql(u8, line, "READY")) continue;
            if (std.mem.startsWith(u8, line, PARK)) {
                const tail = std.mem.trim(u8, line[PARK.len..], " \t\r\x0b\x0c");
                self.park_at = if (tail.len > 0 and allDigits(tail)) (std.fmt.parseInt(i64, tail, 10) catch -1) else -1;
                continue;
            }
            if (!self.armed) continue;
            if (std.mem.eql(u8, line, TERMINATOR)) {
                self.armed = false;
                self.done = true;
                return true;
            }
            const room = BUFFER_LIMIT - self.out_len;
            if (room > 0) {
                const n = @min(room, line.len);
                @memcpy(self.out[self.out_len..][0..n], line[0..n]);
                self.out_len += n;
                if (self.out_len < BUFFER_LIMIT) {
                    self.out[self.out_len] = '\n';
                    self.out_len += 1;
                }
            }
        }
        return false;
    }

    /// The turn's reply: the framed lines plus any unterminated tail, with invalid
    /// UTF-8 replaced as Python's decode("utf-8", "replace") would before re-encoding.
    pub fn take(self: *Framer, dest: []u8) []const u8 {
        const room = BUFFER_LIMIT - self.out_len;
        if (room > 0 and !self.done) {
            const n = @min(room, self.line_len);
            @memcpy(self.out[self.out_len..][0..n], self.line[0..n]);
            self.out_len += n;
        }
        self.line_len = 0;
        const n = replaceInvalidUtf8(self.out[0..self.out_len], dest);
        self.out_len = 0;
        return dest[0..n];
    }
};

fn allDigits(text: []const u8) bool {
    for (text) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// Copies `src` into `dest`, replacing each invalid byte with U+FFFD; returns the length written.
fn replaceInvalidUtf8(src: []const u8, dest: []u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < src.len) {
        const len = std.unicode.utf8ByteSequenceLength(src[i]) catch 0;
        if (len > 0 and i + len <= src.len and std.unicode.utf8ValidateSlice(src[i .. i + len])) {
            @memcpy(dest[n..][0..len], src[i .. i + len]);
            n += len;
            i += len;
        } else {
            @memcpy(dest[n..][0..3], REPLACEMENT);
            n += 3;
            i += 1;
        }
    }
    return n;
}
