/* Inspection-only imports. Blocks must not change policy state. The host
 * pauses policy metering, freezes its clock, and refuses gameplay I/O and
 * randomness until end. Records are separate from action output.
 * Modules using these imports are for loong-judge --inspect, not official play. */
#pragma once
#include <stddef.h>
#include <stdint.h>
__attribute__((import_module("loong_inspection"), import_name("begin")))
int32_t loong_inspection_begin(void);
__attribute__((import_module("loong_inspection"), import_name("end")))
int32_t loong_inspection_end(void);
__attribute__((import_module("loong_inspection"), import_name("write")))
int32_t loong_inspection_write(char const* json, size_t length);
__attribute__((import_module("loong_inspection"), import_name("log")))
int32_t loong_inspection_log(char const* text, size_t length);
