//! A dragon's bot in the judge's sandbox: a metered WebAssembly instance run as a
//! wasmtime async fiber on the driver's own thread, fed turn blocks over stdin and
//! read back through the framer, with the judge's CPU-point accounting. This ports
//! the toolkit's sandbox.py and turn.py, reduced to what compiled bots use.
//!
//! The toolkit runs each bot on a thread that blocks in fd_read; here a host call that
//! would block returns a pending continuation instead, and the driver polls the bot's
//! future only while it is that bot's turn. Nothing crosses a thread.

const std = @import("std");
const wt = @import("wasmtime.zig");
const c = wt.c;
const framer_mod = @import("framer.zig");
const metering = @import("metering.zig");
const Framer = framer_mod.Framer;

pub const MAX_TURN_POINTS: i64 = 100_000_000;
/// A turn's cap in inspect mode, where diagnostics run inside the turn: they are
/// metered, but the bot leaves their points out of its own clock (runtime/).
pub const INSPECTION_TURN_POINTS: i64 = 100 * MAX_TURN_POINTS;
/// A stdout line that is a diagnostic record, not gameplay (runtime/gizmos.h).
const GIZMO_PREFIX = "LOG LOONG_GIZMO ";
pub const MAX_MEMORY_PAGES: u64 = 768;
pub const INITIAL_POINTS: i64 = std.math.maxInt(i64);
const WRITE_SYSCALL_COST: i64 = 2_500_000;
const WRITE_BYTE_COST: i64 = 4_000;
const READ_BYTE_COST: i64 = 6;
/// Whether a new process's first stdin read call is charged. The competition's
/// judge doesn't charge it: in 98 first turns of two ladder games its points
/// were ours less exactly 6 per byte of that read. That evidence can't tell
/// "the first read call is free" from "the first 1,024 bytes are free", since
/// the bots read through a 1,024-byte buffer. The toolkit charges it, and
/// `run --charge-first-read` sets this to match the toolkit.
pub var charge_first_read = false;
const VIRTUAL_EPOCH_NS: u64 = 1_767_225_600_000_000_000;
/// Host calls a turn may make before the bot is treated as out of time; points bound
/// computation, this bounds a bot that only ever yields.
const MAX_CALLS_PER_TURN: u32 = 4_000_000;
const REMAINING_EXPORT = "wasmer_metering_remaining_points";
const EXHAUSTED_EXPORT = "wasmer_metering_points_exhausted";
const ARGV = [_][]const u8{"bot"};
const ENVIRON = [_][]const u8{"TERM=dumb"};

const errno = struct {
    const OK: i32 = 0;
    const E2BIG: i32 = 1;
    const EBADF: i32 = 8;
    const EINVAL: i32 = 28;
    const EISDIR: i32 = 31;
    const ENOTSUP: i32 = 58;
    const ENOTTY: i32 = 59;
    const ERANGE: i32 = 68;
};
const FILETYPE_CHARACTER: u8 = 2;
const FILETYPE_DIRECTORY: u8 = 3;

const HostError = error{ Exit, OutOfBounds, Unsupported, OutOfMemory };

/// The syscalls the judge serves to a bot, and what it does with the rest.
const Syscall = enum {
    args_sizes_get,
    args_get,
    environ_sizes_get,
    environ_get,
    clock_time_get,
    clock_res_get,
    random_get,
    sched_yield,
    poll_oneoff,
    fd_prestat_get,
    fd_prestat_dir_name,
    fd_fdstat_get,
    fd_fdstat_set_flags,
    fd_filestat_get,
    fd_close,
    fd_read,
    fd_write,
    fd_seek,
    fd_tell,
    proc_exit,
    thread_exit,
    proc_exit2,
    futex_wait,
    futex_wake,
    futex_wake_all,
    proc_signals_get,
    proc_signals_sizes_get,
    thread_id,
    thread_parallelism,
    proc_id,
    fd_fdflags_get,
    fd_fdflags_set,
    getcwd,
    chdir,
    tty_get,
    inspection_begin,
    inspection_end,
    inspection_write,
    inspection_log,
    denied, // the judge refuses it: ENOTSUP, or nothing when it returns nothing
    unsupported, // the judge has no such call: the bot fails on it
};

const syscall_names = std.StaticStringMap(Syscall).initComptime(.{
    .{ "args_sizes_get", .args_sizes_get },                 .{ "args_get", .args_get },
    .{ "environ_sizes_get", .environ_sizes_get },           .{ "environ_get", .environ_get },
    .{ "clock_time_get", .clock_time_get },                 .{ "clock_res_get", .clock_res_get },
    .{ "random_get", .random_get },                         .{ "sched_yield", .sched_yield },
    .{ "poll_oneoff", .poll_oneoff },                       .{ "fd_prestat_get", .fd_prestat_get },
    .{ "fd_prestat_dir_name", .fd_prestat_dir_name },       .{ "fd_fdstat_get", .fd_fdstat_get },
    .{ "fd_fdstat_set_flags", .fd_fdstat_set_flags },       .{ "fd_filestat_get", .fd_filestat_get },
    .{ "fd_close", .fd_close },                             .{ "fd_read", .fd_read },
    .{ "fd_write", .fd_write },                             .{ "fd_seek", .fd_seek },
    .{ "fd_tell", .fd_tell },                               .{ "proc_exit", .proc_exit },
    .{ "thread_exit", .thread_exit },                       .{ "proc_exit2", .proc_exit2 },
    .{ "futex_wait", .futex_wait },                         .{ "futex_wake", .futex_wake },
    .{ "futex_wake_all", .futex_wake_all },                 .{ "proc_signals_get", .proc_signals_get },
    .{ "proc_signals_sizes_get", .proc_signals_sizes_get }, .{ "thread_id", .thread_id },
    .{ "thread_parallelism", .thread_parallelism },         .{ "proc_id", .proc_id },
    .{ "fd_fdflags_get", .fd_fdflags_get },                 .{ "fd_fdflags_set", .fd_fdflags_set },
    .{ "getcwd", .getcwd },                                 .{ "chdir", .chdir },
    .{ "tty_get", .tty_get },
});

