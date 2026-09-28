# Counting room faster

<!-- draft: 2c79a50464, stage: Performance -->

Every bot in this series counts how much room a move leaves, and [where the points go](10-where-the-points-go.md) found that this count is the only part of a turn that grows when a bot thinks further ahead. This post makes it cheaper, one step at a time, from the Nim the first bot used down to vector instructions.

To compare versions fairly, I wrote a benchmark bot that plays the first bot's moves and, on every turn, runs each version of the room count on the same window. It checks that they all agree, then logs what each one cost using the judge's own clock, so the numbers are exact CPU points. Over 1,477 turns on six maps, every version agreed on every turn:

![CPU points to count the room behind all four first moves, median of 1,477 turns on six maps, log scale. Nim with a seq queue and a set: 116,218. Nim with fixed arrays: 59,871. C with fixed arrays: 59,645. C with bitboards: 10,810. C with one flood fill per region: 9,230. SIMD with two flood fills at once: 11,249. A hand-written WebAssembly step: 9,422. SIMD for building the bitboards: 1,745.](images/room-kernels.svg)

The code is in [examples/performance](../examples/performance/bench-bot/kernels.c), and `just bench` reruns the benchmark on one map.

## The C that Nim writes

The first bot's flood fill keeps its queue in a growable `seq` and its visited tiles in a `set`, and counting the room behind all four first moves costs about 116,000 points. Nim compiles to C, so we can read what it made:

```c
visited_1 |= ((NU64)(1) << ((start_p1) % (sizeof(NU64) * 8)));
queue_1.len = 1; queue_1.p = (tySequence__qwqHTkRvwhrRyENtudHQ7g_Content*) newSeqPayload(1, sizeof(NI), NIM_ALIGNOF(NI));
/* ... for each tile in the queue, for each side ... */
            visited_1 |= ((NU64)1) << ((next_1) & 63);
            add__fgengrtl_u61((&queue_1), next_1);
/* ... */
eqdestroy___fgengrtl_u327(queue_1);
```

Two things stand out. The `set` has already become a single 64-bit word with one bit per tile, which is about as cheap as a visited set can be. The `seq` is where the cost is. Every flood fill allocates its queue on the heap with `newSeqPayload`, calls `add` for every tile it reaches, which checks the capacity and grows the queue as it fills, and frees it all at the end. Swapping the `seq` for a fixed array on the stack, still in Nim, halves the cost to about 60,000 points. Writing the same thing by hand in C costs almost exactly the same, because at that point Nim and C are producing the same program.

## Bitboards

The rest of the cost is the flood fill's shape: one tile at a time, with a test at every step. The window is 49 tiles, which fits in one 64-bit word, so we can move every reached tile at once. With bit `row × 7 + column` for each tile, a step north is a shift right by 7 and a step east a shift left by 1. A mask per direction marks the tiles with an open side that way:

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

Each pass costs about twenty instructions however many tiles it adds, and one `popcnt` counts the result. That brings the count to about 10,800 points. Flooding once per connected region instead of once per follow-up move takes it to about 9,200, because two follow-ups either reach the same tiles or none in common.

I tried two more ideas at this point, and neither helped. The judge only accepts C, but C can contain inline assembly, so I wrote the growth step by hand in WebAssembly. It cost about 9,400 points, a little more than the plain C, because Clang already emits that loop about as tightly as a person can, which is worth knowing before spending an afternoon on assembly. Then, since a 128-bit vector holds two bitboards, I tried flooding two regions side by side. That cost about 11,200, because the pair runs until the slower flood finishes, and packing and unpacking them cost more than it saved.

## SIMD where the work is

Timing the parts of the 9,200-point version showed that about 7,800 points went on building the bitboards: 49 tiles with four sides each, turned into five masks one bit at a time. The flood fills were already cheap.

![Where the 9,200-point room count spent its points: about 7,800 on building the bitboards, and about 1,400 on the flood fills and counting.](images/mask-cost.svg)

Building masks is what vector instructions are good at. The window arrives as bytes, one per tile and side, each 0 or 1. `i8x16.bitmask` gathers one bit from each of 16 bytes in a single instruction, and byte shuffles first pull out every fourth byte, since the sides are stored four to a tile:

```c
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

The masks now cost about 435 points instead of 7,800, and the whole room count about 1,750. That's 66 times cheaper than where we started, and all of it is plain C the online judge accepts.

## Keeping it vectorised

Vectorised C has one weakness: nothing promises it stays vectorised. A small edit elsewhere can let the compiler turn part of a kernel back into scalar code, and the only way to find out is to read the assembly or notice a slow benchmark.

[Rake](https://rake-lang.org) is a language I'm building for that problem. A kernel works on racks, one vector register with a lane per element, and every operation must compile to vector instructions or the program doesn't build. For this post I added a WebAssembly profile to it. Here is the north mask in Rake:

```rake
crunch north_bits(a: u8s, b: u8s, c: u8s, d: u8s) -> u32:
  | low <| shuffle(a, b, [0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0])
  | high <| shuffle(c, d, [0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0])
  | sides <| shuffle(low, high, [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23])
  return bitmask(sides != <0>)
```

The judge only takes C, so the profile emits C, one intrinsic per selected instruction. `rakec --verify-native` then compiles that C, disassembles it, and rejects any function containing anything but locals, constants and vector instructions. In the benchmark the Rake masks cost 437 points against 435 for the hand-written intrinsics, and matched on every turn. The code is in [examples/performance/rake](../examples/performance/rake/window_bits.rk), and `just rake` regenerates the C.

## What it does for the bot

The fast kernel drops into the first bot as its `room` function, with the strategy left in Nim. That's the split [The choice](02-the-choice.md) planned, and it's how our competition bot is built too: strategy in Nim, and C only in hot kernels. On the bundled maps the fast bot plays exactly the same games as the original:

![A terminal running just fast. The first bot and the fast bot each play room-c on the default map with seed 0x42. Both games have the same five deaths and end with team B winning on length after 500 rounds. The first bot's median turn costs 3.2 million points, and the fast bot's 3.0 million.](images/fast-bot.png)

The median turn only falls from 3.2 million points to 3.0 million, because the output fee and input parsing dominate a turn and no kernel can touch them. What changed is the budget for thinking: the same points now buy 66 times as much room counting, which is the currency a deeper search spends.

One wish remains. Of the mask builder's 260 or so WebAssembly instructions, 42 are shuffles that only pull every fourth byte out of the interleaved sides. x86 can gather arbitrary bits in one `PEXT` instruction, and WebAssembly has nothing like it.

## Next up

[The machine inside the judge](16-the-machine-inside-the-judge.md): the judge we wrote to play these games four times faster, and the machine it presents to a bot.
