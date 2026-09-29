# Loong columns

One binary format for game data: the viewer's games, and the
per-game and per-run records that the collector, verdict and reports read. A
file holds named columns, each one contiguous array of fixed-size values, so a
reader maps the file and uses each column in place with no parse step.

Compiled code writes and reads it: `columns.nim` here for Nim tools and
`columns.odin` in the viewer.

## Container, version 1

All values are little-endian.

The header is 64 bytes:

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 8 | bytes | magic `LOONGCOL` |
| 8 | 4 | u32 | container version, 1 |
| 12 | 4 | u32 | number of columns |
| 16 | 8 | u64 | byte offset of the directory |
| 24 | 8 | u64 | file length, for a truncation check |
| 32 | 32 | bytes | kind, ASCII, NUL-padded: what the file holds, such as `game` |

The directory has one 80-byte entry per column:

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 48 | bytes | name, ASCII, NUL-padded |
| 48 | 1 | u8 | value type |
| 49 | 7 | bytes | reserved, zero |
| 56 | 8 | u64 | number of values |
| 64 | 8 | u64 | byte offset of the first value, a multiple of 8 |
| 72 | 8 | bytes | reserved, zero |

Value types: 1 u8, 2 i8, 3 u16, 4 i16, 5 u32, 6 i32, 7 u64, 8 i64, 9 f32,
10 f64.

**Tables.** A column named `table.field` belongs to `table`, and each table has
its own row count: every plain column of a table has one value per row. A
column that refers to rows of another table is a u32 row index named after that
table, such as `window.side`.

**Lists.** A per-row list `table.field` is two columns: `table.field` holds every
row's values end to end, and `table.field#` (u64, rows + 1 values) holds where
each row's values start, so row `i` is `field[start[i] ..< start[i + 1]]`. A
string is a list of u8 holding UTF-8.

**Absent values.** A column whose value can be absent has a companion
`table.field?` (u8 per row: 1 present, 0 absent). Values in absent rows are
unspecified. Columns that are always present have no companion.

**Enums.** An enum column holds small unsigned integers. Its names are the
string list `enum.<name>`, read by index, and the column's documentation names
the enum.

**Empty tables.** A writer declares every column of its kind, so a table with no
rows still has its columns, with no values and list starts of `[0]`.

**Files are immutable.** A writer builds a file beside its destination and
renames it into place. Per-game records are one file per game, written when the
game lands. A run's all-games file is written when the run ends.

**Merging.** `loong-gamedata merge-results OUTPUT INPUT...` appends files of one
kind table by table. `meta` and `enum.*` come from the first input, list starts
are shifted past the values before, and a u32 row index named after a table in
the same file (`side.game`) is shifted past that table's rows before. A kind
meant to be merged refers to another file's rows under another name.

**Compatibility.** Readers look columns up by name and ignore names they don't
know. Adding a column keeps a kind's version. Removing a column a reader needs,
or changing one's type or meaning, raises the kind's version, which each kind
records in its `meta.version` column.

## Kind `game`, version 1

`just gamedata REPLAY` writes `REPLAY` with the suffix `.cols` from the replay
and, when present, its `points` file. The viewer rebuilds any board by
applying `event` rows forward, so no board is stored per turn.

