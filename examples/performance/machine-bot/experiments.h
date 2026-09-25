/* Loops that do the same work in different orders or shapes, to compare what the judge charges
 * for them with what they cost on real hardware. The bot and native/machine.c both run them. */
#ifndef EXPERIMENTS_H
#define EXPERIMENTS_H

#include <stdint.h>

#define EXPERIMENT_WORDS (2u << 20)   /* 8 MB of 32-bit words: more than a desktop CPU's L2 cache */

typedef struct
{
    char const* name;
    uint32_t (*run)(uint32_t const* words);
} Experiment;

extern Experiment const EXPERIMENTS[];
extern int const        EXPERIMENT_COUNT;

void FillWords(uint32_t* words);

#endif