const denied_names = std.StaticStringMap(void).initComptime(.{
    .{ "callback_signal", {} }, .{ "dl_invalid_handle", {} }, .{ "dlopen", {} },         .{ "dlsym", {} },
    .{ "epoll_create", {} },    .{ "epoll_ctl", {} },         .{ "epoll_wait", {} },     .{ "fd_event", {} },
    .{ "fd_pipe", {} },         .{ "proc_exec4", {} },        .{ "proc_fork", {} },      .{ "proc_join", {} },
    .{ "proc_raise", {} },      .{ "proc_signal", {} },       .{ "proc_spawn3", {} },    .{ "sock_connect", {} },
    .{ "sock_open", {} },       .{ "sock_send", {} },         .{ "sock_send_file", {} }, .{ "sock_send_to", {} },
    .{ "thread-spawn", {} },    .{ "thread_join", {} },       .{ "thread_signal", {} },  .{ "thread_sleep", {} },
    .{ "tty_set", {} },
});

/// xoshiro256**, seeded as the judge seeds a process's random_get.
const Rng = struct {
    state: [4]u64,

    fn init(key: []const u8, process: []const u8) Rng {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(key);
        hasher.update("\x00");
        hasher.update(process);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        var rng: Rng = .{ .state = undefined };
        for (&rng.state, 0..) |*word, i| word.* = std.mem.readInt(u64, digest[i * 8 ..][0..8], .little);
        return rng;
    }

    fn next(self: *Rng) u64 {
        const s = &self.state;
        const out = std.math.rotl(u64, s[1] *% 5, 7) *% 9;
        const t = s[1] << 17;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = std.math.rotl(u64, s[3], 45);
        return out;
    }

    fn fill(self: *Rng, dest: []u8) void {
        var i: usize = 0;
        while (i < dest.len) {
            const word = std.mem.toBytes(std.mem.nativeToLittle(u64, self.next()));
            const n = @min(8, dest.len - i);
            @memcpy(dest[i..][0..n], word[0..n]);
            i += n;
        }
    }
};

/// A compiled, metered bot shared by every dragon that runs it.
pub const BotModule = struct {
    engine: *c.wasm_engine_t,
    module: *c.wasmtime_module_t,
    imports: c.wasm_importtype_vec_t, // kept alive: instances borrow the function types from it
    functions: []const ImportSpec,
    memory_min: u64,
    memory_max: u64,
    inspection_enabled: bool = false,

    const ImportSpec = struct {
        module_name: []const u8,
        name: []const u8,
        functype: *const c.wasm_functype_t,
        syscall: Syscall,
        has_results: bool,
    };

    /// Compiles a bot, metering it first unless it already carries the meter.
    pub fn load(allocator: std.mem.Allocator, engine: *c.wasm_engine_t, bytes: []const u8) !BotModule {
        const metered = if (metering.isMetered(bytes)) bytes else try metering.instrument(allocator, bytes);
        defer if (metered.ptr != bytes.ptr) allocator.free(metered);
        const module = try wt.compileModule(engine, metered);
        var imports: c.wasm_importtype_vec_t = undefined;
        c.wasmtime_module_imports(module, &imports);
        var functions: std.ArrayList(ImportSpec) = .empty;
        var memory_min: u64 = 1;
        var memory_max: u64 = 65536;
        for (imports.data[0..imports.size]) |import| {
            const module_name = nameOf(c.wasm_importtype_module(import));
            const name = nameOf(c.wasm_importtype_name(import));
            const extern_type = c.wasm_importtype_type(import);
            switch (c.wasm_externtype_kind(extern_type)) {
                c.WASM_EXTERN_FUNC => {
                    const functype = c.wasm_externtype_as_functype_const(extern_type);
                    const results = c.wasm_functype_results(functype);
                    const syscall = if (std.mem.eql(u8, module_name, "loong_inspection"))
                        (if (std.mem.eql(u8, name, "begin")) Syscall.inspection_begin else if (std.mem.eql(u8, name, "end")) Syscall.inspection_end else if (std.mem.eql(u8, name, "write")) Syscall.inspection_write else if (std.mem.eql(u8, name, "log")) Syscall.inspection_log else Syscall.unsupported)
                    else
                        syscall_names.get(name) orelse (if (denied_names.has(name)) Syscall.denied else Syscall.unsupported);
                    try functions.append(allocator, .{
                        .module_name = module_name,
                        .name = name,
                        .functype = @ptrCast(functype),
                        .syscall = syscall,
                        .has_results = results.*.size > 0,
                    });
                },
                c.WASM_EXTERN_MEMORY => {
                    const memtype = c.wasm_externtype_as_memorytype_const(extern_type);
                    memory_min = c.wasmtime_memorytype_minimum(memtype);
                    var maximum: u64 = undefined;
                    if (c.wasmtime_memorytype_maximum(memtype, &maximum)) memory_max = maximum;
                },
                else => {},
            }
        }
        return .{
            .engine = engine,
            .module = module,
            .imports = imports,
            .functions = try functions.toOwnedSlice(allocator),
            .memory_min = memory_min,
            .memory_max = memory_max,
        };
    }

    pub fn deinit(self: *BotModule, allocator: std.mem.Allocator) void {
        allocator.free(self.functions);
        c.wasm_importtype_vec_delete(&self.imports);
        c.wasmtime_module_delete(self.module);
    }
};

fn nameOf(name: [*c]const c.wasm_name_t) []const u8 {
    return name.*.data[0..name.*.size];
}

const Binding = struct {
    instance: *Instance,
    syscall: Syscall,
    name: []const u8,
    has_results: bool,
};

/// A host call the guest made that could not complete yet.
const PendingCall = struct {
    binding: *Binding,
    args: [8]c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
};

pub const DriveState = enum { data, exit, park };

pub const TurnState = struct {
    done: bool,
    park_at: ?i64,
    has_output: bool,
};

const State = enum { running, reading, frozen, finished };

