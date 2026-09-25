#define _POSIX_C_SOURCE 199309L  /* for clock_gettime */

#include "kernels.h"

#if !defined(KERNELS_WITHOUT_CLOCK)
#include <time.h>
#endif
#if defined(__wasm_simd128__)
#include <wasm_simd128.h>
#endif

#if !defined(KERNELS_WITHOUT_CLOCK)
/* In the judge the clock advances one nanosecond per CPU point, so this reads points spent. */
uint64_t ClockNanoseconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec;
}
#endif

static int const STEP_ROW[4] = { -1, 0, 1, 0 };
static int const STEP_COL[4] = { 0, 1, 0, -1 };

/* The tile across one side, or -1 if it's outside the window. */
static int NeighbourTile(int tile, int side)
{
    int const row    = tile / 7 + STEP_ROW[side];
    int const column = tile % 7 + STEP_COL[side];
    return row < 0 || row > 6 || column < 0 || column > 6 ? -1 : row * 7 + column;
}

/* The tile a move lands on, or -1 if kelp, a portal, the window's edge or a body is in the way. */
static int StepTile(KernelWindow const* window, int tile, int side)
{
    int const next = NeighbourTile(tile, side);
    return next >= 0 && window->open[tile][side] && !window->occupied[next] ? next : -1;
}

/* ---- Good C: the flood fill from "The choice", on fixed arrays ------------------------------- */

static int CountReachableTiles(KernelWindow const* window, int start, int first_step)
{
    bool visited[WINDOW_TILES] = { false };
    int  queue[WINDOW_TILES];
    int  queue_length = 0;
    visited[HEAD_TILE] = visited[first_step] = visited[start] = true;
    queue[queue_length++] = start;
    for (int cursor = 0; cursor < queue_length; cursor++)
    {
        for (int side = 0; side < 4; side++)
        {
            int const next = StepTile(window, queue[cursor], side);
            if (next >= 0 && !visited[next])
            {
                visited[next]         = true;
                queue[queue_length++] = next;
            }
        }
    }
    return queue_length;
}

void RoomsQueue(KernelWindow const* window, int rooms[4])
{
    for (int first_side = 0; first_side < 4; first_side++)
    {
        int const first_step = StepTile(window, HEAD_TILE, first_side);
        rooms[first_side]    = -1;
        if (first_step < 0)
        {
            continue;
        }
        rooms[first_side] = 0;
        for (int second_side = 0; second_side < 4; second_side++)
        {
            int const second_step = StepTile(window, first_step, second_side);
            if (second_step >= 0 && second_step != HEAD_TILE)
            {
                int const reachable = CountReachableTiles(window, second_step, first_step);
                rooms[first_side]   = reachable > rooms[first_side] ? reachable : rooms[first_side];
            }
        }
    }
}

/* ---- Bitboards: the whole window in one 64-bit word ------------------------------------------ */

typedef struct
{
    uint64_t free;             /* tiles a dragon could move into */
    uint64_t can_move[4];      /* tiles with an open side in each direction, inside the window */
} WindowBits;

static WindowBits const EMPTY_BITS = { 0, { 0, 0, 0, 0 } };

static WindowBits ReadWindowBits(KernelWindow const* window)
{
    WindowBits bits = EMPTY_BITS;
    for (int tile = 0; tile < WINDOW_TILES; tile++)
    {
        uint64_t const bit = (uint64_t)1 << tile;
        bits.free |= window->occupied[tile] ? 0 : bit;
        for (int side = 0; side < 4; side++)
        {
            bits.can_move[side] |= window->open[tile][side] && NeighbourTile(tile, side) >= 0 ? bit : 0;
        }
    }
    return bits;
}

/* Every tile reachable from `reach` through `allowed` tiles: grow by one step in each direction
 * until nothing changes. Moving north is a shift by one row, seven bits; east is one bit. */
static uint64_t FloodFill(WindowBits const* bits, uint64_t reach, uint64_t allowed)
{
    for (;;)
    {
        uint64_t const grown = (reach
                                | (reach & bits->can_move[0]) >> 7
                                | (reach & bits->can_move[1]) << 1
                                | (reach & bits->can_move[2]) << 7
                                | (reach & bits->can_move[3]) >> 1)
                               & allowed;
        if (grown == reach)
        {
            return reach;
        }
        reach = grown;
    }
}

