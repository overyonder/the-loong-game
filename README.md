# The Loong Game

An open source series running alongside the UNSW Battlecode competition: weird bot ideas, beginner tips, tools for `unswbc` and WASM performance deep dives.

Read the posts at [over-yonder.tech/games/loong](https://over-yonder.tech/games/loong/). Their sources are in [blog/](blog/README.md). Code from the posts is in [examples/](examples/), and the tools that make the figures are in [tools/](tools/).

Run the article tools from `examples/tooling` with Just. Command options and
process orchestration live in [just/](just/); Python modules hold reusable
algorithms and adapters to the organiser's toolkit.

| Article capability | Command | Domain owner |
| --- | --- | --- |
| Round robin | `just round-robin` | `harness/round_robin.py` |
| Paired verdict | `just verdict` | `harness/verdict.py` |
| Map generation | `just mapgen` | `harness/mapgen.py` |
| Local ladder | `just ladder` | `harness/ladder.py` |
| Replay sampling | `just sample-replays` | `src/replays/collection.py` |
| Replay inspection | `just decode` | `src/viewer` |
| Graphical and headless viewer | `just viewer` | `src/viewer` |
| Profiling | `just profile`, `just native`, `just native-profile` | `examples/performance/justfile` |

`unseen-maps` runs map generation followed by two evaluations; `ladder-all`
builds the article bots before running the ladder; `deaths` summarizes decoded
events. These recipes are workflows over the owners above. Recipes marked
`[private]`, such as `_match` and `_profile-report`, are internal helpers.
Use `just COMMAND --help` for tools with option parsers and `just --show COMMAND`
for positional build and profiling recipes.

Profiling runs from `examples/performance`. Run `just check-recipes` in both
example directories to check their inline Python. The release manifest,
[tooling-release.json](tooling-release.json), records the source and hash of each
shared file. Replay decoding, reconstruction, sampling, map generation and Odin
display are frozen copies of their canonical private sources. Public export
shows observations; private bot-state recovery and competitive models are not
included. `just viewer REPLAY --image board.png` saves the Odin display as a PNG;
it requires a display and OpenGL context. A headless Wayland or compatible X11
server can provide that context. `--no-display --export board.json` exports data
without a graphics context. Changes to shared code originate in the canonical source and are
released here together with refreshed hashes.

The three evaluation libraries retain the article-era experiments: in
particular, this ladder fits Bradley–Terry ratings, while the private running
ladder uses streaming Elo. Their separate historical provenance is recorded in
the manifest. They are fixtures for reproducing these articles, not independent
implementations of the current private evaluation system. Screenshots and
measurements in the posts describe the recorded experiments and have not been
rerun as part of the command cleanup.
