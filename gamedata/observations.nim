## Each decision's bot-visible input, rebuilt from a game's columns: the init
## block and the turn's observation block, exactly as the engine sent them.
## Written as `observations` columns (format.md).

import std/[sets, strutils, tables]
import board, columns
export BoardFailure

const ObservationsVersion = 1'u32

proc observe(board: var ReconstructedBoard, dragon: int32): (string, string) =
  ## The init and observation blocks the dragon was sent at its turn start.
  let entry = board.dragons[dragon]
  let x = entry.body[0] mod board.width
  let y = entry.body[0] div board.width
  let init = "ID " & $dragon & "\nTEAM " & entry.team & "\nMAP " & $board.width & " " &
    $board.height & "\nUNIT_LIMIT " & $board.unitLimit & "\n"
  var messages: seq[uint64]
  discard board.messages.pop(dragon, messages)
  var echoes: array[5, int]
  discard board.echoes.pop(dragon, echoes)
  var units = 0
  for other in board.dragons.values:
    if other.team == entry.team: inc units
  var lines = @["ROUND " & $board.round, "FACING " & entry.directions[0],
    "LENGTH " & $entry.body.len, "UNIT_COUNT " & $units, "SONAR " & $messages.len]
  for value in messages: lines.add $value
  lines.add "ECHOES " & echoes.join(" ")
  var visible: seq[int]
  for dy in -3 .. 3:
    for dx in -3 .. 3: visible.add board.cellAt(x + dx, y + dy)
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
  lines.add "DRAGONS " & $parts.len
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

proc writeObservationColumns*(gamePath, outputPath: string, dragons: HashSet[int32],
    everyDragon, lenient: bool) =
  ## Decisions of `dragons`, or of every dragon, in game order. A turn with no
  ## recorded action has no decision.
  var game = openColumnsFile(gamePath)
  var board = initialBoard(game.stringRow("meta.map_text", 0), lenient)
  var output = initColumnsFileWriter("observations")
  output.declareColumn("decision.turn", uint32)
  output.declareList("decision.init", uint8)
  output.declareList("decision.observation", uint8)
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
      if dragon in board.dragons and (everyDragon or dragon in dragons):
        # Observing takes the dragon's waiting sonar, as the engine's send did.
        let (init, observation) = board.observe(dragon)
        if turn >= turnEvents.count or game.stringRow("turn.action", turn).len == 0: continue
        output.appendValue("decision.turn", uint32(turn))
        output.appendString("decision.init", init)
        output.appendString("decision.observation", observation)
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
  output.appendValue("meta.version", ObservationsVersion)
  output.appendValue("meta.ambiguous", uint32(board.ambiguous))
  game.closeColumnsFile()
  output.writeColumnsFile(outputPath)
