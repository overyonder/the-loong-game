# Game data

`loong-gamedata` converts a packed Cap'n Proto replay into a `game` columns file
([format.md](format.md)), which the viewer maps directly. From a game file it
also rebuilds each decision's bot-visible input (`observations`, which
diagnostic recovery reruns bots on) and computes the game's `result`, and it
merges a run's results into one file. `decode` summarises replays straight from
their events.

- Input: a `.replay`, and its judge points when present (`REPLAY.points.cols`
  beside it, or `store/<name>.points.cols` in its result directory).
- Output: `REPLAY.cols` beside the replay, or the given path. Every file is
  written under a `.partial` name and renamed, so readers never see it half
  written.
- Commands: `just tools-build` compiles `build/bin/loong-gamedata`. `just
  gamedata REPLAY [OUTPUT]` converts one replay. `loong-gamedata result OUTPUT --game GAME.cols
  [options]` writes one game's result, `loong-gamedata merge-results OUTPUT
  INPUT...` merges results, `loong-gamedata observations GAME.cols OUTPUT`
  rebuilds decisions' inputs, and `just decode REPLAY... [--deaths]` prints each
  replay's sides, result and event counts, or every bot's deaths by cause.
  Run `loong-gamedata` alone for the options. The
  viewer, its recovery server and the harness call the binary themselves.
