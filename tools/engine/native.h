#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

    // ABI 1: callbacks and returned buffers are borrowed for the duration of the
    // call. No C++ allocation, exception or domain object crosses this boundary.
    typedef struct LoongNativeCallbacks
    {
        void *context;
        char const *(*reply)(void *, uint32_t, char const *, size_t, size_t *);
        void (*spawn)(void *, uint32_t, char const *, size_t);
        void (*death)(void *, uint32_t, int32_t, uint8_t);
    } LoongNativeCallbacks;

    typedef struct LoongNativeMatch LoongNativeMatch;
    uint32_t loong_native_abi(void);
    LoongNativeMatch *loong_native_create(LoongNativeCallbacks callbacks);
    // Result uses the existing engine.Match's twelve i32 fields, in the same order.
    int32_t loong_native_run(LoongNativeMatch *, char const *map, size_t, int32_t debug, uint64_t seed,
                             int32_t result[12]);
    int32_t loong_native_replay(LoongNativeMatch *, char const *a, size_t, char const *b, size_t, uint8_t const **bytes,
                                size_t *length);
    char const *loong_native_error(LoongNativeMatch const *);
    void loong_native_destroy(LoongNativeMatch *);

    // Additive CUDA batch boundary. Simulation and event capture run on the
    // selected device; callbacks still execute the registered WASMs on host CPUs.
    typedef struct LoongNativeSetup
    {
        LoongNativeCallbacks callbacks;
        char const *map;
        size_t mapLength;
        int32_t debug;
        uint64_t seed;
    } LoongNativeSetup;

    typedef struct LoongNativeDecision
    {
        uint32_t game;
        int32_t round;
        uint32_t dragonId;
        uint32_t team;
        char const *block;
        size_t blockLength;
    } LoongNativeDecision;

    typedef struct LoongNativeCudaBatch LoongNativeCudaBatch;
    // Creation starts canonical initial lifecycle/events. next is idempotent
    // while waiting; decision/block storage lasts until apply. Supply exactly
    // one complete <=10 KiB reply for each returned decision, in that order.
    // run executes the same wave contract using persistent host callback workers.
    // Failure is sticky; result/replay require every game to be terminal.
    LoongNativeCudaBatch *loong_native_cuda_create(LoongNativeSetup const *, size_t games, char *error,
                                                   size_t capacity);
    int32_t loong_native_cuda_next(LoongNativeCudaBatch *, LoongNativeDecision const **, size_t *count);
    int32_t loong_native_cuda_apply(LoongNativeCudaBatch *, char const *const *replies, size_t const *lengths,
                                    size_t count);
    int32_t loong_native_cuda_run(LoongNativeCudaBatch *, uint32_t hostThreads);
    int32_t loong_native_cuda_result(LoongNativeCudaBatch *, uint32_t game, int32_t result[12]);
    int32_t loong_native_cuda_replay(LoongNativeCudaBatch *, uint32_t game, char const *a, size_t, char const *b,
                                     size_t, uint8_t const **bytes, size_t *length);
    char const *loong_native_cuda_error(LoongNativeCudaBatch const *);
    void loong_native_cuda_destroy(LoongNativeCudaBatch *);

#ifdef __cplusplus
}
#endif
