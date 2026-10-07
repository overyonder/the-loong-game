## One game's `result` columns (format.md): how the game was played and ended,
## and each side's economy, computed from the game's columns in one pass over
## its events.

import std/[sets, strutils, tables]
import columns

const
  ResultVersion = 1'u32
  WinnerNames   = ["a", "b", "draw"]
  ResultNames   = ["elimination", "length"]
  StatusNames   = ["completed", "error", "timeout"]
  DeathColumns  = ["side.deaths_hit_wall", "side.deaths_hit_itself",
                   "side.deaths_hit_dragon", "side.deaths_head_to_head",
                   "side.deaths_no_action"]   ## by the engine's reason code
  OverLimitFailures = ["exceeded CPU limit", "ran out of time"]

type
  GameHarnessFacts* = object
    ## What the match harness knows about a game beyond its replay.
    map*:            string    ## the map played, for a game with no replay
    seed*:           uint64
    bots*:           array[2, string]
    exitCode*:       int32
    timedOut*:       bool
    elapsedSeconds*: float32
    slotSeconds*:    float32   ## the worker slot's time; 0 when played locally
    hasSlotSeconds*: bool

  SideEconomy = object
    pearls, pearlsByLength, dragonTurns, splits: uint32
    deaths:                                     array[5, uint16]
    units, longest, totalLength:                uint32
    bestFedIntake:                              uint32
    peakPoints:                                 uint64
    exceeded:                                   uint16
    visited:                                    HashSet[uint32]

proc column[T](game: ColumnsFileReader, name: string): ptr UncheckedArray[T] =
  game.columnValues[:T](name).values

proc columnCount(game: ColumnsFileReader, name: string): int =
  if name in game.columns: game.columns[name].count else: 0

proc sideEconomies(game: ColumnsFileReader): array[2, SideEconomy] =
  ## As the result columns pipeline counted them from the replay: a pearl
  ## leaving a tile is eaten by the dragon whose turn started last, and length
  ## gained on a turn's second and later steps is net of the step's cost.
  var sides: array[2, SideEconomy]
  var teams: Table[int32, uint8]
  var bodies: Table[int32, seq[int32]]
  var eaten: Table[int32, uint32]
  var substeps: Table[int32, int]   ## dragons in a turn: steps taken so far
  for row in 0 ..< game.columnCount("start.dragon"):
    let dragon = int32(game.column[:uint32]("start.dragon")[row])
    let team = game.column[:uint8]("start.team")[row]
    var body: seq[int32]
    for cell in game.listRow[:uint32]("start.body", row): body.add int32(cell)
    teams[dragon] = team
    bodies[dragon] = body
    if body.len > 0: sides[team].visited.incl uint32(body[0])
  let kinds = game.column[:uint8]("event.kind")
  let a = game.column[:int32]("event.a")
  let b = game.column[:int32]("event.b")
  let c = game.column[:int32]("event.c")
  let d = game.column[:int32]("event.d")
  let turnEvents = game.column[:uint32]("turn.event")
  let turnRows = game.columnCount("turn.event")
  var turnRow = 0
  var lastTurn = -1'i32
  for event in 0 ..< game.columnCount("event.kind"):
    case kinds[event]
    of 2:
      lastTurn = a[event]
      while turnRow < turnRows and int(turnEvents[turnRow]) < event: inc turnRow
      if lastTurn in bodies:
        substeps[lastTurn] = 0
        inc sides[teams[lastTurn]].dragonTurns
        # A split is counted when a dragon alive at its turn start asks for one.
        if turnRow < turnRows and game.stringRow("turn.action", turnRow).startsWith("SPLIT"):
          inc sides[teams[lastTurn]].splits
    of 4:
      if b[event] == 0 and lastTurn >= 0 and lastTurn in teams:
        inc sides[teams[lastTurn]].pearls
        eaten.mgetOrPut(lastTurn, 0) += 1
    of 5:
      let dragon = a[event]
      if dragon notin bodies: continue
      let team = teams[dragon]
      let body = addr bodies[dragon]
      let before = body[].len
      body[].insert(b[event], 0)
      while body[].len > 1 and body[][^1] != c[event]: body[].setLen(body[].len - 1)
      sides[team].visited.incl uint32(b[event])
      var paid = 0
      if dragon == lastTurn and dragon in substeps:
        if substeps[dragon] > 0: paid = 1
        inc substeps[dragon]
      let grew = body[].len - before + paid
      if grew > 0: sides[team].pearlsByLength += uint32(grew)
    of 6:
      let parent = a[event]
      let child = b[event]
      substeps.del parent
      var parentBody, childBody: seq[int32]
      for cell in game.listRow[:uint32]("split.parent_body", int(d[event])): parentBody.add int32(cell)
      for cell in game.listRow[:uint32]("split.child_body", int(d[event])): childBody.add int32(cell)
      bodies[parent] = parentBody
      bodies[child] = childBody
      teams[child] = uint8(c[event])
    of 7:
      let dragon = a[event]
      if dragon in teams and b[event] in 0'i32 .. 4'i32:
        inc sides[teams[dragon]].deaths[b[event]]
      bodies.del dragon
      substeps.del dragon
    else: discard
  for dragon, intake in eaten:
    let side = addr sides[teams[dragon]]
    side.bestFedIntake = max(side.bestFedIntake, intake)
  let turnTeams = game.column[:uint8]("turn.team")
  let turnPoints = game.column[:uint64]("turn.points")
  for row in 0 ..< game.columnCount("turn.team"):
    let side = addr sides[turnTeams[row]]
    side.peakPoints = max(side.peakPoints, turnPoints[row])
    if game.stringRow("turn.failure", row) in OverLimitFailures: inc side.exceeded
  for team in 0 .. 1:
    sides[team].units = game.column[:uint32]("standing.units")[team]
    sides[team].longest = game.column[:uint32]("standing.longest")[team]
    sides[team].totalLength = game.column[:uint32]("standing.total_length")[team]
  sides

