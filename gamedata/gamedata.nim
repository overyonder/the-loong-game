## `loong-gamedata`: write a replay's `game` columns (format.md) from the packed
## Cap'n Proto replay and its judge points file, a game's `result` columns, or
## a run's merged results, and summarise replays. `Usage` below lists the
## commands.

import std/[os, strutils, tables]
import columns, capnp_replay, gzip_inflate
when isMainModule:
  import std/sets
  import decode, observations, result

const GameVersion = 1'u32

type
  TurnBeingRead = object
    round, dragon: int32
    team:          uint8
    event:         uint32
    action:        string
    points:        uint64
    failure:       string
    pointsKnown:   bool
    log:           string

proc pointsFileFor(replay: string): string =
  ## The replay's judge points (harness/zig_judge/src/run.zig): beside it, or
  ## in its result directory's game store.
  let beside = replay.changeFileExt("points.cols")
  let stored = replay.parentDir / "store" / beside.extractFilename
  if not fileExists(beside) and fileExists(stored): stored else: beside

proc cellOf(message: CapnpMessage, point: CapnpStruct, width: int32): uint32 =
  uint32(message.int32Field(point, 1) * width + message.int32Field(point, 0))

proc actionLabel(message: CapnpMessage, dragonAction: CapnpStruct): string =
  ## The action as the observation protocol spells it; NO_ACTION when unset.
  if not message.hasPointer(dragonAction, 0): return "NO_ACTION"
  let action = message.structField(dragonAction, 0)
  case message.uint16Field(action, 0)
  of 0:
    let moves = message.listField(action, 0)
    result = "MOVE "
    for step in 0 ..< moves.count: result.add "NESW"[int(message.uint16Element(moves, step))]
  of 1: result = "SPLIT " & $message.int32Field(action, 1)
  else: result = "SUICIDE"

