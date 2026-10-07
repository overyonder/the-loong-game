// The organisers' Loong engine, ported to fixed arrays so that one source
// compiles for the CPU and for CUDA. Each function follows its namesake in
// unswcpmsoc/unswbc (engine/src, commit eb54612, version 1.0.2), with the
// pearl generator of version 1.2.2 and the queen scoring and free sprint
// allowance of 1.2.6. The judge's lockstep mode checks the official engine
// turn by turn; its result ABI also exposes queen and longest lengths.
//
// Bodies are linked lists through the board: each occupied cell holds its
// dragon's slot and the cells toward the head and toward the tail, so finding
// what occupies a cell costs one lookup where the original scans every body.
// Bodies never overlap, so the answers are the same.
//
// Original work: Copyright (c) 2026 UNSW CPMSoc, MIT License. Permission is
// hereby granted, free of charge, to any person obtaining a copy of this
// software and associated documentation files (the "Software"), to deal in the
// Software without restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions: The above copyright notice and this
// permission notice shall be included in all copies or substantial portions of
// the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

#pragma once

#include <stdint.h>

#if defined(__wasm__) && !defined(__CUDACC__)
#include <wasm_simd128.h>
#elif defined(LOONG_SIMDE) && !defined(__CUDACC__)
#ifndef SIMDE_ENABLE_NATIVE_ALIASES
#define SIMDE_ENABLE_NATIVE_ALIASES
#endif
#include <simde/wasm/simd128.h>
#endif

#ifdef __CUDACC__
#define LE __host__ __device__ inline
#else
#define LE inline
#endif

#include "replay_events.h"

namespace loong {

constexpr int MAX_SIDE = 64;
constexpr int MAX_CELLS = MAX_SIDE * MAX_SIDE;
constexpr int MAX_SLOTS = 128;       // living dragons, 64 a team at most
constexpr int MAX_ORDER = 512;       // turns in one round: the living plus that round's children
constexpr int INBOX = 64;            // sonar messages kept between a dragon's turns
constexpr int MAX_STEPS = 16;        // inline steps; text replies may use an external sequence
constexpr int MAX_ROUNDS = 500;
constexpr int MIN_LENGTH = 2;
constexpr int VISION = 7;
constexpr int VISION_RADIUS = 3;
constexpr int LEGACY_PROTOCOL = 2;
constexpr int ECHO_PROTOCOL = 3;
constexpr int ROUND_START = -1;      // `cursor` before the round's pearl tick

enum Dir : uint8_t { N = 0, E = 1, S = 2, W = 3 };
enum Edge : uint8_t { OPEN = 0, KELP = 1, PORTAL = 2 };
enum Symmetry : uint8_t { SYM_NONE = 0, SYM_X = 1, SYM_Y = 2, SYM_XY = 3 };
enum Death : uint8_t { WALL = 0, SELF = 1, OTHER = 2, HEAD_ON = 3, NO_ACTION = 4 };
// Sonar results, in the order the ECHOES line counts them ("waAeE"); EMPTY is uncounted.
enum Hit : uint8_t { KELP_HIT = 0, ALLY = 1, ALLY_HEAD = 2, ENEMY = 3, ENEMY_HEAD = 4, EMPTY = 5 };
enum ActionKind : uint8_t { SUICIDE = 0, MOVE = 1, SPLIT = 2 };

struct Action
{
    uint8_t kind = SUICIDE;
    int32_t steps = 0;
    uint8_t step[MAX_STEPS] = {};
    uint8_t const* extendedSteps = nullptr; // host reply's sequence when longer than the inline array
    int32_t split = 0;
    uint8_t sonarMask = 0;            // bit d: a directed sonar toward d
    uint64_t sonar[4] = {};
    uint8_t sonarRelative = 0;        // mask and values by side of the facing after the action (0 ahead, 1 right, 2 back, 3 left)
    uint8_t legacySonar = 0;          // `SONAR v`: cast toward the facing after the action
    uint32_t legacyValue = 0;
    int32_t protocol = -1;            // `PROTOCOL p`, or -1
};

struct Dragon
{
    int32_t id;
    uint8_t team;                     // 0 is A, 1 is B
    uint8_t alive;
    uint8_t facing;
    uint8_t echoes[5];
    int32_t protocol;
    int16_t head, tail;
    int32_t length;
    int32_t inboxCount;               // every message received; INBOX of them are kept
    uint64_t inbox[INBOX];
};

struct Turn
{
    int16_t slot;
    int32_t id;
};

struct Rng
{
    uint64_t mt[312];
    int32_t index;
};

struct Game
{
    // The map. Cells are y * width + x.
    int32_t width, height, unitLimit;
    uint8_t symmetry;
    uint8_t spawns[MAX_CELLS];
    int32_t minGap[MAX_CELLS], maxGap[MAX_CELLS];
    // Each cell's north edge (horizontal) and west edge (vertical).
    uint8_t edgeKind[2][MAX_CELLS];
    int16_t portalId[2][MAX_CELLS];
    int32_t partner[2][MAX_CELLS];    // the partner edge as orientation * MAX_CELLS + cell, or -1

