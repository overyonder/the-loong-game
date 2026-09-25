# The machine inside the judge

<!-- draft: 8b7f25069f, stage: Performance -->

Every cost in this series has been in CPU points, and the last post spent them carefully: fewer allocations, bitboards instead of queues, vector instructions where they paid. All of that happened on a computer that doesn't exist. The judge runs our bots on a virtual CPU, WebAssembly, and charges points for each instruction it executes. A virtual CPU has the same parts as a real one: an instruction set, registers, a clock, memory and a vector unit. It just builds them in software, with its own rules.

This post goes through those parts one at a time, and compares each with the real hardware underneath. Where the two disagree, the judge's rules decide which optimisations pay off here. Then it rewrites the most important kernel from the last post in Rake, a language I'm building for vector code, and finishes by looking below the line where software stops and hardware begins.

The experiments are in [examples/performance/machine-bot](../examples/performance/machine-bot/experiments.c). `just machine` runs each loop once in the judge and once natively, on a Ryzen 7 5800X3D.

## A stack machine

A real CPU's instructions name the registers they read and write: `add eax, ebx`. WebAssembly's instructions don't. They take their operands from a stack and push their result back onto it. Here is the inner loop that adds up an array, as Clang compiles it for the judge:

```text
local.get 0     ;; the array
local.get 3     ;; the offset of the next word
i32.add         ;; its address
i32.load        ;; read the word
local.get 1     ;; the running total
i32.add
local.set 1     ;; store the new total
local.get 3
i32.const 4
i32.add
local.tee 3     ;; move to the next word
i32.const 8192
i32.ne
br_if 0         ;; loop until the end of this run
```

The stack is only a notation. Before any of this runs, the judge's engine, Wasmer, compiles it to the host's real machine code, where the stack disappears into ordinary registers. The notation still matters, though, because points are charged for the WebAssembly instructions and not for the machine code they become. Those fourteen instructions cost 16 points for each word of the array, the same on every run.

## Locals are the registers

Each WebAssembly function declares its locals up front, as many as it likes, each with a type: `i32`, `i64`, `f32`, `f64` or `v128`. They play the part of registers. `local.get` and `local.set` cost 1 point, while a load or store to memory costs 2.

So values in locals are cheaper than values in memory, and C code sometimes puts values in memory without saying so. The C stack lives in the module's linear memory, and a struct returned from a function that isn't inlined goes through it. The last post's mask builder returns its five bitboards as a struct. When I first benchmarked the Rake version of it later in this post, Clang had inlined it into its caller. The masks stayed in locals, the loops unrolled, and the same work cost 379 points instead of 437. The benchmark now keeps every mask builder as a call, so they can be compared fairly.

## Prices and the clock

[Where the points go](10-where-the-points-go.md) listed the judge's prices: 1 point for most arithmetic and local access, 2 for loads, stores, branches and vector instructions, 3 for division, and more for calls and memory growth. A real CPU has a similar spread for its own reasons, since division is slow in silicon and calls disturb the pipeline. The judge's prices are fixed, though. An instruction costs the same wherever it appears and whatever ran before it. On a real CPU, the cost of an instruction depends heavily on its neighbours, as the next two sections show.

The clock differs in the same way. A real CPU's clock ticks a few billion times a second, and an instruction takes some number of ticks, depending on what else is happening. The judge's clock is its meter. It advances one nanosecond per point, so reading it gives the exact cost of the code in between, and the same code gives the same answer on every run.

## No pipeline

A real CPU works on many instructions at once. While one add finishes, the next few are already under way, as long as they don't need its result. A floating-point add takes about three cycles on the Ryzen, but it can start new adds every cycle. The limit is how much of the program depends on what came just before.

These two loops add up the same numbers. The first keeps one running total, so each add waits for the one before. The second keeps four totals, so four adds can run at once:

```c
sum += (float)(words[i] & 0xFFu);        a += (float)(words[i] & 0xFFu);
sum += (float)(words[i + 1] & 0xFFu);    b += (float)(words[i + 1] & 0xFFu);
sum += (float)(words[i + 2] & 0xFFu);    c += (float)(words[i + 2] & 0xFFu);
sum += (float)(words[i + 3] & 0xFFu);    d += (float)(words[i + 3] & 0xFFu);
```

Natively, over two million words, the four totals take 1.10 ms and the single total takes 1.50 ms. In the judge they cost 24,117,363 and 24,117,351 points. The loops have the same instructions, and the judge charges for instructions, so the only difference is a few points spent adding up the four totals at the end.

## No cache

A real CPU keeps recently used memory in small, fast caches, and it fetches memory from the next level down in 64-byte lines. Reading the next word of a line that's already cached takes a few cycles. Reading from a line that isn't cached can take hundreds.

These two loops read the same 8 MB of words, in 1,024 runs of 2,048 each. The first reads each run from consecutive addresses, so every cache line fetched serves sixteen reads. The second starts each run one word further along and steps 4 KB between reads, so every read lands on a different cache line and a different page:

```c
sum += start[i];            /* in order: start = words + run * 2048 */
sum += start[i * 1024];     /* strided:  start = words + run */
```

Natively, the strided loop takes 10.2 ms and the in-order loop takes 1.1 ms. In the judge, both cost exactly 33,564,773 points.

So in the judge, data layout doesn't matter for its own sake, only through the number of instructions it takes. That's why the bitboards in the last post paid off here: they needed fewer instructions, and whether they fitted in cache made no difference. The same change would have helped on a real computer for both reasons.

## The vector register

A `v128` local holds 128 bits: sixteen bytes, eight 16-bit integers, four 32-bit integers or floats, or two 64-bit values. One instruction works on every lane at once. In the judge, a vector instruction costs 2 points, twice an ordinary add, so it pays off as soon as it does the work of two scalar instructions.