/// One running copy of a bot: the sandbox, its stdin, its framed stdout and its fiber.
pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: *const BotModule,
    store: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,
    linker: *c.wasmtime_linker_t,
    memory: *c.wasmtime_sharedmemory_t,
    instance: c.wasmtime_instance_t,
    start_fn: c.wasmtime_func_t,
    meter: ?c.wasmtime_global_t,
    exhausted: ?c.wasmtime_global_t,
    bindings: []Binding,
    rng: Rng,

    future: ?*c.wasmtime_call_future_t = null,
    trap_out: ?*c.wasm_trap_t = null, // set by wasmtime when the future completes
    error_out: ?*c.wasmtime_error_t = null,
    state: State = .running,
    pending: ?PendingCall = null,
    deferred_trap: ?*c.wasm_trap_t = null, // a trap raised by a resumed call, delivered at the next
    calls: u32 = 0, // host calls this turn

    // stdin, as the driver feeds it and the guest's fd_read drains it
    stdin: std.ArrayList(u8) = .empty,
    stdin_pos: usize = 0,
    stdin_closed: bool = false,
    parks: u32 = 0, // times the guest waited on an empty stdin
    parks_snapshot: u32 = 0,
    has_read: bool = false, // the process has read stdin before

    // Annotation bytes bypass gameplay stdout and its 10 KiB framer.
    // A separate finite budget bounds broken observers without charging policy.
    annotation_output: std.ArrayList(u8) = .empty,
    annotation_depth: u32 = 0,
    annotation_policy_remaining: i64 = 0,
    annotation_remaining: i64 = 1_000_000_000,
    // In inspect mode, the stdout line being assembled, so diagnostic records can be
    // told from gameplay lines across writes.
    stdout_line: std.ArrayList(u8) = .empty,
    gameplay: std.ArrayList(u8) = .empty,

    // stdout, framed into turns
    framer: Framer = .{},
    framer_attached: bool = true,

    may_run: bool = true, // the sandbox's `frozen` event: host calls proceed only while set

    fd_open: [2]bool = .{ true, true }, // the two preopened directory descriptors, 3 and 4
    fd_pos: [2]u64 = .{ 0, 0 },

    // CPU points, as sandbox.py keeps them
    spent_total: i64 = 0,
    last: i64 = INITIAL_POINTS,
    first: bool = true,
    turn: i64 = 0,
    reported: i64 = 0,
    ended: bool = false,
    budget: ?i64 = null,
    slept_ns: u64 = 0,
    live_points: i64 = 0,
    live_memory: u64 = 0,

    exit_code: ?i32 = null,
    exit_requested: ?i32 = null,
    failure: ?[]const u8 = null,
    unsupported: ?[]const u8 = null,
    message: [256]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, module: *const BotModule, key: []const u8, name: []const u8) !*Instance {
        const self = try allocator.create(Instance);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .module = module,
            .store = undefined,
            .context = undefined,
            .linker = undefined,
            .memory = undefined,
            .instance = undefined,
            .start_fn = undefined,
            .meter = null,
            .exhausted = null,
            .bindings = &.{},
            .rng = Rng.init(key, name),
        };

        self.store = c.wasmtime_store_new(module.engine, null, null) orelse return error.Wasmtime;
        errdefer c.wasmtime_store_delete(self.store);
        self.context = c.wasmtime_store_context(self.store).?;

        var memtype: ?*c.wasm_memorytype_t = null;
        try self.check(c.wasmtime_memorytype_new(module.memory_min, true, @min(module.memory_max, MAX_MEMORY_PAGES), false, true, 16, &memtype));
        defer c.wasm_memorytype_delete(memtype);
        var shared: ?*c.wasmtime_sharedmemory_t = null;
        try self.check(c.wasmtime_sharedmemory_new(module.engine, memtype, &shared));
        self.memory = shared.?;
        errdefer c.wasmtime_sharedmemory_delete(self.memory);

        self.linker = c.wasmtime_linker_new(module.engine) orelse return error.Wasmtime;
        errdefer c.wasmtime_linker_delete(self.linker);
        var memory_extern: c.wasmtime_extern_t = .{ .kind = c.WASMTIME_EXTERN_SHAREDMEMORY, .of = .{ .sharedmemory = self.memory } };
        try self.check(c.wasmtime_linker_define(self.linker, self.context, "env", 3, "memory", 6, &memory_extern));

        self.bindings = try allocator.alloc(Binding, module.functions.len);
        errdefer allocator.free(self.bindings);
        for (module.functions, 0..) |spec, i| {
            self.bindings[i] = .{ .instance = self, .syscall = spec.syscall, .name = spec.name, .has_results = spec.has_results };
            try self.check(c.wasmtime_linker_define_async_func(self.linker, spec.module_name.ptr, spec.module_name.len, spec.name.ptr, spec.name.len, spec.functype, hostCall, &self.bindings[i], null));
        }

        var trap: ?*c.wasm_trap_t = null;
        var err: ?*c.wasmtime_error_t = null;
        const instantiation = c.wasmtime_linker_instantiate_async(self.linker, self.context, module.module, &self.instance, &trap, &err) orelse return error.Wasmtime;
        while (!c.wasmtime_call_future_poll(instantiation)) {}
        c.wasmtime_call_future_delete(instantiation);
        try self.check(err);
        if (trap != null) {
            std.debug.print("bot trapped while instantiating: {s}\n", .{wt.takeTrapMessage(trap, &self.message)});
            return error.Wasmtime;
        }
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(self.context, &self.instance, "_start", 6, &item)) return error.Wasmtime;
        self.start_fn = item.of.func;
        if (c.wasmtime_instance_export_get(self.context, &self.instance, REMAINING_EXPORT, REMAINING_EXPORT.len, &item)) self.meter = item.of.global;
        if (c.wasmtime_instance_export_get(self.context, &self.instance, EXHAUSTED_EXPORT, EXHAUSTED_EXPORT.len, &item)) self.exhausted = item.of.global;
        if (self.meter == null) return error.Unmetered;

        self.future = c.wasmtime_func_call_async(self.context, &self.start_fn, null, 0, null, 0, &self.trap_out, &self.error_out) orelse return error.Wasmtime;
        // Like the toolkit's warm pool: the bot runs its start-up until its first read.
        _ = self.drive();
        return self;
    }

    pub fn destroy(self: *Instance) void {
        if (self.future) |future| c.wasmtime_call_future_delete(future);
        if (self.deferred_trap) |trap| c.wasm_trap_delete(trap);
        self.stdin.deinit(self.allocator);
        self.annotation_output.deinit(self.allocator);
        self.stdout_line.deinit(self.allocator);
        self.gameplay.deinit(self.allocator);
        self.allocator.free(self.bindings);
        c.wasmtime_linker_delete(self.linker);
        c.wasmtime_sharedmemory_delete(self.memory);
        c.wasmtime_store_delete(self.store);
        self.allocator.destroy(self);
    }

    fn check(self: *Instance, err: ?*c.wasmtime_error_t) !void {
        if (err == null) return;
        std.debug.print("bot error: {s}\n", .{wt.takeErrorMessage(err, &self.message)});
        return error.Wasmtime;
    }

    /// Runs the bot until it needs the driver: ENDTURN framed, stdin empty, or exit.
    pub fn drive(self: *Instance) DriveState {
        while (true) {
            if (self.state == .finished) return .exit;
            const future = self.future orelse return .exit;
            if (c.wasmtime_call_future_poll(future)) {
                self.finish();
                return .exit;
            }
            switch (self.state) {
                .frozen => return .data,
                .reading => return .park,
                else => {},
            }
        }
    }

    fn finish(self: *Instance) void {
        if (self.future) |future| c.wasmtime_call_future_delete(future);
        self.future = null;
        if (self.trap_out == null and self.error_out == null) {
            self.exit_code = 0;
        } else if (self.exit_requested) |code| {
            self.exit_code = code;
            self.dropOutcome();
        } else if (self.unsupported) |name| {
            self.failure = std.fmt.bufPrint(&self.message, "sandbox error: {s}", .{name}) catch "sandbox error";
            self.dropOutcome();
        } else if (self.exhaustedFlag()) {
            self.failure = "exceeded CPU limit";
            self.dropOutcome();
        } else {
            var detail: [200]u8 = undefined;
            const text = if (self.trap_out != null) wt.takeTrapMessage(self.trap_out, &detail) else wt.takeErrorMessage(self.error_out, &detail);
            self.trap_out = null;
            self.error_out = null;
            self.failure = std.fmt.bufPrint(&self.message, "sandbox error: {s}", .{text}) catch "sandbox error";
        }
        _ = self.spent();
        self.state = .finished;
    }

    fn dropOutcome(self: *Instance) void {
        if (self.trap_out) |trap| c.wasm_trap_delete(trap);
        if (self.error_out) |err| c.wasmtime_error_delete(err);
        self.trap_out = null;
        self.error_out = null;
    }

    // ---- guest memory -------------------------------------------------------

    fn memoryBytes(self: *Instance) []u8 {
        const size = c.wasmtime_sharedmemory_data_size(self.memory);
        return c.wasmtime_sharedmemory_data(self.memory)[0..size];
    }

    fn guest(self: *Instance, ptr: u32, n: u32) HostError![]u8 {
        const bytes = self.memoryBytes();
        if (@as(u64, ptr) + n > bytes.len) return error.OutOfBounds;
        return bytes[ptr..][0..n];
    }

    fn readU8(self: *Instance, ptr: u32) HostError!u8 {
        return (try self.guest(ptr, 1))[0];
    }

    fn readU16(self: *Instance, ptr: u32) HostError!u16 {
        return std.mem.readInt(u16, (try self.guest(ptr, 2))[0..2], .little);
    }

    fn readU32(self: *Instance, ptr: u32) HostError!u32 {
        return std.mem.readInt(u32, (try self.guest(ptr, 4))[0..4], .little);
    }

    fn readU64(self: *Instance, ptr: u32) HostError!u64 {
        return std.mem.readInt(u64, (try self.guest(ptr, 8))[0..8], .little);
    }

    fn writeU8(self: *Instance, ptr: u32, value: u8) HostError!void {
        (try self.guest(ptr, 1))[0] = value;
    }

    fn writeU32(self: *Instance, ptr: u32, value: u32) HostError!void {
        std.mem.writeInt(u32, (try self.guest(ptr, 4))[0..4], value, .little);
    }

    fn writeU64(self: *Instance, ptr: u32, value: u64) HostError!void {
        std.mem.writeInt(u64, (try self.guest(ptr, 8))[0..8], value, .little);
    }

    fn writeBytes(self: *Instance, ptr: u32, bytes: []const u8) HostError!void {
        @memcpy(try self.guest(ptr, @intCast(bytes.len)), bytes);
    }

    // ---- CPU points ---------------------------------------------------------

    fn meterGet(self: *Instance) i64 {
        var value: c.wasmtime_val_t = undefined;
        c.wasmtime_global_get(self.context, &self.meter.?, &value);
        return value.of.i64;
    }

    fn meterSet(self: *Instance, points: i64) void {
        var value = wt.i64Val(points);
        const err = c.wasmtime_global_set(self.context, &self.meter.?, &value);
        if (err != null) c.wasmtime_error_delete(err);
    }

    fn exhaustedFlag(self: *Instance) bool {
        const global = self.exhausted orelse return false;
        var value: c.wasmtime_val_t = undefined;
        c.wasmtime_global_get(self.context, &global, &value);
        return value.of.i32 != 0;
    }

    fn spent(self: *Instance) i64 {
        if (self.annotation_depth > 0) return self.spent_total;
        if (self.meter != null) {
            const now_points = self.meterGet();
            if (self.first) {
                self.first = false;
            } else {
                self.spent_total += self.last - now_points;
            }
            self.last = now_points;
        }
        return self.spent_total;
    }

    /// ENDTURN is framed: the turn's figures are final and the guest runs on until it
    /// reaches its next syscall.
    fn endTurn(self: *Instance) void {
        self.ended = true;
        self.may_run = false;
    }

    /// Takes the turn's figures, until ENDTURN settles them.
    fn mark(self: *Instance) void {
        if (self.ended) return;
        self.reported = self.spent();
        self.live_points = self.reported - self.turn;
        self.live_memory = c.wasmtime_sharedmemory_data_size(self.memory);
    }

    fn refill(self: *Instance, points: i64) void {
        if (self.meter == null) return;
        // Work done between ENDTURN and this read belongs to the turn starting here.
        const gap = self.spent() - self.reported;
        self.turn = self.reported;
        self.ended = false;
        const left = @max(0, points - gap);
        self.meterSet(left);
        self.last = left;
    }

    fn now(self: *Instance) u64 {
        const points = self.spent();
        return @as(u64, @intCast(@max(points, 0))) + self.slept_ns;
    }

    fn charge(self: *Instance, points: i64) void {
        if (self.meter == null) return;
        const left = self.meterGet();
        self.meterSet(@max(0, left - points));
    }

    /// Charged before the bytes go out, so an unaffordable write never reaches stdout.
    fn chargeWrite(self: *Instance, total: u32) HostError!void {
        if (self.meter == null) return;
        const cost = WRITE_SYSCALL_COST + @as(i64, total) * WRITE_BYTE_COST;
        const left = self.meterGet();
        self.meterSet(left - cost);
        if (!self.first) self.mark();
        if (left < cost) {
            if (self.exhausted) |global| {
                var one = wt.i32Val(1);
                const err = c.wasmtime_global_set(self.context, &global, &one);
                if (err != null) c.wasmtime_error_delete(err);
            }
            self.failure = "exceeded CPU limit";
            self.exit_requested = 137;
            return error.Exit;
        }
    }

    // ---- host calls ---------------------------------------------------------

    fn isExit(syscall: Syscall) bool {
        return switch (syscall) {
            .proc_exit, .proc_exit2, .thread_exit => true,
            else => false,
        };
    }

    /// Whether a call can complete now: exits always, other calls once the turn is
    /// running, and a read of stdin once it holds data or is closed.
    fn ready(self: *Instance, binding: *Binding, args: []const c.wasmtime_val_t) bool {
        if (isExit(binding.syscall)) return true;
        if (!self.may_run) return false;
        if (binding.syscall == .fd_read and argU32(args, 0) == 0 and self.stdin_pos == self.stdin.items.len and !self.stdin_closed) return false;
        return true;
    }

    fn hostCall(env: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize, trap_ret: [*c]?*c.wasm_trap_t, continuation_ret: [*c]c.wasmtime_async_continuation_t) callconv(.c) void {
        _ = caller;
        const binding: *Binding = @ptrCast(@alignCast(env.?));
        const self = binding.instance;
        continuation_ret.* = .{ .callback = completeNow, .env = null, .finalizer = null };
        if (self.deferred_trap) |trap| {
            self.deferred_trap = null;
            trap_ret.* = trap;
            return;
        }
        self.calls += 1;
        if (self.calls > MAX_CALLS_PER_TURN) {
            self.failure = "ran out of time";
            trap_ret.* = wt.trap("ran out of time");
            return;
        }
        if (!self.ready(binding, args[0..nargs])) {
            var pending = PendingCall{ .binding = binding, .args = undefined, .nargs = @min(nargs, 8), .results = results, .nresults = nresults };
            @memcpy(pending.args[0..pending.nargs], args[0..pending.nargs]);
            self.pending = pending;
            self.suspendOn(binding);
            continuation_ret.* = .{ .callback = resumePending, .env = self, .finalizer = null };
            return;
        }
        trap_ret.* = self.perform(binding, args[0..nargs], results, nresults);
    }

    fn suspendOn(self: *Instance, binding: *Binding) void {
        if (!self.may_run) {
            self.state = .frozen;
        } else {
            std.debug.assert(binding.syscall == .fd_read);
            self.state = .reading;
            self.parks += 1;
        }
    }

    fn completeNow(env: ?*anyopaque) callconv(.c) bool {
        _ = env;
        return true;
    }

    fn resumePending(env: ?*anyopaque) callconv(.c) bool {
        const self: *Instance = @ptrCast(@alignCast(env.?));
        const call = &self.pending.?;
        if (!self.ready(call.binding, call.args[0..call.nargs])) {
            if (self.state == .frozen and self.may_run) self.suspendOn(call.binding);
            return false;
        }
        self.state = .running;
        if (self.perform(call.binding, call.args[0..call.nargs], call.results, call.nresults)) |trap| self.deferred_trap = trap;
        self.pending = null;
        return true;
    }

    fn perform(self: *Instance, binding: *Binding, args: []const c.wasmtime_val_t, results: [*c]c.wasmtime_val_t, nresults: usize) ?*c.wasm_trap_t {
        if (!self.first) self.mark();
        const code = self.dispatch(binding, args) catch |err| switch (err) {
            error.Exit => return wt.trap("exit"),
            error.OutOfBounds => return wt.trap("guest pointer outside memory"),
            error.Unsupported => return wt.trap("unsupported syscall"),
            error.OutOfMemory => return wt.trap("host out of memory"),
        };
        if (nresults > 0) results[0] = wt.i32Val(code);
        return null;
    }

    fn argU32(args: []const c.wasmtime_val_t, i: usize) u32 {
        return @bitCast(args[i].of.i32);
    }

    fn dispatch(self: *Instance, binding: *Binding, args: []const c.wasmtime_val_t) HostError!i32 {
        // Observers cannot do gameplay I/O, consume randomness or yield while
        // policy metering is paused. Clock reads return the frozen policy time.
        if (self.annotation_depth > 0) switch (binding.syscall) {
            .inspection_begin, .inspection_end, .inspection_write, .inspection_log, .clock_time_get, .proc_exit, .proc_exit2, .thread_exit => {},
            else => return error.Unsupported,
        };
        switch (binding.syscall) {
            .inspection_begin => {
                if (!self.module.inspection_enabled) return error.Unsupported;
                if (self.annotation_depth == 0) {
                    _ = self.spent();
                    self.annotation_policy_remaining = self.meterGet();
                    self.meterSet(self.annotation_remaining);
                }
                if (self.annotation_depth >= 64) return error.Unsupported;
                self.annotation_depth += 1;
                return errno.OK;
            },
            .inspection_end => {
                if (self.annotation_depth == 0) return error.Unsupported;
                self.annotation_depth -= 1;
                if (self.annotation_depth == 0) {
                    self.annotation_remaining = self.meterGet();
                    self.meterSet(self.annotation_policy_remaining);
                    self.last = self.annotation_policy_remaining;
                }
                return errno.OK;
            },
            .inspection_write, .inspection_log => {
                if (self.annotation_depth == 0) return error.Unsupported;
                const bytes = try self.guest(argU32(args, 0), argU32(args, 1));
                const prefix = if (binding.syscall == .inspection_write) "LOG LOONG_GIZMO " else "LOG ";
                if (bytes.len + self.annotation_output.items.len + prefix.len + 1 > 64 * 1024 * 1024)
                    return error.OutOfMemory;
                if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfAny(u8, bytes, "\r\n") != null)
                    return error.Unsupported;
                try self.annotation_output.appendSlice(self.allocator, prefix);
                try self.annotation_output.appendSlice(self.allocator, bytes);
                try self.annotation_output.append(self.allocator, '\n');
                return errno.OK;
            },
            .args_sizes_get => return self.vectorSizes(&ARGV, argU32(args, 0), argU32(args, 1)),
            .args_get => return self.vectorGet(&ARGV, argU32(args, 0), argU32(args, 1)),
            .environ_sizes_get => return self.vectorSizes(&ENVIRON, argU32(args, 0), argU32(args, 1)),
            .environ_get => return self.vectorGet(&ENVIRON, argU32(args, 0), argU32(args, 1)),
            .clock_time_get => {
                const epoch: u64 = if (argU32(args, 0) == 0) VIRTUAL_EPOCH_NS else 0;
                try self.writeU64(argU32(args, 2), epoch + self.now());
                return errno.OK;
            },
            .clock_res_get => {
                try self.writeU64(argU32(args, 1), 1);
                return errno.OK;
            },
            .random_get => {
                self.rng.fill(try self.guest(argU32(args, 0), argU32(args, 1)));
                return errno.OK;
            },
            .sched_yield, .fd_fdstat_set_flags, .fd_fdflags_set, .chdir, .proc_signals_get => return errno.OK,
            .poll_oneoff => return self.pollOneoff(argU32(args, 0), argU32(args, 1), argU32(args, 2), argU32(args, 3)),
            .fd_prestat_get => {
                if (!self.preopened(argU32(args, 0))) return errno.EBADF;
                const out = try self.guest(argU32(args, 1), 8);
                @memset(out, 0);
                std.mem.writeInt(u32, out[4..8], 1, .little); // the name is "/"
                return errno.OK;
            },
            .fd_prestat_dir_name => {
                if (!self.preopened(argU32(args, 0))) return errno.EBADF;
                if (argU32(args, 2) > 0) try self.writeBytes(argU32(args, 1), "/");
                return errno.OK;
            },
            .fd_fdstat_get => {
                const fd = argU32(args, 0);
                const kind: u8 = if (fd <= 2) FILETYPE_CHARACTER else if (self.preopened(fd)) FILETYPE_DIRECTORY else return errno.EBADF;
                const out = try self.guest(argU32(args, 1), 24);
                @memset(out, 0);
                out[0] = kind;
                std.mem.writeInt(u64, out[8..16], std.math.maxInt(u64), .little);
                std.mem.writeInt(u64, out[16..24], std.math.maxInt(u64), .little);
                return errno.OK;
            },
            .fd_filestat_get => {
                const fd = argU32(args, 0);
                if (fd > 2) return errno.EBADF;
                const out = try self.guest(argU32(args, 1), 64);
                @memset(out, 0);
                std.mem.writeInt(u64, out[0..8], 1, .little);
                std.mem.writeInt(u64, out[8..16], fd, .little);
                out[16] = FILETYPE_CHARACTER;
                std.mem.writeInt(u64, out[24..32], 1, .little);
                return errno.OK;
            },
            .fd_close => {
                const fd = argU32(args, 0);
                if (fd == 3 or fd == 4) self.fd_open[fd - 3] = false;
                return errno.OK;
            },
            .fd_read => {
                const fd = argU32(args, 0);
                if (fd == 0) return self.readStdin(argU32(args, 1), argU32(args, 2), argU32(args, 3));
                return if (self.preopened(fd)) errno.EISDIR else errno.EBADF;
            },
            .fd_write => return self.writeOut(argU32(args, 0), argU32(args, 1), argU32(args, 2), argU32(args, 3)),
            .fd_seek => {
                const fd = argU32(args, 0);
                if (!self.preopened(fd)) return errno.EBADF;
                const offset = args[1].of.i64;
                const base: i64 = switch (argU32(args, 2)) {
                    1 => @intCast(self.fd_pos[fd - 3]),
                    else => 0, // start, or the end of an empty directory
                };
                self.fd_pos[fd - 3] = @intCast(@max(0, base + offset));
                try self.writeU64(argU32(args, 3), self.fd_pos[fd - 3]);
                return errno.OK;
            },
            .fd_tell => {
                const fd = argU32(args, 0);
                if (!self.preopened(fd)) return errno.EBADF;
                try self.writeU64(argU32(args, 1), self.fd_pos[fd - 3]);
                return errno.OK;
            },
            .proc_exit, .proc_exit2, .thread_exit => {
                self.exit_requested = args[0].of.i32;
                return error.Exit;
            },
            .futex_wait => {
                if ((try self.readU32(argU32(args, 0))) != argU32(args, 1)) {
                    try self.writeU8(argU32(args, 3), 1);
                    return errno.OK;
                }
                const timeout_ptr = argU32(args, 2);
                if (timeout_ptr != 0 and (try self.readU8(timeout_ptr)) != 0) {
                    try self.writeU8(argU32(args, 3), 0);
                    return errno.OK;
                }
                self.unsupported = "futex_wait would block forever (the judge runs one thread)";
                return error.Unsupported;
            },
            .futex_wake, .futex_wake_all => {
                try self.writeU8(argU32(args, 1), 0);
                return errno.OK;
            },
            .proc_signals_sizes_get, .fd_fdflags_get => {
                try self.writeU32(argU32(args, if (binding.syscall == .fd_fdflags_get) 1 else 0), 0);
                return errno.OK;
            },
            .thread_id, .thread_parallelism, .proc_id => {
                try self.writeU32(argU32(args, 0), 1);
                return errno.OK;
            },
            .getcwd => {
                const cwd = "/";
                const ptr = argU32(args, 0);
                const len_ptr = argU32(args, 1);
                const maxlen = try self.readU32(len_ptr);
                try self.writeU32(len_ptr, cwd.len);
                if (cwd.len > maxlen) return errno.ERANGE;
                if (ptr == 0 or maxlen == 0) return errno.EINVAL;
                try self.writeBytes(ptr, cwd);
                if (cwd.len < maxlen) try self.writeU8(ptr + @as(u32, cwd.len), 0);
                return errno.OK;
            },
            .tty_get => return errno.ENOTTY,
            .denied => return if (binding.has_results) errno.ENOTSUP else errno.OK,
            .unsupported => {
                self.unsupported = binding.name;
                return error.Unsupported;
            },
        }
    }

    fn preopened(self: *Instance, fd: u32) bool {
        return (fd == 3 or fd == 4) and self.fd_open[fd - 3];
    }

    fn vectorSizes(self: *Instance, items: []const []const u8, count_ptr: u32, bytes_ptr: u32) HostError!i32 {
        var total: u32 = 0;
        for (items) |item| total += @intCast(item.len + 1);
        try self.writeU32(count_ptr, @intCast(items.len));
        try self.writeU32(bytes_ptr, total);
        return errno.OK;
    }

    fn vectorGet(self: *Instance, items: []const []const u8, vec_ptr: u32, buf_ptr: u32) HostError!i32 {
        var buf = buf_ptr;
        for (items, 0..) |item, k| {
            try self.writeU32(vec_ptr + 4 * @as(u32, @intCast(k)), buf);
            try self.writeBytes(buf, item);
            try self.writeU8(buf + @as(u32, @intCast(item.len)), 0);
            buf += @intCast(item.len + 1);
        }
        return errno.OK;
    }

    /// The judge allows clock waits and no descriptors; a wait advances the virtual clock.
    fn pollOneoff(self: *Instance, subs: u32, events: u32, n: u32, out: u32) HostError!i32 {
        if (n == 0) return errno.EINVAL;
        var k: u32 = 0;
        while (k < n) : (k += 1) if ((try self.readU8(subs + 48 * k + 8)) != 0) return errno.E2BIG;
        var wait: ?u64 = null;
        k = 0;
        while (k < n) : (k += 1) {
            const base = subs + 48 * k;
            const userdata = try self.readU64(base);
            const timeout = try self.readU64(base + 24);
            const flags = try self.readU16(base + 40);
            const nanos: u64 = if (flags & 1 != 0) timeout -| self.now() else timeout;
            wait = if (wait) |w| @min(w, nanos) else nanos;
            const event = try self.guest(events + 32 * k, 32);
            @memset(event, 0);
            std.mem.writeInt(u64, event[0..8], userdata, .little);
        }
        if (wait) |w| self.slept_ns += w;
        try self.writeU32(out, n);
        return errno.OK;
    }

    /// Reads stdin, which `ready` has already found non-empty or closed; the turn's
    /// budget is applied at the first read after the driver's write, as the judge does.
    fn readStdin(self: *Instance, iovs: u32, n: u32, out: u32) HostError!i32 {
        var total: u32 = 0;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const ptr = try self.readU32(iovs + 8 * k);
            const length = try self.readU32(iovs + 8 * k + 4);
            const available = self.stdin.items.len - self.stdin_pos;
            const count: usize = @min(length, available);
            const chunk = self.stdin.items[self.stdin_pos..][0..count];
            if (self.budget) |points| {
                self.refill(points);
                self.budget = null;
            }
            if (count > 0) @memcpy(try self.guest(ptr, @intCast(count)), chunk);
            self.stdin_pos += count;
            if (self.stdin_pos == self.stdin.items.len) {
                self.stdin.clearRetainingCapacity();
                self.stdin_pos = 0;
            }
            total += @intCast(count);
            if (count < length) break;
        }
        if (self.has_read or charge_first_read) self.charge(@as(i64, total) * READ_BYTE_COST);
        self.has_read = true;
        try self.writeU32(out, total);
        return errno.OK;
    }

    fn writeOut(self: *Instance, fd: u32, iovs: u32, n: u32, out: u32) HostError!i32 {
        var total: u32 = 0;
        var k: u32 = 0;
        while (k < n) : (k += 1) total += try self.readU32(iovs + 8 * k + 4);
        if (fd != 2 and self.framer_attached and self.module.inspection_enabled) {
            try self.writeInspected(iovs, n);
            try self.writeU32(out, total);
            return errno.OK;
        }
        try self.chargeWrite(total);
        k = 0;
        while (k < n) : (k += 1) {
            const ptr = try self.readU32(iovs + 8 * k);
            const length = try self.readU32(iovs + 8 * k + 4);
            const bytes = try self.guest(ptr, length);
            // stderr is dropped; anything else is the turn's reply
            if (fd != 2 and self.framer_attached) {
                if (self.framer.feed(bytes)) self.endTurn();
            }
        }
        try self.writeU32(out, total);
        return errno.OK;
    }

    /// Inspect mode's stdout: diagnostic record lines become annotations, uncharged
    /// and outside the framer; the other lines reach the framer and are charged as
    /// the judge charges them, so a turn's gameplay output costs what it did in play.
    fn writeInspected(self: *Instance, iovs: u32, n: u32) HostError!void {
        self.gameplay.clearRetainingCapacity();
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const ptr = try self.readU32(iovs + 8 * k);
            const length = try self.readU32(iovs + 8 * k + 4);
            for (try self.guest(ptr, length)) |byte| {
                self.stdout_line.append(self.allocator, byte) catch return error.OutOfMemory;
                if (byte != '\n') continue;
                const line = self.stdout_line.items;
                if (std.mem.startsWith(u8, line, GIZMO_PREFIX)) {
                    if (line.len + self.annotation_output.items.len > 64 * 1024 * 1024) return error.OutOfMemory;
                    self.annotation_output.appendSlice(self.allocator, line) catch return error.OutOfMemory;
                } else {
                    self.gameplay.appendSlice(self.allocator, line) catch return error.OutOfMemory;
                }
                self.stdout_line.clearRetainingCapacity();
            }
        }
        if (self.gameplay.items.len == 0) return;
        try self.chargeWrite(@intCast(self.gameplay.items.len));
        if (self.framer.feed(self.gameplay.items)) self.endTurn();
    }

    // ---- driver side --------------------------------------------------------

    pub fn arm(self: *Instance) void {
        self.framer.arm();
        self.annotation_output.clearRetainingCapacity();
        self.annotation_remaining = 1_000_000_000;
        self.stdout_line.clearRetainingCapacity();
    }

    /// Feeds a turn; false when the bot has already exited.
    pub fn write(self: *Instance, data: []const u8) !bool {
        if (self.state == .finished) return false;
        self.budget = if (self.module.inspection_enabled) INSPECTION_TURN_POINTS else MAX_TURN_POINTS;
        self.parks_snapshot = self.parks;
        self.calls = 0;
        try self.stdin.appendSlice(self.allocator, data);
        self.may_run = true;
        return true;
    }

    pub fn turnState(self: *Instance) TurnState {
        return .{
            .done = self.framer.done,
            .park_at = self.framer.park_at,
            .has_output = self.framer.out_len > 0 or self.framer.line_len > 0,
        };
    }

    pub fn take(self: *Instance, dest: []u8) []const u8 {
        return self.framer.take(dest);
    }

    /// The turn's CPU points as last marked, and the memory size.
    pub fn live(self: *Instance) struct { points: i64, memory: u64 } {
        return .{ .points = self.live_points, .memory = self.live_memory };
    }

    pub fn parkedSince(self: *Instance) bool {
        return self.parks > self.parks_snapshot;
    }

    pub fn reason(self: *Instance, buf: []u8) []const u8 {
        if (self.failure) |text| return text;
        return std.fmt.bufPrint(buf, "exited with code {d}", .{self.exit_code orelse 0}) catch "exited";
    }
};

