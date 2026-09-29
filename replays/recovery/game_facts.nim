## A replay's recorded facts that recovery needs: each dragon's build identity,
## its birth, the sonar it sent each turn, and its decisions' recorded inputs,
## rebuilt exactly from the game columns (gamedata/format.md).

import std/[json, os, sets, strutils, tables]
import ../../gamedata/[capnp_replay, columns, gamedata, gzip_inflate, observations]
import gizmos, recover

type
  GameFacts* = object
    area*: int
    identities*: Table[int32, JsonNode]
    births*: Table[int32, (int32, int32)]   ## child -> (parent, round)
    sonar*: Table[(int32, int32), seq[uint64]]
    samples*: OrderedTable[int32, seq[Sample]]

proc readGameFacts*(replayPath, gamePath, observationsPath: string, sides: string): GameFacts =
  ## The facts of the dragons on `sides`, writing the game and observation
  ## columns where they don't exist yet.
  var packed = readFile(replayPath)
  if packed.isGzip: packed = packed.gunzip
  let message = readCapnpPackedMessage(packed.toOpenArrayByte(0, packed.high))
  let replay = message.root
  var width, height = 0
  for line in message.textField(replay, 0).splitLines:
    let fields = line.splitWhitespace
    if fields.len >= 3 and fields[0] == "MAP":
      (width, height) = (parseInt(fields[1]), parseInt(fields[2]))
      break
  let area = width * height
  # Identities, births and observable sonar output, from the events.
  var identities: Table[int32, JsonNode]
  var firstRounds: Table[int32, int32]
  var births: Table[int32, (int32, int32)]
  var sonar: Table[(int32, int32), seq[uint64]]
  var round = -1'i32
  var active = -1'i32
  let events = message.listField(replay, 3)
  for index in 0 ..< events.count:
    let event = events.listStruct(index)
    let member = message.structField(event, 0)
    case message.uint16Field(event, 0)
    of 0: round = message.int32Field(member, 0)
    of 1:
      active = message.int32Field(member, 0)
      if active notin firstRounds: firstRounds[active] = round
      sonar[(active, round)] = @[]
    of 6:
      let text = message.textField(member, 0)
      if not text.startsWith(BuildPrefix): continue
      let dragon = message.int32Field(member, 0)
      try:
        if active != dragon: raise newException(ValueError, "Diagnostic outside its dragon's turn")
        let identity = parseBuild(text)
        if dragon notin identities and firstRounds.getOrDefault(dragon, -2) != round:
          raise newException(ValueError, "Build identity was not emitted on the first turn")
        if dragon in identities and identities[dragon] != identity:
          raise newException(ValueError, "Conflicting build identities")
        identities[dragon] = identity
      except ValueError, KeyError:
        identities[dragon] = %*{"invalid": true}
    of 10: births[message.int32Field(member, 1)] = (message.int32Field(member, 0), round)
    of 11:
      if message.int32Field(member, 0) == active: sonar.del (active, round)
    of 12:
      let key = (message.int32Field(member, 0), round)
      if key notin sonar: raise newException(KeyError, $key)
      sonar[key].add message.uint64Field(member, 2)
    else: discard
  if message.uint32Field(replay, 0) != 2:
    raise newException(ValueError, "Exact observations require version 2 sonar echo events")
  # Every decision's recorded input, rebuilt exactly.
  if not fileExists(gamePath): writeGameColumns(replayPath, gamePath)
  if not fileExists(observationsPath):
    writeObservationColumns(gamePath, observationsPath, initHashSet[int32](),
      everyDragon = true, lenient = false)
  var game = openColumnsFile(gamePath)
  var decisions = openColumnsFile(observationsPath)
  var byDragon: OrderedTable[int32, seq[Sample]]
  for index in 0 ..< decisions.rowCount("decision.turn"):
    let turn = int(decisions.numberAt("decision.turn", index))
    let team = "AB"[int(game.numberAt("turn.team", turn))]
    if team notin sides: continue
    let dragon = int32(game.numberAt("turn.dragon", turn))
    byDragon.mgetOrPut(dragon, @[]).add Sample(dragon: dragon,
      round: int32(game.numberAt("turn.round", turn)), team: team,
      init: decisions.stringRow("decision.init", index),
      observation: decisions.stringRow("decision.observation", index),
      action: game.stringRow("turn.action", turn))
  decisions.closeColumnsFile()
  game.closeColumnsFile()
  result = GameFacts(area: area, identities: identities, births: births, sonar: sonar,
    samples: byDragon)
