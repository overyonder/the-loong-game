# Zig judge

Build with `just zig-judge-build`. The pinned Wasmtime C API and Zig compiler
come from `nix develop`; `just setup` extracts the official engine and
compiler from the pinned organiser wheel.

Input: a map, two compiled WASM bots and a seed. Output: the game log, packed
replay and per-turn points columns.

```sh
just zig-judge --engine build/toolkit/unswbc/unswbc_engine.wasm run --sandbox --seed 1 -o assets/game.replay tools/evaluation/maps/arena.map build/random.wasm build/random.wasm
```

Use `--native-library PATH` before `run` to select a separately built
native replay library. `--jobs FILE --threads N` plays a prepared batch.
`--script-a FILE` and `--script-b FILE` replay recorded replies.
Inspection re-executes registered bots for the viewer's recovery service.

`--lockstep MAP_LIST --games N` compares the native text interface with
the official WASM engine after every turn. `--lockstep-cases` checks the
independently specified queen-rule cases. Supply the official module through
`--engine` for both checks.
