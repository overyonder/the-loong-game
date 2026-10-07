## `loong-gamedata decode`: summarise packed replays from their events, or
## tabulate each bot's deaths by the engine's cause.

import std/[algorithm, os, strutils, tables]
import capnp_replay, gzip_inflate

const
  EventNames = ["roundStart", "turnStart", "pearlCountdown", "tileChange",
    "dragonAction", "engineLog", "dragonLog", "dragonIndicator", "debugDraw",
    "dragonUpdate", "dragonSplit", "dragonDeath", "sonarPing"]
  ## A `dragonDeath` reason code as the engine's log words it; tools/opponents
  ## README.md records how the codes were read off the engine.
  DeathReasons* = ["hit a wall", "hit itself", "hit another dragon",
    "lost a head-to-head", "no valid action"]

proc grouped(value: int): string =
  let digits = $value
  for position, digit in digits:
    if position > 0 and (digits.len - position) mod 3 == 0: result.add ','
    result.add digit

proc deathReason(code: int): string =
  if code < DeathReasons.len: DeathReasons[code] else: "unknown reason " & $code

proc decodeReplays*(paths: seq[string], deaths: bool) =
  ## Each replay's sides, map, result and event counts, most frequent first;
  ## with `deaths`, one table of every bot's deaths by cause instead.
  var causes: Table[(string, string), int]
  var bots: seq[string]
  for path in paths:
    var packed = readFile(path)
    if packed.isGzip: packed = packed.gunzip
    let message = readCapnpPackedMessage(packed.toOpenArrayByte(0, packed.high))
    let replay = message.root
    var names = [message.textField(replay, 1), message.textField(replay, 2)]
    for team in 0 .. 1:
      # A runner may record a bot by its directory path; the name is its last part.
      names[team] = names[team].strip(leading = false, chars = {'/'}).extractFilename
      if names[team].len == 0: names[team] = "team " & "AB"[team]
    var width, height = 0
    var teams: Table[int32, int]
    var starting = 0'i32
    for line in message.textField(replay, 0).splitLines:
      let fields = line.splitWhitespace
      if fields.len == 0: continue
      if fields[0] == "MAP": (width, height) = (parseInt(fields[1]), parseInt(fields[2]))
      elif fields[0] == "DRAGON":
        teams[starting] = parseInt(fields[1])
        inc starting
    var counts: OrderedTable[string, int]
    var round = -1'i32
    let events = message.listField(replay, 3)
    for index in 0 ..< events.count:
      let event = events.listStruct(index)
      let kind = int(message.uint16Field(event, 0))
      let name = if kind < EventNames.len: EventNames[kind] else: "unknown" & $kind
      counts[name] = counts.getOrDefault(name) + 1
      let member = message.structField(event, 0)
      case kind
      of 0: round = message.int32Field(member, 0)
      of 10: teams[message.int32Field(member, 1)] = int(message.uint16Field(member, 4))
      of 11:
        let bot = names[teams.getOrDefault(message.int32Field(member, 0))]
        if bot notin bots: bots.add bot
        let key = (bot, deathReason(int(message.uint16Field(member, 2))))
        causes[key] = causes.getOrDefault(key) + 1
      else: discard
    if deaths: continue
    let outcome = message.structField(replay, 4)
    let result = if message.uint16Field(outcome, 2) == 1:
        "team " & "AB"[int(message.uint16Field(outcome, 3))] & " wins"
      else: "draw"
    echo path.extractFilename, ": ", names[0], " vs ", names[1], " on a ", width, "×",
      height, " map, format ", message.uint32Field(replay, 0)
    echo "  ", result, " after ", round + 1, " rounds"
    var ranked: seq[(string, int)]
    for name, count in counts: ranked.add (name, count)
    ranked.sort(proc (x, y: (string, int)): int = cmp(y[1], x[1]))
    for (name, count) in ranked: echo "  ", grouped(count).align(8), " ", name
  if deaths:
    var width = 20
    for bot in bots: width = max(width, bot.len + 2)
    var header = "bot".alignLeft(width)
    for reason in DeathReasons: header.add reason.align(22)
    echo header
    bots.sort
    for bot in bots:
      var row = bot.alignLeft(width)
      for reason in DeathReasons: row.add grouped(causes.getOrDefault((bot, reason))).align(22)
      echo row
    echo paths.len, " replays"
