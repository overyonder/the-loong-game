# The Loong Game

An open source series running alongside the UNSW Battlecode competition: weird bot ideas, beginner tips, tools for `unswbc` and WASM performance deep dives.

Read the posts at [over-yonder.tech/games/loong](https://over-yonder.tech/games/loong/). Their sources are in [blog/](blog/README.md). Code from the posts is in [examples/](examples/), and the tools that make the figures are in [tools/](tools/).

Run the article tools from `examples/tooling` with Just. Command options and
process orchestration live in [just/](just/). Python modules schedule games, the
Zig judge plays them with the organiser's engine, and compiled Nim tools read
what the games leave.

| Article capability | Command | Domain owner |
| --- | --- | --- |
| Round robin | `just round-robin` | `harness/tournament.py` |
| Sequential verdict | `just batch`, `just verdict` | `harness/compare.py`, `harness/batch.py`, `harness/report` |
| Standard summary and ratings | `just report` | `harness/report` |
| Map generation | `just mapgen` | `harness/mapgen.py` |
| Map-variant fitting and lookup | `just map-variants` | `harness/map_variants.nim` |
| Replay regeneration | `just regenerate` | `harness/regenerate.nim` |
| Local ladder | `just ladder` | `harness/ladder.py` |
| Game data | `just gamedata`, `just decode`, `just deaths` | `gamedata` |
| Capped replay collection and retention | `just sample-replays` | `replays/collection.nim`, `replays/retention.nim` |
| Graphical viewer and decision recovery | `just viewer`, `just decisions`, `just showcase` | `replays/viewer`, `replays/recovery` |
| Build registry | `just bot-build` | `harness/build_registry.py` |
| Bot diagnostics runtime | `just showcase-bot` | `runtime` |
| Nim tools | `just tools-build` | `gamedata`, `harness/report`, `harness/profiling`, `harness/map_variants.nim`, `harness/regenerate.nim`, `replays` |
| Profiling | `just profile`, `just native`, `just native-profile` | `examples/performance/justfile` |
| Judge CPU points and compiler remarks | `just points-profile`, `just vector-remarks` | `harness/zig_judge`, `harness/profiling`, `harness/compiler.py` |
| Zig judge | `just zig-judge-build`, `just zig-judge`, `just judge-fidelity` | `harness/zig_judge` |

`just viewer-build` compiles the Odin viewer into `build/bin/viewer`. It needs
Odin, raylib, raygui, GLFW and OpenGL. raygui ships as a header only, so the
recipe first builds `build/lib/libraygui.so` from it and links the viewer
against that. With Nix:

```sh
cd examples/tooling
nix-shell -p odin raylib raygui glfw libGL just --run 'just viewer-build'
```

`just tools-build` compiles `loong-gamedata`, `loong-report`,
`loong-sample-replays`, `loong-recover`, `loong-profile`, `loong-map-variants`
and `loong-regenerate` into `build/bin`: seven binaries. The evaluation,
inspection and profiling commands use them, so build them first. They need
Nim 2.2 or newer, zlib, SQLite and OpenSSL. With Nix:

```sh
cd examples/tooling
nix-shell -p nim zlib sqlite openssl just --run 'just tools-build'
```

The Zig judge plays sandboxed games with the organiser's own engine module, which
it takes from the installed toolkit, and meters each bot with a port of the
toolkit's metering pass (`harness/zig_judge/src/metering.zig`). Its `run` mode
takes the arguments `unswbc run --sandbox` takes and writes the same log lines
and replay, and each dragon turn's judge points beside the replay as
`REPLAY.points.cols` (`src/run.zig`). Like the competition's judge, it leaves a
new process's first stdin read uncharged, and `run --charge-first-read` charges
it as the toolkit does. Its `--inspect` mode reruns a bot for the viewer's
recovery. The round robin, batch and ladder play in it by default. Building it needs Zig 0.16 and the wasmtime C API, named by
`WASMTIME_INCLUDE` and `WASMTIME_LIB`. With Nix:

```sh
export WASMTIME_INCLUDE=$(nix build --no-link --print-out-paths nixpkgs#wasmtime.dev)/include
export WASMTIME_LIB=$(nix build --no-link --print-out-paths nixpkgs#wasmtime.lib)/lib
cd examples/tooling
nix shell nixpkgs#zig nixpkgs#just -c just zig-judge-build
```

After the build, play one game from `examples/tooling`, with bots compiled by
`just bot-build`:

```sh
just zig-judge --engine <toolkit site-packages>/unswbc/unswbc_engine.wasm run --sandbox --seed 1 -o game.replay maps/arena.map A.wasm B.wasm
```

`--log FILE` sends the game's output to a file, and `--timeout SECONDS` ends it
with exit code 124 at that wall time. `harness/zig_judge/harness.py` runs the
judge from Python, one game or a batch on N threads.

The judge also offers served-team policy framing and a generic CPU lockstep
interface. Its bundled minimal CPU reference implements toolkit 1.2.2 rules:
one free move, then longest and total length for the verdict. It does not
implement later queen rules or their length-based free-move quota. A newer
official engine requires a matching replacement reference for lockstep.
The host accepts both 32-byte and 48-byte engine results but reports the
shared first eight fields. See the [judge README](harness/zig_judge/README.md)
for commands, inspection accounting and the replaceable reference interface.
The [harness README](harness/README.md) documents strict map fitting and
regeneration, and the [profiling README](harness/profiling/README.md) documents
CPU profiles and saved compiler sidecars.

`just judge-fidelity` checks that the judge matches the toolkit: it meters each
bot with both and compares the modules byte for byte, then plays each seeded game
in both, the judge charging first reads as the toolkit does, and compares the replays byte for byte and the logs line by line, apart
from timings. Run it after building the judge and after changing toolkit. By
default it plays `room-c` and `starter-c` on Arena and Portals.

`just round-robin` plays every pair of bots on every map from both sides, in
parallel, and writes `results.json` and `summary.md`, with a log, replay and
`result` record per game ([gamedata/format.md](gamedata/format.md)). Add
`--sandbox` to play in the judge's sandbox and `--seeds N` for seeded,
repeatable games. Sandboxed games between compiled bots play in the Zig judge;
`--engine toolkit` plays them through the toolkit instead, and Python bots and
unsandboxed games always play through the toolkit. `just batch` and `just
ladder` take the same `--engine`. Seeded sandbox games are cached in
`build/game-cache` and reused while the bots, map, toolkit and judge are
unchanged. `just bot-build` builds a
bot once into the toolkit's own caches, as the round robin does before it
plays, and registers a judge build in `build/registry` under a GUID, which it
prints with the WASM's path. The viewer reruns a registered build to rebuild its
dragons' decisions (`just viewer REPLAY --seat A GUID`). An existing `--output` is resumed, playing again only the games that did
not complete.

Every run's `summary.md` has the same form, rendered by `loong-report`: a
headline table of each candidate against each opponent with W–D–L, score,
implied Elo and its 95% interval and side-swapped pairs, then scores by map
group and map, then each side's deaths by cause and final size, and last an
Insights section that re-rendering keeps. `just report DIR... [--output OUT]`
renders it for any result directories. It writes into the first directory
unless `--output` says otherwise, so pass `--output` for a ladder, which keeps
its own `summary.md`.

`just batch --bots CANDIDATE` plays a sequential run and `just verdict --output
DIR --candidate CANDIDATE` judges it. Each opponent (default `room-c`) gets
Wald's sequential probability ratio test of a 50% score against a planned edge
(default +70 Elo, α 0.05, power 80%, at most 155 games), over the longest
completed prefix of a schedule that interleaves maps, sides and opponents from
the first game. With `--baseline BASE`, the candidate and the baseline both play
every fixture against the opponents, and each test counts only the fixtures the
two play differently. Ten games against `starter-c` check for upsets. The
docstring of `harness/compare.py` has the details. `verdict.md` adds the tests
to the standard summary, and `verdict.json` records them.

`just ladder` plays rounds in which each bot plays at most one game, from
frozen copies of the bots and maps, so an interrupted ladder continues with
`--resume`. After each round it fits Bradley–Terry ratings to every game so
far with `loong-report ratings` (`harness/report/rating.nim`), and writes
`results.json`, `ratings.csv` and `summary.md`, which holds the ratings and the
head-to-head table. The round robin reports ratings from the same fit.

`just mapgen` is xCirno's layered world generator
([gist](https://gist.github.com/xCirno1/ffdaac4236c1f1085c351af4fdfc1600)),
widened to the official maps' variety. It keeps a map only if every measure lies
within the range the organiser's maps in `maps/` span, so run `just article-bots`
first. The maps a seed gives depend on which toolkit's maps are installed.
`just mapgen --check DIR` compares DIR's maps with them. The module
docstring in `harness/mapgen.py` lists the stages and our additions.

`just decode REPLAY...` prints each replay's sides, map, result and event
counts, and `just deaths REPLAY...` each bot's deaths by the engine's cause.
Both read the packed Cap'n Proto replay directly with `loong-gamedata`. `just
sample-replays` collects public replays from the competition site, pacing its
requests and following its robots.txt, into `public-replays/` with a
`manifest.sqlite` of every battle and replay. No collection starts unless
invoked.

`article-bots` fetches the bundled maps, creates the starter bots and puts the
flood-fill bots from the posts in place. `first-bot`, `roles`, `tactics`,
`nim-bot` and `room-nim` build the article bots from Nim, and the first three
then judge them with `just batch` and `just verdict`. `unseen-maps` runs map
generation followed by two evaluations; `ladder-all` builds the article bots
before running the ladder; `deaths` summarizes decoded events. These recipes
are workflows over the owners above. Recipes marked
`[private]`, such as `_match` and `_profile-report`, are internal helpers.
Use `just COMMAND --help` for tools with option parsers and `just --show COMMAND`
for positional build and profiling recipes.

Profiling runs from `examples/performance`, whose justfile is the home of the
performance posts' recipes (`profile`, `bench`, `bench-maps`, `native`,
`native-profile`, `fast`, `rake` and `machine`). The private profiling commands
run these public copies. Run `just check-recipes` in both
example directories to check their inline Python. The release manifest,
[tooling-release.json](tooling-release.json), records the source and hash of each
shared file. Game data, reports, verdicts, replay reconstruction, sampling, map
generation, the round robin, the ladder, the Zig judge, the build registry, the
diagnostics runtime, decision recovery and the Odin viewer are copies of their
canonical private sources. Competitive bots and models are not included.
[replays/viewer/README.md](replays/viewer/README.md) describes the viewer and
[replays/viewer/diagnostics.md](replays/viewer/diagnostics.md) the records a bot
writes for it. [examples/showcase-bot](examples/showcase-bot/strategy.nim) writes
every kind, exposes its typed state from WebAssembly memory, and gives its roles
and tasks colours, head icons and body patterns. Recovery keeps full records in
a moving round window, resumes from memory-bounded checkpoints, and keeps a
small role-and-task summary for the whole-game chart. `just showcase` builds the
bot, plays it against itself and opens the game. `just viewer REPLAY --image board.png` saves the Odin display as a PNG;
it requires a display and OpenGL context. A headless Wayland or compatible X11
server can provide that context. `--no-display` only writes the game's columns.
Changes to shared code originate in the canonical source and are released here
together with refreshed hashes.

Screenshots and measurements in the posts describe the recorded experiments.
