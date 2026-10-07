## Whole-game economy: a `result` file's games as economy summaries
## (tools/gamedata/format.md), and one replay summarised through
## loong-gamedata. `just economy` is `loong-report economy`.

import std/[json, os, strutils, tempfiles]
import ../evaluation/tournament
import ../gamedata/[capnp_replay, columns, compare]

const
  DeathColumns = [("deaths_hit_wall", "hit a wall"), ("deaths_hit_itself", "hit itself"),
                  ("deaths_hit_dragon", "hit another dragon"), ("deaths_head_to_head", "lost a head-to-head"),
                  ("deaths_no_action", "no valid action")]
  SideFields = ["pearls", "pearls_by_length", "dragon_turns", "pearls_per_dragon_turn", "splits",
    "deaths", "final_units", "final_longest", "final_total_length", "best_fed_intake", "best_fed_share",
    "peak_points", "exceeded", "tiles_visited", "head_coverage"]

proc readResult*(path: string): seq[JsonNode] =
  ## A `result` file's games: `{map, map_tiles, rounds, winner, status,
  ## exit_code, sides}` with `sides["a"]` and `sides["b"]` holding the
  ## economy fields, and `deaths_by_cause` keyed by the engine's wording. A
  ## game that left no replay has `rounds` null and no sides.
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  proc enumNames(name: string): seq[string] =
    for row in 0 ..< file.rowCount("enum." & name): result.add file.stringRow("enum." & name, row)
  let (winners, statuses) = (enumNames("winner"), enumNames("status"))
  for game in 0 ..< file.rowCount("game.rounds"):
    let played = file.numberAt("game.rounds?", game) != 0
    result.add %*{"map": file.stringRow("game.map", game), "map_tiles": int(file.numberAt("game.map_tiles", game)),
      "rounds": if played: %int(file.numberAt("game.rounds", game)) else: newJNull(),
      "winner": if file.numberAt("game.winner?", game) != 0: %winners[int(file.numberAt("game.winner", game))] else: newJNull(),
      "status": statuses[int(file.numberAt("game.status", game))],
      "exit_code": int(file.numberAt("game.exit_code", game)), "sides": {}}
  for row in 0 ..< file.rowCount("side.game"):
    let game = result[int(file.numberAt("side.game", row))]
    if game["rounds"].kind == JNull: continue
    var side = %*{"bot": file.stringRow("side.bot", row)}
    for name in SideFields: side[name] = file.valueAt("side." & name, row)
    var deaths = newJObject()
    for (column, wording) in DeathColumns:
      let count = file.numberAt("side." & column, row)
      if count != 0: deaths[wording] = %int(count)
    side["deaths_by_cause"] = deaths
    game["sides"][$"ab"[int(file.numberAt("side.team", row))]] = side

proc standing(message: CapnpMessage, value: CapnpStruct): JsonNode =
  %*{"dragonCount": message.int32Field(value, 0), "longestDragon": message.int32Field(value, 1),
     "totalLength": message.int32Field(value, 2), "queenLength": message.int32Field(value, 3)}

proc summarise*(replay: string): JsonNode =
  ## Both sides' intake, splits, deaths, final size and coverage in one game,
  ## computed by loong-gamedata from the replay and its judge points, as the
  ## collector records it for every game, with the replay's teams, map name
  ## and result.
  let work = createTempDir("loong-result-", "")
  defer: removeDir(work)
  writeResult(work / "game.result.cols", replay, "", 0, "", "", 0, false)
  result = readResult(work / "game.result.cols")[0]
  if result["rounds"].kind == JNull: raise newException(ValueError, replay & ": loong-gamedata could not read the replay")
  let message = loadReplay(replay)
  let root = message.root
  result["sides"]["a"]["bot"] = %message.textField(root, 1)
  result["sides"]["b"]["bot"] = %message.textField(root, 2)
  result["map"] = %""
  for line in message.textField(root, 0).splitLines:
    if line.startsWith("MAP_NAME"):
      result["map"] = %line.splitWhitespace[1 .. ^1].join(" ")
      break
  let gameResult = message.structField(root, 4)
  var outcome = newJObject()
  case message.uint16Field(gameResult, 2)
  of 0: outcome["noWinner"] = newJNull()
  else: outcome["winner"] = %(if message.uint16Field(gameResult, 3) == 0: "a" else: "b")
  outcome["terminated"] = %message.boolField(gameResult, 0)
  outcome["endReason"] = %message.uint16Field(gameResult, 1)
  if message.hasPointer(gameResult, 0): outcome["teamA"] = message.standing(message.structField(gameResult, 0))
  if message.hasPointer(gameResult, 1): outcome["teamB"] = message.standing(message.structField(gameResult, 1))
  result["result"] = outcome
