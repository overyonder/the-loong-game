# The Loong Game

Read the [article series](https://over-yonder.tech/games/loong/), with sources
in [blog/](blog/README.md). This repository also releases frozen copies of our
game tools and demonstration bots.

The tool sources are frozen from private revision
`692e7e09353531c09cf1022bc6196f99ae073b33`.
[tooling-release.json](tooling-release.json) records source and release hashes.
Release adaptations provide local configuration and extract the generic game
engine from the shared bot library. Competitive policies and training remain
private.

Enter the pinned development environment with `nix develop`. Run each build
stage separately:

```sh
just setup
just tools-build
just zig-judge-build
just zig-native-build build/native cpu
just map-fit-build
just viewer-build
```

Setup downloads the pinned organiser wheel and extracts the engine and compiler.
The evaluation tools run as compiled Nim programs. The judge is Zig, its native
game engine is C++, and the viewer is Odin. CUDA complete-match builds use
`just zig-native-build OUTPUT cuda` with `NVCC`, `CUDART` and `CUDA_ARCH`
set for the selected toolkit and device.

| Tool | Inputs and outputs | Command |
|---|---|---|
| Bot builder | Source directory → registered WASM and build GUID | `just bot-build SOURCE OUTPUT` |
| Map generator | Seed and generation settings → map files | `just mapgen --help` |
| Tournament | Registered bots, maps and seeds → game records and replays | `just round-robin --help` |
| Sequential evaluation | Candidate and opponents → sequential game records | `just batch --help` |
| Offline ladder | Registered bots and maps → rounds and ratings | `just ladder --help` |
| Reports | Finished result directories → summaries and verdicts | `just report DIR`, `just verdict --output DIR` |
| Game data | Packed replay → mapped columns or event summary | `just gamedata REPLAY`, `just decode REPLAY` |
| Replay recovery | Replay, columns and registered builds → decision diagnostics | `just decisions` |
| Viewer | Game columns and optional recovered decisions → interactive display | `just viewer REPLAY [OPTIONS]` |
| Regeneration | Saved game record and registered builds → checked replay | `just regenerate RESULT_DIR GAME` |
| Map fitting | Replays and seeds → compatible spawn-gap tables | `just map-variants --help` |
| Public replay collection | Explicit team and selection → retained replays and manifest | `just sample-replays --own-team TEAM --help` |

Generated builds belong in `build/`; retained game files and registered
snapshots belong in `assets/`. Set `LOONG_STORAGE_ROOT` and
`LOONG_BUILD_REGISTRY` to choose other locations. The released tournament runs
locally.

[Examples](examples/) retain the bots and benchmark inputs from the articles.
The current random bot lives in [bots/random](bots/random/), and the viewer's
small diagnostic examples live in [tools/viewer/examples](tools/viewer/examples/).
Historical article links select the corresponding committed source where the
tool implementation has since changed.

Publishing utilities, including figure generators, the shared palette and
terminal captures, live in [Over Yonder's tools](https://github.com/overyonder/over-yonder.tech/tree/main/tools).
The article benchmark chart recipe uses that sibling checkout.