proc writeResultColumns*(gamePath: string, facts: GameHarnessFacts, outputPath: string) =
  ## `gamePath` is empty for a game that left no replay.
  var record = initColumnsFileWriter("result")
  record.appendValue("meta.version", ResultVersion)
  for (name, names) in [("enum.winner", @WinnerNames), ("enum.result", @ResultNames),
      ("enum.status", @StatusNames)]:
    for text in names: record.appendString(name, text)
  let played = gamePath.len > 0
  let status = if facts.timedOut: 2'u8 elif facts.exitCode != 0 or not played: 1'u8 else: 0'u8
  var game: ColumnsFileReader
  var tiles = 0
  var sides: array[2, SideEconomy]
  var mapName = facts.map
  if played:
    game = openColumnsFile(gamePath)
    tiles = int(game.column[:uint32]("meta.width")[0] * game.column[:uint32]("meta.height")[0])
    mapName = game.stringRow("meta.map_name", 0)
    sides = sideEconomies(game)
  record.appendString("game.map", mapName)
  record.appendValue("game.map_tiles", uint32(tiles))
  record.appendValue("game.seed", facts.seed)
  record.appendValue("game.rounds", uint16(if played: game.columnCount("round.event") else: 0))
  record.appendValue("game.rounds?", uint8(played))
  let winner = if played: game.column[:int8]("meta.winner")[0] else: -1'i8
  record.appendValue("game.winner", uint8(if winner < 0: 2 else: winner))
  record.appendValue("game.winner?", uint8(played))
  record.appendValue("game.result", uint8(if played: game.column[:uint16]("meta.end_reason")[0] else: 0))
  record.appendValue("game.result?", uint8(played))
  record.appendValue("game.status", status)
  record.appendValue("game.exit_code", facts.exitCode)
  record.appendValue("game.elapsed_seconds", facts.elapsedSeconds)
  record.appendValue("game.slot_seconds", facts.slotSeconds)
  record.appendValue("game.slot_seconds?", uint8(facts.hasSlotSeconds))
  for team in 0 .. 1:
    let side = sides[team]
    record.appendValue("side.game", 0'u32)
    record.appendValue("side.team", uint8(team))
    record.appendString("side.bot", facts.bots[team])
    record.appendValue("side.pearls", side.pearls)
    record.appendValue("side.pearls_by_length", side.pearlsByLength)
    record.appendValue("side.dragon_turns", side.dragonTurns)
    record.appendValue("side.pearls_per_dragon_turn",
      float32(if side.dragonTurns > 0: side.pearls.float / side.dragonTurns.float else: 0.0))
    record.appendValue("side.splits", uint16(side.splits))
    var deaths = 0'u16
    for reason, name in DeathColumns:
      record.appendValue(name, side.deaths[reason])
      deaths += side.deaths[reason]
    record.appendValue("side.deaths", deaths)
    record.appendValue("side.final_units", uint16(side.units))
    record.appendValue("side.final_longest", uint16(side.longest))
    record.appendValue("side.final_total_length", side.totalLength)
    record.appendValue("side.best_fed_intake", side.bestFedIntake)
    record.appendValue("side.best_fed_share",
      float32(if side.pearls > 0: side.bestFedIntake.float / side.pearls.float else: 0.0))
    record.appendValue("side.peak_points", side.peakPoints)
    record.appendValue("side.exceeded", side.exceeded)
    record.appendValue("side.tiles_visited", uint32(side.visited.len))
    record.appendValue("side.head_coverage",
      float32(if tiles > 0: side.visited.len.float / tiles.float else: 0.0))
  if played: game.closeColumnsFile()
  record.writeColumnsFile(outputPath)
