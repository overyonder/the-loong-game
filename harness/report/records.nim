## The games a report reads, from what the runners left: result sets
## (`results.json`) and each game's `result` columns (gamedata/format.md),
## written beside its log. Nothing here plays, converts or computes a missing
## record.

import std/[algorithm, json, os, strutils, tables]
import ../../gamedata/columns

const
  ## The result columns' death counts and the engine's wording for each.
  DeathColumns = [("deaths_hit_wall", "hit a wall"),
                  ("deaths_hit_itself", "hit itself"),
                  ("deaths_hit_dragon", "hit another dragon"),
                  ("deaths_head_to_head", "lost a head-to-head"),
                  ("deaths_no_action", "no valid action")]

type
  SideRecord* = object
    ## One side's economy in one game, as the report's death section reads it.
    deaths*, finalLongest*, finalTotalLength*, finalUnits*, splits*: float
    causes*: seq[tuple[cause: string, count: float]]   ## in record order

  Game* = object
    a*, b*:     string        ## the bots, as the runner names them
    map*:       string        ## the map's file name
    mapPath*:   string        ## the map file the runner played
    seed*:      JsonNode      ## as recorded: an integer, or null
    status*:    string        ## completed, error or timeout
    winner*:    int           ## 0 A, 1 B, -1 no winner
    rounds*:    int
    reason*:    string
    sides*:     array[2, SideRecord]
    economy*:   bool          ## whether `sides` holds a record
    log*:       string        ## the game's log file
    record*:    JsonNode      ## the result set's entry, for a verdict's faults

proc gameId*(game: Game): string =
  ## A scheduled game's identity within a result set: sides, map and seed.
  [game.a, game.b, game.map, $game.seed].join("\t")

proc besideLog*(directory, log, suffix: string): string =
  ## The record another stage wrote beside a game's log.
  let (parent, name, _) = log.splitFile
  directory / parent / (name & suffix)

proc readJsonFile*(path: string): JsonNode =
  if fileExists(path): parseFile(path) else: nil

# Result columns

proc readResultGame(path: string, game: var Game) =
  ## The first game of a `result` file: its sides' economy when it was played.
  if not fileExists(path): return
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  if file.numberAt("game.rounds?", 0) == 0: return
  for row in 0 ..< file.rowCount("side.game"):
    if file.numberAt("side.game", row) != 0: continue
    var side: SideRecord
    side.deaths = file.numberAt("side.deaths", row)
    side.finalLongest = file.numberAt("side.final_longest", row)
    side.finalTotalLength = file.numberAt("side.final_total_length", row)
    side.finalUnits = file.numberAt("side.final_units", row)
    side.splits = file.numberAt("side.splits", row)
    for (column, wording) in DeathColumns:
      let count = file.numberAt("side." & column, row)
      if count != 0: side.causes.add (wording, count)
    game.sides[int(file.numberAt("side.team", row))] = side
    game.economy = true

# Result directories

proc setGame*(directory: string, entry: JsonNode): Game =
  ## A result set's game with its economy record, when one was written.
  result = Game(a: entry["A"].getStr, b: entry["B"].getStr,
    map: entry["map"].getStr.extractFilename,
    # A ladder records map names and keeps frozen copies in its maps/.
    mapPath: (if entry["map"].getStr.isAbsolute: entry["map"].getStr
              else: directory / "maps" / entry["map"].getStr.extractFilename),
    seed: entry{"seed"}, status: entry["status"].getStr, rounds: entry{"rounds"}.getInt,
    reason: entry{"reason"}.getStr, record: entry,
    log: directory / entry["log"].getStr)
  if result.seed == nil: result.seed = newJNull()
  let winner = entry{"winner_side"}.getStr
  result.winner = if winner == "A": 0 elif winner == "B": 1 else: -1
  readResultGame(besideLog(directory, entry["log"].getStr, ".result.cols"), result)

proc loadGames*(paths: seq[string]): seq[Game] =
  ## Every played game in the result sets under `paths`, once each.
  var seen: Table[string, int]
  for given in paths:
    let path = given.absolutePath.normalizedPath
    var sets: seq[string]
    for file in walkDirRec(path, {pcFile}):
      if file.extractFilename == "results.json": sets.add file
    sets.sort
    for file in sets:
      for entry in parseFile(file){"games"}:
        let game = setGame(file.parentDir, entry)
        if game.gameId notin seen:
          seen[game.gameId] = result.len
          result.add game