static int const SHIFT_UP[4]   = { 7, 0, 0, 1 };   /* right shifts for north and west */
static int const SHIFT_DOWN[4] = { 0, 1, 7, 0 };   /* left shifts for east and south */

/* The tile a move lands on as a single bit, or 0 if the move isn't possible. */
static uint64_t MoveBit(WindowBits const* bits, uint64_t from, int side)
{
    uint64_t const moved = ((from & bits->can_move[side]) >> SHIFT_UP[side]) << SHIFT_DOWN[side];
    return moved & bits->free;
}

void RoomsBitboard(KernelWindow const* window, int rooms[4])
{
    WindowBits const bits = ReadWindowBits(window);
    uint64_t const   head = (uint64_t)1 << HEAD_TILE;
    for (int first_side = 0; first_side < 4; first_side++)
    {
        uint64_t const first = MoveBit(&bits, head, first_side);
        rooms[first_side]    = first ? 0 : -1;
        for (int second_side = 0; first && second_side < 4; second_side++)
        {
            uint64_t const second = MoveBit(&bits, first, second_side) & ~head;
            if (second)
            {
                int const reachable = __builtin_popcountll(FloodFill(&bits, second, bits.free & ~first & ~head));
                rooms[first_side]   = reachable > rooms[first_side] ? reachable : rooms[first_side];
            }
        }
    }
}

/* Every second move from the same first move floods the same board, so two second moves either
 * reach exactly the same tiles or none in common. One flood fill answers for every second move
 * it reaches. */
void RoomsComponents(KernelWindow const* window, int rooms[4])
{
    WindowBits const bits = ReadWindowBits(window);
    uint64_t const   head = (uint64_t)1 << HEAD_TILE;
    for (int first_side = 0; first_side < 4; first_side++)
    {
        uint64_t const first = MoveBit(&bits, head, first_side);
        rooms[first_side]    = first ? 0 : -1;
        uint64_t seconds = 0;
        for (int second_side = 0; first && second_side < 4; second_side++)
        {
            seconds |= MoveBit(&bits, first, second_side) & ~head;
        }
        while (seconds)
        {
            uint64_t const start     = seconds & -seconds;
            uint64_t const reached   = FloodFill(&bits, start, bits.free & ~first & ~head);
            int const      reachable = __builtin_popcountll(reached);
            rooms[first_side]        = reachable > rooms[first_side] ? reachable : rooms[first_side];
            seconds &= ~reached;
        }
    }
}

#if defined(__wasm_simd128__)
/* ---- SIMD: two flood fills per 128-bit vector ------------------------------------------------ */

static v128_t FloodFillPair(WindowBits const* bits, v128_t reach, v128_t allowed)
{
    v128_t const north = wasm_i64x2_splat((int64_t)bits->can_move[0]);
    v128_t const east  = wasm_i64x2_splat((int64_t)bits->can_move[1]);
    v128_t const south = wasm_i64x2_splat((int64_t)bits->can_move[2]);
    v128_t const west  = wasm_i64x2_splat((int64_t)bits->can_move[3]);
    for (;;)
    {
        v128_t grown = wasm_v128_or(reach, wasm_u64x2_shr(wasm_v128_and(reach, north), 7));
        grown        = wasm_v128_or(grown, wasm_i64x2_shl(wasm_v128_and(reach, east), 1));
        grown        = wasm_v128_or(grown, wasm_i64x2_shl(wasm_v128_and(reach, south), 7));
        grown        = wasm_v128_or(grown, wasm_u64x2_shr(wasm_v128_and(reach, west), 1));
        grown        = wasm_v128_and(grown, allowed);
        if (wasm_i64x2_all_true(wasm_i64x2_eq(grown, reach)))
        {
            return reach;
        }
        reach = grown;
    }
}

