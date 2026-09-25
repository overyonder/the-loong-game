/* Run one room-counting kernel natively over windows recorded from real games, for perf.
 *
 *     cc -O2 -g -fno-omit-frame-pointer -I ../bench-bot bench.c ../bench-bot/kernels.c -o bench
 *     perf stat ./bench queue windows.bin
 *
 * Every result is checked against the queue flood fill before timing starts. */
#define _POSIX_C_SOURCE 199309L
#include "kernels.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RECORDED_BYTES 245   /* occupied[49] then open[49][4], as the benchmark bot logs them */
#define REPEATS        2000

typedef void (*Kernel)(KernelWindow const*, int[4]);

static struct
{
    char const* name;
    Kernel      kernel;
} const KERNELS[] = {
    { "queue", RoomsQueue },
    { "bitboard", RoomsBitboard },
    { "components", RoomsComponents },
};

int main(int argc, char** argv)
{
    if (argc != 3)
    {
        fprintf(stderr, "usage: bench queue|bitboard|components windows.bin\n");
        return 1;
    }
    Kernel kernel = NULL;
    for (size_t index = 0; index < sizeof KERNELS / sizeof KERNELS[0]; index++)
    {
        kernel = strcmp(argv[1], KERNELS[index].name) == 0 ? KERNELS[index].kernel : kernel;
    }
    FILE* file = fopen(argv[2], "rb");
    if (!kernel || !file)
    {
        fprintf(stderr, "unknown kernel or unreadable file\n");
        return 1;
    }
    static KernelWindow windows[4096];
    int                 count = 0;
    while (count < 4096 && fread(&windows[count], RECORDED_BYTES, 1, file) == 1)
    {
        count++;
    }
    fclose(file);

    for (int index = 0; index < count; index++)
    {
        int expected[4], rooms[4];
        RoomsQueue(&windows[index], expected);
        kernel(&windows[index], rooms);
        if (memcmp(expected, rooms, sizeof rooms) != 0)
        {
            fprintf(stderr, "window %d: %s disagrees with queue\n", index, argv[1]);
            return 1;
        }
    }

    struct timespec started, finished;
    int             sink = 0;
    clock_gettime(CLOCK_MONOTONIC, &started);
    for (int repeat = 0; repeat < REPEATS; repeat++)
    {
        for (int index = 0; index < count; index++)
        {
            int rooms[4];
            kernel(&windows[index], rooms);
            sink += rooms[0] + rooms[1] + rooms[2] + rooms[3];
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &finished);
    double const seconds = (double)(finished.tv_sec - started.tv_sec) + (double)(finished.tv_nsec - started.tv_nsec) * 1e-9;
    printf("%-11s %d windows: %.1f ns per window (checksum %d)\n", argv[1], count, seconds * 1e9 / ((double)count * REPEATS), sink);
    return 0;
}
