/* Runs one experiment per turn and logs the CPU points it took. In the judge the clock advances
 * one nanosecond per point, so clock_gettime reads points. */
#define _POSIX_C_SOURCE 199309L
#include "experiments.h"
#include "helper.h"

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
    UnswbcController* ct = NULL;
    UnswbcGame* game = NULL;
    unswbc_init(&ct, &game);
    uint32_t* words = malloc(EXPERIMENT_WORDS * sizeof *words);
    FillWords(words);

    int turn = 0;
    while (unswbc_update(ct, game))
    {
        if (turn < EXPERIMENT_COUNT)
        {
            Experiment const* experiment = &EXPERIMENTS[turn];
            uint64_t const started = ClockNanoseconds();
            uint32_t const result = experiment->run(words);
            uint64_t const points = ClockNanoseconds() - started;
            char note[96];
            snprintf(note, sizeof note, "machine %s points=%llu result=%u", experiment->name,
                     (unsigned long long)points, result);
            unswbc_log(note);
        }
        turn++;
        unswbc_move(unswbc_facing(ct));
        unswbc_end_turn();
    }
    return 0;
}