    // The play.
    int32_t round;
    int32_t cursor;                   // index into `order`, or ROUND_START
    int32_t nextId;
    uint8_t over;
    uint8_t winner;                   // 0 A, 1 B, 2 none
    uint8_t endReason;                // 0 a team eliminated, 1 the round limit
    uint8_t pearl[MAX_CELLS];
    int32_t countdown[MAX_CELLS];
    int16_t occupant[MAX_CELLS];      // slot, or -1
    int16_t towardHead[MAX_CELLS], towardTail[MAX_CELLS];
    int32_t alive[2];
    // A sampled game's dragons believed alive but not placed (search/0001.h's
    // SampleGame), which count as living at the round's end; 0 in a real game.
    int32_t unseen[2];
    Dragon dragon[MAX_SLOTS];
    int32_t orderCount;
    Turn order[MAX_ORDER];
    int32_t overflow;                 // limits this port hit: dragons, turns or messages beyond its arrays
    Rng rng;
};

// mt19937_64, as libc++ implements it.
LE void Seed(Rng& r, uint64_t seed)
{
    r.mt[0] = seed;
#if defined(__wasm__) && defined(__clang__)
#pragma clang loop unroll(full)
#endif
    for (int i = 1; i < 312; i++)
    {
        r.mt[i] = 6364136223846793005ull * (r.mt[i - 1] ^ (r.mt[i - 1] >> 62)) + static_cast<uint64_t>(i);
    }
    r.index = 0;
}

LE uint64_t Draw(Rng& r)
{
    uint64_t const upper = 0xFFFFFFFF80000000ull;
    uint64_t const lower = 0x7FFFFFFFull;
    int const i = r.index;
    int const j = i + 1 == 312 ? 0 : i + 1;
    uint64_t y = (r.mt[i] & upper) | (r.mt[j] & lower);
    int const k = i + 156 >= 312 ? i + 156 - 312 : i + 156;
    r.mt[i] = r.mt[k] ^ (y >> 1) ^ ((y & 1) ? 0xB5026F5AA96619E9ull : 0);
    uint64_t z = r.mt[i];
    r.index = j;
    z ^= (z >> 29) & 0x5555555555555555ull;
    z ^= (z << 17) & 0x71D67FFFEDA60000ull;
    z ^= (z << 37) & 0xFFF7EEE000000000ull;
    z ^= z >> 43;
    return z;
}

#if (defined(__wasm__) || defined(LOONG_SIMDE)) && !defined(__CUDACC__)
#if defined(__wasm__)
__attribute__((target("simd128")))
#endif
inline v128_t DrawPair(Rng& r)
{
    int const i = r.index;
    // These pairs cross an array end. All other pairs read their inputs
    // before either output can change an input of the second draw.
    if (i == 155 || i >= 310)
    {
        uint64_t const first = Draw(r), second = Draw(r);
        return wasm_i64x2_make(first, second);
    }
    int const k = i < 156 ? i + 156 : i - 156;
    v128_t const y = wasm_v128_bitselect(wasm_v128_load(r.mt + i), wasm_v128_load(r.mt + i + 1),
                                        wasm_i64x2_splat(0xFFFFFFFF80000000ull));
    v128_t const odd = wasm_i64x2_sub(wasm_i64x2_splat(0), wasm_v128_and(y, wasm_i64x2_splat(1)));
    v128_t z = wasm_v128_xor(wasm_v128_load(r.mt + k), wasm_v128_xor(wasm_u64x2_shr(y, 1),
                            wasm_v128_and(odd, wasm_i64x2_splat(0xB5026F5AA96619E9ull))));
    wasm_v128_store(r.mt + i, z);
    r.index = i + 2;
    z = wasm_v128_xor(z, wasm_v128_and(wasm_u64x2_shr(z, 29), wasm_i64x2_splat(0x5555555555555555ull)));
    z = wasm_v128_xor(z, wasm_v128_and(wasm_i64x2_shl(z, 17), wasm_i64x2_splat(0x71D67FFFEDA60000ull)));
    z = wasm_v128_xor(z, wasm_v128_and(wasm_i64x2_shl(z, 37), wasm_i64x2_splat(0xFFF7EEE000000000ull)));
    return wasm_v128_xor(z, wasm_u64x2_shr(z, 43));
}
#endif

LE int Opposite(int d) { return (d + 2) & 3; }
LE int Wrap(int v, int size)
{
    int const remainder = v % size;
    return remainder < 0 ? remainder + size : remainder;
}
LE int Cell(Game const& g, int x, int y) { return y * g.width + x; }
LE int X(Game const& g, int cell) { return cell % g.width; }
LE int Y(Game const& g, int cell) { return cell / g.width; }
LE int DX(int d) { return d == E ? 1 : d == W ? -1 : 0; }
LE int DY(int d) { return d == S ? 1 : d == N ? -1 : 0; }

LE int MirrorTile(Game const& g, int cell)
{
    switch (g.symmetry)
    {
    case SYM_X: return cell + (g.height - 1 - 2 * Y(g, cell)) * g.width;
    case SYM_Y: return cell + g.width - 1 - 2 * X(g, cell);
    case SYM_XY: return g.width * g.height - 1 - cell;
    default: return cell;
    }
}

// The edge on one side of a tile, as orientation * MAX_CELLS + cell: 0 is the
// horizontal edge on a cell's north side, 1 the vertical edge on its west side.
LE int EdgeOnTileSide(Game const& g, int cell, int side)
{
    switch (side)
    {
    case N: return cell;
    case S: return cell + (cell < (g.height - 1) * g.width ? g.width : (1 - g.height) * g.width);
    case W: return MAX_CELLS + cell;
    default: return MAX_CELLS + cell + (X(g, cell) + 1 == g.width ? 1 - g.width : 1);
    }
}

LE int TileAfterCrossing(Game const& g, int edge, int heading)
{
    int const cell = edge % MAX_CELLS;
    // A sampled portal without an ID can still have partner -1. Preserve
    // its existing signed-coordinate wrapping, including one-cell maps.
    if (cell < 0)
        return Cell(g, X(g, cell), Wrap(heading == S ? Y(g, cell) : Y(g, cell) - 1, g.height));
    if (edge < MAX_CELLS)
    {
        return heading == S ? cell : cell + (cell < g.width ? (g.height - 1) * g.width : -g.width);
    }
    return heading == E ? cell : cell + (X(g, cell) == 0 ? g.width - 1 : -1);
}

// The tile a step leads to, or -1 through kelp.
LE int TileAfterStep(Game const& g, int from, int dir)
{
    int const edge = EdgeOnTileSide(g, from, dir);
    int const o = edge / MAX_CELLS, c = edge % MAX_CELLS;
    switch (g.edgeKind[o][c])
    {
    case KELP: return -1;
    case PORTAL: return TileAfterCrossing(g, g.partner[o][c], dir);
    default: return TileAfterCrossing(g, edge, dir);
    }
}

LE int DirectionOfStepBetween(Game const& g, int from, int to)
{
    for (int d = 0; d < 4; d++)
    {
        if (TileAfterStep(g, from, d) == to)
        {
            return d;
        }
    }
    return -1;
}

template<typename Events = NoReplayEvents>
LE void Kill(Game& g, int slot, int reason, int32_t* deaths, Events const& events = {})
{
    Dragon& d = g.dragon[slot];
    events.emit({DEATH_EVENT, {d.id, reason, g.round}});
    int segment = 0;
    for (int cell = d.head; cell >= 0; segment++)
    {
        int const next = g.towardTail[cell];
        if (segment % 2 == 0)
        {
            g.pearl[cell] = 1;
            events.emit({TILE_EVENT, {X(g, cell), Y(g, cell), 1}});
        }
        g.occupant[cell] = -1;
        cell = next;
    }
    d.alive = 0;
    g.alive[d.team]--;
    if (deaths)
    {
        deaths[reason]++;
    }
}

LE void PopTail(Game& g, Dragon& d)
{
    int const tail = d.tail;
    int const next = g.towardHead[tail];
    g.occupant[tail] = -1;
    g.towardHead[tail] = -1;
    d.tail = static_cast<int16_t>(next);
    g.towardTail[next] = -1;
    d.length--;
}

// Counts of what a turn did, for rewards and statistics.
struct Outcome
{
    int32_t deaths[5];                // by cause, across every dragon the turn killed
    int32_t pearls;                   // pearls the acting dragon ate
    int32_t children;
};

template<typename Events = NoReplayEvents>
LE void Step(Game& g, int slot, int dir, bool pay, Outcome& out, Events const& events = {})
{
    Dragon& d = g.dragon[slot];
    d.facing = static_cast<uint8_t>(dir);
    int const dest = TileAfterStep(g, d.head, dir);
    if (dest < 0)
    {
        Kill(g, slot, WALL, out.deaths, events);
        return;
    }
    int const other = g.occupant[dest];
    if (other == slot)
    {
        Kill(g, slot, SELF, out.deaths, events);
        return;
    }
    if (other >= 0)
    {
        if (g.dragon[other].head == dest)
        {
            Kill(g, other, HEAD_ON, out.deaths, events);
            Kill(g, slot, HEAD_ON, out.deaths, events);
            return;
        }
        Kill(g, slot, OTHER, out.deaths, events);
        return;
    }
    g.occupant[dest] = static_cast<int16_t>(slot);
    g.towardTail[dest] = d.head;
    g.towardHead[dest] = -1;
    g.towardHead[d.head] = static_cast<int16_t>(dest);
    d.head = static_cast<int16_t>(dest);
    d.length++;
    if (g.pearl[dest])
    {
        g.pearl[dest] = 0;
        events.emit({TILE_EVENT, {X(g, dest), Y(g, dest), 0}});
        out.pearls++;
    }
    else
    {
        PopTail(g, d);
    }
    if (pay)
    {
        PopTail(g, d);
    }
    events.emit({UPDATE_EVENT, {d.id, d.facing, X(g, d.head), Y(g, d.head), X(g, d.tail), Y(g, d.tail)}});
}

template<typename Events = NoReplayEvents>
LE void Move(Game& g, int slot, Action const& a, Outcome& out, Events const& events = {})
{
    int const freeSteps = (g.dragon[slot].length + 3) / 4;
    for (int i = 0; i < a.steps; i++)
    {
        bool const pay = i >= freeSteps;
        if (pay && g.dragon[slot].length <= MIN_LENGTH)
        {
            events.emit({ACTION_ERROR_EVENT, {g.dragon[slot].id, 0, i + 1, g.dragon[slot].team}});
            Kill(g, slot, NO_ACTION, out.deaths, events);
            return;
        }
        Step(g, slot, a.extendedSteps ? a.extendedSteps[i] : a.step[i], pay, out, events);
        if (!g.dragon[slot].alive)
        {
            return;
        }
    }
}

template<typename Events = NoReplayEvents>
LE void Split(Game& g, int slot, int count, Outcome& out, Events const& events = {})
{
    Dragon& parent = g.dragon[slot];
    int const length = parent.length;
    if (count < MIN_LENGTH || count > length - MIN_LENGTH || g.alive[parent.team] >= g.unitLimit)
    {
        events.emit({ACTION_ERROR_EVENT, {parent.id, count < MIN_LENGTH || count > length - MIN_LENGTH ? 1 : 2, count, length, parent.team, g.unitLimit}});
        Kill(g, slot, NO_ACTION, out.deaths, events);
        return;
    }
    int free = -1;
    for (int s = 0; s < MAX_SLOTS; s++)
    {
        if (!g.dragon[s].alive)
        {
            free = s;
            break;
        }
    }
    if (free < 0 || g.orderCount >= MAX_ORDER)
    {
        g.overflow++;
        Kill(g, slot, NO_ACTION, out.deaths, events);
        return;
    }
    // The child takes the rear `count` segments, reversed: the old tail is its head.
    Dragon& child = g.dragon[free];
    int const childHead = parent.tail;
    int last = childHead;
    for (int i = 1; i < count; i++)
    {
        last = g.towardHead[last];
    }
    int const parentTail = g.towardHead[last];
    g.towardTail[parentTail] = -1;
    parent.tail = static_cast<int16_t>(parentTail);
    parent.length = length - count;
    for (int cell = childHead, previous = -1; ; )
    {
        int const next = g.towardHead[cell];
        g.occupant[cell] = static_cast<int16_t>(free);
        g.towardHead[cell] = static_cast<int16_t>(previous);
        g.towardTail[cell] = static_cast<int16_t>(cell == last ? -1 : next);
        if (cell == last)
        {
            break;
        }
        previous = cell;
        cell = next;
    }
    child.id = g.nextId++;
    child.team = parent.team;
    child.alive = 1;
    child.protocol = parent.protocol;
    child.head = static_cast<int16_t>(childHead);
    child.tail = static_cast<int16_t>(last);
    child.length = count;
    child.facing = static_cast<uint8_t>(DirectionOfStepBetween(g, g.towardTail[childHead], childHead));
    child.inboxCount = 0;
    for (int k = 0; k < 5; k++)
    {
        child.echoes[k] = 0;
    }
    g.alive[child.team]++;
    g.order[g.orderCount++] = Turn{static_cast<int16_t>(free), child.id};
    out.children++;
    events.split(g, slot, free);
}

template<typename Events = NoReplayEvents>
LE int CastSonar(Game& g, int slot, int dir, uint64_t value, Events const& events = {})
{
    Dragon& d = g.dragon[slot];
    bool const fromTail = dir == Opposite(d.facing) && d.length > 1;
    int const origin = fromTail ? d.tail : d.head;
    if (fromTail)
    {
        int const along = DirectionOfStepBetween(g, g.towardHead[d.tail], d.tail);
        if (along >= 0)
        {
            dir = along;
        }
    }
    int at = origin;
    int hit = -1;
    int kind = EMPTY;
    int const reach = g.width + g.height;
    for (int step = 0; step < reach && hit < 0; step++)
    {
        int const next = TileAfterStep(g, at, dir);
        if (next < 0)
        {
            kind = KELP_HIT;
            break;
        }
        at = next;
        hit = g.occupant[at];
    }
    if (hit >= 0)
    {
        Dragon& target = g.dragon[hit];
        if (target.inboxCount < INBOX)
        {
            target.inbox[target.inboxCount] = value;
        }
        else
        {
            g.overflow++;
        }
        target.inboxCount++;
        bool const isHead = target.head == at;
        kind = target.team == d.team ? (isHead ? ALLY_HEAD : ALLY) : (isHead ? ENEMY_HEAD : ENEMY);
    }
    events.emit({SONAR_EVENT, {d.id, dir, X(g, origin), Y(g, origin), X(g, at), Y(g, at), hit < 0 ? -1 : g.dragon[hit].id, kind == EMPTY ? 1 : kind + 2}, value});
    return kind;
}

template<typename Events = NoReplayEvents>
LE void SetCountdown(Game& g, int bed, int mirror, int gap, Events const& events = {})
{
    g.countdown[bed] = gap;
    g.countdown[mirror] = gap;
    events.emit({COUNTDOWN_EVENT, {X(g, bed), Y(g, bed), gap}});
    if (mirror != bed) events.emit({COUNTDOWN_EVENT, {X(g, mirror), Y(g, mirror), gap}});
}

LE int DrawRespawnGap(Game& g, int bed)
{
    uint64_t const span = static_cast<uint64_t>(g.maxGap[bed] - g.minGap[bed] + 1);
    return g.minGap[bed] + static_cast<int>(Draw(g.rng) % span);
}

template<typename Events = NoReplayEvents>
LE void TrySpawnPearl(Game& g, int bed, Events const& events = {})
{
    if (!g.pearl[bed] && g.occupant[bed] < 0)
    {
        g.pearl[bed] = 1;
        events.emit({TILE_EVENT, {X(g, bed), Y(g, bed), 1}});
    }
}

template<typename Events = NoReplayEvents>
LE void InitPearlCountdowns(Game& g, Events const& events = {})
{
    int const cells = g.width * g.height;
    for (int bed = 0; bed < cells; bed++)
    {
        int const mirror = MirrorTile(g, bed);
        if (mirror < bed || !g.spawns[bed])
        {
            continue;
        }
        SetCountdown(g, bed, mirror, DrawRespawnGap(g, bed), events);
    }
}

template<typename Events>
LE void TickSpawnBed(Game& g, int bed, Events const& events)
{
    int const mirror = MirrorTile(g, bed);
    if (mirror < bed) return;
    int const remaining = g.countdown[bed] - 1;
    g.countdown[bed] = g.countdown[mirror] = remaining;
    if (remaining > 0) return;
    TrySpawnPearl(g, bed, events);
    if (mirror != bed) TrySpawnPearl(g, mirror, events);
    SetCountdown(g, bed, mirror, DrawRespawnGap(g, bed), events);
}

template<typename Events = NoReplayEvents>
#if defined(__wasm__) && !defined(__CUDACC__)
__attribute__((target("simd128")))
#endif
LE void PearlTick(Game& g, Events const& events = {})
{
    int const cells = g.width * g.height;
    int bed = 0;
#if (defined(__wasm__) || defined(LOONG_SIMDE)) && !defined(__CUDACC__)
    uint8_t const* cursor = g.spawns;
    uint8_t const* const end = cursor + (cells & ~15);
#if defined(__wasm__) && defined(__clang__)
#pragma clang loop unroll_count(4)
#endif
    for (; cursor != end; cursor += 16)
    {
        v128_t const spawns = wasm_v128_load(cursor);
        if (!wasm_v128_any_true(spawns)) continue;
        // Visit set bytes in cell order to preserve draws and replay events.
        unsigned mask = wasm_i8x16_bitmask(wasm_i8x16_ne(spawns, wasm_i8x16_splat(0)));
        do
        {
            TickSpawnBed(g, static_cast<int>(cursor - g.spawns) + __builtin_ctz(mask), events);
            mask &= mask - 1;
        } while (mask);
    }
    bed = static_cast<int>(cursor - g.spawns);
#endif
    for (; bed < cells; bed++)
        if (g.spawns[bed]) TickSpawnBed(g, bed, events);
}

struct Standing
{
    int32_t dragons, longest, total, queen;
};

LE void Standings(Game const& g, Standing* s)
{
    s[0] = s[1] = Standing{0, 0, 0, 0};
    s[0].dragons = g.unseen[0], s[1].dragons = g.unseen[1];
    for (int slot = 0; slot < MAX_SLOTS; slot++)
    {
        Dragon const& d = g.dragon[slot];
        if (!d.alive)
        {
            continue;
        }
        s[d.team].dragons++;
        s[d.team].longest = d.length > s[d.team].longest ? d.length : s[d.team].longest;
        s[d.team].total += d.length;
        if (d.id == 0 || d.id == 1)
        {
            s[d.team].queen = d.length;
        }
    }
}

// ResultAfterRound: whether the game ends after this round, and who won.
LE void EndRound(Game& g)
{
    Standing s[2];
    Standings(g, s);
    bool const aOut = s[0].dragons == 0, bOut = s[1].dragons == 0;
    if (aOut || bOut)
    {
        g.over = 1;
        g.endReason = 0;
        g.winner = aOut == bOut ? 2 : (aOut ? 1 : 0);
        return;
    }
    // A sampled game whose placed dragons have all died has no turn left to
    // play, only empty rounds to the last: it ends now, scored as it stands.
    bool const empty = s[0].dragons == g.unseen[0] && s[1].dragons == g.unseen[1];
    if (g.round + 1 < MAX_ROUNDS && !empty)
    {
        return;
    }
    g.over = 1;
    g.endReason = 1;
    bool const aAhead = s[0].queen > s[1].queen || (s[0].queen == s[1].queen &&
        (s[0].longest > s[1].longest || (s[0].longest == s[1].longest && s[0].total > s[1].total)));
    bool const bAhead = s[1].queen > s[0].queen || (s[1].queen == s[0].queen &&
        (s[1].longest > s[0].longest || (s[1].longest == s[0].longest && s[1].total > s[0].total)));
    g.winner = aAhead ? 0 : bAhead ? 1 : 2;
}

// Starts a round: its pearl tick, then the living dragons in ID order.
template<typename Events = NoReplayEvents>
LE void StartRound(Game& g, Events const& events = {})
{
    events.emit({ROUND_EVENT, {g.round}});
    PearlTick(g, events);
    g.orderCount = 0;
    for (int slot = 0; slot < MAX_SLOTS; slot++)
    {
        if (g.dragon[slot].alive)
        {
            int at = g.orderCount++;
            while (at > 0 && g.order[at - 1].id > g.dragon[slot].id)
            {
                g.order[at] = g.order[at - 1];
                at--;
            }
            g.order[at] = Turn{static_cast<int16_t>(slot), g.dragon[slot].id};
        }
    }
    g.cursor = 0;
}

// Runs the game forward to the next dragon that must act and returns its
// slot, or -1 once the game is over. The dragon's observation is read now,
// before Act clears its inbox.
template<typename Events = NoReplayEvents>
LE int Advance(Game& g, Events const& events = {})
{
    while (!g.over)
    {
        if (g.cursor == ROUND_START)
        {
            StartRound(g, events);
        }
        while (g.cursor < g.orderCount)
        {
            Turn const t = g.order[g.cursor];
            if (g.dragon[t.slot].alive && g.dragon[t.slot].id == t.id)
            {
                return t.slot;
            }
            g.cursor++;
        }
        EndRound(g);
        if (!g.over)
        {
            g.round++;
            g.cursor = ROUND_START;
        }
    }
    return -1;
}

// TakeTurn after the observation: the acting dragon's action, then its sonar.
template<typename Events = NoReplayEvents>
LE Outcome Act(Game& g, Action const& a, Events const& events = {})
{
    Outcome out{};
    int const slot = g.order[g.cursor].slot;
    Dragon& d = g.dragon[slot];
    d.inboxCount = 0;
    for (int k = 0; k < 5; k++)
    {
        d.echoes[k] = 0;
    }
    if (a.protocol >= 0)
    {
        d.protocol = a.protocol;
    }
    if (a.kind == MOVE && a.steps > 0)
    {
        Move(g, slot, a, out, events);
    }
    else if (a.kind == SPLIT)
    {
        Split(g, slot, a.split, out, events);
    }
    else
    {
        Kill(g, slot, NO_ACTION, out.deaths, events);
    }
    g.cursor++;
    if (!g.dragon[slot].alive)
    {
        return out;
    }
    uint64_t value[4];
    uint8_t mask = a.sonarMask;
    for (int k = 0; k < 4; k++)
    {
        value[k] = a.sonar[k];
    }
    int const facing = g.dragon[slot].facing;
    if (a.sonarRelative)
    {
        uint8_t world = 0;
        uint64_t worldValue[4] = {};
        for (int k = 0; k < 4; k++)
        {
            if (mask & (1 << k))
            {
                int const d = (facing + k) & 3;
                world |= static_cast<uint8_t>(1 << d);
                worldValue[d] = value[k];
            }
        }
        mask = world;
        for (int k = 0; k < 4; k++) value[k] = worldValue[k];
    }
    if (a.legacySonar && !(mask & (1 << facing)))
    {
        mask |= static_cast<uint8_t>(1 << facing);
        value[facing] = a.legacyValue;
    }
    for (int k = 0; k < 4; k++)
    {
        if (mask & (1 << k))
        {
            int const kind = CastSonar(g, slot, k, value[k], events);
            if (kind != EMPTY)
            {
                g.dragon[slot].echoes[kind]++;
            }
        }
    }
    return out;
}

// The trainer's actions, one integer each, in the acting dragon's frame: a
// direction 0-3 is forward, right, back or left of the heading before it.
//   bits 28-29  the kind: 0 a move, 1 a sprint, 2 a split;
//   bits 20-21  a move's direction;
//   bits 24-27  a split's option: split off 2, 3 or 4 segments, a quarter,
//               a third, a half, two thirds or three quarters of the body,
//               or all but 2, 3 or 4 segments;
//   bits 16-18  a sprint's steps less one, 2 to SPRINT_STEPS steps;
//   bits 0-15   the sprint's directions, two bits a step, each turned from
//               the heading the step before left.
// A sampled action carries every kind's part, so training can score the
// parts of the decision its kind didn't use; only the kind's part is played.
constexpr int SPRINT_STEPS = 8;
constexpr int SPLIT_OPTIONS = 11;
constexpr int KIND_SHIFT = 28, MOVE_SHIFT = 20, SPLIT_SHIFT = 24, STEPS_SHIFT = 16;
enum Kind : uint8_t { KIND_MOVE = 0, KIND_SPRINT = 1, KIND_SPLIT = 2 };

// What a dragon may choose, a byte each: whether each split option is
// legal, then the most steps a sprint may take (0 when it may not sprint).
// Every move is legal.
constexpr int LEGAL = SPLIT_OPTIONS + 1;

LE int SplitCount(int length, int option)
{
    int const percent[5] = {25, 33, 50, 67, 75};
    return option < 3 ? option + 2 : option < 8 ? (length * percent[option - 3] + 50) / 100 : length - (option - 6);
}

// The most steps a sprint can pay for with no pearl on its way: before each
// paid step the dragon must be longer than MIN_LENGTH, and each costs a
// segment. A longer sprint that pearls on its way would pay for is left out.
LE int SprintSteps(int length)
{
    int const affordable = (length + 3) / 4 + length - MIN_LENGTH;
    return affordable < 2 ? 0 : affordable < SPRINT_STEPS ? affordable : SPRINT_STEPS;
}

// The legal bytes for a dragon of this length whose team has `units` living
// dragons of `limit`.
LE void LegalFor(int length, int units, int limit, uint8_t* legal)
{
    for (int o = 0; o < SPLIT_OPTIONS; o++)
    {
        int const k = SplitCount(length, o);
        legal[o] = k >= MIN_LENGTH && k <= length - MIN_LENGTH && units < limit ? 1 : 0;
    }
    legal[SPLIT_OPTIONS] = static_cast<uint8_t>(SprintSteps(length));
}

LE void Legal(Game const& g, int slot, uint8_t* legal)
{
    Dragon const& d = g.dragon[slot];
    LegalFor(d.length, g.alive[d.team], g.unitLimit, legal);
}

LE int ActionKind(int32_t a)
{
    return (a >> KIND_SHIFT) & 3;
}

LE Action DecodeFor(int facing, int length, int32_t a)
{
    Action act;
    int const kind = ActionKind(a);
    if (kind == KIND_MOVE)
    {
        act.kind = MOVE;
        act.steps = 1;
        act.step[0] = static_cast<uint8_t>((facing + (a >> MOVE_SHIFT)) & 3);
    }
    else if (kind == KIND_SPRINT)
    {
        act.kind = MOVE;
        act.steps = static_cast<uint8_t>(((a >> STEPS_SHIFT) & 7) + 1);
        int heading = facing;
        for (int k = 0; k < act.steps; k++)
        {
            heading = (heading + (a >> (2 * k))) & 3;
            act.step[k] = static_cast<uint8_t>(heading);
        }
    }
    else
    {
        act.kind = SPLIT;
        act.split = SplitCount(length, (a >> SPLIT_SHIFT) & 15);
    }
    act.protocol = ECHO_PROTOCOL;
    return act;
}

LE Action Decode(Game const& g, int slot, int32_t a)
{
    return DecodeFor(g.dragon[slot].facing, g.dragon[slot].length, a);
}

// Game::Run's opening, once the map is loaded and its dragons placed.
template<typename Events = NoReplayEvents>
LE void Begin(Game& g, uint64_t seed, Events const& events = {})
{
    Seed(g.rng, seed);
    g.round = 0;
    g.cursor = ROUND_START;
    g.over = 0;
    g.winner = 2;
    g.endReason = 0;
    g.overflow = 0;
    InitPearlCountdowns(g, events);
    for (int id = 0; id < g.nextId; id++)
    {
        for (int slot = 0; slot < MAX_SLOTS; slot++)
        {
            Dragon const& d = g.dragon[slot];
            if (d.alive && d.id == id) events.emit({UPDATE_EVENT, {d.id, d.facing, X(g, d.head), Y(g, d.head), X(g, d.tail), Y(g, d.tail)}});
        }
    }
}

} // namespace loong