proc writeGameColumns*(replayPath, outputPath: string) =
  var packed = readFile(replayPath)
  if packed.isGzip: packed = packed.gunzip
  let message = readCapnpPackedMessage(packed.toOpenArrayByte(0, packed.high))
  let replay = message.root
  let mapText = message.textField(replay, 0)
  var game = initColumnsFileWriter("game")
  # Tables a game may leave empty still have their columns.
  for name in ["edge.x", "edge.y", "spawn.cell", "ping.origin", "ping.end",
      "ping.event"]: game.declareColumn(name, uint32)
  for name in ["edge.portal", "spawn.minimum", "spawn.maximum", "ping.round",
      "ping.sender", "ping.hit", "ping.received_round"]: game.declareColumn(name, int32)
  for name in ["edge.side", "ping.direction", "split.child_facing"]: game.declareColumn(name, uint8)
  game.declareColumn("ping.hit_kind", uint16)
  game.declareColumn("ping.value", uint64)
  for name in ["split.parent_body", "split.child_body"]: game.declareList(name, uint32)
  var width, height: int32
  var mapName = replayPath.splitFile.name
  var teams: Table[int32, uint8]
  var startCount = 0'i32
  for line in mapText.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 0: continue
    case fields[0]
    of "MAP":
      width = int32(parseInt(fields[1]))
      height = int32(parseInt(fields[2]))
    of "MAP_NAME":
      mapName = fields[1 .. ^1].join(" ")
    of "EDGE":
      let identifier = parseInt(fields[1])
      let kind = parseInt(fields[2])
      if kind notin [1, 2]: continue
      let row = identifier div (width + 1)
      game.appendValue("edge.x", uint32(identifier mod (width + 1) mod width))
      game.appendValue("edge.y", uint32(row div 2 mod height))
      game.appendValue("edge.side", uint8(row mod 2))
      game.appendValue("edge.portal", int32(if kind == 1: -1 else: parseInt(fields[3])))
    of "TILE":
      game.appendValue("spawn.cell", uint32(parseInt(fields[2]) * width + parseInt(fields[1])))
      game.appendValue("spawn.minimum", int32(parseInt(fields[3])))
      game.appendValue("spawn.maximum", int32(parseInt(fields[4])))
    of "DRAGON":
      var values: seq[int]
      for field in fields[1 .. ^1]: values.add parseInt(field)
      var body: seq[uint32]
      var at = 2
      while at + 1 < values.len:
        body.add uint32(values[at + 1] * width + values[at])
        at += 2
      game.appendValue("start.dragon", uint32(startCount))
      game.appendValue("start.team", uint8(values[0]))
      game.appendList("start.body", body)
      teams[startCount] = uint8(values[0])
      inc startCount
    else: discard

  var points: Table[(int32, int32), (uint64, string)]
  let pointsPath = pointsFileFor(replayPath)
  if fileExists(pointsPath):
    var record = openColumnsFile(pointsPath)
    let rounds = record.columnValues[:int32]("turn.round")
    let dragons = record.columnValues[:uint32]("turn.dragon").values
    let spent = record.columnValues[:uint64]("turn.points").values
    let failureStarts = record.columnValues[:uint64]("turn.failure#").values
    let failureBytes = record.columnValues[:uint8]("turn.failure").values
    for row in 0 ..< rounds.count:
      var failure = ""
      for at in int(failureStarts[row]) ..< int(failureStarts[row + 1]): failure.add char(failureBytes[at])
      points[(rounds.values[row], int32(dragons[row]))] = (spent[row], failure)
    record.closeColumnsFile()

  var turns: seq[TurnBeingRead]
  var pingReceived: seq[int32]         ## per ping: the round its target next moved, or -1
  var awaitingTarget: Table[int32, seq[int]]  ## dragon to its unread pings
  var active = -1                     ## the turn whose action and logs follow
  var round = -1'i32
  var eventCount = 0'u32
  proc addEvent(game: var ColumnsFileWriter, kind: uint8, a, b, c, d: int32) =
    game.appendValue("event.kind", kind)
    game.appendValue("event.a", a)
    game.appendValue("event.b", b)
    game.appendValue("event.c", c)
    game.appendValue("event.d", d)
    inc eventCount

  let events = message.listField(replay, 3)
  for index in 0 ..< events.count:
    let event = events.listStruct(index)
    let member = message.structField(event, 0)
    case message.uint16Field(event, 0)
    of 0:
      round = message.int32Field(member, 0)
      game.appendValue("round.event", eventCount)
      game.addEvent(1, round, 0, 0, 0)
      active = -1
    of 1:
      let dragon = message.int32Field(member, 0)
      for ping in awaitingTarget.getOrDefault(dragon): pingReceived[ping] = round
      awaitingTarget.del dragon
      let (turnPoints, failure) = points.getOrDefault((round, dragon), (0'u64, ""))
      turns.add TurnBeingRead(round: round, dragon: dragon, team: teams.getOrDefault(dragon),
        event: eventCount, points: turnPoints, failure: failure,
        pointsKnown: (round, dragon) in points)
      active = turns.high
      game.addEvent(2, dragon, 0, 0, 0)
    of 2:
      let tile = message.structField(member, 0)
      game.addEvent(3, int32(message.cellOf(tile, width)), message.int32Field(member, 0), 0, 0)
    of 3:
      let tile = message.structField(member, 0)
      game.addEvent(4, int32(message.cellOf(tile, width)),
        int32(message.boolField(member, 0)), 0, 0)
    of 4:
      let dragon = message.int32Field(member, 0)
      if active >= 0 and turns[active].dragon == dragon:
        turns[active].action = message.actionLabel(member)
    of 6:
      if active >= 0 and turns[active].dragon == message.int32Field(member, 0):
        if turns[active].log.len > 0: turns[active].log.add '\n'
        turns[active].log.add message.textField(member, 0)
    of 9:
      if round >= 0:
        game.addEvent(5, message.int32Field(member, 0),
          int32(message.cellOf(message.structField(member, 0), width)),
          int32(message.cellOf(message.structField(member, 1), width)),
          int32(message.uint16Field(member, 2)))
    of 10:
      let parent = message.int32Field(member, 0)
      let child = message.int32Field(member, 1)
      let team = uint8(message.uint16Field(member, 4))
      teams[child] = team
      for (name, pointerIndex) in [("split.parent_body", 0), ("split.child_body", 1)]:
        let body = message.listField(member, pointerIndex)
        var cells: seq[uint32]
        for segment in 0 ..< body.count: cells.add message.cellOf(body.listStruct(segment), width)
        game.appendList(name, cells)
      game.appendValue("split.child_facing", uint8(message.uint16Field(member, 5)))
      let splitRow = int32(game.valueCount("split.parent_body#") - 2)
      game.addEvent(6, parent, child, int32(team), splitRow)
    of 11:
      game.addEvent(7, message.int32Field(member, 0), int32(message.uint16Field(member, 2)), 0, 0)
    of 12:
      game.appendValue("ping.round", round)
      game.appendValue("ping.sender", message.int32Field(member, 0))
      let hit = message.uint16Field(member, 3) == 1
      let target = if hit: message.int32Field(member, 3) else: -1'i32
      game.appendValue("ping.hit", target)
      game.appendValue("ping.event", eventCount)
      pingReceived.add -1
      if hit: awaitingTarget.mgetOrPut(target, @[]).add pingReceived.high
      game.appendValue("ping.hit_kind", message.uint16Field(member, 12))
      game.appendValue("ping.direction", uint8(message.uint16Field(member, 2)))
      game.appendValue("ping.origin", message.cellOf(message.structField(member, 0), width))
      game.appendValue("ping.end", message.cellOf(message.structField(member, 1), width))
      game.appendValue("ping.value", message.uint64Field(member, 2))
    else: discard

  for turn in turns:
    game.appendValue("turn.round", uint32(turn.round))
    game.appendValue("turn.dragon", uint32(turn.dragon))
    game.appendValue("turn.team", turn.team)
    game.appendValue("turn.event", turn.event)
    game.appendString("turn.action", turn.action)
    game.appendValue("turn.points", turn.points)
    game.appendValue("turn.points?", uint8(turn.pointsKnown))
    game.appendString("turn.failure", turn.failure)
    game.appendString("turn.log", turn.log)
  for received in pingReceived: game.appendValue("ping.received_round", received)

  let outcome = message.structField(replay, 4)
  game.appendValue("meta.version", GameVersion)
  game.appendValue("meta.width", uint32(width))
  game.appendValue("meta.height", uint32(height))
  game.appendValue("meta.winner",
    if message.uint16Field(outcome, 2) == 1: int8(message.uint16Field(outcome, 3)) else: -1'i8)
  game.appendValue("meta.end_reason", message.uint16Field(outcome, 1))
  for pointerIndex in 0 .. 1:
    let standing = message.structField(outcome, pointerIndex)
    game.appendValue("standing.units", uint32(message.int32Field(standing, 0)))
    game.appendValue("standing.longest", uint32(message.int32Field(standing, 1)))
    game.appendValue("standing.total_length", uint32(message.int32Field(standing, 2)))
  game.appendValue("meta.replay_format", message.uint32Field(replay, 0))
  game.appendString("meta.map_name", mapName)
  game.appendString("meta.bot_a", message.textField(replay, 1))
  game.appendString("meta.bot_b", message.textField(replay, 2))
  game.appendString("meta.map_text", mapText)
  game.writeColumnsFile(outputPath)

const Usage = """usage:
  loong-gamedata REPLAY [OUTPUT]
      the replay's `game` columns, beside it unless OUTPUT is given
  loong-gamedata result OUTPUT [--game GAME.cols] [--map NAME] [--seed N]
      [--bot-a NAME] [--bot-b NAME] [--exit-code N] [--timed-out]
      [--elapsed SECONDS] [--slot-seconds SECONDS]
      one game's `result` columns; without --game, a game that left no replay
  loong-gamedata merge-results OUTPUT INPUT...
      every input's rows in one file of the same kind
  loong-gamedata observations GAME.cols OUTPUT [--dragons ID,ID...] [--lenient]
      each decision's bot-visible input, for these dragons or every dragon;
      --lenient takes the first of two possible body headings instead of failing
  loong-gamedata decode REPLAY... [--deaths]
      each replay's sides, map, result and event counts; with --deaths, one
      table of every bot's deaths by the engine's cause"""

when isMainModule:
  if paramCount() == 0: quit Usage, 2
  case paramStr(1)
  of "result":
    if paramCount() < 2: quit Usage, 2
    var facts: GameHarnessFacts
    var game = ""
    var at = 3
    while at <= paramCount():
      let name = paramStr(at)
      if name == "--timed-out":
        facts.timedOut = true
        inc at
        continue
      if at + 1 > paramCount(): quit Usage, 2
      let value = paramStr(at + 1)
      case name
      of "--game": game = value
      of "--map": facts.map = value
      of "--seed": facts.seed = parseBiggestUInt(value)
      of "--bot-a": facts.bots[0] = value
      of "--bot-b": facts.bots[1] = value
      of "--exit-code": facts.exitCode = int32(parseInt(value))
      of "--elapsed": facts.elapsedSeconds = float32(parseFloat(value))
      of "--slot-seconds":
        facts.slotSeconds = float32(parseFloat(value))
        facts.hasSlotSeconds = true
      else: quit Usage, 2
      at += 2
    writeResultColumns(game, facts, paramStr(2))
  of "observations":
    if paramCount() < 3: quit Usage, 2
    var dragons: HashSet[int32]
    var everyDragon = true
    var lenient = false
    var at = 4
    while at <= paramCount():
      case paramStr(at)
      of "--lenient": lenient = true
      of "--dragons":
        if at + 1 > paramCount(): quit Usage, 2
        everyDragon = false
        for identifier in paramStr(at + 1).split(','):
          if identifier.len > 0: dragons.incl int32(parseInt(identifier))
        inc at
      else: quit Usage, 2
      inc at
    try:
      writeObservationColumns(paramStr(2), paramStr(3), dragons, everyDragon, lenient)
    except BoardFailure as failure:
      stderr.writeLine failure.msg
      quit 3
  of "decode":
    var replays: seq[string]
    var deaths = false
    for at in 2 .. paramCount():
      if paramStr(at) == "--deaths": deaths = true
      else: replays.add paramStr(at)
    if replays.len == 0: quit Usage, 2
    decodeReplays(replays, deaths)
  of "merge-results":
    if paramCount() < 3: quit Usage, 2
    var inputs: seq[string]
    for at in 3 .. paramCount(): inputs.add paramStr(at)
    mergeColumnsFiles(inputs, paramStr(2))
  else:
    if paramCount() > 2: quit Usage, 2
    let replay = paramStr(1)
    writeGameColumns(replay, if paramCount() == 2: paramStr(2) else: replay.changeFileExt("cols"))
