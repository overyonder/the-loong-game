# Game data

`loong-gamedata` converts a packed Cap'n Proto replay into a `game` columns file
([format.md](format.md)), which the viewer maps directly. From a game file it
also rebuilds each decision's bot-visible input (`observations`, which
diagnostic recovery reruns bots on) and computes the game's `result`, and it
merges a run's results into one file. `decode` summarises replays straight from
their events. All consumers use the compiled tools or Nim modules directly.

- Input: a `.replay`, and its judge points when present (`REPLAY.points.cols`
  beside it, or `store/<name>.points.cols` in its result directory).
- Output: `REPLAY.cols` beside the replay, or the given path. Every file is
  written under a `.partial` name and renamed, so readers never see it half
  written.
- Commands: `just tools-build` compiles `build/bin/loong-gamedata` for glibc
  2.28, so the same binary runs here and on fleet workers. `just gamedata REPLAY
  [OUTPUT]` converts one replay. `loong-gamedata result OUTPUT --game GAME.cols
  [options]` writes one game's result, `loong-gamedata merge-results OUTPUT
  INPUT...` merges results, `loong-gamedata observations GAME.cols OUTPUT`
  rebuilds decisions' inputs, and `just decode REPLAY... [--deaths]` prints each
  replay's sides, result and event counts, or every bot's deaths by cause.
  `loong-gamedata regeneration REPLAY [SCRIPT_A SCRIPT_B]` prints a ladder
  replay's pearl spawns and writes each side's recorded replies as the judge's
  scripts. `loong-gamedata compare SITE PLAYED` finds where a regenerated
  game's state first departs from the site's. `just regenerate` calls both,
  and `just map-variants` reads the spawns. Run `loong-gamedata` alone for the options. The
  viewer, its recovery server and the fleet worker call the binary themselves.

The canonical replay schema retains SDK 1.2.7's team-owned queen lengths and
known/unknown seed union. The decoder writes `standing.queen_length`,
`meta.seed` and `meta.seed?`; unknown seed differs from known zero. Older
replays retain zero queen length and unknown seed defaults. Added columns do
not change the recorded replay's rule identity.

Nim consumers share `observations.observe(board, dragon)` for the init and
protocol-3 turn strings. It consumes waiting sonar and echoes once per turn.
Unknown countdowns remain `-1`; the reconstruction limits are in
[format.md](format.md#kind-observations-version-1). The independent protocol
check runs with `just test-reverse` after `just tools-build` and
`just zig-judge-build`. Its Nim served-team fixture captures inputs from the
official engine through the Zig judge and compares replay reconstruction for
growth, splits, sonar, portals, sprint substeps and wrapping. Temporary maps,
replays and columns live under `assets/checks/` and are removed after the run.
