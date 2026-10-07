## `loong-gamedata regeneration REPLAY [SCRIPT_A SCRIPT_B]`: what playing a
## ladder game again in the judge reads from its replay (`just regenerate`):
## its pearl spawns, and each side's script when their paths are given.
##
## Each side's script is its recorded replies, one `ROUND<TAB>DRAGON<TAB>REPLY`
## line per turn it acted or pinged, in round then dragon order: its move or
## split first, then its sonar, joined by `|`. A turn whose action is neither
## (a suicide, an empty move, none at all) still has its line, with no action
## word. A dragon's team is its map `DRAGON` line's, or its split's. A replay
## records the direction a ray travelled. A ray asked for opposite the sender's
## facing leaves from its tail, pointing away from its body
## (planning/rules.md), so a ping from the tail was asked for opposite the
## facing, whatever direction it travelled. A ping's value is its 64-bit value,
## else its 32-bit one.
##
## The pearl spawns go to standard output, one `ROUND X Y` line each: a pearl
## appearing at the start of a round, before its first turn. Pearls dropped by
## deaths come during turns (tools/ladder/map_variants.nim).

import std/[algorithm, strutils, tables]
import capnp_replay, compare

const DirectionLetters = "NESW"

type Shape = object
  head, tail: (int32, int32)
  facing: int   ## direction index, or -1 when unknown

proc pointAt(message: CapnpMessage, point: CapnpStruct): (int32, int32) =
  (message.int32Field(point, 0), message.int32Field(point, 1))

type PearlSpawn* = tuple[round, x, y: int32]

proc regeneration*(replay: string, scripts: seq[string]): seq[PearlSpawn] =
  ## The replay's pearl spawns, writing each side's script when `scripts`
  ## names their paths.
  let message = loadReplay(replay)
  let events = message.eventList(replay)
  var teams: Table[int32, int]
  var dragon = 0'i32
  for line in message.textField(message.root, 0).splitLines:
    if line.startsWith("DRAGON "):
      teams[dragon] = parseInt(line.splitWhitespace[1])
      inc dragon
  for index in 0 ..< events.count:
    let event = events.listStruct(index)
    if message.uint16Field(event, 0) == DragonSplit:
      let member = message.structField(event, 0)
      teams[message.int32Field(member, 1)] = if message.uint16Field(member, 4) == 0: 0 else: 1
  var replies: array[2, Table[(int32, int32), seq[string]]]
  var shapes: Table[int32, Shape]
  var round = -1'i32
  var ticking = false
  for index in 0 ..< events.count:
    let event = events.listStruct(index)
    let member = message.structField(event, 0)
    case message.uint16Field(event, 0)
    of RoundStart:
      round = message.int32Field(member, 0)
      ticking = true
    of TurnStart: ticking = false
    of TileChange:
      if ticking and message.boolField(member, 0):
        let (x, y) = message.pointAt(message.structField(member, 0))
        result.add (round, x, y)
    of DragonUpdate:
      shapes[message.int32Field(member, 0)] = Shape(
        head: message.pointAt(message.structField(member, 0)),
        tail: message.pointAt(message.structField(member, 1)),
        facing: int(message.uint16Field(member, 2)))
    of DragonSplit:
      let parent = message.int32Field(member, 0)
      let child = message.int32Field(member, 1)
      let parentBody = message.listField(member, 0)
      let childBody = message.listField(member, 1)
      if parentBody.count == 0 or childBody.count == 0:
        raise newException(UnreadableReplay, replay & ": a split with an empty body")
      shapes[parent] = Shape(
        head: message.pointAt(message.structElement(parentBody, 0)),
        tail: message.pointAt(message.structElement(parentBody, parentBody.count - 1)),
        facing: shapes.getOrDefault(parent, Shape(facing: -1)).facing)
      shapes[child] = Shape(
        head: message.pointAt(message.structElement(childBody, 0)),
        tail: message.pointAt(message.structElement(childBody, childBody.count - 1)),
        facing: int(message.uint16Field(member, 5)))
    of SonarPing:
      let sender = message.int32Field(member, 0)
      let team = teams.getOrDefault(sender, -1)
      if team in 0 .. 1:
        let shape = shapes.getOrDefault(sender, Shape(facing: -1))
        let origin = message.pointAt(message.structField(member, 0))
        let asked = if shape.facing >= 0 and origin == shape.tail and origin != shape.head:
                      (shape.facing + 2) mod 4
                    else: int(message.uint16Field(member, 2))
        var value = message.uint64Field(member, 2)
        if value == 0: value = uint64(message.uint32Field(member, 2))
        replies[team].mgetOrPut((round, sender), @[]).add(
          "SONAR " & DirectionLetters[asked] & ' ' & $value)
    of DragonAction:
      let id = message.int32Field(member, 0)
      let team = teams.getOrDefault(id, -1)
      if team in 0 .. 1:
        var words = addr replies[team].mgetOrPut((round, id), @[])
        if message.hasPointer(member, 0):
          let action = message.structField(member, 0)
          case message.uint16Field(action, 0)
          of 0:
            let moves = message.listField(action, 0)
            if moves.count > 0:
              var word = "MOVE "
              for step in 0 ..< moves.count:
                word.add DirectionLetters[int(message.enumElement(moves, step))]
              words[].insert(word, 0)
          of 1: words[].insert("SPLIT " & $message.int32Field(action, 1), 0)
          else: discard
    else: discard
  for team, path in scripts:
    var turns: seq[(int32, int32)]
    for turn in replies[team].keys: turns.add turn
    turns.sort
    var text = ""
    for turn in turns:
      text.add $turn[0] & '\t' & $turn[1] & '\t' & replies[team][turn].join("|") & '\n'
    writeFile(path, text)

proc writeRegeneration*(replay: string, scripts: seq[string]) =
  ## `loong-gamedata regeneration`: the spawns to standard output, one
  ## `ROUND X Y` line each.
  for spawn in regeneration(replay, scripts): echo spawn.round, ' ', spawn.x, ' ', spawn.y
