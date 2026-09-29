#ifndef LOONG_GIZMOS_H
#define LOONG_GIZMOS_H

/* Public wire contract: replays/viewer/diagnostics.md. Diagnostics are
 * compiled into every build and run only when our inspection harness starts
 * the bot with a LOONG_INSPECT line before its init block, which the official
 * engine never sends (unswbc_init). Records go to stdout as
 * `LOG LOONG_GIZMO <json>` lines. Expressions passed here must be
 * observational; with diagnostics off they are not even evaluated. Emit before
 * ENDTURN; never flush individual records. */
#include <stdint.h>
#include <stdio.h>

/* Set by unswbc_init from the LOONG_INSPECT marker. */
extern int loong_diagnostics_enabled;

#define LOONG_GIZMO_JSON(json_expression)                                      \
  do {                                                                         \
    if (loong_diagnostics_enabled)                                             \
      printf("LOG LOONG_GIZMO %s\n", (json_expression));                       \
  } while (0)
#define LOONG_DIAGNOSTIC_BLOCK(...)                                            \
  do {                                                                         \
    if (loong_diagnostics_enabled) {                                           \
      __VA_ARGS__                                                              \
    }                                                                          \
  } while (0)

/* Nim builds (points.c): the judge clock in points, and the points diagnostic
 * blocks have spent, which loong_current_points leaves out so a bot budgets
 * the same with diagnostics on as off. */
uint64_t loong_raw_points(void);
extern uint64_t loong_diagnostic_points;

#endif
