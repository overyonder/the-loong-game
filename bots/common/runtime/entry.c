/* Platform boundary only: Nim startup and the judge's metered clock. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <time.h>
void NimMain(void);

/* Points spent inside diagnostic blocks (gizmos.nim), kept out of the clock the
 * bot reads, so it budgets the same with diagnostics on as off. */
uint64_t loong_diagnostic_points = 0;

/* The judge's clock in points; a failed read returns UINT64_MAX. */
uint64_t loong_raw_points(void) {
  struct timespec value;
#ifdef __wasm__
  const clockid_t clock_id = CLOCK_MONOTONIC;
#else
  const clockid_t clock_id = CLOCK_PROCESS_CPUTIME_ID;
#endif
  if (clock_gettime(clock_id, &value) != 0)
    return UINT64_MAX;
  return (uint64_t)value.tv_sec * UINT64_C(1000000000) +
         (uint64_t)value.tv_nsec;
}

uint64_t loong_current_points(void) {
  uint64_t raw = loong_raw_points();
  return raw == UINT64_MAX ? raw : raw - loong_diagnostic_points;
}
int main(void) {
  NimMain();
  return 0;
}
