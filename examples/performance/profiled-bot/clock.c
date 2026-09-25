#define _POSIX_C_SOURCE 199309L  /* for clock_gettime */
#include <stdint.h>
#include <time.h>

/* In the judge the clock advances one nanosecond per CPU point, so this reads points spent. */
uint64_t ClockNanoseconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec;
}
