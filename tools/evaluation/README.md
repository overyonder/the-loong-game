# Evaluation tools

Build the Nim tools with `just tools-build`. Build the judge separately with
`just zig-judge-build` and register each bot with
`just bot-build SOURCE OUTPUT.wasm`.

Inputs are registered bots, map files and explicit seeds. `round-robin`
schedules every selected pairing, `batch` uses sequential comparison, and
`ladder` plays an offline rating ladder. Outputs are `results.json`,
summaries and per-game records. Each result directory's `store` link points
to retained files beneath `LOONG_STORAGE_ROOT`.

```sh
just round-robin --bots random random --maps tools/evaluation/maps/arena.map --sandbox --seeds 1 --output results/smoke
just report results/smoke
just regenerate --again results/smoke 001
just mapgen --count 4 --seed 2026 --output build/generated-maps
```

Run each command with `--help` for selection and scheduling options.
The public pool contains the random demonstration bot. Supply explicit
candidates and opponents for sequential evaluation. The standalone release
runs games locally and retains their replays.

`loong-build vector-remarks GUID PROFILE TEAM TOP` joins a saved compiler
sidecar to a judge profile. The performance article fixtures have their own
`examples/performance/justfile`: run `prepare` once, then `profile`,
`bench`, `machine`, `native` or `native-profile`. Preparation registers
the benchmark builds. The game recipes use the current judge and random
demonstration opponent.
