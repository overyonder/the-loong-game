/* Room counting for the first bot, written several ways. Each kernel fills rooms[side] with the
 * most tiles any second move leaves after first moving to that side, or -1 if that first move
 * isn't possible. The window is the 7×7 view, tile index row * 7 + column, head at 24. */
#ifndef KERNELS_H
#define KERNELS_H

#include <stdbool.h>
#include <stdint.h>

#define WINDOW_TILES 49
#define HEAD_TILE    24

typedef struct
{
    bool    occupied[WINDOW_TILES];    /* any dragon segment, ours included */
    bool    open[WINDOW_TILES][4];     /* no kelp and no portal on that side: north, east, south, west */
    uint8_t padding[64];               /* lets the SIMD kernel read whole 16-byte vectors past the end */
} KernelWindow;

uint64_t ClockNanoseconds(void);

void RoomsQueue(KernelWindow const* window, int rooms[4]);
void RoomsBitboard(KernelWindow const* window, int rooms[4]);
void RoomsComponents(KernelWindow const* window, int rooms[4]);
void RoomsSimd(KernelWindow const* window, int rooms[4]);
void RoomsInlineAsm(KernelWindow const* window, int rooms[4]);
void RoomsSimdMasks(KernelWindow const* window, int rooms[4]);
uint64_t MasksOnly(KernelWindow const* window);
uint64_t MasksOnlySimd(KernelWindow const* window);

#endif
