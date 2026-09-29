# Public bot diagnostics, version 1

The bot explains its own decision. The viewer renders records; it does not know
roles, heuristics, scoring formulae or strategies. A bot can use any language or
runtime that writes the protocol below. Shared C and Nim helpers are provided in
`runtime/gizmos.h` and `gizmos.nim`.

## Build identity

A bot announces no build identity while it plays: nothing in a game identifies
the build. Which build played each side is the caller's word: `--seat A|B GUID`
on `just viewer` or `just decisions`.

`just bot-build SOURCE` builds a C, C++ or prepared Nim bot's one judge WASM and
registers it (`harness/build_registry.py`). The same artifact plays games and
is inspected. A GUID identifies the immutable build.

`build/registry/GUID/manifest.json` records the compiled sources, the compiler
settings and the WASM's hash. Lookups verify the retained files and never
rebuild from current source. `LOONG_BUILD_REGISTRY` or the viewer's
`--registry` selects another local registry. Copy the complete GUID directory
to transport a build. Keep it with any replay you want to inspect again:
deleting the registry makes recovery unavailable. Python bots aren't
registered, but can still emit recorded gizmos using the wire contract.

## Primitive records

Write one JSON object per `LOG LOONG_GIZMO` line. The engine's turn/log events
supply dragon and round identity; payloads cannot override them. Records are a
**complete snapshot for that turn**, with no implicit retention from earlier
turns. Every primitive requires `version: 1`, `kind` and a nonempty `label`.

```text
LOG LOONG_GIZMO {"version":1,"kind":"candidate","label":"North","objective":"Food collected minus movement cost","score":2.5,"selected":true,"reason":"Best evaluated candidate"}
LOG LOONG_GIZMO {"version":1,"kind":"path","label":"Chosen route","points":[12,13,14]}
```

Cells use `y * width + x`, with the same wrapped board coordinates as the bot.
Colors are four RGBA bytes, for example `[232,200,114,255]`. Omitted/all-zero
colors use the viewer's accent. Lines join cell centers directly; a wrapped hop
is intentionally a straight connection between its two explicit endpoints.

