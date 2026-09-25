# Counting room faster

<!-- draft: 2c79a50464, stage: Performance -->

Every bot in this series leans on the same piece of work: counting how much room a move leaves. The flood-fill bot from [The choice](02-the-choice.md) does it for every move and follow-up, and so does every strategy bot since. [Where the points go](10-where-the-points-go.md) found that it's the only part of the turn that grows when a bot thinks harder, and that its cost is spread thinly over one-tile-at-a-time code rather than concentrated in a line we could fix.

This post takes that one job and makes it cheaper, step by step, from the Nim the first bot was written in down to hand-written WebAssembly. Each step is measured the same way. A benchmark bot plays the first bot's moves, and on every turn it runs each version of the room count on the same window, checks that they all agree, and logs what each cost in CPU points using the judge's own clock. Over 1,477 turns on six maps, every version agreed on every turn:

![CPU points to count the room behind all four first moves, median of 1,477 turns on six maps, log scale. Nim with a seq queue and a set: 116,218. Nim with fixed arrays: 59,871. C with fixed arrays: 59,645. C with bitboards: 10,810. C with one flood fill per region: 9,230. SIMD with two flood fills at once: 11,249. A hand-written WebAssembly step: 9,422. SIMD for building the bitboards: 1,745.](images/room-kernels.svg)

The code is in [examples/performance](../examples/performance/bench-bot/kernels.c), and `just bench` reruns the benchmark on one map.

## Nim

The first bot's flood fill is the Nim from The choice: a queue in a growable `seq`, and the visited tiles in a `set`. Counting the room behind all four first moves costs a median of about 116,000 points.

## The C that Nim writes

Nim compiles to C, so the obvious question is what that C looks like. Here's the heart of it, trimmed a little:

```c
visited_1 = 0;
visited_1 |= ((NU64)(1) << (((NI)24) % (sizeof(NU64) * 8)));
visited_1 |= ((NU64)(1) << ((first_p2) % (sizeof(NU64) * 8)));
visited_1 |= ((NU64)(1) << ((start_p1) % (sizeof(NU64) * 8)));
queue_1.len = 1; queue_1.p = (tySequence__qwqHTkRvwhrRyENtudHQ7g_Content*) newSeqPayload(1, sizeof(NI), NIM_ALIGNOF(NI));
queue_1.p->data[0] = start_p1;
/* ... for each tile in the queue, for each side ... */
            visited_1 |= ((NU64)1) << ((next_1) & 63);
            add__fgengrtl_u61((&queue_1), next_1);
/* ... */
eqdestroy___fgengrtl_u327(queue_1);
```

Two things stand out. The `set` has already become a single 64-bit word with one bit per tile, which is about as cheap as a visited set can be. The `seq` is where the cost is. Every flood fill allocates its queue on the heap with `newSeqPayload`, calls `add` for every tile it reaches, which checks the capacity and grows the queue as it fills, and frees it all at the end with `eqdestroy`. Swapping the `seq` for a fixed array on the stack, still in Nim, halves the cost to about 60,000 points. Writing the same thing by hand in C costs almost exactly the same, because at that point Nim and C are producing the same program.

## Good C: bitboards

Halving the cost is good, but the profile showed the rest of the cost spread across the flood fill's one-tile-at-a-time shape. So the next step changes the shape. The whole window is 49 tiles, which fits in one 64-bit word with room to spare, so instead of visiting tiles one at a time we can move every reached tile at once.

With bit `row × 7 + column` standing for each tile, stepping north is a shift right by 7, south a shift left by 7, and east and west shifts by 1. A mask for each direction marks the tiles that have an open side that way, so a shift only moves the tiles that can actually move. One step of the flood fill grows the whole reached region in every direction at once:

```c
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
```

Each pass costs about twenty instructions however many tiles it adds, and the loop stops when a pass adds nothing. Counting the result is one `popcnt`. That brings the count to about 10,800 points.

There's also a smaller saving hiding in the algorithm. For one first move, all four follow-up moves flood the same board, so any two of them either reach exactly the same tiles or none in common. One flood fill answers for every follow-up move it reaches, so the kernel only floods again from a follow-up the earlier fills didn't touch. That takes the cost to about 9,200.

## Inline WebAssembly

The judge only accepts C, but C can contain inline assembly, and Clang supports it for WebAssembly. So the next step is to write the growth step by hand:

```c
__asm__("local.get %1\n\t"
        "local.get %1\n\t" "local.get %2\n\t" "i64.and\n\t" "i64.const 7\n\t" "i64.shr_u\n\t" "i64.or\n\t"
        "local.get %1\n\t" "local.get %3\n\t" "i64.and\n\t" "i64.const 1\n\t" "i64.shl\n\t"   "i64.or\n\t"
        "local.get %1\n\t" "local.get %4\n\t" "i64.and\n\t" "i64.const 7\n\t" "i64.shl\n\t"   "i64.or\n\t"
        "local.get %1\n\t" "local.get %5\n\t" "i64.and\n\t" "i64.const 1\n\t" "i64.shr_u\n\t" "i64.or\n\t"
        "local.get %6\n\t" "i64.and\n\t"
        "local.set %0"
        : "=r"(grown)
        : "r"(reach), "r"(north), "r"(east), "r"(south), "r"(west), "r"(allowed));
```

It works, and it's a nice way to see exactly what the judge will run, but it costs about 9,400 points, a little more than the plain C. Clang already emits this loop about as tightly as we can write it by hand, so there was nothing left to win. That's the usual outcome with modern compilers, and worth knowing before spending an afternoon on assembly.

## SIMD, in the right place

WebAssembly has 128-bit vector instructions, and the judge enables them. A vector instruction costs 2 points, the same as a load, but can hold two 64-bit bitboards at once, so the obvious idea is to flood two regions side by side. That came out slightly worse, about 11,200 points. The pair runs until the slower of the two floods finishes, and packing the pair and unpacking the results costs instructions of its own, and here that cancelled out the gain.

Before trying anything else, it's worth profiling the fast version itself. Timing its parts the same way shows that about 7,800 of its 9,200 points go on building the bitboards in the first place: 49 tiles, each with four sides, turned into five 64-bit masks one bit at a time. The flood fills themselves were already cheap.

That job is exactly what vector instructions are good at. The window arrives as bytes, one per tile and side, each 0 or 1. `i8x16.bitmask` collects one bit from each of 16 bytes into an integer in a single instruction, so the occupied tiles take four loads and four bitmasks. The open sides are harder, because they're stored four to a tile, but byte shuffles can pull out every fourth byte first:

```c
/* One bit per byte: the low bit of each of 16 bools, via the top bit that i8x16.bitmask reads. */
static uint32_t BoolBits(v128_t bytes)
{
    return (uint32_t)wasm_i8x16_bitmask(wasm_i8x16_shl(bytes, 7));
}

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
```

Building the masks this way costs about 435 points instead of 7,800, and the whole room count drops to about 1,750. That's about 66 times cheaper than the Nim we started with, and every step so far is plain C the online judge accepts.

## What it does for the bot

The fast kernel drops into the first bot as its `room` function, with the rest of the strategy left in Nim, which is how [The choice](02-the-choice.md) planned to split the work. On all 13 bundled maps, it plays the same games as the original, with the same deaths in the same rounds and the same results:

![A terminal running just fast. The first bot and the fast bot each play room-c on the default map with seed 0x42. Both games have the same five deaths and end with team B winning on length after 500 rounds. The first bot's median turn costs 3.2 million points, and the fast bot's 3.0 million.](images/fast-bot.png)

The median turn falls from 3.2 million points to 3.0 million, which is close to the floor: the output fee and the input parsing from the last post, which no kernel can touch. That isn't the point of the exercise, though. The same budget now fits about 66 times as much room counting, and that's the currency a deeper search spends.

## Extra credit: outside the judge

The last stage can't be submitted, because the online judge compiles our C itself with fixed settings. The local judge will run a prebuilt WebAssembly module, though, which opens two more doors.

The first is optimising after compilation. [Binaryen](https://github.com/WebAssembly/binaryen)'s `wasm-opt` rewrites a finished module, and running the judge's own build of the benchmark through `wasm-opt -O4` changed the kernels' costs by about 1% either way. Clang had already done nearly everything there was to do.

The second is the instruction set itself, which we can't change but can at least measure against. The SIMD mask builder compiles to about 260 WebAssembly instructions, and 42 of them are byte shuffles whose only job is to pull every fourth byte out of the interleaved sides. x86 processors have an instruction, `PEXT`, that gathers arbitrary bits from a word in one step, and WebAssembly has nothing like it. A bit-gather instruction would remove those shuffles, a sixth of the mask builder. It's a small wish, but it's the kind of detail that decides how much a bot can think in 100 million points.

## Next up

This is the first of the performance posts. The next one turns to the other side of the turn, the 320,000 points the helper spends reading the input.
