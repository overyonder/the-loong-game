# Through one dragon's eyes

> **Editor's note, 2 October 2026.** The viewer now shows roles and tasks on the board and reads a bot's state from memory. It reconstructs the reasoning behind a decision and grades the team's beliefs against the replay, rebuilding only the part of a game being inspected. Saved comments return to their exact context.

When a dragon does something stupid, the official visualiser shows the whole board. But the dragon only saw the 7×7 square around its head, and a move that looks absurd from above can look sensible from inside that square. So the debugging question is never "what was on the board?" but "what could this dragon see, and what did it make of it?" The seventh tool answers both: a debug viewer that shows a game through one dragon's eyes, written in [Odin](https://odin-lang.org) for the reasons in [The choice](03-the-choice.md) and built on the [decoder](09-reading-a-replay.md).

![The viewer on a showcase game at round 178, focused on dragon 0 after all 68 dragons have rebuilt. The left sidebar charts the team's roles and tasks. Scouts are green with magnifying-glass heads, foragers are gold with arrow heads, and parents are blue with crowns. Body patterns show the task. The board is zoomed on the dragon, with its 7×7 window outlined in yellow, a route to a pearl, a red line to the nearest enemy head, and dots where it believes other dragons are. The Brain tab shows Eat selected with utility 6. Under the board, the beliefs strip grades what team A's eight dragons know.](images/viewer-overview.png)

## The window

The board in the middle shows the replay's truth at the moment the focused dragon decides, with its window outlined. Everything the dragon couldn't see is shaded, and `f` zooms to the 15×15 cells round its head. The left sidebar holds the overlay switches, the dragon's judge points against the 100M limit across its whole life, and a chart of the team's decisions by round. The right sidebar is the dragon's own view: what it decided and why, the messages it sent and received, and what it remembers.

Playback moves in turns or in rounds. In Turns mode each dragon's turn is a step, and the left and right arrows jump between the focused dragon's own turns, first with the board as it saw it and then with the result of its move. Rounds mode shows each round after every dragon has moved.

The `Us` button chooses which team the charts, beliefs and role drawings describe. Mirror lays each dragon's reflected path over the matching half of a symmetric map, which lets me compare the two openings on the same ground. Comments belong to the view as much as the overlays do: saving one records the replay, exact turn, focused dragon, highlighted cells and edges, and the words I typed. Previous and Next saved return to that exact context.

Two views read the replay alone. The Evaluation pane gives each side's chance of winning after every round, from [bceval](https://github.com/xCirno1/battlecode-eval) by xCirno1, a logistic model over 23 features of the whole board, such as bodies, pearls eaten, fights and the ground nearer each team. The viewer ports it to Odin. The Spawn gaps overlay tints each cell by how fast pearls come back to it, so the rich ground stands out under everything else.

How the viewer opens a 500-round game in under a second is [its own post](22-game-data-in-columns.md).

## Rebuilt decisions

A replay records what each dragon observed and what it did, but not why. The viewer gets the why from the bot itself. The replay holds every observation a dragon was sent, and a bot is a deterministic program, so running the same build on the same observations gives the same decisions again. This time the bot can explain each one as it makes it.

