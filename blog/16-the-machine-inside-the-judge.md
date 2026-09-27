# The machine inside the judge

> **Editor's note, 28 September 2026.** I've added figures to this post, linked the judge's source, and moved the reasons for writing it in Zig to [The choice](02-the-choice.md).

We wrote our own judge. It plays exactly the same games as the official toolkit, event for event and point for point, in about a quarter of the time. And it never loses a dragon to a race in the official sandbox that occasionally kills a freshly split dragon with "no valid action", because each bot runs as a fibre on the judge's own thread instead of on a thread of its own.

This post explains that design, the bug it rules out, and what the machine underneath looks like to a bot. The judge is open source in [harness/zig_judge](../harness/zig_judge/src/main.zig). From `examples/tooling`, `just zig-judge-build` builds it with Zig 0.16 and the wasmtime C API, and [harness.py](../harness/zig_judge/harness.py) plays batches of games from Python, metering each bot on the way.

## What a judge does

The rules aren't in the judge. The organisers ship the game engine as a WebAssembly module, `unswbc_engine.wasm`, which owns every rule and writes the replay. The judge hosts it, along with one WebAssembly instance for every dragon. Each turn it gives a dragon its view as text on stdin, runs the bot until the bot finishes its reply with `ENDTURN`, and charges the CPU points the bot spent along the way.

![What a judge does. The game engine, unswbc_engine.wasm, owns every rule and writes the replay, and talks to the judge through bot_spawn, bot_reply and log. The judge hosts the engine, feeds each dragon its turn, meters CPU points and reads the reply. Each dragon is its own bot.wasm instance, reading its view on stdin and replying on stdout.](images/judge-parts.svg)

The online judge runs bots in Wasmer. The toolkit reproduces it in wasmtime, with a metering pass that inserts the same point counting into each bot's module. Our judge uses that same metering pass and the same engine module. Only the host around them is new.

## The race in the official sandbox

The toolkit's sandbox gives every dragon its own Python thread. The bot runs on that thread, and when it reads stdin with nothing waiting, the read blocks. That's how a turn ends: a bot that has written its reply goes back to read the next turn, and the host sees it waiting. The host counts these waits as *parks*. Before feeding a turn, it notes the count, and a count that has gone up since means the bot has stopped for this turn:

```python
def _write(self, data: bytes) -> bool:
    ...
    self._parks = self._stdin.parks    # line 1469: note the park count
    self._stdin.feed(data)             # line 1470: then feed the turn
    self._box.frozen.set()
    return True
```

Those two lines don't hold the pipe's lock between them. Usually that doesn't matter, because a bot between turns is frozen. A dragon that has just split is the exception. Its new sandbox is already running on its own thread, on its way to its first read. If it reaches that read between line 1469 and line 1470, it finds stdin empty and parks. Then the turn arrives. The host sees a park count higher than the one it noted, decides the new dragon has already finished its turn, and takes its empty reply. The dragon dies of "no valid action", and no error line says why.

It's rare, and it lands on the worst dragon to lose: a fresh child, the whole point of a split. On busy cloud workers, 2 games in one batch of 384 lost a new dragon this way. It happens in toolkit 1.1.0, and the same two lines are unchanged in 1.2.2, the latest release. The repair for anyone running the official toolkit is to take the pipe's lock across both steps:

```python
with self._stdin.cv:
    self._parks = self._stdin.parks
    self._stdin.feed(data)
```

## Fibres instead of threads

Our judge never had this bug, because no bot ever runs on a thread of its own. wasmtime can run a WebAssembly call asynchronously, as a fibre: a call stack that can be paused and resumed on the same thread. When a bot's read would block, the host call returns a pending continuation instead of waiting. The instance pauses, and the judge's own loop decides when to resume it, which is only ever on that dragon's turn.

The park count only rises inside the judge's loop, when it resumes a bot and finds it still waiting for input:

```zig
fn suspendOn(self: *Instance, binding: *Binding) void {
    if (!self.may_run) {
        self.state = .frozen;
    } else {
        std.debug.assert(binding.syscall == .fd_read);
        self.state = .reading;
        self.parks += 1;
    }
}
```

And feeding a turn notes the count, appends the turn and lets the bot run, all on the same thread with no bot able to run in between:

```zig
pub fn write(self: *Instance, data: []const u8) !bool {
    if (self.state == .finished) return false;
    self.budget = MAX_TURN_POINTS;
    self.parks_snapshot = self.parks;
    self.calls = 0;
    try self.stdin.appendSlice(self.allocator, data);
    self.may_run = true;
    return true;
}
```

