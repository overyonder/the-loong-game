//! The wasmtime C API and the few helpers the judge needs around it.

pub const c = @cImport({
    @cInclude("wasmtime.h");
});

pub const ValKind = enum { i32, i64, f32, f64 };

pub const Error = error{Wasmtime};

fn newValtype(kind: ValKind) ?*c.wasm_valtype_t {
    return c.wasm_valtype_new(switch (kind) {
        .i32 => c.WASM_I32,
        .i64 => c.WASM_I64,
        .f32 => c.WASM_F32,
        .f64 => c.WASM_F64,
    });
}

/// A function type built from value kinds; wasmtime takes ownership of the vectors.
pub fn functype(params: []const ValKind, results: []const ValKind) *c.wasm_functype_t {
    var param_types: [8]?*c.wasm_valtype_t = undefined;
    var result_types: [8]?*c.wasm_valtype_t = undefined;
    for (params, 0..) |kind, i| param_types[i] = newValtype(kind);
    for (results, 0..) |kind, i| result_types[i] = newValtype(kind);
    var param_vec: c.wasm_valtype_vec_t = undefined;
    var result_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&param_vec, params.len, @ptrCast(&param_types));
    c.wasm_valtype_vec_new(&result_vec, results.len, @ptrCast(&result_types));
    return c.wasm_functype_new(&param_vec, &result_vec).?;
}

pub fn i32Val(value: i32) c.wasmtime_val_t {
    return .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = value } };
}

pub fn i64Val(value: i64) c.wasmtime_val_t {
    return .{ .kind = c.WASMTIME_I64, .of = .{ .i64 = value } };
}

pub fn trap(message: []const u8) ?*c.wasm_trap_t {
    return c.wasmtime_trap_new(message.ptr, message.len);
}

/// Copies a wasmtime error's message into `buf` and frees the error.
pub fn takeErrorMessage(err: ?*c.wasmtime_error_t, buf: []u8) []const u8 {
    var name: c.wasm_name_t = undefined;
    c.wasmtime_error_message(err, &name);
    defer c.wasm_byte_vec_delete(&name);
    defer c.wasmtime_error_delete(err);
    const n = @min(name.size, buf.len);
    @memcpy(buf[0..n], name.data[0..n]);
    return buf[0..n];
}

/// Copies a trap's message into `buf` and frees the trap.
pub fn takeTrapMessage(t: ?*c.wasm_trap_t, buf: []u8) []const u8 {
    var name: c.wasm_name_t = undefined;
    c.wasm_trap_message(t, &name);
    defer c.wasm_byte_vec_delete(&name);
    defer c.wasm_trap_delete(t);
    const n = @min(name.size, buf.len);
    @memcpy(buf[0..n], name.data[0..n]);
    return buf[0..n];
}

/// An engine configured the way the toolkit's sandbox configures wasmtime.
pub fn newEngine(async_support: bool) Error!*c.wasm_engine_t {
    const config = c.wasm_config_new();
    if (config == null) return error.Wasmtime;
    c.wasmtime_config_wasm_threads_set(config, true);
    c.wasmtime_config_shared_memory_set(config, true);
    c.wasmtime_config_wasm_bulk_memory_set(config, true);
    c.wasmtime_config_wasm_simd_set(config, true);
    c.wasmtime_config_wasm_multi_value_set(config, true);
    c.wasmtime_config_wasm_reference_types_set(config, true);
    c.wasmtime_config_wasm_multi_memory_set(config, true);
    if (@hasDecl(c, "wasmtime_config_wasm_tail_call_set")) c.wasmtime_config_wasm_tail_call_set(config, true);
    if (@hasDecl(c, "wasmtime_config_wasm_wide_arithmetic_set")) c.wasmtime_config_wasm_wide_arithmetic_set(config, true);
    if (@hasDecl(c, "wasmtime_config_wasm_exceptions_set")) c.wasmtime_config_wasm_exceptions_set(config, true);
    // Bot memories are capped at 768 pages, so reserve no more address space than that.
    if (@hasDecl(c, "wasmtime_config_memory_reservation_set")) c.wasmtime_config_memory_reservation_set(config, 768 * 65536);
    _ = async_support; // async calls need no flag in this wasmtime; the parameter documents intent
    const engine = c.wasm_engine_new_with_config(config);
    return engine orelse error.Wasmtime;
}

pub fn compileModule(engine: *c.wasm_engine_t, bytes: []const u8) Error!*c.wasmtime_module_t {
    var module: ?*c.wasmtime_module_t = null;
    const err = c.wasmtime_module_new(engine, bytes.ptr, bytes.len, &module);
    if (err != null) {
        var buf: [512]u8 = undefined;
        const message = takeErrorMessage(err, &buf);
        @import("std").debug.print("compile failed: {s}\n", .{message});
        return error.Wasmtime;
    }
    return module orelse error.Wasmtime;
}