Adding up the same array four words at a time with `i32x4.add` costs 5,242,996 points, against 33,564,773 for the in-order loop. That's 2.5 points per word instead of 16, because Clang also unrolled the vector loop to four loads per pass. Natively, the vector loop takes 0.11 ms against 1.1 ms. On both machines the vector register is the biggest single win available, and in the judge it's the only hardware trick on this list that the meter rewards.

## Writing the hot kernel in Rake

The biggest saving in the last post came from building the bitboards with vector instructions, which took them from 7,800 points to 435. It was written in C with SIMD intrinsics, and C gives no guarantee that it stays vectorised. A small change can make the compiler fall back to scalar code without a word, and the cost goes back up by an order of magnitude.

[Rake](https://github.com/rakelang/rake) is a language I'm building for this kind of code. A value in Rake is a rack: one vector register, with one lane per element. The compiler either turns every operation into a vector instruction or refuses to compile the program. It never splits a rack or falls back to scalar code. Rake has had x86 AVX2 and ARM NEON backends. For this post I added a WebAssembly profile, `wasm-simd128`, with byte racks, two-rack shuffles and `bitmask`. It lives on a branch for now, as a proposal.

Here's the mask builder in Rake. Four racks hold the open sides of sixteen tiles, four bytes per tile, and one function pulls out the north side of each:

```text
crunch occupied_bits(tiles: u8s) -> u32:
  return bitmask(tiles != <0>)

crunch north_bits(a: u8s, b: u8s, c: u8s, d: u8s) -> u32:
  | low <| shuffle(a, b, [0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0])
  | high <| shuffle(c, d, [0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0])
  | sides <| shuffle(low, high, [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23])
  return bitmask(sides != <0>)
```

The `<0>` is a uniform value, spread across every lane. The angle brackets mark it so that each broadcast is visible in the source. The `|` lines are fused bindings: names for intermediate racks that stay in registers.

Rake's other backends emit assembly, but the judge only takes C source, and its Clang can't pass `v128` values in and out of inline assembly. It stops with an internal error, "Do not know how to split this operator's operand". So this profile emits C. Each instruction Rake selects becomes the matching intrinsic, in order:

```c
RAKE_WASM_LINKAGE uint32_t north_bits(v128_t a, v128_t b, v128_t c, v128_t d)
{
    uint32_t result;
    v128_t const step0 = wasm_i8x16_shuffle(a, b, 0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0);
    v128_t const step1 = wasm_i8x16_shuffle(c, d, 0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0);
    v128_t const step2 = wasm_i8x16_shuffle(step0, step1, 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23);
    v128_t const step3 = wasm_i8x16_splat(0);
    v128_t const step4 = wasm_i8x16_ne(step2, step3);
    uint32_t const step5 = wasm_i8x16_bitmask(step4);
    result = step5;
    return result;
}
```

Clang still chooses the locals, and it may swap one vector instruction for an equivalent one. Here it turns the splatted zero into a `v128.const`. To keep the guarantee, `rakec --verify-native` compiles the C itself, disassembles the result, and rejects any function that contains anything but locals, constants and vector instructions. There can be no loops, calls, memory access or scalar fallbacks.

Because the output is plain C, it runs in the online judge like any other bot. In the benchmark bot, over the same 1,477 turns on six maps, the Rake masks cost 437 points against 435 for the hand-written intrinsics, and matched the scalar masks on every turn. The code is in [examples/performance/rake](../examples/performance/rake/window_bits.rk), and `just rake` regenerates the C.

## One manual polish

Rake writes `tiles != <0>` as a splat of zero and a compare, because as far as Rake knows, a byte could hold anything. We know more: every byte in the window is 0 or 1. `i8x16.bitmask` only reads the top bit of each byte, and negating a byte turns 1 into 0xFF and leaves 0 alone. So one `i8x16.neg` can replace the compare with zero:

```c
v128_t const step4 = wasm_i8x16_neg(step2);
uint32_t const step5 = wasm_i8x16_bitmask(step4);
```

Clang had already made the zero once and kept it in a local, so the change mostly saves a `local.get` per mask. The polished masks cost 417 points instead of 437, and matched on every turn. The change is kept in a [separate copy](../examples/performance/bench-bot/window_bits_polished.h) of the generated file, with a note at the top explaining it. It depends on a fact about the input that the program never states, which is exactly the kind of knowledge a compiler can't use and a person can.

## Datapaths and silicon highways

Everything in this series has happened above one line. Choosing a strategy, changing an algorithm, laying out data and picking instructions are all changes to software, running on hardware that someone else designed. The instruction set is the contract between the two. In the judge, even that is fixed: WebAssembly is the floor, and the last post's wish for a bit-gather instruction is as far down as we can reach.

On a real computer, the stack keeps going. Below the instruction set is the microarchitecture, with the pipelines and caches this post has been setting aside. Below that, you stop programming a processor and start building one: an FPGA configured with a datapath for one job, or an ASIC with that datapath etched into silicon. Each step down trades flexibility for speed. This chart, from the [Over Yonder homepage](https://over-yonder.tech/), shows one path down the whole stack, with that line drawn in:

![An optimisation path down the computing stack, plotted against the time per operation after each fix on a log scale from 1 second to 10 microseconds. Fixes in product and architecture, data and execution, runtime and toolchain, operating system and services, and machine architecture sit above a dashed line marked software. Fixes with reconfigurable logic and application-specific silicon sit below it, marked hardware.](images/computing-stack.svg)

The Loong Game's bots live in the top half of that chart. This series has worked its way down from strategy to the instruction set, and the judge stops us there. At [Over Yonder](https://over-yonder.tech/) we work down the whole of that stack, including the part below the line.
