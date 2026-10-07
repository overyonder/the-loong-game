## Each decision's bot-visible input, rebuilt from a game's columns: the init
## block and the turn's protocol-3 observation block. Unrecorded countdowns
## stay unknown (-1); replay data does not record the bot's protocol selection.
## Written as `observations` columns (format.md).

import std/[sets, strutils, tables]
import board, columns
export BoardFailure

const ObservationsVersion = 1'u32

type
  Observation* = object
    ## What the engine sends a dragon at its turn start, as values.
    round*:    int32
    facing*:   char
    length*, units*: int
    messages*: seq[uint64]
    echoes*:   array[5, int]
    x*, y*:    int
    cells*:    array[49, int]        ## the 7x7 view, row by row from its top left

proc observed*(board: var ReconstructedBoard, dragon: int32): Observation =
  ## The dragon's observation at its turn start. Observing takes its waiting
  ## sonar and echoes, as the engine's send did.
  let entry = board.dragons[dragon]
  result.x = entry.body[0] mod board.width
  result.y = entry.body[0] div board.width
  discard board.messages.pop(dragon, result.messages)
  discard board.echoes.pop(dragon, result.echoes)
  for other in board.dragons.values:
    if other.team == entry.team: inc result.units
  result.round = board.round
  result.facing = entry.directions[0]
  result.length = entry.body.len
  var index = 0
  for dy in -3 .. 3:
    for dx in -3 .. 3:
      result.cells[index] = board.cellAt(result.x + dx, result.y + dy)
      inc index

proc observe*(board: var ReconstructedBoard, dragon: int32): (string, string) =
  ## The init and protocol-3 observation blocks at the dragon's turn start.
  ## Consumes its waiting sonar and echoes. Unknown countdowns remain -1.
  let entry = board.dragons[dragon]
  let seen = board.observed(dragon)
  let (x, y) = (seen.x, seen.y)
  let init = "ID " & $dragon & "\nTEAM " & entry.team & "\nMAP " & $board.width & " " &
    $board.height & "\nUNIT_LIMIT " & $board.unitLimit & "\n"
  var lines = @["ROUND " & $seen.round, "DIR " & seen.facing,
    "LENGTH " & $seen.length, "UNIT_COUNT " & $seen.units, "NUM_MSGS " & $seen.messages.len]
  for value in seen.messages: lines.add $value
  lines.add "ECHOES " & seen.echoes.join(" ")
  let visible = seen.cells
  for cell in visible:
    let due = board.due[cell]
    let countdown = if due == NoDue: -1 else: max(0, int(due) - int(board.round))
    lines.add $(cell mod board.width) & " " & $(cell div board.width) & " " &
      $int(board.pearls[cell]) & " " & $countdown
  var parts: seq[string]
  for cell in visible:
    let owner = board.occupied[cell]
    if owner.present:
      parts.add owner.team & " " & $owner.dragon & " " & $(cell mod board.width) & " " &
        $(cell div board.width) & " " & owner.direction & " " & $int(owner.head)
  lines.add "DRAGON_BODIES " & $parts.len
  lines.add parts
  for (side, rows, columns) in [(0, 8, 7), (1, 7, 8)]:
    for row in 0 ..< rows:
      var edges: seq[string]
      for column in 0 ..< columns:
        edges.add board.edges[board.cellAt(x - 3 + column, y - 3 + row) * 2 + side]
      lines.add edges.join(" ")
  (init, lines.join("\n") & "\n\n")

proc listCells(game: ColumnsFileReader, name: string, row: int): seq[int] =
  for cell in game.listRow[:uint32](name, row): result.add int(cell)

proc replayDecisions*(game: ColumnsFileReader, lenient: bool, wanted: proc (dragon: int32): bool,
    visit: proc (board: var ReconstructedBoard, dragon: int32, turn: int)): int =
  ## Rebuild the board event by event and visit each wanted dragon's decision
  ## at its turn start, in game order, before anything observes it. A turn with
  ## no recorded action has no decision. Returns the ambiguous headings taken.
  var board = initialBoard(game.stringRow("meta.map_text", 0), lenient)
  let kinds = game.columnValues[:uint8]("event.kind")
  let a = game.columnValues[:int32]("event.a").values
  let b = game.columnValues[:int32]("event.b").values
  let c = game.columnValues[:int32]("event.c").values
  let d = game.columnValues[:int32]("event.d").values
  let turnEvents = game.columnValues[:uint32]("turn.event")
  let (pingEvents, pingCount) = game.columnValues[:uint32]("ping.event")
  let pingSenders = game.columnValues[:int32]("ping.sender").values
  let pingHits = game.columnValues[:int32]("ping.hit").values
  let pingKinds = game.columnValues[:uint16]("ping.hit_kind").values
  let pingValues = game.columnValues[:uint64]("ping.value").values
  let childFacings = game.columnValues[:uint8]("split.child_facing").values
  var ping = 0
  var turn = 0
  for event in 0 .. kinds.count:
    while ping < pingCount and int(pingEvents[ping]) <= event:
      if pingHits[ping] >= 0: board.messages.mgetOrPut(pingHits[ping], @[]).add pingValues[ping]
      if pingKinds[ping] >= 2:
        board.echoes.mgetOrPut(pingSenders[ping], [0, 0, 0, 0, 0])[int(pingKinds[ping]) - 2] += 1
      inc ping
    if event == kinds.count: break
    case kinds.values[event]
    of 1:
      board.round = a[event]
    of 2:
      while turn < turnEvents.count and int(turnEvents.values[turn]) < event: inc turn
      let dragon = a[event]
      if dragon in board.dragons and wanted(dragon):
        if turn >= turnEvents.count or game.stringRow("turn.action", turn).len == 0:
          # Observing takes the dragon's waiting sonar even without a decision.
          discard board.observed(dragon)
          continue
        visit(board, dragon, turn)
    of 3:
      board.due[a[event]] = board.round + b[event]
    of 4:
      board.pearls[a[event]] = b[event] != 0
    of 5:
      if a[event] notin board.dragons: continue
      board.moveDragon(a[event], int(b[event]), int(c[event]), Directions[d[event]])
    of 6:
      if a[event] notin board.dragons: continue
      board.splitDragon(a[event], b[event], "AB"[c[event]],
        game.listCells("split.parent_body", int(d[event])),
        game.listCells("split.child_body", int(d[event])), Directions[childFacings[d[event]]])
    of 7:
      if a[event] notin board.dragons: continue
      board.removeDragon(a[event])
    else: discard
  board.ambiguous

proc writeObservationColumns*(gamePath, outputPath: string, dragons: HashSet[int32],
    everyDragon, lenient: bool) =
  ## Decisions of `dragons`, or of every dragon, in game order.
  var game = openColumnsFile(gamePath)
  var output = initColumnsFileWriter("observations")
  output.declareColumn("decision.turn", uint32)
  output.declareList("decision.init", uint8)
  output.declareList("decision.observation", uint8)
  let ambiguous = game.replayDecisions(lenient, proc (dragon: int32): bool = everyDragon or dragon in dragons,
    proc (board: var ReconstructedBoard, dragon: int32, turn: int) =
      let (init, observation) = board.observe(dragon)
      output.appendValue("decision.turn", uint32(turn))
      output.appendString("decision.init", init)
      output.appendString("decision.observation", observation))
  output.appendValue("meta.version", ObservationsVersion)
  output.appendValue("meta.ambiguous", uint32(ambiguous))
  game.closeColumnsFile()
  output.writeColumnsFile(outputPath)
