# CPU points and compiler remarks

The profile counts judge CPU points by function and operator class. It
measures the game policy under the supplied engine; it is not a wall-time
CPU sampler. Build the tools and judge first, then use the existing build
stage to retain names and compiler remarks alongside a bot:

```sh
cd examples/tooling
just bot-build starter-c
just points-profile /path/a.wasm /path/b.wasm maps/arena.map 123 /path/game.replay
just vector-remarks BUILD_GUID /path/game.profile.tsv A 25
```

`bot-build` compiles each C/C++ translation unit once with the organiser's
clang and vectoriser optimization records enabled. It links those same
objects into the stripped playing module and a temporary named module.
`loong-profile` extracts names from the latter; the named module is not
registered. The immutable build stores `judge.wasm`, `judge.names`,
`judge.remarks.tsv`, the source snapshot and their SHA-256 hashes in
`manifest.json`. The source and compiler settings, including the adapter's
hash, determine the build GUID. Existing builds without sidecars remain
readable; rebuild sources to get a new build with sidecars.

The name file has `function_index<TAB>raw_name`, without a header. The
remarks TSV has columns `function`, `pass`, `kind`, `name`, `where`,
`message`. It contains LLVM loop-vectorize and slp-vectorizer records,
including missed transformations when the compiler emits them. It does
not claim every loop has a record. The decoder handles this selected LLVM
record format, not arbitrary YAML.

A profiled game writes `game.profile.tsv` with columns:

```text
team function name arithmetic locals memory simd calls control other total
```

They are tab separated. `team` is A or B. Each function row reports points
in the seven classes. Host-call rows have a blank function index and report
their charged cost in `total`. These costs include ordinary stdout writes;
printing more diagnostics during play can change the budget. Operator
classes describe charged work, not a judgment of bot quality.

`vector-remarks BUILD_GUID` alone prints saved remarks. With a profile, it
joins raw function names and prints `function`, `name`, `total`, `simd`,
`remarks` for the busiest functions on the chosen side. Inlining can leave
remarks on a source function that no longer has a separate WASM body.

The standalone compiled decoder commands are:

```sh
../../build/bin/loong-profile names named.wasm bot.names
../../build/bin/loong-profile remarks bot.remarks.tsv unit.yaml
../../build/bin/loong-profile join bot.remarks.tsv game.profile.tsv A 25
```

Profiling changes the metered module to add counters. Counters themselves
are uncharged and the original policy costs remain in the budget. Use
matching modules and `.names` sidecars; names from another build can label
the wrong function indices. A profile of a served or scripted team does
not measure an external policy's compute.
