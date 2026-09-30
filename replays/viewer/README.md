# Replay viewer

`just viewer REPLAY [OPTIONS]` opens a replay in the Odin display, from
`examples/tooling`. `just viewer --help` lists the options:

- `--seat A|B GUID` names the registered build that played that side (`just
  bot-build` prints it). Its dragons' decisions are rebuilt (see
  [Decision and memory inspection](#decision-and-memory-inspection)). A side
  with no seat shows the replay alone.
- `--dragon N` and `--round R` set the initial focus. That dragon's decisions
  are rebuilt first.
- `--turn T` opens Turns mode at that turn index, overriding `--round`.
- A `--dragon` with `--round` or `--turn` opens zoomed on its area, as F does,
  unless `--whole-board` is given. The button at the board's top-right corner
  toggles the zoom too: outward arrows zoom in, inward arrows show the whole
  board.
- While open and paused, the viewer keeps where it is and everything selected
  in `GAME.cols.position`, one JSON line rewritten whenever it changes
  (`Viewer_Position` in `position.odin`): the replay, round, Turns mode and
  turn index, focused dragon, zoom, selected cell, each highlight with its
  description, the inspector's selected record, tab and Brain view, the open
  dialog's title and belief-map cell, the overlays, and the comment being
  typed. `--position GAME.cols.position` restores all of it but the dialog.
- `--rounds` opens in Rounds mode rather than Turns.
- `--play` starts playback, at `--speed` turns or rounds per second.
- `--game FILE` chooses where the game columns go (default
  `build/viewer/<stem>.<hash>.cols`), `--no-display` only writes them, and
  `--image FILE` renders a PNG (see [Image output](#image-output)).
- `--knowledge FILE` opens no window: it rebuilds every dragon the recovery
  can, writes each round's team knowledge for each rebuilt team as a
  `knowledge` columns file ([gamedata/format.md](../../gamedata/format.md)), and
  exits. A whole game takes as long as the viewer's rebuild of it.
- `--no-recovery` shows only what the replay recorded, and `--registry`
  selects another build registry.
- `--inbox FILE` is where comments are saved (default
  `build/viewer/comments.md`).

`just showcase` builds the [showcase bot](../../examples/showcase-bot), plays it
against itself on Default and opens the game with both sides rebuilt. The bot
exists to emit every kind of record the viewer draws.

Games follow the [diagnostic contract](diagnostics.md). Each dragon is rerun
over its recorded observations through its side's registered build; its
rebuilt actions are checked against the replay, and its overlays hide after
divergence. The viewer has no strategy-specific adapters.

The board shows recorded truth immediately before the selected dragon's
**same-round** decision. The yellow 7×7 outline is that decision's recorded
observation window, including wraparound. Remembered contents come only from
the bot's own records, drawn by the Mental map and Positions overlays; unknown
memory stays dark. Pearl countdowns on the main board are truth.

`f`, with a dragon focused, switches the board between the whole map and the
15×15 area centred on its head, which follows it round the torus.

Right-click a dragon (or Tab), scroll the inspector, and left-click cells or
edges to highlight them. Shift-click a body to highlight a dragon. Records and
ping rows in the inspector are also selectable. Type a
comment and save it with Enter or Save comment, which keeps the field focused for
the next one. A comment wider than the field scrolls, keeping its end in view as
you type. Saving it appends one line to the inbox file. The line names the replay,
the round (and turn in turn playback), the selected dragon and each highlight,
with cells and edges as `(x,y)`, then the text, and carries the same context as
JSON in an HTML comment at its end. Previous/Next saved restores the round,
dragon, highlights and exact text of this replay's comments while they are
still in the inbox. The line under the field names the match: the replay's
name, each side's bot by the last part of its recorded path with the build
shown for it and how far that build is established, the map, the rounds and
the winner, then the latest message. A side reads `no build`, or the build's
first eight characters and where it came from, `asserted` until a turn is
rebuilt, then how many rebuilt turns match the replay. Its `i` button opens
the replay path, the full bot paths and the build the recovery gives each
team. Beside it, Issues lists what the viewer can't use in the records of
every dragon rebuilt so far, amber with the number of kinds when there is any:
records the recovery rejected, sonar records the replay doesn't bear out,
rebuilt actions that diverged, and memories that name no source
(diagnostics.md, Tables). Each record is checked once as it arrives, and each
kind is listed with its turns, dragons and first appearance, then the focused
decision's own issues. Ctrl-A clears the comment;
Ctrl-V pastes. Text−/Text+ scales the embedded DejaVu Sans font. Raylib's default
font is a small bitmap font; this viewer instead embeds a 48px font atlas and
uses filtered scalable drawing. All overlays except Mental map start enabled.

## Decisions as text

`just decisions REPLAY --seat A|B GUID... (--dragon D... | --team A|B | --all)
[--rounds A-B] [--json]` rebuilds dragons' decisions as the viewer does (`loong-recover decisions`,
replays/recovery/decisions.nim) and prints a block per turn in those
rounds, dragon by dragon, each dragon and its ancestors rebuilt once: the action, the Brain's breakdown and reason, every alternative it
weighed with its eligibility, score and reason, then the dragon's other records
in its own order (option tables, target, route, sonar sent and received, costs),
and what changed in its retained memory this turn. Each dragon's
turns follow a line giving where its build came from, how many rebuilt turns
match the replay, and the round it first diverged, after which its turns are
marked UNRELIABLE and are not the bot's decisions. It lays out the contract's
record kinds and knows nothing of any strategy. `--json` prints one object a
turn, the record as streamed and with retained records rebuilt, for scripts.
It stops recovering once past the last round asked for. A dragon it can't show,
such as one without a registered build, is listed with the reason.

## Image output

The same Odin renderer produces PNG images:

```sh
just viewer REPLAY --seat A GUID --dragon 0 --round 178 --image viewer.png --size 1440x900
```

`--size WIDTHxHEIGHT` sets the starting window size, and so the image's
(default 1600x960). Interface text is 12 pt (16 px) throughout, from the
constants in `typography.odin`; board labels scale with the board instead.

The binary creates a hidden raylib window, renders one frame, saves it and
exits. With a seat, it first waits up to two minutes for the focused dragon's
decisions. It requires a working display and graphics context even though the
window is hidden. Use an existing display, a headless Wayland compositor, or
an X server such as Xvfb with an X11-capable raylib build and software OpenGL.

## Game data

The viewer maps the game's columns ([`gamedata/format.md`](../../gamedata/format.md)),
converted from the replay once by `loong-gamedata` (`just gamedata REPLAY`) and
kept in `build/viewer` until the replay is newer. Nothing is parsed at load
except the small directory. The board shown is rebuilt from the game's events,
with a copy kept every 32 rounds the first time playback passes it, so any board
is at most 32 rounds of events away. A 500-round game's 13.0 MB replay converts
in 0.37 s to a 14.6 MB game file, and the viewer draws its first frame 0.96 s
after start.

Decisions come from `loong-recover` (`replays/recovery/serve.nim`), which
the viewer starts beside itself over pipes and stops when it closes. It reruns
each dragon the viewer asks for through that dragon's registered build and
streams every turn's validated record as the judge answers, and the viewer keeps
them all in memory. Nothing is written to disk but the game columns: the
decisions' recorded inputs, needed only while they load, go to `/dev/shm`. A
dragon's retained records (`retain`, such as its memory table and map) arrive as
what changed since its previous turn, and the viewer rebuilds a turn's records
when it first opens it. What the viewer derives from the records is computed for
the turn on screen: the mental map's grades against the replay, the join of
both ends' sonar records with each ping, and the team's beliefs graded against
the replay.

## Turn playback and inspection

Playback has independent **Rounds** and **Turns** modes, selected beside Play,
and opens in Turns unless `--rounds` is given. The arrow buttons and Up/Down
step one turn or round in that mode; speed uses its units. Left/Right step
between the focused dragon's key turns in Turns mode (below), and otherwise
step like Up/Down. The scroll wheel over the board steps as Left/Right do,
scrolling down to go forward. R switches between Rounds and Turns, as the button
does. The Hotkeys button at the top of the left sidebar lists every key and
gesture (`HOTKEYS` in controls.odin).
Rounds mode shows each round after every dragon has moved in it, so a head is
where that round's sonar pings leave from, with the round's deaths marked. Turns
mode shows the board at the active turn's start, before that dragon moves, and
draws faded every dragon still to move this round, the active one included, with
the deaths so far this round marked.
The arrow keys work even while a comment is being typed or a dialog is open, since
nothing else uses them.
The focused dragon stays fixed while the engine timeline advances, including
rounds before its birth or after its death (where diagnostics are unavailable).
Right-click a dragon to focus it, or an empty cell to clear the highlights and
inspection selections. Defocus in the playback bar drops the focus for the team
view, and becomes Focus D14 to return to that dragon. Tab and Shift-Tab cycle forward/backward within the current team.
Selecting another dragon seeks its turn within the current round in Turns mode.
Focusing a dragon with no diagnostics, such as an enemy's, follows it on the
replay alone: its pings, the replay's spawn countdowns and, with Edges on, a
line joining each portal pair.

The left sidebar owns replay truth, selected-cell information, spawn comparisons,
filters and the legend. The right sidebar owns only the selected dragon's
recorded/recovered worldview and decision. Click a cell or edge to highlight it,
or Shift-click a dragon. Hold the left button and drag to paint cells like a
brush, which erases instead when its first cell was already highlighted.
Shift-drag adds a rectangle and Control-drag a line of cells. Every drag adds
to the selection, and right-clicking an empty cell clears it. A range has no implicit single cell.
Long diagnostic explanations and table rows open with `+` in a scrollable dialog.
Saved annotations retain their exact sub-turn as well as round and dragon.

Fog strongly shades cells outside the selected dragon's current 7×7 observation;
it is a visibility guide over the replay truth, not a claim of remembered contents.
Cell numbers sit in a corner of their cell, a size under the board's labels,
and shrink to fit: evaluated search utility top-left in cream (`?` means not
evaluated), the bot's remembered timers top-right in teal and the true turns
until the next spawn attempt bottom-right in gold. Sonar uses dashed rays and
diamond impacts, distinct from the solid gold of planned paths: purple for the
values the focused decision read, teal for the echoes of its own last sonar.
A ray that came back to its own sender is drawn once, as read. Targets that
share a cell, such as a task's claim and its route's goal, share one circle
with their labels stacked beside it.

Bots observe exact visible countdowns. The hidden per-cell reset distribution is
uniform, not Poisson. The replay exposes its bounds. The spawn comparison labels
a bot's period-estimate error against the true upper bound separately from its
due-round prediction error.

The viewer renders only after input, a visible playback step, resizing, focus
changes, a record arriving from the recovery or an updated watched game or status
file. Drawing is capped at 60 FPS.
Paused windows retain their last frame; input polling sleeps between checks and
watched files are checked every 100 ms. Moves currently switch snapshots without
animation.

The Evaluation pane, the thin sidebar between the team information and the
board, opens with Stats: each side's dragons, longest dragon and total length
after the round on screen, each with a sparkline of both sides over the game
that seeks on click. The same board pass as the evaluation counts them.

The bar at the board's left edge and the Evaluation pane give each side's chance of winning
after the round on screen (in Turns mode, the last round finished), from bceval
0.1.0 by xCirno1 (MIT,
[github.com/xCirno1/battlecode-eval](https://github.com/xCirno1/battlecode-eval),
commit 9c70c71), copied under `references/battlecode-eval`. Its logistic model
scores 23 features per team on the whole board at the start of each round:
bodies, pearls eaten, deaths and head-to-head kills over the last 25 rounds,
the ground nearer each team's heads by walking distance and its spawn supply,
and the champion's nearest heads and free exits. `evaluation.odin` ports its
features and scorer and reads its fitted weights from its `model.json`, and
matches its Python on every round of the two games checked. The pane shows
both chances, A's chance across the game as a strip chart that scrubs like the
timeline, and the log-odds each group of features adds for A.

The left sidebar's judge points show the focused dragon's points this turn
against the 100M limit, and its whole life as a strip chart: orange from 90%,
red where the turn failed, with the toolkit's reason. Click the chart to seek,
or drag along it to scrub, as on the timeline.
It also names the team's costliest dragon this round. Points come from the
`.points.cols` that the Zig judge (`harness/zig_judge/src/run.zig`)
writes beside its replay, carried into the game columns; other replays say they have none. A bot that wants its
own per-stage breakdown emits it as an ordinary table gizmo, read from its
monotonic clock, which the sandbox runs in points.

Timers shows the replay's true spawn countdowns bottom-right. Where the focused
decision states a cell's next spawn (a `spawn_due` truth column), it is graded
as the beliefs strip grades it: a correct memory turns the countdown cyan, and a
wrong one leaves it gold with the remembered countdown in red on the line above,
or `never` for a cell remembered as never spawning. A bot's other timer columns
are drawn top-right in cyan unless it chooses a colour or corner.

Spawn gaps tints each cell's background towards yellow by the maximum of its
true reset range, so fast-spawning ground shows how dense the farming is under
everything drawn on it. The bands, strongest first, are a maximum of at most
10, 20, 100 and 200 rounds, where the bundled maps' maxima cluster (`SPAWN_BANDS` in
`palette.odin`). Slower cells, cells that never spawn and replays that record
no ranges stay plain.

## Decision and memory inspection

The right sidebar renders the bot's generic decision records. A fixed state tree
shows every alternative and its stable parentage. Supplied active/eligibility
flags and scores describe the selected turn, a score named by its objective
such as `suitability 2`; absent evaluation fields stay unknown. A target lists
its cells. A table sizes each column to its contents and scrolls sideways,
with a bar above it, when it is wider than the sidebar. Selecting an alternative opens its attached tables and calculations
in place. No function-call Modules or duplicate Catalog view is maintained.
The viewer never reconstructs a scoring formula or infers a role hierarchy.

The left sidebar charts the focused dragon's team (else the first team that
reports one) by its Brain roots' `breakdown`, such as role and then behaviour:
a stacked strip of each round's turns by the first level, which seeks on click,
then this round's count for each first-level value and, beneath it, for each
second-level value. It says how many of the team's turns this round reported
one, since dragons are rebuilt one at a time. The
producer names the levels and values ([diagnostics.md](diagnostics.md#brain-placement)).

Recovery reruns a dragon's build, marked for inspection, over its recorded observations from
its birth, about 10 ms a turn, and a child after its parent, at low CPU
priority (`nice -n 10`), with half the processor's threads rebuilding a dragon
each (`loong-recover --workers`). It queues every dragon in the match:
the focused dragon (`--dragon`, else the first to move) first, then the other
dragons on the board that round, then the rest. Focusing a dragon moves it to
the front, and reaching a new round, except while playing, moves that round's
dragons in behind it. Every turn stays in memory once it
arrives, so seeking back or forward needs no rerun. Until a turn's decisions
arrive, the inspector says whether its dragon is being rebuilt or waiting and
how many are ahead of it. Under the breakdown chart, a line lists the round's dragons as
rebuilt, rebuilding, waiting, not asked or without diagnostics, the last with
the recovery's note on their build. The arrow left of the Brain tab expands the
inspector over the board and collapses it back, as `B` does.

Brain and Memory (the Sources tab) are producer-selected display slots; either can contain any
generic gizmo kind. Memory has no viewer-prescribed structure. In Turns mode
the focused dragon has two key turns each time it acts: its own, whose board is
what it saw when it decided, and the next, whose board shows the result. Left and
Right step between them. Both show the same Brain and Memory, the decision about
to be made and then the reasons for the move just seen, even when the next turn
falls in the following round. A band under the tabs names the state: gold
"deciding" with the move about to be made while the board is what the dragon
sees, blue "decided" with that move once the board shows the result (always
so in Rounds mode), and grey "waiting" earlier in the round, when every tab
stays empty. A bot should emit Memory as its decision found it, before its
action and sends change it.

The window has six panes, each with a one-pixel border: the two sidebars, the
board and, under it, the beliefs strip, the playback bar and comments. At the end
of the selected turn, the beliefs strip grades each living dragon of one
team (the focused dragon's when the recovery can rebuild it, else the one it
can) that has a rebuilt record against the replay, from its latest record: the
map (edges, pearls, spawn deadlines), where other dragons are, their lengths, and which dragon is each team's champion. Each belief
is a column. Its box reads, for example, `Positions 20/27, 93%`: 20 of the 27
graded dragons hold no false position, and 93% of all stated positions are
right. Under the box are the team's four knowledge measures for the belief
(diagnostics.md, Team knowledge):

| Row | Reads | Meaning |
| --- | --- | --- |
| Connectivity | `54%, 5/9 share` | a stated fact is stated by 54% of the other graded dragons too; 5 of 9 dragons share at least half of what they state |
| Agreement | `97%, 2 disputing` | 97% of pairs of dragons stating one fact agree; 2 dragons are in a contradiction |
| Coverage | `31%, each 12%` | the team states 31% of the facts that exist; each dragon 12% of those it could |
| Validity | `88%, 3/40 misled` | 88% of stated facts are true; 3 of 40 facts two or more dragons state are false for most of them |

Labels and boxes stay neutral, and each figure takes its own colour: green when
complete, yellow when partial, red at none and muted where nothing was
measured. Disputing dragons and misled facts read the other way, green at none.
Click a box for the measures in words, each wrong dragon's false facts, how
many believers are right about each dragon, and the contradictions in its
consensus annotations. A belief annotated for consensus about cells or edges
opens as a map: each fact green where every dragon stating it agrees, red
where any disagree and grey where one dragon alone states it, stronger the more
dragons state it. Click a cell to list each dragon's value for it and its
sides, with the source and round it was learned. The strip's first line says how
many living dragons are graded and why the rest aren't: yet to take a turn or
without diagnostics, with the recovery's reason. Beside the team buttons, a dot
tracks the whole match's rebuilding: amber `Rebuilding 40/45` while dragons are
queued, green `All 45 rebuilt` once every dragon the recovery can rebuild is
done, and red if any failed or the recovery ended first. Refused builds aren't
counted. The rules are in diagnostics.md, Belief correctness.

The Mental map overlay turns the board into the focused dragon's view, graded
against the replay, and hides the replay's own sonar, deaths and fog. Cells it
has no record of are black. Each side is drawn as the dragon believes it, just
inside the cell: remembered kelp solid green, possible kelp dashed orange and
portals violet with a line to their remembered landing from the selected cell.
A cell with a wrong claim is red, solid within its 7×7 window and hatched
beyond it, and a wrongly remembered side is a red line. With Positions on, each
dragon it believes in is a dot where it thinks the dragon is, a square for a
champion, green if the replay's head lies among the cells the dragon says it
may occupy and red if not. Dragons it knows nothing of are grey. Without the
mental map, Positions draws each dot where the dragon was last known or is
likeliest, fading with age. A position shows only that centre, what the dragon
chose to believe, until it is opened: click its centre cell, or highlight its
dragon with Shift-click. Then the cells it may occupy are hatched, strongest
where the bot lists them likeliest, and outlined.

The Sources tab (the Memory slot) lists where the dragon's memory came from. A
cell table there leaves out the edge, pearl and spawn beliefs the board draws,
and a long table's own maps and records come before its rows. The Signals tab opens with the echoes the dragon
read on its turn, each naming what its previous sonar hit and what it meant by
it, then each ping it read, with the sender's own meaning, the receiver's meaning
and outcome, and the receiver's memory rows before and after. Deciding and
decided show the same pings, since what the dragon sends this turn reaches it
only as next turn's echoes. Then comes its sonar table, in both phases, since
choosing what to send each ray, and which rays to leave unsent, is part of the
decision. The Sonar overlay draws the same rays. The bot's other root
records follow, such as its budget and option tables, without the sonar tables
the pings already join. Both follow [diagnostics.md](diagnostics.md) and decode
nothing themselves.

Map annotations can request `display_overlay: "markers"` to place their own
labelled cells on the main board. The viewer never fills private enemy knowledge
from the omniscient replay board.
