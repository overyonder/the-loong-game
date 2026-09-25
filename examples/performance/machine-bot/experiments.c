#include "experiments.h"

#if defined(__wasm_simd128__)
#include <wasm_simd128.h>
#endif

/* Every loop reads each word once. The pragmas keep Clang from vectorising the scalar ones. */

void FillWords(uint32_t* words)
{
    uint32_t state = 0x9E3779B9u;
    for (uint32_t i = 0; i < EXPERIMENT_WORDS; i++)
    {
        state ^= state << 13, state ^= state >> 17, state ^= state << 5;
        words[i] = state;
    }
}

/* Both loops below read the words in 1,024 runs of 2,048, so they run the same instructions. */
#define RUNS 1024u
#define RUN_LENGTH (EXPERIMENT_WORDS / RUNS)

/* In address order: each 64-byte cache line serves sixteen reads in a row. */
static uint32_t InOrder(uint32_t const* words)
{
    uint32_t sum = 0;
    for (uint32_t run = 0; run < RUNS; run++)
    {
        uint32_t const* start = words + run * RUN_LENGTH;
#pragma clang loop vectorize(disable) interleave(disable) unroll(disable)
        for (uint32_t i = 0; i < RUN_LENGTH; i++)
        {
            sum += start[i];
        }
    }
    return sum;
}

/* The same reads, 4 KB apart: every read lands on a different cache line and page. */
static uint32_t Strided(uint32_t const* words)
{
    uint32_t sum = 0;
    for (uint32_t run = 0; run < RUNS; run++)
    {
        uint32_t const* start = words + run;
#pragma clang loop vectorize(disable) interleave(disable) unroll(disable)
        for (uint32_t i = 0; i < RUN_LENGTH; i++)
        {
            sum += start[i * RUNS];
        }
    }
    return sum;
}

/* An empty asm statement that claims to change a value, so Clang can't combine the four totals
 * below into one vector add. It emits no instructions. On x86 the value stays in an SSE register. */
#if defined(__wasm__)
#define KEEP_SCALAR(value) __asm__("" : "+r"(value))
#else
#define KEEP_SCALAR(value) __asm__("" : "+x"(value))
#endif

/* One running total in floating point: each add waits for the one before it. */
static uint32_t OneChain(uint32_t const* words)
{
    float sum = 0;
#pragma clang loop vectorize(disable) interleave(disable) unroll(disable)
    for (uint32_t i = 0; i < EXPERIMENT_WORDS; i += 4)
    {
        sum += (float)(words[i] & 0xFFu);
        KEEP_SCALAR(sum);
        sum += (float)(words[i + 1] & 0xFFu);
        KEEP_SCALAR(sum);
        sum += (float)(words[i + 2] & 0xFFu);
        KEEP_SCALAR(sum);
        sum += (float)(words[i + 3] & 0xFFu);
        KEEP_SCALAR(sum);
    }
    return (uint32_t)sum;
}

/* Four running totals: four adds that don't depend on each other can overlap. */
static uint32_t FourChains(uint32_t const* words)
{
    float a = 0, b = 0, c = 0, d = 0;
#pragma clang loop vectorize(disable) interleave(disable) unroll(disable)
    for (uint32_t i = 0; i < EXPERIMENT_WORDS; i += 4)
    {
        a += (float)(words[i] & 0xFFu);
        KEEP_SCALAR(a);
        b += (float)(words[i + 1] & 0xFFu);
        KEEP_SCALAR(b);
        c += (float)(words[i + 2] & 0xFFu);
        KEEP_SCALAR(c);
        d += (float)(words[i + 3] & 0xFFu);
        KEEP_SCALAR(d);
    }
    return (uint32_t)(a + b + c + d);
}

#if defined(__wasm_simd128__)
/* Four words per instruction in one v128 register. */
static uint32_t Vector(uint32_t const* words)
{
    v128_t sum = wasm_i32x4_splat(0);
    for (uint32_t i = 0; i < EXPERIMENT_WORDS; i += 4)
    {
        sum = wasm_i32x4_add(sum, wasm_v128_load(words + i));
    }
    return wasm_i32x4_extract_lane(sum, 0) + wasm_i32x4_extract_lane(sum, 1) +
           wasm_i32x4_extract_lane(sum, 2) + wasm_i32x4_extract_lane(sum, 3);
}
#else
typedef uint32_t Lanes __attribute__((vector_size(16)));
static uint32_t Vector(uint32_t const* words)
{
    Lanes sum = { 0, 0, 0, 0 };
    for (uint32_t i = 0; i < EXPERIMENT_WORDS; i += 4)
    {
        Lanes lanes;
        __builtin_memcpy(&lanes, words + i, sizeof lanes);
        sum += lanes;
    }
    return sum[0] + sum[1] + sum[2] + sum[3];
}
#endif

Experiment const EXPERIMENTS[] = {
    { "in-order", InOrder },
    { "strided", Strided },
    { "one-chain", OneChain },
    { "four-chains", FourChains },
    { "vector", Vector },
};
int const EXPERIMENT_COUNT = sizeof EXPERIMENTS / sizeof EXPERIMENTS[0];