void RoomsSimd(KernelWindow const* window, int rooms[4])
{
    WindowBits const bits = ReadWindowBits(window);
    uint64_t const   head = (uint64_t)1 << HEAD_TILE;
    for (int first_side = 0; first_side < 4; first_side++)
    {
        uint64_t const first = MoveBit(&bits, head, first_side);
        rooms[first_side]    = first ? 0 : -1;
        if (!first)
        {
            continue;
        }
        uint64_t seconds[4];
        for (int second_side = 0; second_side < 4; second_side++)
        {
            seconds[second_side] = MoveBit(&bits, first, second_side) & ~head;
        }
        v128_t const allowed = wasm_i64x2_splat((int64_t)(bits.free & ~first & ~head));
        for (int pair = 0; pair < 4; pair += 2)
        {
            v128_t const reached = FloodFillPair(&bits, wasm_i64x2_make((int64_t)seconds[pair], (int64_t)seconds[pair + 1]), allowed);
            int const    a       = __builtin_popcountll((uint64_t)wasm_i64x2_extract_lane(reached, 0));
            int const    b       = __builtin_popcountll((uint64_t)wasm_i64x2_extract_lane(reached, 1));
            rooms[first_side]    = a > rooms[first_side] ? a : rooms[first_side];
            rooms[first_side]    = b > rooms[first_side] ? b : rooms[first_side];
        }
    }
}

#endif

#if defined(__wasm__)
/* ---- Inline WebAssembly: one growth step written by hand ------------------------------------- */

static uint64_t GrowOnce(uint64_t reach, WindowBits const* bits, uint64_t allowed)
{
    uint64_t grown;
    uint64_t const north = bits->can_move[0], east = bits->can_move[1];
    uint64_t const south = bits->can_move[2], west = bits->can_move[3];
    __asm__("local.get %1\n\t"
            "local.get %1\n\t" "local.get %2\n\t" "i64.and\n\t" "i64.const 7\n\t" "i64.shr_u\n\t" "i64.or\n\t"
            "local.get %1\n\t" "local.get %3\n\t" "i64.and\n\t" "i64.const 1\n\t" "i64.shl\n\t"   "i64.or\n\t"
            "local.get %1\n\t" "local.get %4\n\t" "i64.and\n\t" "i64.const 7\n\t" "i64.shl\n\t"   "i64.or\n\t"
            "local.get %1\n\t" "local.get %5\n\t" "i64.and\n\t" "i64.const 1\n\t" "i64.shr_u\n\t" "i64.or\n\t"
            "local.get %6\n\t" "i64.and\n\t"
            "local.set %0"
            : "=r"(grown)
            : "r"(reach), "r"(north), "r"(east), "r"(south), "r"(west), "r"(allowed));
    return grown;
}

void RoomsInlineAsm(KernelWindow const* window, int rooms[4])
{
    WindowBits const bits = ReadWindowBits(window);
    uint64_t const   head = (uint64_t)1 << HEAD_TILE;
    for (int first_side = 0; first_side < 4; first_side++)
    {
        uint64_t const first = MoveBit(&bits, head, first_side);
        rooms[first_side]    = first ? 0 : -1;
        uint64_t seconds = 0;
        for (int second_side = 0; first && second_side < 4; second_side++)
        {
            seconds |= MoveBit(&bits, first, second_side) & ~head;
        }
        uint64_t const allowed = bits.free & ~first & ~head;
        while (seconds)
        {
            uint64_t reached = seconds & -seconds;
            for (uint64_t grown = GrowOnce(reached, &bits, allowed); grown != reached; grown = GrowOnce(reached, &bits, allowed))
            {
                reached = grown;
            }
            int const reachable = __builtin_popcountll(reached);
            rooms[first_side]   = reachable > rooms[first_side] ? reachable : rooms[first_side];
            seconds &= ~reached;
        }
    }
}

#endif

#if defined(__wasm_simd128__)
/* ---- SIMD where it pays: turning the window's bytes into bitboards --------------------------- */

/* One bit per byte: the low bit of each of 16 bools, via the top bit that i8x16.bitmask reads. */
static uint32_t BoolBits(v128_t bytes)
{
    return (uint32_t)wasm_i8x16_bitmask(wasm_i8x16_shl(bytes, 7));
}

/* Side `s` of 16 tiles whose four sides are stored together: bytes s, s+4, s+8, ... of 64 bytes. */
#define SIDE_OF_16_TILES(a, b, c, d, s)                                                             \
    wasm_i8x16_shuffle(                                                                             \
        wasm_i8x16_shuffle(a, b, s, s + 4, s + 8, s + 12, 16 + s, 20 + s, 24 + s, 28 + s,           \
                           s, s, s, s, s, s, s, s),                                                 \
        wasm_i8x16_shuffle(c, d, s, s + 4, s + 8, s + 12, 16 + s, 20 + s, 24 + s, 28 + s,           \
                           s, s, s, s, s, s, s, s),                                                 \
        0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23)

