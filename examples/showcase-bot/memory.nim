# What the dragon remembers: every cell it has seen, and every dragon it has
# seen or heard of. The viewer grades both against the replay.
import std/[strutils, tables]
from ../repertoire/games/loong/controller import nil
from ../repertoire/games/loong/window import nil
from gizmos import nil
when defined(loongDiagnostics):
  import std/json

const
  DragonEntity = 1
  Sides = "NESW"
  KelpEdge = 1
  ForgetAfter* = 20  # rounds before a sighting is dropped

type
  Cell* = object
    edges*: string    # four tokens, such as "N. Ew S? Wp3"
    pearl*: bool
    spawnDue*: int    # the round a pearl next tries to spawn; -1 never
    seen*: int        # the round this cell was last in view

  Sighting* = object
    ## A dragon seen in the window or heard of over sonar.
    cell*, round*, length*: int
    ours*, exact*: bool
    source*: string

var
  cells*: Table[int, Cell]
  changed: seq[int]  # cells whose record changed this turn
  sightings*: Table[int, Sighting]

proc cellOf*(game: ptr controller.Game, position: controller.Position): int =
  int(position.y) * int(game.width) + int(position.x)

proc edgeTokens(tile: ptr controller.Tile): string =
  var tokens: seq[string]
  for side in 0 .. 3:
    let edge = controller.unswbc_edge(tile, controller.UNSWBC_DIRECTIONS[side])
    let claim =
      if not edge.present: "?"
      elif controller.unswbc_is_portal(edge) != 0: "p" & $controller.unswbc_portal_id(edge)
      elif controller.unswbc_passable(edge) == 0: "w"
      else: "."
    tokens.add Sides[side] & claim
  tokens.join(" ")

proc observe*(ct: ptr controller.Controller, game: ptr controller.Game) =
  ## Fold this turn's window into memory.
  let round = int(game.roundNum)
  let ourTeam = controller.unswbc_team(ct)
  changed.setLen 0
  var segments: Table[int, int]
  var heads: Table[int, (int, bool)]
  for i in 0 ..< window.Tiles:
    let tile = controller.unswbc_tile_at(ct, i.cint)
    let cell = cellOf(game, tile.position)
    let remembered = Cell(edges: edgeTokens(tile),
      pearl: controller.unswbc_has_pearl(tile) != 0,
      spawnDue: (if tile.pearlTime < 0: -1 else: round + int(tile.pearlTime)), seen: round)
    let before = cells.getOrDefault(cell, Cell(seen: -1))
    if before.seen < 0 or before.edges != remembered.edges or before.pearl != remembered.pearl or
        before.spawnDue != remembered.spawnDue:
      changed.add cell
    cells[cell] = remembered
    let entity = controller.unswbc_entity(tile)
    if entity != nil and entity.kind == DragonEntity:
      let id = int(entity.dragonId)
      segments[id] = segments.getOrDefault(id) + 1
      if entity.isHead: heads[id] = (cell, entity.team == ourTeam)
  for id, head in heads:
    let (cell, ours) = head
    if id == int(controller.unswbc_id(ct)): continue
    # The segments in view are a lower bound on its length.
    sightings[id] = Sighting(cell: cell, round: round, length: segments[id], ours: ours,
      exact: false, source: "seen")
  var forgotten: seq[int]
  for id, sighting in sightings:
    if round - sighting.round > ForgetAfter: forgotten.add id
  for id in forgotten: sightings.del id

proc champion*(ownId, ownLength: int): int =
  ## The longest dragon of ours we know of, ourselves included; ties go to the
  ## lowest ID.
  result = ownId
  var longest = ownLength
  for id, sighting in sightings:
    if sighting.ours and (sighting.length > longest or sighting.length == longest and id < result):
      result = id
      longest = sighting.length

proc emit*(round, width: int) =
  ## The retained cell table the Sources tab shows, graded as the mental map.
  ## Only changed cells are sent: `retain` keeps the rest.
  gizmos.diagnosticBlock:
    var rows: seq[JsonNode]
    var rowCells: seq[int]
    for cell in changed:
      let remembered = cells[cell]
      let due = if remembered.spawnDue < 0: "never" else: $remembered.spawnDue
      rows.add %[remembered.edges, "seen", $remembered.seen,
        (if remembered.pearl: "1" else: "0"), "seen", $remembered.seen,
        due, "seen", $remembered.seen, "1"]
      rowCells.add cell
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

    # Pearls remembered out of sight, drawn on the board as markers.
    var markers: seq[JsonNode]
    for cell, remembered in cells:
      if remembered.pearl and remembered.seen < round:
        markers.add %*{"cell": cell, "label": "pearl seen r" & $remembered.seen,
          "color": [232, 200, 114, 255]}
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "map", "label": "Remembered pearls",
      "display_overlay": "markers", "cells": markers,
      "reason": "Pearls last seen on an earlier round, which may have been eaten since"})
