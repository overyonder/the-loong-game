# The showcase bot: simple, readable play whose only purpose is to show every
# kind of record the viewer draws (replays/viewer/diagnostics.md). It chooses
# between four options on one utility scale (options.nim), remembers what it
# has seen (memory.nim) and tells its teammates where it is (sonar.nim).
#
# The records cost nothing in play. They are compiled in, but run only when
# the viewer's recovery reruns the bot over a replay (runtime/gizmos.nim).
import std/tables
from ../repertoire/games/loong/controller import nil
from ../repertoire/games/loong/window import nil
from gizmos import nil
from memory import nil
from options import nil
from sonar import nil
when defined(loongDiagnostics):
  import std/json

proc currentPoints(): uint64 {.importc: "loong_current_points", cdecl.}
  ## Points spent so far, less those spent on diagnostics (runtime/points.c).

type Stage = enum Young, Grown, Parent

var hasSplit = false

proc stageOf(length: int): Stage =
  if hasSplit: Parent elif length >= 6: Grown else: Young

proc turn(ct: ptr controller.Controller, game: ptr controller.Game) =
  var points: seq[(string, uint64)]
  var last = currentPoints()
  template lap(stage: string) =
    let now = currentPoints()
    points.add (stage, now - last)
    last = now

  let round = int(game.roundNum)
  let id = int(controller.unswbc_id(ct))
  let length = int(controller.unswbc_length(ct))
  var cellAt: array[window.Tiles, int]  # each window tile's board cell
  for i in 0 ..< window.Tiles:
    cellAt[i] = memory.cellOf(game, controller.unswbc_tile_at(ct, i.cint).position)
  sonar.listen(ct, game)
  memory.observe(ct, game)
  lap "observe"

  let look = options.look(window.read(ct, -1), length,
    controller.unswbc_can_split(ct, cint(length div 2)) != 0)
  var evaluations: array[options.Option, options.Evaluation]
  var chosen = options.Explore
  for option in options.Option:
    evaluations[option] = options.evaluate(option, look)
    if evaluations[option].eligible and
        (not evaluations[chosen].eligible or evaluations[option].score > evaluations[chosen].score):
      chosen = option
  var side = options.best(evaluations[chosen])
  if chosen != options.Split and side < 0:
    # Every step this option measures is ruled out: keep the most room instead.
    chosen = options.Explore
    side = options.best(evaluations[chosen])
  lap "decide"

  let stage = stageOf(length)
  var action: string
  if chosen == options.Split:
    let child = length div 2
    controller.unswbc_split(ct, cint(child))
    hasSplit = true
    action = "SPLIT " & $child
  else:
    let direction = if side >= 0: controller.UNSWBC_DIRECTIONS[side] else: controller.unswbc_facing(ct)
    controller.unswbc_move(direction)
    action = "MOVE " & $char(cint(direction))
  controller.unswbc_indicator(cstring($chosen))
  sonar.announce(ct, game)
  lap "act"

  gizmos.diagnosticBlock:
    memory.emit(round, int(game.width))

    # Brain: every option in a fixed tree, with its eligibility, score and reason.
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
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "state", "layout": "tree",
      "label": "Options", "slot": "brain", "id": "brain", "nodes": nodes,
      "reason": $chosen & " has the highest utility of the eligible options",
      "breakdown": [{"level": "Stage", "value": $stage}, {"level": "Option", "value": $chosen}]})

    # Under each option: how it scored, and each first step by its own measure.
    for option in options.Option:
      let evaluation = evaluations[option]
      var operands: seq[JsonNode]
      for (name, value) in evaluation.operands: operands.add %*{"name": name, "value": value}
      gizmos.emitGizmoJson($ %*{"version": 1, "kind": "calculation", "label": "Utility",
        "id": $option & "-utility", "parent": $option, "expression": evaluation.formula, "operands": operands,
        "result": evaluation.score})
      if evaluation.measure.len == 0 or option == options.Split: continue
      for candidate in 0 .. 3:
        if evaluation.sides[candidate] == options.Unsafe: continue
        gizmos.emitGizmoJson($ %*{"version": 1, "kind": "candidate",
          "label": "Move " & options.Sides[candidate], "parent": $option,
          "id": $option & "-" & options.Sides[candidate],
          "objective": evaluation.measure, "score": evaluation.sides[candidate],
          "selected": option == chosen and candidate == side})
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "action", "label": action,
      "id": "action", "parent": $chosen, "reason": options.purpose(chosen)})

    # The four first steps as a table, each row opening its safety check.
    var rows, states, rowIds: seq[JsonNode]
    for candidate in 0 .. 3:
      let next = window.neighbour(window.Head, candidate)
      let gap = if next >= 0: window.gapToEnemy(look.view, next) else: 0
      rows.add %[$options.Sides[candidate], (if look.safe[candidate] >= 0: "yes" else: "no"),
        $gap, (if look.safe[candidate] >= 0: $window.room(look.view, look.safe[candidate]) else: "-")]
      states.add %(if chosen != options.Split and candidate == side: "selected"
        elif look.safe[candidate] >= 0: "eligible" else: "ineligible")
      rowIds.add %("move-" & options.Sides[candidate])
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "table", "label": "First steps", "id": "steps",
      "columns": ["side", "safe", "enemy gap", "room"], "rows": rows, "row_states": states,
      "row_ids": rowIds})
    for candidate in 0 .. 3:
      let next = window.neighbour(window.Head, candidate)
      let open = look.view.open[window.Head][candidate]
      let free = next >= 0 and not look.view.occupied[next]
      let gap = if next >= 0: window.gapToEnemy(look.view, next) else: 0
      gizmos.emitGizmoJson($ %*{"version": 1, "kind": "calculation", "label": "Safety",
        "id": "safety-" & options.Sides[candidate], "parent": "move-" & options.Sides[candidate],
        "expression": "safe = open and free and enemy gap > 1",
        "operands": [{"name": "open", "value": int(open)}, {"name": "free", "value": int(free)},
          {"name": "enemy gap", "value": gap}],
        "result": int(open and free and gap > 1)})

    # On the board: the route to the pearl, its target, everything the search
    # reached, the nearest threat and the room each first step leaves.
    if chosen == options.Eat:
      var route: seq[int]
      for tile in look.route: route.add cellAt[tile]
      gizmos.emitGizmoJson($ %*{"version": 1, "kind": "path", "label": "Route to pearl",
        "points": route})
      gizmos.emitGizmoJson($ %*{"version": 1, "kind": "target", "label": "pearl",
        "points": [cellAt[look.pearlAt]]})
    var reached: seq[JsonNode]
    for (tile, steps) in look.reached:
      reached.add %*{"cell": cellAt[tile], "value": steps}
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "search", "label": "Reachable",
      "objective": "moves from the head", "cells": reached})
    if look.threatAt >= 0:
      gizmos.emitGizmoJson($ %*{"version": 1, "kind": "line", "label": "Nearest enemy head",
        "points": [cellAt[window.Head], cellAt[look.threatAt]], "color": [251, 73, 52, 255]})
    var roomRows: seq[JsonNode]
    var roomCells: seq[int]
    for candidate in 0 .. 3:
      if look.safe[candidate] < 0: continue
      roomRows.add %[$options.Sides[candidate], $window.room(look.view, look.safe[candidate])]
      roomCells.add cellAt[look.safe[candidate]]
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "table", "label": "Room",
      "objective": "cells reachable after two moves", "columns": ["side", "room"],
      "rows": roomRows, "row_cells": roomCells, "display_column": 1})

    # Every dragon it knows of, where it may be now, and who it takes for our
    # champion.
    let at = memory.cellOf(game, controller.unswbc_position(ct))
    let champion = memory.champion(id, length)
    var known = @[%*{"cell": at, "radius": 0, "age": 0, "source": "self", "dragon": id,
      "team": "ours", "length": length, "champion": champion == id, "label": "D" & $id & " (self)"}]
    for other, sighting in memory.sightings:
      let age = round - sighting.round
      known.add %*{"cell": sighting.cell, "radius": age, "age": age, "source": sighting.source,
        "dragon": other, "team": (if sighting.ours: "ours" else: "enemy"),
        "length": sighting.length, "length_exact": sighting.exact,
        "champion": sighting.ours and champion == other,
        "label": (if sighting.ours: "our D" else: "enemy D") & $other,
        "color": (if sighting.ours: [127, 176, 105, 255] else: [251, 73, 52, 255])}
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "positions", "label": "Known dragons",
      "positions": known})

    # A graph laid out by the bot: this dragon's stage of life.
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "state", "label": "Stage",
      "reason": "Grown at length 6; Parent after its first split",
      "nodes": [{"id": "young", "label": "Young", "x": 0.1, "y": 0.5, "active": stage == Young},
        {"id": "grown", "label": "Grown", "x": 0.5, "y": 0.5, "active": stage == Grown},
        {"id": "parent", "label": "Parent", "x": 0.9, "y": 0.5, "active": stage == Parent}],
      "links": [{"from": "young", "to": "grown", "label": "length 6"},
        {"from": "grown", "to": "parent", "label": "split"}]})

    # Where this turn's points went, from the clock the bot budgets with.
    var spent: seq[JsonNode]
    for (stage, used) in points: spent.add %[stage, $used]
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "table", "label": "Points",
      "columns": ["stage", "points"], "rows": spent})

proc play() =
  var ct: ptr controller.Controller
  var game: ptr controller.Game
  controller.unswbc_init(ct.addr, game.addr)
  while controller.unswbc_update(ct, game) != 0:
    turn(ct, game)
    controller.unswbc_end_turn()

play()