/* Tiles that have a neighbour inside the window on each side. */
#define WINDOW_BITS   ((((uint64_t)1) << WINDOW_TILES) - 1)
#define NOT_TOP_ROW   (WINDOW_BITS & ~(uint64_t)0x7F)
#define NOT_BOTTOM    (WINDOW_BITS >> 7)
#define NOT_LEFT      (WINDOW_BITS & ~(uint64_t)0x0040810204081)
#define NOT_RIGHT     (WINDOW_BITS & ~((uint64_t)0x0040810204081 << 6))

static WindowBits ReadWindowBitsSimd(KernelWindow const* window)
{
    uint8_t const* occupied = (uint8_t const*)window->occupied;
    uint64_t taken = 0;
    for (int chunk = 0; chunk < 4; chunk++)
    {
        taken |= (uint64_t)BoolBits(wasm_v128_load(occupied + 16 * chunk)) << (16 * chunk);
    }
    WindowBits bits = EMPTY_BITS;
    bits.free = ~taken & WINDOW_BITS;
    uint8_t const* open = (uint8_t const*)window->open;
    for (int chunk = 0; chunk < 4; chunk++)
    {
        uint8_t const* tiles = open + 64 * chunk;
        v128_t const   a = wasm_v128_load(tiles), b = wasm_v128_load(tiles + 16);
        v128_t const   c = wasm_v128_load(tiles + 32), d = wasm_v128_load(tiles + 48);
        bits.can_move[0] |= (uint64_t)BoolBits(SIDE_OF_16_TILES(a, b, c, d, 0)) << (16 * chunk);
        bits.can_move[1] |= (uint64_t)BoolBits(SIDE_OF_16_TILES(a, b, c, d, 1)) << (16 * chunk);
        bits.can_move[2] |= (uint64_t)BoolBits(SIDE_OF_16_TILES(a, b, c, d, 2)) << (16 * chunk);
        bits.can_move[3] |= (uint64_t)BoolBits(SIDE_OF_16_TILES(a, b, c, d, 3)) << (16 * chunk);
    }
    bits.can_move[0] &= NOT_TOP_ROW;
    bits.can_move[1] &= NOT_RIGHT;
    bits.can_move[2] &= NOT_BOTTOM;
    bits.can_move[3] &= NOT_LEFT;
    return bits;
}

#endif

static void RoomsFromBits(WindowBits const* bits, int rooms[4])
{
    uint64_t const head = (uint64_t)1 << HEAD_TILE;
    for (int first_side = 0; first_side < 4; first_side++)
    {
        uint64_t const first = MoveBit(bits, head, first_side);
        rooms[first_side]    = first ? 0 : -1;
        uint64_t seconds = 0;
        for (int second_side = 0; first && second_side < 4; second_side++)
        {
            seconds |= MoveBit(bits, first, second_side) & ~head;
        }
        while (seconds)
        {
            uint64_t const reached   = FloodFill(bits, seconds & -seconds, bits->free & ~first & ~head);
            int const      reachable = __builtin_popcountll(reached);
            rooms[first_side]        = reachable > rooms[first_side] ? reachable : rooms[first_side];
            seconds &= ~reached;
        }
    }
}

#if defined(__wasm_simd128__)
void RoomsSimdMasks(KernelWindow const* window, int rooms[4])
{
    WindowBits const bits = ReadWindowBitsSimd(window);
    RoomsFromBits(&bits, rooms);
}

#endif

uint64_t MasksOnly(KernelWindow const* window)
{
    WindowBits const bits = ReadWindowBits(window);
    return bits.free ^ bits.can_move[0] ^ bits.can_move[1] ^ bits.can_move[2] ^ bits.can_move[3];
}

#if defined(__wasm_simd128__)
uint64_t MasksOnlySimd(KernelWindow const* window)
{
    WindowBits const bits = ReadWindowBitsSimd(window);
    return bits.free ^ bits.can_move[0] ^ bits.can_move[1] ^ bits.can_move[2] ^ bits.can_move[3];
}
#endif
