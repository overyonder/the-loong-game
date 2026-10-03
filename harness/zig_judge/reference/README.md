# Native engine references

The CPU and CUDA libraries play complete games and export packed Cap'n Proto
replays through ABI 1 in `native.h`. They share the same fixed-array simulation,
text protocol, reply parser and replay serializer. This source implements the
queen scoring and free-move rules checked against SDK 1.2.7, engine SHA-256
`26e68680e45eb0f221db702aead9eefde776c2ad2ba066f4ddf8c12500c6a546`.
Queens are raw IDs 0/1, assigned to their recorded owners; either team may
appear first in a map. Historical measurements retain their original rules
and source identities.

## Build

Use C++20 and Cap'n Proto's C++ development libraries and code generator.
The checked source toolchains are Clang 20.1.8 and Cap'n Proto 1.4.0 for CPU;
GCC 14.3.0, nvcc 12.8.93 and CUDART 12.8.90 for CUDA. CUDA additionally needs
pthreads and an NVIDIA driver/device supporting the selected architecture.
The tested target is `sm_120`. No Rake compiler is needed.

From `examples/tooling`, select the installed dependency packages:

```sh
CAPNP_PREFIX=/path/to/capnproto CXX=clang++ just zig-native-build cpu

CAPNP_PREFIX=/path/to/capnproto CXX=g++ NVCC=/path/to/nvcc \
  CUDART=/path/to/cudart CUDA_ARCH=120 just zig-native-build cuda
```

The commands build `build/native-reference/BACKEND/libloong-native-BACKEND.so`.
They generate bindings from the existing canonical
`replays/viewer/replay.capnp`, record input/generated/library SHA-256s in
`hashes.tsv`, and write compiler versions and flags beside the library.
An existing output directory is refused. To choose another output directory,
run `bash harness/zig_judge/reference/build-native.sh OUTPUT cpu|cuda` from
the repository root. No build installs a library or runs a game.

CUDA compilation emits an ahead-of-time `sm_120` image, with no PTX image
or runtime PTX JIT fallback. `CUDA_ARCH` can select another architecture
supported by nvcc, but that does not establish runtime agreement there.
CUDA C++ compiles to native device code; CUDA is the compiler/runtime approach
used here. Rake's GPU backend is a separate proposed implementation.

## Use through the judge

Build the host separately with `just zig-judge-build`. The ordinary official
WASM engine remains its default. Select a native library explicitly:

```sh
just zig-judge --engine /path/unswbc_engine.wasm \
  --native-library ../../build/native-reference/cpu/libloong-native-cpu.so \
  --charge-first-read --timeout 300 run --sandbox --seed 123 \
  -o /path/cpu.replay /path/map.map /path/a.wasm /path/b.wasm

just zig-judge --engine /path/unswbc_engine.wasm \
  --native-library ../../build/native-reference/cuda/libloong-native-cuda.so \
  --cuda-batch 4 --threads 4 --charge-first-read \
  --jobs /path/jobs.tsv --debug 31
```

The engine argument identifies the ordinary reference module loaded by the
host; the explicitly selected library runs simulation. Both paths run live
WASM bots in the existing metered host. They preserve seeded randomness,
fresh-worker retries, framing and spawn/death callbacks. CUDA accelerates
simulation; bots and text/replay serialization run on host CPUs. For one
`run`, CUDA uses one game. Jobs process up to `--cuda-batch N` games per wave,
with at most `--threads T` persistent reply workers. CPU-only libraries refuse
CUDA selection. There is no silent CPU simulation fallback.

`run` writes the packed replay, `.points.cols` and the existing match log.
Jobs use the ordinary eight-field input TSV: job ID, map, A WASM, B WASM,
seed, replay path, A name, B name. They print the existing figures TSV, prefixed
by job ID, including per-team point aggregates. Jobs do not export per-turn
points. `--charge-first-read` selects SDK first-read accounting; the default
retains ladder accounting. `--debug 31` includes SDK-limited logs, drawings,
indicators and parse errors. Replay instruction metadata is not inferred from
the points sidecar.

## ABI and lifetime

`native.h` is the complete C ABI. `loong_native_abi()` returns 1. A CPU match
is create -> run -> replay -> destroy. CUDA also exposes create -> next ->
apply -> result/replay -> destroy; `cuda_run` drives those waves using the
supplied callbacks. Each game has one outstanding raw-ID decision. Device
completion precedes host access to observations/events, and lifecycle callbacks
finish before the next turn.

The result has twelve signed 32-bit fields: last zero-based round, winner
(0 draw, 1 A, 2 B), end reason, A/B dragon counts, A/B total lengths, event
count, A/B queen lengths, A/B longest lengths. Callback blocks/replies and
exported replay bytes are borrowed, as documented in the header. Copy replay
bytes before mutating or destroying the match. Keep callback contexts alive
until destruction; CUDA callbacks can run concurrently for different games.

The plain CPU lockstep port in `port.h` has its own twelve-int result order;
do not pass an ABI 1 result buffer to a consumer expecting that order.

## Bounds and evidence

Maps are 7–64 cells per side, with at most 64 living dragons per team.
The shared engine retains fixed turn-order and sonar-inbox capacities. Native
replies obey the SDK's 10 KiB frame bound. Allocation, overflow, CUDA or event
capacity failures refuse a complete export; no replay is truncated to claim
success. The first correct CUDA implementation copies full Game snapshots
and drains ordered events after each decision. Its transfer and host-policy
costs belong in complete-match timing.

The committed source passed CPU/official/CUDA scripted queen, physical-sonar,
round-reply and callback checks; SDK22 live-bot pilots compared full packed
replays in both seats. CPU per-turn points and CUDA exported aggregates agreed.
Those finite checks are not proof for every map or bot. The public extraction
removes learner tensors, observation encoders, training actions and all training
exports. `tooling-release.json` records its exact source/adaptation identities.
The clean export builds the host and both libraries. Its CPU replay and per-turn
points checks matched the official engine in both initial team orders. The three
exported CUDA device kernels have identical instruction-section bytes to the
tested source build. The extracted CUDA library has no fresh GPU runtime result;
its source-specific runtime evidence retains the original build identities.
Full CUDA workload timing and paired profiler overhead remain unmeasured; no
throughput claim follows from releasing this reference.
