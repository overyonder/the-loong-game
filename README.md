# The Loong Game

An open source series running alongside the UNSW Battlecode competition: weird bot ideas, beginner tips, tools for `unswbc` and WASM performance deep dives.

Read the posts at [over-yonder.tech/games/loong](https://over-yonder.tech/games/loong/). Their sources are in [blog/](blog/README.md). Code from the posts is in [examples/](examples/), and the tools that make the figures are in [tools/](tools/).

Run the article tools from `examples/tooling` with Just. Command options and
process orchestration live in [just/](just/); Python modules hold reusable
algorithms and adapters to the organiser's toolkit.

| Article capability | Command | Domain owner |
| --- | --- | --- |
| Round robin | `just round-robin` | `harness/tournament.py` |
| Paired verdict | `just verdict` | `harness/verdict.py` |
| Map generation | `just mapgen` | `harness/mapgen.py` |
| Local ladder | `just ladder` | `harness/ladder.py` |
| Replay sampling | `just sample-replays` | `replays/collection.py` |
| Replay inspection | `just decode` | `replays/viewer` |
| Graphical and headless viewer | `just viewer` | `replays/viewer` |
| Profiling | `just profile`, `just native`, `just native-profile` | `examples/performance/justfile` |
| Zig judge | `just zig-judge-build`, `just zig-judge` | `harness/zig_judge` |

The Zig judge plays seeded sandbox games with the organiser's engine. Building it
needs Zig 0.16 and the wasmtime C API, named by `WASMTIME_INCLUDE` and
`WASMTIME_LIB`. With Nix:

```sh
export WASMTIME_INCLUDE=$(nix build --no-link --print-out-paths nixpkgs#wasmtime.dev)/include
export WASMTIME_LIB=$(nix build --no-link --print-out-paths nixpkgs#wasmtime.lib)/lib
cd examples/tooling
nix shell nixpkgs#zig nixpkgs#just -c just zig-judge-build
```

After the build, play one game from `examples/tooling`. `--a` and `--b` take
metered modules:

```sh
just zig-judge --engine <toolkit site-packages>/unswbc/unswbc_engine.wasm --map maps/default.map --a A.wasm --b B.wasm --seed 1
```

The simpler route is `harness/zig_judge/harness.py`, which meters bots itself and
plays batches from Python.

`just round-robin` plays every pair of bots on every map from both sides, in
parallel, and writes `results.json` and `summary.md` with a log and replay per
game. Add `--sandbox` to play in the judge's sandbox and `--seeds N` for
seeded, repeatable games. Seeded sandbox games are cached in `build/game-cache`
and reused while the bots, map and toolkit are unchanged. `just bot-build`
builds a bot once into the toolkit's own caches, as the round robin does before
it plays. `just verdict` and `just ladder` run their games through the round robin.

`article-bots` fetches the bundled maps, creates the starter bots and puts the
flood-fill bots from the posts in place. `first-bot`, `roles`, `tactics`,
`nim-bot` and `room-nim` build the article bots from Nim, and the first three
then judge them with `just verdict`. `unseen-maps` runs map generation followed
by two evaluations; `ladder-all` builds the article bots before running the
ladder; `deaths` summarizes decoded events. These recipes are workflows over
the owners above. Recipes marked
`[private]`, such as `_match` and `_profile-report`, are internal helpers.
Use `just COMMAND --help` for tools with option parsers and `just --show COMMAND`
for positional build and profiling recipes.

Profiling runs from `examples/performance`, whose justfile is the home of the
performance posts' recipes (`profile`, `bench`, `bench-maps`, `native`,
`native-profile`, `fast`, `rake` and `machine`). The private profiling commands
run these public copies. Run `just check-recipes` in both
example directories to check their inline Python. The release manifest,
[tooling-release.json](tooling-release.json), records the source and hash of each
shared file. Replay decoding, reconstruction, sampling, map generation, the round
robin, the Zig judge and Odin display are frozen copies of their canonical private
sources. Public export shows observations; private bot-state recovery and
competitive models are not included. `just viewer REPLAY --image board.png` saves the Odin display as a PNG;
it requires a display and OpenGL context. A headless Wayland or compatible X11
server can provide that context. `--no-display --export board.json` exports data
without a graphics context. Changes to shared code originate in the canonical source and are
released here together with refreshed hashes.

The verdict and ladder statistics retain the article-era experiments: in
particular, this ladder fits Bradley–Terry ratings, while the private running
ladder uses streaming Elo. Their historical provenance is recorded in the
manifest. Screenshots and measurements in the posts describe the recorded
experiments and have not been rerun.