So the race is impossible by construction. There's no window to close with a lock, because nothing crosses a thread.

![Threads in the official sandbox, fibres in ours. In the official sandbox, a driver thread notes parks and feeds turns to dragon threads blocked in fd_read, and a new child's thread is already running, so it can reach its first read between the park count and the feed and be taken as done. In our judge, one thread per game holds the driver, the engine and every dragon, and a dragon's fibre pauses mid read and runs only when the driver resumes it, so no bot runs between noting the count and feeding a turn.](images/threads-fibres.svg)

The judge is written in Zig, for reasons [The choice](02-the-choice.md) goes into: it reads wasmtime's C headers directly, has no runtime of its own, and builds to a single binary. A batch runs one game per thread, with every bot in a game sharing that game's thread.

## Same games

A faster judge is only useful if it plays the same games. A probe bot, written to call every one of the starter helper's 40 functions, played six paired games through both hosts, with the same bot, engine, maps and seeds. That covered splits, sprints, both sonar formats, portals and replay annotations, over 15,296 dragon turns and 183,711 replay events. Every decoded event matched, and so did the probe's per-turn clock readings and each team's median, mean and maximum CPU points.

## Four times faster

Timed one game at a time on a Ryzen 7 5800X3D, with the same bot, map, seed, engine and replay output for both hosts:

| Game | Dragon turns | Official toolkit | Our judge | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Probe bot, Default | 6,662 | 3.16 s | 0.83 s | 3.8× |
| Older bot of ours, Arena | 1,961 | 3.14 s | 0.81 s | 3.9× |
| Older bot of ours, Default | 29,670 | 124.9 s | 28.2 s | 4.4× |

Each time is the median of three runs, including startup, compiling the WebAssembly and writing the replay. All twelve paired games, warm-ups included, produced identical replays. CPU time fell by about half in the short games and by three quarters in the long one, and peak memory fell from 467 MiB to 294 MiB in the long game.

![End-to-end wall time for one game, in seconds on a log scale. Probe bot on Default: 3.16 with the toolkit and 0.83 with our judge. Older bot on Arena: 3.14 and 0.81. Older bot on Default: 124.9 and 28.2. Median of three runs each on a Ryzen 7 5800X3D, with identical replays from both hosts.](images/judge-speed.svg)

The new host differs from the old one in two ways at once: a compiled loop in place of Python, and fibres in place of a thread per dragon with locks and condition variables between them. These timings don't separate the two.

## What the meter sees

Underneath the judge is the machine our bots actually run on, and it's a strange one. The meter charges for WebAssembly instructions: 1 point for most arithmetic and local variables, 2 for loads, stores, branches and vector instructions, 3 for division, more for calls. Wasmer compiles those instructions to real machine code before running them, but the price is set by the instructions, whatever the hardware does with them.

That makes the judge a CPU with no pipeline and no cache. A few loops show the difference, each run once in the judge and once natively. The code is in [examples/performance/machine-bot](../examples/performance/machine-bot/experiments.c), and `just machine` runs it:

| Loop | Natively | In the judge |
| --- | ---: | ---: |
| Sum floats with one running total | 1.50 ms | 24,117,351 points |
| Sum floats with four totals, so adds overlap | 1.10 ms | 24,117,363 points |
| Sum 8 MB of words in order | 1.1 ms | 33,564,773 points |
| Sum the same words 4 KB apart | 10.2 ms | 33,564,773 points |
| Sum the same words four at a time with SIMD | 0.11 ms | 5,242,996 points |

Four running totals let a real CPU overlap its additions, and the judge charges the same for both. A strided read misses the cache on every step and runs ten times slower natively, and costs exactly the same in the judge. Only vector instructions pay on both machines, because they do more work per instruction. In the judge, the way to make code cheaper is fewer instructions, and nothing else counts.

## Below the instruction set

Everything in this series has happened above one line. Strategy, algorithms, data layout and instruction choice are all software, running on hardware someone else designed, and in the judge even the instruction set is fixed. On a real computer the stack keeps going, down through the microarchitecture to FPGAs and custom silicon, each step trading flexibility for speed:

![An optimisation path down the computing stack, plotted against the time per operation after each fix on a log scale from 1 second to 10 microseconds. Fixes in product and architecture, data and execution, runtime and toolchain, operating system and services, and machine architecture sit above a dashed line marked software. Fixes with reconfigurable logic and application-specific silicon sit below it, marked hardware.](images/computing-stack.svg)

The judge stops our bots at WebAssembly. At [over|yonder](https://over-yonder.tech/) we work down the whole of that stack, including the part below the line.
