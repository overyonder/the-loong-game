# Judge

`loong-judge` runs compiled bots with the official engine, records replays
and CPU points, and reruns recorded observations for inspection. It takes
an engine WASM file rather than embedding one. Build it with `just
zig-judge-build` from `examples/tooling`; prerequisites are in the
[harness README](../README.md).

```sh
just zig-judge --engine ENGINE.wasm --timeout 300 run --sandbox --seed 123 \
  -o /path/game.replay maps/arena.map /path/a.wasm /path/b.wasm
```

`run` writes the replay and its `.points.cols` sidecar. `--profile` also
writes `.profile.tsv`, described under [profiling](../profiling/README.md).
`--script-a FILE` or `--script-b FILE` uses recorded replies on that side;
its TSV rows are `round<TAB>dragon<TAB>reply`, with `|` separating reply
lines. `--charge-first-read` enables the toolkit's startup-read accounting
for fidelity comparisons. The default treats the first stdin read as free.

The host allocates and reads the twelve-int engine result, including queen
and longest-dragon lengths. An older eight-int engine leaves the extra fields
zero. Rule behaviour comes from the selected engine. The bundled native
reference implements the SDK 1.2.7 rules and is selected only explicitly;
see its [build commands, C ABI and limits](reference/README.md).

```sh
just zig-judge --engine ENGINE.wasm --native-library /path/libloong-native-cpu.so \
  --charge-first-read --timeout 300 run --sandbox --seed 123 \
  -o /path/native.replay /path/map.map /path/a.wasm /path/b.wasm
```

For CUDA jobs, select the CUDA library and add `--cuda-batch N --threads T`.
The ordinary official-engine path, metering, inspection and jobs figures remain
available through the same host. Native simulation does not replace WASM bot
execution. The selectors precede `run` and do not install a default.

## Inspection

```sh
just zig-judge --inspect /path/request.json --a /path/bot.wasm \
  --output /path/response.jsonl
```

The request supplies one dragon's init block and chronological observations:

```json
{"init":"...","name":0,"initial_protocol":1,"state":false,
 "loud_from":0,"loud_until":10,
 "observations":[{"v1":"...","v3":"..."}]}
```

Both blocks are required for each observation. A bot's `PROTOCOL 3` reply
selects `v3` on following turns. Each response line contains `reply`,
`annotations`, `failure` (null or a string), `points`, `memory`, and `traced`.
Bots that expose memory or decision records may add `state`, `trace` or
`state_offered`; see [diagnostics.md](../../replays/viewer/diagnostics.md).

`--inspect - --a FILE.wasm` keeps a loaded module for multiple requests. It
prints `inspection-server 1`, accepts `REQUEST<TAB>RESPONSE` file paths one
per stdin line, and answers `ok` or `failed`. Each request starts a fresh
bot instance. Linux recovery clients can also use fork checkpoints; their
FIFO protocol and owner lifetime are documented in `src/inspection.zig`.

`inspection.h` declares the inspection-only `loong_inspection` imports:
`begin`, `end`, `write`, and `log`. Inside balanced begin/end blocks, observer
computation spends a separate metered allowance. Reported policy points and
the bot's virtual clock exclude that computation. `write` appends one JSON
diagnostic line; `log` appends one text line. Their output stays separate
from the action reply. Text must be UTF-8 without embedded newlines.

Observers may inspect state but must not alter policy state or choices.
The host freezes the clock and rejects gameplay I/O, randomness and yields
inside an observer block. It cannot enforce read-only guest memory. The
separate observer allowance is finite, as is the 64 MiB annotation buffer;
an exhausted observer still fails inspection. These imports are available
only in inspection, so use a separate inspection build rather than
submitting a module that imports them. Legacy stdout gizmo macros remain
supported, but do not become uncharged merely by printing a diagnostic line.

## Served team

An external policy process can answer one team over a local UNIX stream
socket. Start its listener, then run:

```sh
just zig-judge --engine ENGINE.wasm --map maps/arena.map \
  --a /path/opponent.wasm --b /path/opponent.wasm --seed 123 \
  --serve /path/policy.sock --serve-team B --replay /path/served.replay
```

The judge connects and sends these ASCII headers, each terminated by LF.
Blocks follow immediately as the specified number of bytes, with no extra
separator. Only `TURN` expects a reply.

| Header | Body or response |
| --- | --- |
| `GAME seed A|B` | Game seed and served side |
| `SPAWN id bytes` | Init block follows |
| `TURN id bytes` | Observation follows; answer `bytes\n` followed by reply text |
| `DEATH id` | Dragon ended |
| `END A|B|- rounds` | Result and number of completed rounds |

The served side needs no WASM module. Both teams may be served with
`--serve-a SOCKET_A --serve-b SOCKET_B`, using separate listeners or one shared
listener. Served decisions have no WASM CPU-point measurement. Transport replies
are limited to 1 MiB and native callbacks also require SDK-sized frames.
A disconnected server supplies empty replies. Use `--timeout 300` to bound a
blocked server, or an external `timeout`.

## Lockstep

The generic runner gives two implementations the same deterministic replies
and compares dragon IDs and observation blocks byte for byte, then compares
the result. Its policy exercises movement, sprints, splits, sonar, protocol
changes and rejected actions.

```sh
printf '%s\n' "$PWD/maps/arena.map" > /tmp/maps.txt
just zig-judge --engine ENGINE.wasm --lockstep /tmp/maps.txt --games 2 --seed 123
```

`reference/port.h` is the replaceable C interface: create, next observation,
apply reply, result and destroy. `next` returns a dragon ID, or -1 at end;
the result holds twelve integers as labelled in the header. Build another CPU
implementation with `just zig-judge-build -Dreference-source=/path/host.cc`.
Map files are ordinary local inputs. A mismatch, unsupported map or empty
map list makes lockstep exit nonzero; skipped games never count as passes.

The bundled CPU reference implements SDK 1.2.7 queen scoring and its free-move
quota. Lockstep compares zero-based rounds, both teams' counts, queen/longest/total
lengths and overflow. The old 1.2.2 implementation is available in Git history;
historical measurements keep their original rule/source identities. Passing
a finite lockstep run establishes agreement only for those games. The generic
CPU and CUDA replay libraries share this simulation; learning code and the
private benchmark runner are excluded.