| Kind | Fields and meaning |
| --- | --- |
| `line` | `points: [from, to]` |
| `target` | `points: [cell]`; the label is drawn beside the target |
| `path` | `points: [cell, ...]`, in traversal order |
| `search` | `cells` and optional `edges`; rendered on the board |
| `map` | `cells` and optional `edges`; rendered on a separate initially blank inspector map |
| `candidate` | Required numeric `score` and nonempty `objective`; optional boolean `selected` |
| `state` | `nodes` and `links`; a graph positioned by the bot |
| `positions` | `positions`: remembered positions, drawn on the board (see [Positions](#positions)) |

Any primitive may include `objective`, `reason` and `color`. Scores from different
objectives are not normalized or compared by the viewer. A map cell is
`{"cell":12,"value":3,"label":"pearl due in 3","color":[232,200,114,255]}`;
only `cell` is required. An edge is
`{"cell":12,"direction":0,"label":"remembered kelp","color":[127,176,105,255]}`,
with directions N/E/S/W = 0/1/2/3. The viewer does not infer map contents, edge
meaning, freshness or confidence: put those in the bot's labels/reasons.
Click a map cell to inspect its values and edge labels; board-cell selection
also exposes search values. Click a primitive's inspector heading to highlight
its line/path. Existing target/path/search toggles control board primitives.

State nodes are `{"id":"farm","label":"Farm","x":0.2,"y":0.5,"active":true}`;
`x` and `y` are normalized panel coordinates. Links are
`{"from":"explore","to":"farm","label":"food found","active":true}`.
IDs must be unique, and links must refer to declared nodes. Put the actual
transition condition or reason in the label, not a viewer-side approximation.

Unknown versions, fields, invalid coordinates, nonfinite numbers and broken
graph references are rejected visibly, by the record's label. A rejected record
takes with it only what is grouped under it; the rest of the turn stays, and a
turn whose Brain or Memory root was rejected lists that slot in
`gizmo_rejected_slots`. Limits: 1024 records per turn (including merged display slots), 4096 entries
per collection, 512 characters per label. Game/judge output limits still apply.
No single record may span multiple log lines. Use a JSON encoder for dynamic
strings. A protocol-independent bot must emit its gizmos itself; there is no
name-based strategy adapter.

## Instrumentation and trust

In C, wrap observational work in `LOONG_DIAGNOSTIC_BLOCK(...)` and emit an object
with `LOONG_GIZMO_JSON(json_expression)`. In Nim, use `diagnosticBlock:` and
`emitGizmoJson(json_expression)`. Disabled blocks and expressions are not
evaluated. Emit after selecting the action, before the existing buffered flush.
Never mutate decision state inside an instrumentation block. Do not use its
compile-time define to choose a different policy.

Every build compiles diagnostics in, and each block checks one flag first.
The flag is off unless the bot's init input starts with a `LOONG_INSPECT` line
before the `ID` block, which the official engine never sends and our inspection
harness always does (`unswbc_init` in `runtime/helper.c`). With the flag
off a block costs that check, a few points, and its expressions are not
evaluated. Records leave on standard output as `LOG LOONG_GIZMO <json>` lines,
so the submitted artifact imports nothing the official judge doesn't provide.

The Zig judge's `--inspect` mode lifts gizmo lines out of standard output into a
separate annotation channel of up to 64 MiB per turn, and they never enter the
10 KiB gameplay framer. Gameplay output is charged as the judge charges it. An
inspected turn may spend up to 100 times the normal turn budget, so diagnostic
work never times a dragon out. In Nim builds the outermost `diagnosticBlock`
times itself and `loong_current_points` leaves those points out, so a bot's
budget-sensitive decisions see the same clock with diagnostics on as off
(`runtime/points.c`). C diagnostic blocks aren't timed. Matching decisions
are still required, since the flag checks and timing add a small instruction
cost. The inspection subprocess has a 120-second wall limit for the supplied
observation sequence, and normal bot memory limits remain.

Recorded gizmos describe the actual process that played, even if its build is
unavailable locally. The viewer says so separately from build verification.
For judge replays, the viewer's recovery (`loong-recover`,
`replays/recovery/serve.nim`) feeds each dragon's recorded observations
through its build's registered artifact with the `LOONG_INSPECT` marker, the build its seat names
(see [Build identity](#build-identity)), and streams each turn's validated
records to the viewer as they are produced. Because the build comes from the
caller rather than from the game, the rerun is the check: it compares each
rebuilt action and observable sonar output with the replay, retains mismatch
taint for the rest of that dragon's life, and the viewer hides unreliable
overlays. `just decisions` leads each dragon with how many rebuilt turns match
and where it first diverged. An action match is
evidence, not proof of identical hidden state; random streams and instruction
budgets may differ. A child's starting protocol is inherited from the reliably
recovered parent at the split, rather than reset to version 1. Missing parent
evidence prevents child recovery. `just viewer --no-recovery` displays only
recorded diagnostics. A missing build never selects current source.
`replays/recovery/gizmos.nim` is the contract's validator.

## Save and view

```sh
just showcase
```

builds the [showcase bot](../../examples/showcase-bot), which emits every
record kind below, plays it against itself and opens the game with both sides
rebuilt.

## Tables, retained cell records and numeric transport

`table` has `columns: [string, ...]` and `rows: [[string, ...], ...]`.
Every row has the same width as the columns (1–64 columns, at most 4096 rows).
Rows appear as a grid; clicking a row opens its complete field values. Optional
`row_cells` associates each row with a unique board cell: these tables expose
cell details only when that cell is selected.

A `map` or cell `table` may explicitly set `retain: true`. Its label identifies
that retained collection within one dragon process. Emitted cells replace prior
records for those cells; an emitted empty update retains the prior collection.
Omitting the primitive does not display it on that turn. Initial state is empty,
and state never crosses dragon identities. Exported turns contain independent
snapshots. Retained table columns must remain unchanged.

Two optional numeric encodings expand to ordinary string rows before rendering:

- `packed_rows` replaces `rows`: base64 signed zigzag unsigned-LEB128 integers,
  flattened row-major, with exactly one value per column in every row.
- `packed_columns` replaces `rows` and `row_cells`: one base64 string per column,
  and `cell_range: [first_cell, count]`. Decode each string as byte pairs
  `[repeat_count, byte]` (count 1–255), expand those runs, then decode signed
  zigzag unsigned-LEB128 **deltas**, accumulating from zero separately in each
  column. `column_formats` is `int` (default) or `f32`; `f32` interprets each
  reconstructed integer as the exact IEEE float32 bit pattern, without rounding.

`display_column` opts a cell table into the search overlay. `evaluated_column`
optionally marks whether its value was evaluated (zero leaves the cell label blank). The bot
supplies the scoring objective. Optional `truth_columns`, parallel to `columns`,
requests comparisons in the **left objective sidebar**: an empty string means no
comparison; supported quantities are `spawn_due`, `spawn_min`, `spawn_max`,
`spawn_mean`, and `edges` and `pearl` (see Mental map accuracy). These are replay facts, never injected into the bot's knowledge.
Every memory should name its source, and a table shows it by its columns alone.
A memory kept as sourced facts (a value, its source and the round it was
learned) reflects into columns named after each fact: `pearl`, `pearl.source`,
`pearl.round`, and for a fact with several fields `timer.due`, `timer.gapLow`
and so on. A column belongs to the fact named before its first `.`, after any
`belief: ` prefix marking a belief derived from that fact, and takes its source
from `FACT.source`. The Issues button under the comment field lists each graded
belief column with no source column, each belief cell stated with a blank, `-`,
`?` or `none` source, and each position with an empty `source`.

## Mental map accuracy

Two more `truth_columns` quantities grade a retained cell table as the
dragon's mental map. At most one table per turn may carry them, and it needs
`row_cells`.

- `edges`: four space-separated tokens in N/E/S/W order, each the direction
  letter followed by `?` unknown, `s` suspected (ungraded), `.` open, `w`
  kelp, `c` passable (open or a portal, never kelp), or `p`, an optional bot-local portal ID and an optional
  `>` landing cell. For example, `N. Ew S? Wp3>45`. Other values are rejected.
- `pearl`: `1` present or `0` absent. Any other value is unknown.

The viewer grades each stated edge against the map, including a stated portal
landing, and each stated pearl against the board at the start of that turn, so
a stale pearl record counts as wrong. A cell is wrong if any claim is wrong,
correct if it has a correct claim and no wrong one, and otherwise unknown.
Cells without a row and `?` claims are unknown. Truth never fills them. The
Mental map overlay is the board's view of this memory. It dims unknown cells,
tints graded cells, and draws each side as the dragon believes it, just inside
the cell: kelp solid, suspected kelp dashed, portals with their IDs, and, for
the selected cell, a line to each stated portal landing. Sides the replay proves
wrong are marked red over the belief. The left sidebar gives totals and the
selected cell's wrong claims.

## Positions

A `positions` record lists where things were last known and how far they may
be now, such as enemy dragons or a teammate reported over sonar:

```json
{"version":1,"kind":"positions","label":"Remembered positions","positions":[
 {"cell":123,"radius":0,"age":0,"source":"seen","label":"enemy D7, length 12","color":[251,73,52,255]},
 {"cell":456,"radius":5,"age":5,"source":"message r140","label":"our champion D4"}]}
```

Only `cell` is required: the last known or best-guess cell. `cells`, when
given, lists every cell it may occupy now, as the bot works them out, for
example round kelp. Without it, `radius` says it may be up to that many steps
from `cell` on the torus, 0 when known exactly; the bot decides how it grows.
`age` is the rounds since it was last known exactly. Both are whole numbers up
to 4096. `source` and `label` are the bot's own words, and `color` defaults to
the record's. The Positions overlay outlines each `cell` and hatches the cells
it may occupy, tracing their boundary, fading with age and labelled with the
age, and the inspector lists them. The viewer infers no position itself.

An entry about a dragon may also say who it is and what the believer holds
about it: `dragon` (its ID), `team` (`ours` or `enemy`), `length` (whole number
to 4096), `length_exact` (false makes `length` a lower bound) and `champion`
(true when the believer takes it for its team's champion). The viewer grades
these against the replay (see Belief correctness).

## Sonar records

A table may carry a `sonar` annotation so the viewer can join the bot's own
reading of its messages with the replay's recorded pings:

```json
{"role":"received","value_column":0,"meaning_column":1,"outcome_column":2,"cells_column":3}
```

Each row is one 64-bit value as an unsigned decimal string. `role: "sent"`
rows are this turn's transmissions, and `meaning` is the sender's decode of
each. `role: "received"` rows are this turn's inbox in order, including
values the bot could not decode. Optional `outcome` says what the receiver
did with the value. Optional `cells` lists space-separated cell indices the
message concerns.

The viewer matches sent rows to pings by sender, round and value, and received
rows to delivered pings by receiver, reading round and value. For each ping,
the Signals tab shows the sender, the sender's meaning, the receiver, the
receiver's meaning and outcome, and the receiver's memory row for each named
cell before and after that turn. The memory row comes from the graded mental
map table, else the `slot: "memory"` table. A sender's meaning also labels its
ray on the board. Records that match no ping, and delivered pings that a
reporting receiver does not list, are shown as errors. A ping of 2^32 or more
that reaches a receiver still on legacy input (its first turn, before its
`PROTOCOL 3` takes effect) is shown as dropped by the engine, since the
receiver never saw it. The viewer decodes no protocol itself.

Nim's `diagnostic_descriptions.nim` provides `describedEnum`: put a
`{.purpose: "One-line purpose".}` attribute beside each enum member. The macro
creates its description procedure from those attributes, so the generic viewer
needs no strategy dictionary.

Cell tables can set `display_overlay` to `search` (default) or `timers`,
`display_position` to `top_left` or `top_right`, and `color` to an RGBA text
colour. Search values default to the top-left corner in cream and timers to the
top-right in teal, apart from the true countdowns in the bottom-right. A timers
column that is also the table's `spawn_due` truth column isn't drawn itself: the
viewer grades it against the true countdowns, cyan where it is correct and in
red above the countdown where it is wrong. Cell text
is drawn a size under the board's labels and shrinks to fit its cell. `display_format: "round_delta"` treats the displayed column as an
absolute remembered deadline and subtracts the diagnostic turn's round. Negative
stored deadlines are unknown (`?`), which the timers overlay leaves blank; elapsed known deadlines remain signed,
without predicting their replacement. The default format, `number`, is a decimal.

`column_encodings` selects `raw` or `rle` per packed column (default `rle`).
Both carry the same signed integer delta stream; raw skips byte-run expansion.
Producers should select the shorter representation, since runs of length one
otherwise double the payload before base64 encoding.

## Generic decision hierarchy and calculations

Every gizmo may carry a stable `id` and a `parent`. Parent references another
gizmo ID **or a state-tree node ID** in the same turn. An empty parent is a root.
IDs in grouped records and their nodes share a namespace; unknown parents,
duplicates and cycles are rejected. Sibling order is producer order. Maximum
depth is 128. Grouping never implies eligibility or a score.

A `state` record with `layout: "tree"` supplies nodes with `id`, `label` and
optional `parent` (empty for roots). Positions `x/y` are unnecessary in tree
layout. Its optional per-node evaluation fields are:

- `active: true`: the selected node, supplied by the producer.
- `eligible: true/false`: eligibility was evaluated. Omission is uncomputed.
- `score: number`: the recorded score, including zero. Omission is uncomputed.
- `objective: string`: what the score measures, such as `suitability`, shown
  beside it.
- `reason: string`: the actual gate or selection explanation.

All fixed alternatives and parentage remain in the tree on every turn. Inactive
branches may omit evaluation fields. The renderer does not filter them by the
winner. Clicking an alternative opens gizmos whose parent is that node, directly
beneath it. There is no second policy catalog or viewer-side formula.

Tables may carry `row_states`, parallel to `rows`: `selected`, `eligible`,
`ineligible` or `not_evaluated`. These affect styling only.
A `calculation` gizmo carries a required `expression`, optional
`operands: [{"name":"gain","value":3}]`, and optional numeric `result`.
Names are unique. The renderer displays these supplied values without evaluating
the expression; an absent result is labelled not evaluated.

## Belief correctness

The beliefs strip grades the beliefs of each living dragon whose latest turn
has a usable record against the replay at the start of that turn, for our team:
the focused dragon's when the recovery can rebuild it, else the team it can. Each box is one belief: how many graded dragons
hold it without a false fact, and the share of all their stated facts that is
correct. A click lists every dragon's wrong facts, who states nothing, who is
not graded and, for dragons as subjects, how many believers are right about
each one. The strip says why each ungraded dragon isn't graded: it has yet to
take a turn, it is not rebuilt yet, or its turn has no usable diagnostics.

- Map beliefs come from a retained cell table's `truth_columns` and are graded
  as in Mental map accuracy: `edges` and `pearl`, and `spawn_due`, the round of
  a cell's next spawn attempt, or `never`, which is correct where the map
  disables spawning. A number is ungraded where the replay has no attempt due
  and the cell spawns. A belief takes its name from the consensus category
  annotating its column or its parts (columns named after it with a `.`
  suffix, such as each side of `belief: edges` in `belief: edges.N`), else
  from the column.
- Positions: an entry naming a `dragon` other than the believer is correct when
  that dragon's head lies in its `cells`, or without them within `radius` steps
  of `cell`, counted on the torus without portals, and wrong when that dragon
  is dead.
- Lengths: `length` equals the true length, or is at most it when
  `length_exact` is false.
- Our champion and Enemy champion: an entry with `champion` is correct when that
  dragon is alive on the stated team and no teammate of it is longer, and its
  length is right. A dragon's entry for itself is graded here only. The strip
  also compares, dragon against dragon, which dragon each takes for our
  champion and its length.

Unstated values, `?` and empty cells are never graded.

## Team consensus annotations

A table may annotate its existing columns with `consensus`, without sending a
second copy of the knowledge. Each entry has a `category`, numeric `column`,
`known_column`, integer `minimum`, and `scope`. A row contributes a fact only
when its integer knowledge marker is at least that minimum. Values are compared
exactly as emitted strings; producers must use canonical representations.

Scopes are `singleton` (exactly one row), `cell`, `edge`, or `directed_edge`.
Spatial scopes require `row_cells`; edge scopes also require a `direction` in
N/E/S/W order, 0..3. Physical `edge` keys canonicalize opposite sides and wrapped
seams; directed destinations retain their orientation. A category name is its
semantic identity across dragons/builds, so different meanings require different
names. Annotation lists are limited to 64 entries. Existing table packing and
explicit retention apply before comparisons.

```json
{"category":"Respawn timers","column":3,"known_column":3,"minimum":0,"scope":"cell"}
```

A value of `?` or an empty value states nothing and is not compared. The
agreement appears in a belief's detail in the strip (Belief correctness). It
uses each living dragon's latest usable snapshot, including
the current turn and excluding future knowledge. Births without snapshots count
as missing evidence; dead dragons leave the population. A missing or unreliable
update invalidates the previous usable snapshot. Round-boundary navigation shows
the end of that round's last turn.

Each living pair compares its own intersection of known fact keys. `DISAGREE`
means at least one differing pair-fact; `AGREE` means every compared fact agrees
and all dragons supplied usable category snapshots. `UNKNOWN` means no comparable
facts; `INCOMPLETE` means missing snapshots (or unknown singleton claims). A known
disagreement remains visible even when other evidence is incomplete. The detail
gives pair and fact counts, snapshot rounds and up to 30 disagreement
witnesses; all disagreements are counted. Disjoint knowledge is never fabricated
as agreement. No replay-truth cell values enter these comparisons.

### Map markers

A `map` primitive may set `display_overlay: "markers"` to draw its annotated cells
on the main board as well as in its inspector preview. The viewer treats labels,
colours and reasons as producer data and does not infer enemy positions itself.

### Brain placement

Brain is a UI slot, independent of the primitive's shape. A producer marks
exactly one root record with `slot: "brain"`; its `kind` chooses the generic
renderer. A state graph, table, calculation, or single `action` block can fill
the same slot. No role, priority, stage, or hierarchy is required. Descendants
omit slot and attach by parent ID to gizmos or graph nodes. Other root records
appear under Signals, after the turn's pings, except sonar tables, which Signals
shows joined with those pings. A `sent` table is also shown whole after the
pings, as the dragon's choice of what to send. Missing Brain records are shown as unavailable, never
reconstructed from an AST or inferred from other diagnostics.

The Brain root may carry `breakdown`: one or two entries, coarsest first, that
decompose the turn's decision however the bot's design cares to show it. The
utility adapter, for example, gives its role and then its behaviour:

```json
"breakdown":[{"level":"Role","value":"harvester"},{"level":"Behaviour","value":"farm"}]
```

Each bot names its own levels and values as nonempty labels. There is no fixed
vocabulary. The viewer counts each team's turns per round by the first value,
and within it by the second, draws them as a stacked chart titled with the
levels, and attaches no meaning to either. Only the Brain root may carry it.
The recovery sends it beside each turn's record, so the whole game's tallies
need no record parsed.

An `action` primitive requires the usual version and label, and optionally
objective and reason. It needs no nodes, score, or calculation. Graph nodes can
be selected to inspect their attached records.

Memory uses the same placement contract: `slot: "memory"` on at most one root.
Omission means no Memory view is supplied. The viewer does not synthesize a
presentation from registered state.

Tables may supply `row_ids`, nonempty stable IDs parallel to `rows`, with an ID
on the table itself. Row IDs share the gizmo/node namespace. A child primitive's
`parent` can refer to a row ID; selecting that row opens its children inline,
including further graphs or tables. These are complete tables, not retained
cell deltas. `row_states` remains optional and conveys nothing when absent.
Coefficients, variables and contributions may be ordinary producer-named table
columns; the viewer does not derive or evaluate equations.

State `layout: "graph"` (or omitted layout) requires producer-supplied normalized
`x,y` coordinates in [0,1], left-to-right and top-to-bottom. Graph links may form
loops and joins. Parent links describe containment, not control flow.

Positioned graphs derive readable canvas spacing from supplied coordinate gaps,
with bounded scrollable viewports. Selected labels and attachments appear below
the viewport.

Table cell payloads may contain up to 16,384 characters, allowing complete source
expressions and structured recorded values. Labels and identifiers remain limited
to 512 characters. Table summaries are clipped visually; cell details retain the
full payload.
