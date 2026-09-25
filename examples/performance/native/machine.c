/* The machine bot's experiments on real hardware: the fastest of 20 runs of each, in nanoseconds.
 *
 *     clang -O2 -I machine-bot native/machine.c machine-bot/experiments.c -o native/machine
 */
#define _POSIX_C_SOURCE 199309L
#include "experiments.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint64_t ClockNanoseconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec;
}

int main(void)
{
    uint32_t* words = malloc(EXPERIMENT_WORDS * sizeof *words);
    FillWords(words);
    for (int index = 0; index < EXPERIMENT_COUNT; index++)
    {
        uint64_t best = UINT64_MAX;
        uint32_t result = 0;
        for (int run = 0; run < 20; run++)
        {
            uint64_t const started = ClockNanoseconds();
            result = EXPERIMENTS[index].run(words);
            uint64_t const took = ClockNanoseconds() - started;
            best = took < best ? took : best;
        }
        printf("%-12s %10llu ns  result=%u\n", EXPERIMENTS[index].name, (unsigned long long)best, result);
    }
    return 0;
}
