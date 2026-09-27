//! The monotonic clock and a mutex, through libc.

const std = @import("std");

pub const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("time.h");
});

pub const Mutex = struct {
    inner: c.pthread_mutex_t,

    pub fn init() Mutex {
        var mutex: Mutex = .{ .inner = undefined };
        _ = c.pthread_mutex_init(&mutex.inner, null);
        return mutex;
    }

    pub fn deinit(self: *Mutex) void {
        _ = c.pthread_mutex_destroy(&self.inner);
    }

    pub fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

pub fn monotonicNanos() i128 {
    var now: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
    return @as(i128, now.tv_sec) * std.time.ns_per_s + now.tv_nsec;
}