![In play, bot.wasm has its diagnostics compiled in and switched off, costing one flag check per block. The judge plays the game and writes the replay, with what each dragon observed and did. In the viewer, the same bot.wasm comes from the build registry and is started with LOONG_INSPECT, so its diagnostics run. loong-recover runs it in the judge on each dragon's recorded observations and checks each action, and the viewer draws each turn's records beside the board, hiding a dragon's overlays after its rebuilt action first differs from the replay.](images/viewer-recovery.svg)

The explanations are compiled into the build that plays, but switched off, so in a game each block costs one flag check. The organiser's engine never sends the line that switches them on. Our recovery tool, `loong-recover`, sends it first, then feeds the dragon its recorded observations one turn at a time in the [Zig judge](19-the-machine-inside-the-judge.md). Each rebuilt action is checked against the replay. If one ever differs, that dragon's later turns are marked unreliable and their overlays disappear, since from then on they show some other game.

A bot writes its explanations inside a diagnostic block, which runs only when inspection has switched it on. The Nim helper times itself, too, so the points a block spends are left out of the clock the bot budgets with:

```nim
template diagnosticBlock*(body: untyped) =
  when defined(loongDiagnostics):
    if diagnosticsEnabled != 0:
      if diagnosticDepth == 0:
        let started = rawPoints()
        inc diagnosticDepth
        try:
          body
        finally:
          dec diagnosticDepth
          diagnosticPoints += rawPoints() - started
      else:
        body
```

Each explanation is one JSON record on its own `LOG` line, which the judge lifts out of the bot's output before the engine sees it. The records follow a small [public contract](../replays/viewer/diagnostics.md), and the viewer knows nothing about any strategy. It doesn't know what a role is, or a score formula, or a pearl protocol. It draws what the bot says, in the bot's own words.

## The showcase bot

To show every kind of record, there's a new example: the [showcase bot](../examples/showcase-bot/strategy.nim). Its play is simple on purpose. Each turn it scores four options on one utility scale, as the utility systems of Dave Mark's *Behavioral Mathematics for Game AI* (2009) do, and takes the best eligible one: flee an enemy head within two cells, eat the nearest reachable pearl, split once it's long enough, or explore wherever leaves the most room. It remembers every cell it has seen and every dragon it has seen or heard of, and it tells its teammates by sonar where its head is and how long it is.

From `examples/tooling`, `just showcase` builds it, plays it against itself on Default and opens the game. `just bot-build` registers each judge build under a GUID, with the hash of every source file and of the WebAssembly, so the viewer reruns exactly the build that played, and `just viewer REPLAY --seat A GUID` names it for a side. In this game all 68 dragons rebuilt, and all 7,941 of their rebuilt turns matched the replay.

## Records on the board

Some records draw on the board itself. Each has its own overlay switch.

![Records the viewer draws on the board, each on a small board. A line joins two cells, such as a threat. A target marks a cell with its label beside it. A path is cells in the order they're walked. A search gives cells a value each. Map markers are labelled cells from the bot's memory. Positions show where a dragon was, and every cell it may have reached since.](images/gizmo-board.svg)

The showcase bot draws its route to the pearl it's eating as a path and the pearl as a target, every cell its search reached with the number of moves to it, and a line to the nearest enemy head. Pearls it remembers from earlier rounds become markers. A positions record lists every dragon it knows of: where it last saw it or heard of it, and how many rounds ago. The viewer shades every cell the dragon could have reached since, as far as the bot says it could move.

## Records in the inspector

The rest lay out in the right sidebar.

![Records the inspector lays out. A state tree shows each option with its eligibility, score and reason, and the chosen one opens its children. A state graph places nodes at the bot's own coordinates, fills the active one and labels links with their conditions. A candidate has a score and what it measures, and scores from different objectives are never compared. A table marks rows selected, eligible or ineligible, and a row can open records of its own. A calculation shows the bot's expression, operands and result, and the viewer evaluates nothing. A sonar table joins the sender's meaning with the receiver's reading and outcome, on the ping the replay recorded.](images/gizmo-inspector.svg)

One record fills the Brain tab. The showcase bot sends its options as a tree, each with whether it was eligible, its utility and the reason, and it marks which one it took. The `breakdown` field gives the left sidebar its chart of the team's decisions, here by role and then task. It also gives each role a colour and head icon, and each task a body pattern:

```nim
var nodes = @[%*{"id": "dragon", "label": "Dragon", "parent": ""}]
for option in options.Option:
  let evaluation = evaluations[option]
  var node = %*{"id": $option, "label": $option, "parent": "dragon",
    "eligible": evaluation.eligible, "reason": options.purpose(option) & ". " & evaluation.reason,
    "active": option == chosen}
  if evaluation.eligible:
    node["score"] = %evaluation.score
    node["objective"] = %"utility"
  nodes.add node
let roleLook = case role
  of Scout: %*{"level": "Role", "value": "Scout",
    "color": [72, 170, 123, 255], "icon": "magnifier"}
  of Forager: %*{"level": "Role", "value": "Forager",
    "color": [232, 200, 114, 255], "icon": "arrow"}
  of Parent: %*{"level": "Role", "value": "Parent",
    "color": [105, 150, 214, 255], "icon": "crown"}
let pattern = case chosen
  of Flee: "crosshatch"
  of Eat: "stripes"
  of Split: "dots"
  of Explore: "dither"
inspect.summary($ %*{"version": 1, "kind": "state", "layout": "tree",
  "label": "Options", "slot": "brain", "id": "brain", "nodes": nodes,
  "reason": $chosen & " has the highest utility of the eligible options",
  "breakdown": [roleLook,
    %*{"level": "Task", "value": $chosen, "pattern": pattern}]})
```

Any record can give a parent, another record or a node of the tree, and clicking a node opens its children underneath. Under Eat, this dragon's calculation shows the utility of 6, then each move it could make, scored by the moves left to the pearl, then the move it made:

![The Brain tab with Eat opened. Its reason reads: take the nearest pearl we can reach, a pearl is 2 moves away. Under it, a calculation, utility = 8 − moves with moves 2 and result 6, then two candidates, Move N and Move W, each scored −1 by moves to the pearl, Move N chosen, and the action MOVE N.](images/viewer-brain.png)

The Signals tab starts with sonar. The showcase bot sends one table of what it transmitted and another of what it received, each row with what the value meant to it. The viewer joins both ends on the pings the replay recorded, so a message shows the sender's meaning beside the receiver's reading of it, what the receiver did about it, and its memory of the cells involved before and after. A message that no ping bears out is listed as a fault. Then come the echoes of the dragon's own last pings, and the rest of its records, such as a table of the four first steps and the role it has reached, as a small state graph.

![The Signals tab at round 178. Echoes of dragon 0's round-177 sonar: north hit kelp, east hit an enemy body, south hit kelp, west hit an allied head, each sent as D0's head, length 6. Then a ping received from dragon 2: the sender's meaning, D2's head, length 7; the receiver's reading, the same; its outcome, position of D2 updated; and the receiver's memory of that cell, unchanged. Below starts the table of values it sent.](images/viewer-signals.png)

`just decisions` prints the same records as text, dragon by dragon and turn by turn, for reading a whole stretch of a game at once or searching it:

![just decisions for dragon 0 at round 178. It says the build was taken from --seat A and that 179 of 179 rebuilt turns match the replay. Then the turn: MOVE N, the breakdown Role Parent, Task Eat, the tree of four options with their states and reasons, the sonar sent and received, and the utility calculations and candidates under each option.](images/viewer-decisions.png)

## State from memory

Writing a second description of a bot's state is an easy way to make a debugger lie. The public introspection helper takes another route. The bot gives the judge the address of a small region table and a schema made from its Nim types. While the bot is paused in that write, the judge copies those regions from WebAssembly memory. Objects become tables, enums keep their names, references are followed once, and arrays laid over the board become cell or edge records. The bot does not list its fields by hand.

The showcase bot exposes the record it just used to decide. Here the Sources tab has reflected its round, dragon, length, role, task and whether it has split. The Mental map above it is still the ordinary retained record the bot chose to emit.

![The Sources tab for dragon 0 at round 178. Under its Mental map is State, read from the bot's memory: round 178, dragon 0, length 7, role Parent, task Eat and hasSplit true. The board and the role-and-task chart remain beside it, and all 68 dragons have rebuilt.](images/viewer-state.png)

The same capture can include the state at the start and end of a turn. The released recovery adapter uses those two views to lay out a role-and-task bot's full Brain: the suitability and eligibility of every role, the utility calculation for every offered task, the task's states and phases, and the checks that made each active or inactive. Claims, task claims, orders, right-of-way rays and movement choices attach beneath the decision that used them. The viewer still knows none of those concepts. The adapter turns the bot's recorded structures into the same generic trees, tables and calculations as the showcase bot emits.

Capturing all of that for every turn would make a long game slow and large. The viewer asks for detailed records only in a window around the round on screen. Every other turn runs with diagnostics off, except for a small role-and-task summary used by the chart, and every action is still checked. When I move outside the window, recovery resumes the bot from a memory-bounded checkpoint before the new one. Focusing a dragon also asks for its state, rebuilding that dragon if its earlier pass did not capture it. `--buffer` changes the window, and `--memory` or `--memory-share` sets the checkpoint allowance.

## Graded memory

A bot's mistakes often start in what it believes rather than in what it decides. The viewer can check beliefs, because it has the replay's truth to compare them with. A bot marks a remembered fact with the quantity it claims: which sides of a cell have kelp, whether a pearl is there, the round its next pearl is due, where another dragon is and how long, and which dragon is a team's champion. Every fact carries where it came from and the round it was learned.

The showcase bot keeps its map as one table, one row per cell it has seen. It sends only the rows that changed, and `retain` tells the viewer to keep the rest:

```nim
gizmos.emitGizmoJson($ %*{"version": 1, "kind": "table", "label": "Mental map",
  "slot": "memory", "id": "memory", "retain": true,
  "reason": "Every cell seen, as last seen",
  "columns": ["edges", "edges.source", "edges.round", "pearl", "pearl.source", "pearl.round",
    "spawn", "spawn.source", "spawn.round", "known"],
  "truth_columns": ["edges", "", "", "pearl", "", "", "spawn_due", "", "", ""],
  "rows": rows, "row_cells": rowCells,
  "display_column": 6, "display_overlay": "timers", "display_format": "round_delta",
  "consensus": [
    {"category": "Pearls", "column": 3, "known_column": 9, "minimum": 1, "scope": "cell"},
    {"category": "Spawn rounds", "column": 6, "known_column": 9, "minimum": 1, "scope": "cell"}]})
```

The Mental map overlay turns the board into that memory. Cells the dragon has never seen are black. Remembered kelp is drawn as the dragon believes it, and a cell whose remembered contents the replay contradicts turns red. With Positions on, each dragon it believes in is a dot where it thinks the dragon is, green if the dragon really is among the cells it allowed for and red if not. Clicking a dot hatches those cells, strongest where the bot thinks the dragon likeliest. The Sources tab lists the selected cell's memory with its sources.

Champion markings keep the belief and the replay's truth visible together. The enemy's actual longest dragon has a red crown, or a grey one where the focused dragon's Mental map doesn't know it. The enemy it believes to be champion is written inside that crown, green when it chose the right dragon and yellow when it did not. A yellow question mark means it named none.

![The Mental map overlay at round 178. The board the dragon has seen shows its remembered kelp in bright green, the parts it has never seen are black, and a few pearl cells are hatched red where its memory is wrong. Dots mark where it believes other dragons are, green where they are and red for two teammates it last heard of 2 and 11 rounds ago. The Sources tab shows the selected cell's memory: its edges, pearl and spawn round, each seen at round 176.](images/viewer-mental-map-positions.png)

The strip under the board does this for the whole team at once. Each belief is a column. Its box says how many of the team's living dragons hold it without a single false fact, and what share of all their stated facts are right. Under the box are four measures of the team's knowledge, taken from the properties a consensus protocol must have (Lynch, *Distributed Algorithms*, 1996, chapters 5 and 6):

- **Connectivity** is how far each fact has spread: the share of the other dragons that state it too, as an update spreads between sites in the epidemic protocols of [Demers and colleagues](https://doi.org/10.1145/41840.41841) (1987).
- **Agreement** is the share of pairs of dragons stating the same fact that don't contradict each other.
- **Coverage** is the share of the facts that exist that any dragon states. It stands in for termination, where every process eventually decides.
- **Validity** is the share of stated facts that are true.

Each figure is green when complete, yellow when partial and red at none. Clicking a box explains the measures in words and lists every wrong fact. Where the bot marks a column for consensus, a belief about cells opens as a map, coloured by whether the dragons that state each cell agree:

![The Pearls belief for team A at round 178. The map is mostly green, where every dragon stating a pearl agrees, with red cells where they disagree. The detail for cell (13,29) lists six dragons that remember it with no pearl, each with the round they saw it. Below, 3,775 of 3,884 stated facts are correct, then the four measures in words: connectivity 61%, agreement 98% with 191 of 8,288 pairs contradicting, coverage 84% and validity 97%. Then each dragon's wrong facts are listed, such as a pearl remembered absent that the replay has present.](images/viewer-belief-map.png)

These numbers show the showcase bot's memory has two simple faults. It keeps a pearl it saw on an earlier round as present, or absent, until it sees that cell again, so the strip counts every pearl eaten or grown out of its sight. It also keeps a spawn round after that round has passed. Neither shows up in how the dragons move, and both are one click away here. The Our champion column shows the team also disagrees about its champion: only 2 of the 8 dragons have it right.

The comment field under the playback bar takes notes. A saved comment carries the round, the dragon and any cells highlighted, so Previous and Next saved take you back to exactly what you were looking at.

## Long dragons

Back to the question from the last post: why do the pearl chaser's dragons hit walls and themselves so much more often than the plain flood-fill bot's? Neither bot writes any diagnostics, so the viewer shows them from the replay alone. Here's one on the bundled Autarky map, as it starts its last turn:

![The viewer at round 208 of room-c against room-pearls on Autarky, a wide map. Dragon 7 of room-pearls is focused: its head is in a small walled box on the left, inside its yellow window, and the rest of its 27-segment body lies on the right side of the board, drawn faded because it has yet to move this turn. Lines join the ends of each portal pair across the board.](images/viewer-long-dragon-portal.png)

Its head is inside a small walled box that the dragon can only have entered through a portal, and most of its body is back on the other side of the board, far outside its 49-tile window. Its next move went north through the portal edge and landed on its own body on the far side. That's the portal blind spot from [the map generator post](06-maps-nobody-has-seen.md), and 28 of the pearl chaser's 91 self-hits in these games went through a portal the same way.

The next one has no portal to blame. Pale Maze, one of the generated maps, has no portals, and this dragon had grown to 55 segments:

![The viewer at round 130 of room-c against room-pearls on Pale Maze, a 26×50 generated map with no portals. Dragon 9 of room-pearls is 55 segments long, and its head, inside its yellow window, is enclosed by a loop of its own body.](images/viewer-long-dragon.png)

Its head is wound inside a loop of its own body, so most of what its window shows is itself. The flood fill only counts room inside the window, so it has almost nothing to choose between moves with, and the next move ran into its own body.

Across all 70 games the numbers agree. Chasing pearls works, in that dragons get long, and the ones that die on their own bodies are long too:

![Median dragon lengths across the 70 games. The longest dragon per game: 22 segments for room-c and 46.5 for room-pearls. Dragons that hit themselves: 8.5 for room-c and 27 for room-pearls.](images/pearl-lengths.svg)

A third of the pearl chaser's self-hits were dragons longer than 49 segments, too long to fit in their own window. The flood fill was designed for a short dragon, and chasing pearls takes that assumption away. A bot that grows long needs to know where its own body is outside its window, which is a job for strategy.

## Next up

The last tool on the wishlist is profiling: [where the points go](12-where-the-points-go.md).