Cells are `y * width + x`. Teams are 0 for A and 1 for B. Directions are 0 N,
1 E, 2 S, 3 W.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32, `width` u32, `height` u32, `winner` i8 (-1 draw), `end_reason` u16, `replay_format` u32, `map_name`, `bot_a`, `bot_b`, `map_text` (strings) | 1 |
| `edge` | `x`, `y` u32, `side` u8 (0 the cell's north edge, 1 its west), `portal` i32 (-1 kelp) | one per non-empty edge |
| `spawn` | `cell` u32, `minimum`, `maximum` i32 | one per spawning tile |
| `start` | `dragon` u32, `team` u8, `body` (list of u32 cells, head first) | the map's starting dragons |
| `event` | `kind` u8, `a`, `b`, `c`, `d` i32 | every board event, in replay order |
| `split` | `parent_body`, `child_body` (lists of u32 cells, head first), `child_facing` u8 | one per split, in order |
| `round` | `event` u32 (its round-start row) | one per round |
| `turn` | `round` u32, `dragon` u32, `team` u8, `event` u32 (its turn-start row), `action` (string: `MOVE` and its directions, `SPLIT` and its length, `SUICIDE`, `NO_ACTION`, or empty when the turn recorded no action), `points` u64 (with `points?`), `failure` (string), `log` (string: the turn's dragon log lines, newline-separated) | one per dragon turn, in replay order |
| `ping` | `round` i32, `sender` i32, `hit` i32 (-1 none), `hit_kind` u16, `direction` u8, `origin`, `end` u32, `value` u64, `event` u32 (rows of `event` before it), `received_round` i32 (the round its target next took a turn, or -1) | one per sonar ping, in replay order |
| `standing` | `units`, `longest`, `total_length` u32 | the final standings, team A then B |

`event.kind` and the meaning of its fields:

| Kind | Event | `a` | `b` | `c` | `d` |
| ---: | --- | --- | --- | --- | --- |
| 1 | round start | round | | | |
| 2 | turn start | dragon | | | |
| 3 | pearl countdown | cell | countdown | | |
| 4 | tile change | cell | has pearl (0/1) | | |
| 5 | dragon moved | dragon | new head cell | tail cell after | facing |
| 6 | dragon split | parent | child | child team | row of `split` |
| 7 | dragon death | dragon | reason code | | |

A pearl countdown makes the tile due at the current round plus the countdown.
A move puts the new head first and drops tail cells until the body ends at
`c`. A split replaces the parent's body and adds the child. Judge points exist
only for games the Zig judge played; elsewhere
`turn.points?` is 0.

## Kind `points`, version 1

Each dragon turn's judge points, written beside a sandboxed match's replay as
`REPLAY.points.cols` by the Zig judge (`harness/zig_judge/src/run.zig`). The
`game` converter carries them into `turn.points`.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32 | 1 |
| `turn` | `round` i32 (-1 before round 0), `dragon` u32, `points` u64, `failure` (string: the toolkit's reason the turn gave no reply, such as `exceeded CPU limit`, or empty) | one per dragon turn, in the order played |

## Kind `observations`, version 1

Each decision's bot-visible input, rebuilt from a `game` file by
`loong-gamedata observations GAME.cols OUTPUT [--dragons ID,ID...] [--lenient]`,
and by recovery (`loong-recover`) for as long as it
reads them: the init block and the observation block the engine sent at the dragon's turn
start, byte for byte. A turn with no recorded action has no decision. A body
whose heading two directions explain fails the rebuild (exit 3) unless
`--lenient`, which takes the first and counts it in `meta.ambiguous`.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32, `ambiguous` u32 | 1 |
| `decision` | `turn` u32 (row of the game's `turn`), `init`, `observation` (strings) | one per decision, in game order |

## Kind `result`, version 1

How one game was played and ended, and each side's economy, for the collector,
verdicts and reports. `loong-gamedata result OUTPUT --game GAME.cols` computes
it from the game's columns in one pass over its events, with the harness's facts
as options (`loong-gamedata` without arguments lists them). Without `--game` it
records a game that left no replay: its status and harness facts, with the
`rounds?`, `winner?` and `result?` companions 0 and each side's economy 0. A
run's games merge into one file of this kind.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32 | 1 |
| `game` | `map` (string), `map_tiles` u32, `seed` u64, `rounds` u16 (rounds played, with `rounds?`), `winner` u8 (enum `winner`, with `winner?`), `result` u8 (enum `result`, the replay's end reason, with `result?`), `status` u8 (enum `status`), `exit_code` i32, `elapsed_seconds` f32, `slot_seconds` f32 (with `slot_seconds?`) | one per game |
| `side` | `game` u32, `team` u8, `bot` (string), `pearls`, `pearls_by_length`, `dragon_turns` u32, `pearls_per_dragon_turn` f32, `splits`, `deaths`, `deaths_hit_wall`, `deaths_hit_itself`, `deaths_hit_dragon`, `deaths_head_to_head`, `deaths_no_action` u16, `final_units`, `final_longest` u16, `final_total_length` u32, `best_fed_intake` u32, `best_fed_share` f32, `peak_points` u64, `exceeded` u16, `tiles_visited` u32, `head_coverage` f32 | two per game, team A then B |

Enums: `winner` a, b, draw. `result` elimination, length. `status` completed,
error (a non-zero exit or no replay), timeout.

A pearl leaving a tile is eaten by the dragon whose turn started last.
`pearls_by_length` counts the same intake from length gained on moves, adding
back one cell for each step after a turn's first, so a gap between the two
means a misreading. A split is counted when a dragon alive at its turn start
asks for one. `best_fed_intake` is the most any one dragon of the side ate, and
`best_fed_share` its share of the side's pearls. `peak_points` and `exceeded`
(turns that exceeded the CPU limit or ran out of time) are 0 for a game played
outside the Zig judge. `tiles_visited` counts the cells a head of
the side occupied, starting heads included, and `head_coverage` divides it by
`map_tiles`.

