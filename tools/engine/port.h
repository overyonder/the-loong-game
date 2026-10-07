// Twelve-int CPU reference interface used by the generic lockstep runner.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct LoongPort;
struct LoongPort* loong_port_create(char const* map, size_t length, uint64_t seed, char* error, size_t capacity);
int32_t loong_port_next(struct LoongPort* port, char* block, size_t capacity, size_t* length);
void loong_port_apply(struct LoongPort* port, char const* reply, size_t length);
// Last zero-based round, winner (0 draw, 1 A, 2 B), end reason,
// A count/longest/total, B count/longest/total, overflow, A queen, B queen.
// This order belongs to lockstep; native.h owns the distinct match ABI 1.
void loong_port_result(struct LoongPort const* port, int32_t out[12]);
void loong_port_destroy(struct LoongPort* port);
#ifdef __cplusplus
}
#endif