/// A dragon as the engine sees it: turns are asked of whichever instance is running,
/// and a worker that dies is replaced (turn.py's TurnBot and sandbox.py's SandboxBot).
pub const Dragon = struct {
    allocator: std.mem.Allocator,
    module: *const BotModule,
    key: []const u8,
    team: u8, // 0 for A, 1 for B
    name: [12]u8,
    name_len: usize,
    init: []u8,
    instance: ?*Instance = null,
    written: usize = 0,
    is_new: bool = true,
    error_reason: ?[]const u8 = null,
    /// The last turn's CPU points as the toolkit's match wrapper records them: the
    /// sandbox's figures when the turn ended, and none for a turn killed at the wall.
    points: i64 = 0,
    skipped_points: ?i64 = null,
    payload: std.ArrayList(u8) = .empty,
    reply_buf: [3 * framer_mod.BUFFER_LIMIT + 8]u8 = undefined,
    reason_buf: [64]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, module: *const BotModule, key: []const u8, team: u8, dragon_id: u32, init: []const u8) !*Dragon {
        const self = try allocator.create(Dragon);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .module = module,
            .key = key,
            .team = team,
            .name = undefined,
            .name_len = 0,
            .init = try allocator.dupe(u8, init),
        };
        self.name_len = (std.fmt.bufPrint(&self.name, "{d}", .{dragon_id}) catch unreachable).len;
        return self;
    }

    pub fn destroy(self: *Dragon) void {
        self.stop();
        self.payload.deinit(self.allocator);
        self.allocator.free(self.init);
        self.allocator.destroy(self);
    }

    fn dragonName(self: *const Dragon) []const u8 {
        return self.name[0..self.name_len];
    }

    /// One turn: the reply, or an empty reply with `error_reason` set.
    pub fn ask(self: *Dragon, block: []const u8) []const u8 {
        self.skipped_points = null;
        const out = self.answer(block);
        self.points = self.skipped_points orelse if (self.instance) |inst| inst.live().points else 0;
        return out;
    }

    fn answer(self: *Dragon, block: []const u8) []const u8 {
        self.error_reason = null;
        if (self.instance == null) self.fresh();
        var attempt: u32 = 0;
        while (attempt < 2) : (attempt += 1) {
            const inst = self.instance orelse return self.skip("the sandbox failed to start");
            inst.arm();
            self.payload.clearRetainingCapacity();
            if (self.is_new) self.payload.appendSlice(self.allocator, self.init) catch return self.skip("host out of memory");
            self.payload.appendSlice(self.allocator, block) catch return self.skip("host out of memory");
            if (!std.mem.endsWith(u8, self.payload.items, "\n\n")) self.payload.append(self.allocator, '\n') catch return self.skip("host out of memory");
            const data = self.payload.items;
            const wrote = inst.write(data) catch false;
            if (!wrote) {
                if (attempt == 0) {
                    self.fresh();
                    continue;
                }
                return self.skip(self.reason());
            }
            self.written += data.len;
            self.is_new = false;
            const state = inst.drive();
            const turn = inst.turnState();
            const parked_here = if (turn.park_at) |at| at == @as(i64, @intCast(self.written)) else false;
            if (turn.done or parked_here or state == .park or inst.parkedSince()) return inst.take(&self.reply_buf);
            // the bot exited
            const why = self.reason();
            if (attempt == 1 or turn.has_output) return self.skip(why);
            self.fresh();
        }
        return "";
    }

    fn reason(self: *Dragon) []const u8 {
        const inst = self.instance orelse return "exited";
        return inst.reason(&self.reason_buf);
    }

    fn skip(self: *Dragon, why: []const u8) []const u8 {
        // The toolkit kills a bot at its wall limit before skipping it, taking its figures.
        const killed = std.mem.eql(u8, why, "ran out of time");
        self.skipped_points = if (killed) 0 else if (self.instance) |inst| inst.live().points else 0;
        self.error_reason = why;
        self.stop();
        return "";
    }

    fn fresh(self: *Dragon) void {
        self.stop();
        self.instance = Instance.create(self.allocator, self.module, self.key, self.dragonName()) catch null;
        self.written = 0;
        self.is_new = true;
    }

    pub fn stop(self: *Dragon) void {
        const inst = self.instance orelse return;
        self.instance = null;
        inst.destroy();
    }
};
