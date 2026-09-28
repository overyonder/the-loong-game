# The Loong Game

An open source series running alongside the UNSW Battlecode competition: weird bot ideas, beginner tips, tools for `unswbc` and WASM performance deep dives.

Read the posts at [over-yonder.tech/games/loong](https://over-yonder.tech/games/loong/). Their sources are in [blog/](blog/README.md). Code from the posts is in [examples/](examples/), and the tools that make the figures are in [tools/](tools/).

Run the article tools from `examples/tooling` with Just. Command options and
process orchestration live in [just/](just/). Python modules run games through
the organiser's toolkit, and compiled Nim tools read what the games leave.

| Article capability | Command | Domain owner |
| --- | --- | --- |
| Round robin | `just round-robin` | `harness/tournament.py` |
| Sequential verdict | `just batch`, `just verdict` | `harness/compare.py`, `harness/batch.py`, `harness/report` |
| Standard summary and ratings | `just report` | `harness/report` |
| Map generation | `just mapgen` | `harness/mapgen.py` |
| Local ladder | `just ladder` | `harness/ladder.py` |
| Game data | `just decode`, `just deaths` | `gamedata` |
| Replay sampling | `just sample-replays` | `replays/collection.nim` |
| Graphical and headless viewer | `just viewer` | `replays/viewer` |
| Nim tools | `just tools-build` | `gamedata`, `harness/report`, `replays` |
| Profiling | `just profile`, `just native`, `just native-profile` | `examples/performance/justfile` |
| Zig judge | `just zig-judge-build`, `just zig-judge` | `harness/zig_judge` |

`just viewer-build` compiles the Odin viewer into `build/bin/viewer`. It needs
Odin, raylib, raygui, GLFW and OpenGL. raygui ships as a header only, so the
recipe first builds `build/lib/libraygui.so` from it and links the viewer
against that. With Nix:

```sh
cd examples/tooling
nix-shell -p odin raylib raygui glfw libGL just --run 'just viewer-build'
```

`just tools-build` compiles `loong-gamedata`, `loong-report` and
`loong-sample-replays` into `build/bin`. The round robin, batch, ladder, verdict,
report, decode and replay sampling run them, so build them first. They need Nim,
zlib, SQLite and OpenSSL. With Nix:

```sh
cd examples/tooling
nix-shell -p nim zlib sqlite openssl just --run 'just tools-build'
```

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
parallel, and writes `results.json` and `summary.md`, with a log, replay and
`result` record per game ([gamedata/format.md](gamedata/format.md)). Add
`--sandbox` to play in the judge's sandbox and `--seeds N` for seeded,
repeatable games. Seeded sandbox games are cached in `build/game-cache` and
reused while the bots, map and toolkit are unchanged. `just bot-build` builds a
bot once into the toolkit's own caches, as the round robin does before it
plays. An existing `--output` is resumed, playing again only the games that did
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
generation, the round robin, the ladder, the Zig judge and Odin display are
copies of their canonical private sources. Public export shows observations;
private bot-state recovery and competitive models are not included. The viewer
reads replays with [pycapnp](https://github.com/capnproto/pycapnp), so install
it into the Python that `LOONG_PYTHON` names, such as the toolkit's. `just viewer REPLAY --image board.png` saves the Odin display as a PNG;
it requires a display and OpenGL context. A headless Wayland or compatible X11
server can provide that context. `--no-display --export board.json` exports data
without a graphics context. Changes to shared code originate in the canonical source and are
released here together with refreshed hashes.

Screenshots and measurements in the posts describe the recorded experiments.
