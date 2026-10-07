# Loong columns

One binary format for game data: the viewer's games, and the
per-game and per-run records that the collector, verdict and census read. A
file holds named columns, each one contiguous array of fixed-size values, so a
reader maps the file and uses each column in place with no parse step.

Compiled code writes and reads it: `columns.nim` here for Nim tools and
`columns.odin` in the viewer. `columns.py` is a thin reader and writer for the
Python that remains at boundaries, such as the match wrapper, which runs inside
the toolkit's own Python. Python readers take a column with
`numpy.frombuffer(mapped, dtype, count, offset)` over an `mmap`.

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
| `meta` | `version` u32, `width` u32, `height` u32, `winner` i8 (-1 draw), `end_reason` u16, `terminated` u8 (the recorded result's completed flag), `replay_format` u32, `seed` u64 (with `seed?`), `map_name`, `bot_a`, `bot_b`, `map_text` (strings) | 1 |
| `edge` | `x`, `y` u32, `side` u8 (0 the cell's north edge, 1 its west), `portal` i32 (-1 kelp) | one per non-empty edge |
| `spawn` | `cell` u32, `minimum`, `maximum` i32 | one per spawning tile |
| `start` | `dragon` u32, `team` u8, `body` (list of u32 cells, head first) | the map's starting dragons |
| `event` | `kind` u8, `a`, `b`, `c`, `d` i32 | every board event, in replay order |
| `split` | `parent_body`, `child_body` (lists of u32 cells, head first), `child_facing` u8 | one per split, in order |
| `round` | `event` u32 (its round-start row) | one per round |
| `turn` | `round` u32, `dragon` u32, `team` u8, `event` u32 (its turn-start row), `action` (string: `MOVE` and its directions, `SPLIT` and its length, `SUICIDE`, `NO_ACTION`, or empty when the turn recorded no action), `points` u64 (with `points?`), `failure` (string), `log` (string: the turn's dragon log lines, newline-separated) | one per dragon turn, in replay order |
| `ping` | `round` i32, `sender` i32, `hit` i32 (-1 none), `hit_kind` u16, `direction` u8, `origin`, `end` u32, `value` u64, `event` u32 (rows of `event` before it), `received_round` i32 (the round its target next took a turn, or -1) | one per sonar ping, in replay order |
| `standing` | `units`, `longest`, `total_length`, `queen_length` u32 | the final standings, team A then B |

The canonical [replay schema](replay.capnp) includes SDK 1.2.7's queen length
and inline `seed` union. Unknown seed (`none`, including historical absent
fields) writes `meta.seed? = 0`; known zero writes `meta.seed? = 1` and
`meta.seed = 0`. The stored zero for an unknown seed is not a reconstruction.
Absent historical queen-length fields decode as zero. Existing columns files
can lack these added columns; readers must preserve that absence rather than
infer new-rule provenance.

`meta.terminated` records the replay's existing `GameResult.terminated` flag.
Older columns can lack it; missing completion evidence stays unknown. A
complete-workload check requires the flag to be present and true, and requires
a known seed equal to the scheduled input. It never infers completion from an
end-reason code or upgrades older files in place.

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
only for games played through the match wrapper's sandbox; elsewhere
`turn.points?` is 0.

## Kind `native-workload`, version 2

The compiled `loong-report native-workload` stage writes one completed batch's
measurements beside its games as `native-workload.cols`. It streams the fixed
schedule and maps one game's canonical columns at a time. The caller supplies
the scheduled denominator; absent jobs, incomplete replays, wrong seeds/maps,
or a requested reference difference refuse a completed report. Bot failures
in exported jobs figures refuse by default. Explicit `--bot-failures record`
retains every terminal game and records those failed-turn counts; it still
requires complete replays and the requested reference agreement.
`workload-timings.json` is a small human summary.
Reference byte differences are counted across the scheduled batch before
refusal; its incomplete summary gives the total and first sixteen job indices.
Other evidence failures still stop validation at their boundary. An
incomplete summary contains no throughput rate.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32, `scheduled_games` u32, `backend` string (`cpu`, `cuda`, `kvm`), `bot_failure_policy` string (`reject` or `record`) | 1 |
| `game` | `index` u32, `map` string, `seed` u64, `seat_order` u8, `turns`, `events`, `replay_bytes` u64, `winner` i8 (-1 draw), `rounds` u32, `end_reason` u16, `latency_seconds` f64, `reference_equal`, `aggregate_points_equal` u8 (each with `?`) | every scheduled game, in schedule order |
| `side` | `game` u32, `team` u8, `points?` u8, `point_turns`, `point_median`, `point_mean`, `point_maximum` u64, `bot_failures` u32 (with `?`) | team A then B for each game |

The `side` figures are the actual CPU/CUDA jobs output; KVM's unexported points
stay unknown, as do its unexported bot-failure counts. Version 1 files lack
the failure-policy/count columns; those counts are unknown, not zero.
Reference replay equality is known only when a reference store
was supplied. Aggregate-point equality additionally requires actual per-turn
reference points, and does not establish equality of unexported native
per-turn counters. Match latency uses the native jobs wall milliseconds or
KVM child-process timing; the outer dispatch-to-sync timer is separate. A
failed batch writes an incomplete summary without throughput rates.

## Kind `native-profile`, version 1

The compiled `native-workload-profile` stage reads RL's source-owned aggregate
TSV1 from stderr (`judge.log`). Each batch has 24 ordered rows: its header,
14 host stages, six device stages, waves/decisions and two copy directions.
[`native_profile.h` and the engine README](../engine/README.md#complete-match-cuda-profiling)
own their exact names and meanings. The reader streams the log, preserving
missing stages as unknown, and writes `native-profile.cols` plus a small
`profile-summary.json`. Acceptance requires the existing complete workload
validation, reference replay/known SDK point equality and recorded profile
mode. Enabled batches additionally need successful flags, the full row set,
one serialization per game and the scheduled denominator. Disabled mode
retains an absent profile as unknown, with no invented zero durations.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version`, `expected_stream_version`, `scheduled_games` u32; `expectation` string; `profile_present`, `stream_complete`, `workload_verified` u8 | 1 |
| `batch` | `index` u32; `games`, `waves`, `decisions` u64; `completed`, `failed`, `stream_complete`, `waves?` u8 | one per parsed header; `waves?` governs both counter values |
| `host`, `device` | `batch` u32, `stage` string, `known` u8, `calls`, `ns` u64 | 14 host and six device rows per parsed batch; `known` governs both numeric values |
| `copy` | `batch` u32, `stage` string (`htod`, `dtoh`), `known` u8, `calls`, `bytes` u64 | two per parsed batch |

Unknown numeric slots carry storage zero only under a clear known flag.
Inclusive host spans overlap; callback sums can exceed wall time. Device
copy spans may include host enqueue gaps. Host and device totals cannot be
added. Cleanup excludes later host member destruction and printing. File
writes/close and final sync remain the timed driver's separate intervals.
These columns provide aggregate diagnostics, not an overhead or speed claim.

## Kind `points`, version 1

Each dragon turn's judge points, written beside a sandboxed match's replay as
`REPLAY.points.cols` by the judge (`tools/judge/src/run.zig`). The
`game` converter carries them into `turn.points`.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32 | 1 |
| `turn` | `round` i32 (-1 before round 0), `dragon` u32, `points` u64, `failure` (string: the toolkit's reason the turn gave no reply, such as `exceeded CPU limit`, or empty) | one per dragon turn, in the order played |

## Kind `activation`, version 1

How often each Brain node of our bots was active in one game, written beside the
game's log as `<game>.activation.cols` by `loong-audit activation`
(`tools/analysis/audit/activation.nim`, through `just activation` or fleet
tracing); `loong-tournament activation` (`tools/analysis/activation_stage.nim`) reads it.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32, `error` (string: why the game couldn't be traced, or empty) | 1 |
| `side` | `team` u8, `turns`, `mismatches` u32 | one per traced side |
| `node` | `side` u32, `name` (string), `active` u32 (turns it was active), `leaf` u8 (no other node names it as parent) | one per Brain node seen on the side |

## Kind `knowledge`, version 1

How well each team knew its world in one game, round by round, written beside
the game's log as `<game>.knowledge.cols` by the viewer's `--knowledge` export
(`tools/viewer/knowledge.odin`, through `just knowledge`) once it has
rebuilt every dragon it can; `loong-report knowledge` and summary.md read it
(`tools/evaluation/report/knowledge.nim`). A row sums one belief over one
team's living dragons at the end of a round, each judged by its latest usable
record, counting only facts the replay can grade.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32 | 1 |
| `row` | `round` i32, `team` u8, `category` u8 (enum `category`, the belief), `kind` u8 (enum `kind`), `alive`, `dragons` (graded), `stating`, `possible` (facts that exist), `each` (facts one dragon could state), `known` (distinct facts stated about what exists), `linkable`, `linked`, `disputing`, `agreed`, `misled` i32, `facts`, `correct`, `covered`, `sharable`, `comparisons`, `conflicts` i64, `shared` f64 | one per round, rebuilt team and belief stated |

Enums: `category` the beliefs in order of first appearance. `kind` Sides (four
facts a cell), Cells (one a cell), Positions, Lengths, Queen (where the
enemy queen is, one for the team). `covered` counts stated facts about what exists: a position of a dragon
no longer alive is stated and false, and left out of `covered` and `known`.
`sharable` counts stated facts and `linkable` graded dragons, both only where
two or more dragons are graded. `shared` sums, over those facts, the share of
the other graded dragons stating the same fact. `linked` counts dragons at
least half of whose facts another dragon states too. `comparisons` counts pairs of dragons stating one
fact, `conflicts` those whose values contradict: unequal values, exact lengths
that differ or undercut a lower bound, or positions with no cell in common.
`disputing` counts dragons in a contradiction, `agreed` facts two or more
dragons state and `misled` those of them most of whose holders are wrong.

## Kind `observations`, version 1

Each decision's bot-visible input, rebuilt from a `game` file by
`loong-gamedata observations GAME.cols OUTPUT [--dragons ID,ID...] [--lenient]`,
and by recovery (`loong-recover`, `loong-audit activation`) for as long as it
reads them: the init block and a protocol-3 observation block at the dragon's
turn start. Headers use the official names `DIR`, `NUM_MSGS` and
`DRAGON_BODIES`; `ECHOES` contains the five sonar echo counts. The replay does
not record protocol negotiation, so these blocks always include protocol-3
echoes and 64-bit messages. Body rows follow visible-cell order, rather than
the engine's dragon order. Countdown events establish known spawn times;
unrecorded countdowns remain `-1`, with no invented timer from the map's gap
range. `-1` also represents a nonspawning cell in the official protocol, so
consumers use the map's spawn cells to distinguish an unresolved countdown.
A consumer requiring complete spawning-cell countdowns must reject or mark
those inputs incomplete. A turn with no recorded action has no decision. A body
whose heading two directions explain fails the rebuild (exit 3) unless
`--lenient`, which takes the first and counts it in `meta.ambiguous`.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32, `ambiguous` u32 | 1 |
| `decision` | `turn` u32 (row of the game's `turn`), `init`, `observation` (strings) | one per decision, in game order |

Compiled consumers use `observations.observe(board, dragon)` from
`tools/gamedata/observations.nim`, returning `(init, observation)` strings.
Call it once at the turn start: it consumes the dragon's waiting sonar and
echoes, as `observations.observed` does. `observations.replayDecisions` visits
the reconstructed board before that observation is consumed.

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
| `game` | `map` (string), `map_tiles` u32, `seed` u64, `rounds` u16 (rounds played, with `rounds?`), `winner` u8 (enum `winner`, with `winner?`), `result` u8 (enum `result`, the replay's end reason, with `result?`), `status` u8 (enum `status`), `exit_code` i32, `elapsed_seconds` f32, `slot_seconds` f32 (the fleet worker slot's time, with `slot_seconds?`) | one per game |
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
outside the match wrapper's sandbox. `tiles_visited` counts the cells a head of
the side occupied, starting heads included, and `head_coverage` divides it by
`map_tiles`.

## Kind `census`, version 2

Census v2's measured games, written by `loong-census measure`
(`tools/opponents/census/measure.nim`) and read by its later stages. Signatures
come and go, so the counters are columns named by the counter and their set
varies from file to file: every column of `count` and `window` other than the
fixed ones below is a counter, i64 when all its values are integers and f64
otherwise, with a `?` companion when some rows lack it. The chosen teams are
those `sample` marked in the ratings file beside the jobs. Version 1 files, from
the first census, have no `event` or `motif` tables and none of the named
detectors' counters.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32 | 1 |
| `game` | `id` u64 (the public game, or the job's row number for a named replay), `replay` (string: the replay file a job named, or empty), `error` (string: why it couldn't be measured, or empty), `format` u32 (replay format), `map`, `symmetry` (strings), `width`, `height`, `tiles`, `kelp`, `portals`, `rounds` u32, `end_reason` u16, `mean_gap` f32 (with `mean_gap?`), `winner` u8 (enum `winner`: a, b, draw) | one per sampled game |
| `side` | `game` u32, `team` u8, `team_id`, `submission` u32 (each with `?`), `team_name` (string), `final_longest`, `final_total`, `final_units` u32 | two per measured game, A then B |
| `count` | the side's counters | one per row of `side`, in the same order |
| `champion` | `side` u32, `id`, `length`, `inherited`, `born`, `eaten`, `paid`, `donated`, `residual` i32 | one per side with a live dragon at the end |
| `window` | `side` u32, `index` u16 (rounds `50 * index` onward), then the window's counters: its turn counts and the `open_` state the side held when it opened | one per side and 50-round window it played |
| `event` | `side` u32 (the actor's `side` row), `kind` u8 (enum `kind`: tailStrike, championHunt, shadowEpisode, feedDelivered), `round`, `dragon` (the actor), `other` (its target, or -1) i32 | one per detection of a named behaviour |
| `motif` | `team` i32 (a chosen team, or -1 for every other team), `key` u64 (the motif, `tools/opponents/census/motifs.nim`), `count` i64, then one example: `game` u64, `round`, `dragon` i32 | one per team and motif seen 5 times or more |
| `motif_total` | `team` i32, `length` u8 (turns in the motif, 1–3), `windows` i64 (the team's motifs of that length) | one per team and length |

A game with an `error` has no sides.

## Kind `sonar_census`, version 1

One team's sonar traffic and what its dragons did after hearing it, over a
sample of public games (measured by `tools/opponents/sonar_census.nim`), written by
`just sonar-census` as `build/opponents/sonar/census/team-<id>.cols` and read by
its `--reuse` summary and by `just sonar-signatures`. Only the studied team's
side of each game is recorded. Directions are 0 N, 1 E, 2 S, 3 W.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version`, `team` u32 (the public team ID), `name` (string), `elo` f32 (at sampling) | 1 |
| `game` | `id` u64 (the public game), `side` u8 (0 A, 1 B), `submission` u32 (with `submission?`) | one per measured game, newest first |
| `sent` | `game` u32, `round`, `sender`, `length` i32 (the sender's), `hit_kind` u8, `value` u64 | one per ray the team sent |
| `turn` | `game` u32, `round`, `dragon`, `length` i32, `facing` u8, `enemy_heads` u8 (enemy heads in its 7x7 window), `split` i32 (the split length, 0 none), `first` i8 (the first step's direction, -1 for a split or no move), `steps` u8 | one per dragon turn of the team, taken before its action |
| `inbox` | `turn` u32, `value` u64, `ally` u8 (1 when a teammate sent it), `sender_length`, `sender` i32 | one per value a dragon of the team read at that turn |

## Kind `sonar_packets`, version 1

One team's distinct sonar packets with what each sender knew when it sent them,
for fitting bit fields (measured by `tools/opponents/sonar.nim`), written by
`just sonar-decode` as `build/opponents/sonar/packets/team-<id>.cols`. A packet is one
(game, round, sender, value); the rays that carried it are its lists.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version`, `team` u32, `name` (string), `elo` f32, `submission` u32 (0 unknown) | 1 |
| `game` | `id` u64 | one per game with packets, in order of first packet |
| `packet` | `game` u32, `value` u64, `side` u8 (0 A, 1 B), `hit_kind` u8 (the first ray's), `width`, `height` u16, the sender's context as i32 (`sender`, `round`, `head_x`, `head_y`, `length`, `facing`, the same four before its action as `pre_x`, `pre_y`, `pre_length`, `pre_facing`, `unit_count`, `enemy_unit_count`, `team_total_length`, `team_longest`, and from its 7x7 window `seen_pearls`, `seen_enemy_heads`, `seen_ally_heads`, `seen_kelp_edges` and `nearest_{pearl,enemy,ally}_{x,y,linear,distance}`, `nearest_enemy_id`, `nearest_enemy_length`, 0 when none is seen), the first ray's `origin_x`, `origin_y`, `end_x`, `end_y` i32, and the lists `ray_kind` u8 (each ray's echo kind) and `ray_receiver` u8 (the dragon it reached: 0 none, 1 team A, 2 team B) | one per packet |

## Kind `food_intake`, version 1

Every pearl eaten in a set of games attributed to the dragon that ate it,
written by `just food-intake` (`loong-audit food-intake`,
`tools/analysis/audit/food_intake.nim`) into an analysis directory's game
store as `store/NAME.cols`. Its intake counts, from tile changes and again from
length deltas plus paid sprint steps, are described in tools/evaluation/README.md.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32 | 1 |
| `game` | `label`, `path`, `map`, `bot_a`, `bot_b`, `error` (strings; `error` empty when measured), `winner` u8 (enum `winner`: a, b, draw), `rounds` u32 | one per game |
| `side` | `game` u32, `team` u8, the side's counts as i64 (intake by source and round bucket, turns, deaths, paid sprint steps, the moves toward or away from food, `dragons`, `alive_at_end`, the best-fed and final longest dragons' intake and turns, final standings and `initial_length`), each with a `?` companion when some side lacks it; `intake_per_dragon_turn`, `intake_per_round`, `best_fed_share`, `top3_share`, `mean_intake_per_dragon` f64; `best_fed`, `best_fed_born`, `best_fed_died`, `longest`, `longest_born` i32, each with `?` | two per measured game, A then B |
| `dragon` | `game` u32, `id` u32, `team` u8, `born` i32, `died` i32 (with `died?`), `turns`, `eaten`, `length` u32, `parent` i32 (with `parent?`), `placed` u8 (a starting dragon) | one per dragon of each measured game, unless written with `--no-dragons` |

## Kind `survival`, version 1

One bot's survival diagnostics over a completed result set, written by `just
survival-audit` (`loong-audit survival`, `tools/analysis/audit/survival.nim`)
into the set's game store as `store/survival-BOT.cols`. A clear single step is
a move to a free, reachable square; it is a diagnostic, not a proven escape.

| Table | Columns | Rows |
| --- | --- | --- |
| `meta` | `version` u32, `bot` (string) | 1 |
| `game` | `map` (string), `side` u8 (0 A, 1 B), `won` u8, `rounds`, `longest_survivor`, `total_surviving_length`, `survivors` u32, and each count the game recorded as i64 (`dragon_turns`, `splits`, `decisions_without_clear_single`, `deaths`, the three death categories, and `death_<cause>`), with `?` 0 in a game that didn't record it | one per game the bot played |
| `death` | `game` u32, `round` i32, `dragon`, `length` u32, `category` u8 (enum `category`: own_action_death_with_clear_single, own_action_death_without_clear_single, death_during_other_turn), `clear_singles` (string: the directions, of N E S W, a step could have taken), `reason` u16 (the engine's death code) | one per death of the bot's dragons |
