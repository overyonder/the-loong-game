## The games a report reads, from what the runners left: result sets
## (`results.json`), raw fleet runs (`jobs.json` and `out/`), each game's
## `result` columns (tools/gamedata/format.md) or, for runs from before them, its
## `.economy.json` summary, the log's engine outcome and the Brain `activation`
## columns. Nothing here plays, converts or computes a missing record.

import std/[algorithm, json, os, strutils, tables]
import ../../gamedata/[columns, store]
export GameStoreLink, gameFile, besideLog

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
    seed*:      JsonNode      ## as recorded: an integer, or null
    status*:    string        ## completed, error or timeout
    winner*:    int           ## 0 A, 1 B, -1 no winner
    rounds*:    int
    reason*:    string
    sides*:     array[2, SideRecord]
    economy*:   bool          ## whether `sides` holds a record
    log*:       string        ## the game's log file
    command*:   seq[string]   ## the match command a local runner recorded
    record*:    JsonNode      ## the result set's entry, for a verdict's faults

  Activation* = object
    ## One side's Brain activation in one game.
    turns*:  int
    active*: seq[tuple[node: string, turns: int]]   ## in record order
    leaves*: seq[string]

proc gameId*(game: Game): string =
  ## A scheduled game's identity within a result set: sides, map and seed.
  [game.a, game.b, game.map, $game.seed].join("\t")

proc readJsonFile*(path: string): JsonNode =
  if fileExists(path): parseFile(path) else: nil

# Result columns

proc enumNames(file: ColumnsFileReader, name: string): seq[string] =
  for row in 0 ..< file.rowCount("enum." & name): result.add file.stringRow("enum." & name, row)

proc readResultGame(path: string, game: var Game) =
  ## The first game of a `result` file: its sides' economy when it was played.
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

proc resultExit*(path: string): tuple[code: int, timedOut: bool] =
  ## A fleet job's exit code and whether it timed out, from its result record.
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  let status = file.enumNames("status")[int(file.numberAt("game.status", 0))]
  (int(file.numberAt("game.exit_code", 0)), status == "timeout")

proc readLegacyEconomy(path: string, game: var Game) =
  ## An `.economy.json` summary from before the result record.
  let summary = readJsonFile(path)
  if summary == nil or "error" in summary or "sides" notin summary: return
  for team, key in ["a", "b"]:
    let record = summary["sides"]{key}
    if record == nil: return
    var side: SideRecord
    side.deaths = record{"deaths"}.getFloat
    side.finalLongest = record{"final_longest"}.getFloat
    side.finalTotalLength = record{"final_total_length"}.getFloat
    side.finalUnits = record{"final_units"}.getFloat
    side.splits = record{"splits"}.getFloat
    if record{"deaths_by_cause"} != nil:
      for cause, count in record["deaths_by_cause"]: side.causes.add (cause, count.getFloat)
    game.sides[team] = side
  game.economy = true

proc readEconomy(resultPath, legacyPath: string, game: var Game) =
  if fileExists(resultPath): readResultGame(resultPath, game)
  else: readLegacyEconomy(legacyPath, game)

# Engine outcome from a log

proc isFailureLine(line: string): bool =
  ## `round N: bot N (team X) ` then running out of time, exiting, or a fuel,
  ## trap or memory limit failure.
  if not line.startsWith("round "): return false
  var at = 6
  while at < line.len and line[at].isDigit: inc at
  if at == 6 or not line.continuesWith(": bot ", at): return false
  at += 6
  let digits = at
  while at < line.len and line[at].isDigit: inc at
  if at == digits or not line.continuesWith(" (team ", at): return false
  at += 7
  if at >= line.len or line[at] notin {'A', 'B'} or not line.continuesWith(") ", at + 1): return false
  let rest = line[at + 3 .. ^1]
  rest.startsWith("ran out of time") or rest.startsWith("exited") or
    "fuel" in rest or "trap" in rest or "memory limit" in rest

proc readOutcome*(logPath: string, code: int, timedOut: bool, game: var Game) =
  ## The engine's last result line in a game's log, and whether the game failed.
  let text = readFile(logPath)
  var found, failed = false
  for line in text.splitLines:
    var winner = -2
    var rest: string
    if line.startsWith("team A wins after "): (winner, rest) = (0, line[18 .. ^1])
    elif line.startsWith("team B wins after "): (winner, rest) = (1, line[18 .. ^1])
    elif line.startsWith("draw after "): (winner, rest) = (-1, line[11 .. ^1])
    if winner != -2:
      let space = rest.find(" rounds (")
      let close = rest.find(')', max(space, 0))
      if space > 0 and rest[0 ..< space].allCharsInSet(Digits) and close > space + 9:
        (found, game.winner, game.rounds) = (true, winner, parseInt(rest[0 ..< space]))
        game.reason = rest[space + 9 ..< close]
    failed = failed or line.isFailureLine
  failed = failed or "died: no valid action" in text
  game.status = if timedOut or code != 0 or failed or not found: "error" else: "completed"
  if not found: game.winner = -1

# Result directories

proc fleetExit*(remote: string, job: int): tuple[returned: bool, code: int, timedOut: bool] =
  ## A fleet job's exit, once it has returned: from its result record, or from
  ## a `.status` file for a run from before the record existed.
  let record = remote / $job & ".result.cols"
  if fileExists(record):
    let (code, timedOut) = resultExit(record)
    return (true, code, timedOut)
  let status = remote / $job & ".status"
  if fileExists(status):
    let code = parseInt(readFile(status).strip)
    return (true, code, code == -9)

proc fleetGames(fleet: string): seq[Game] =
  ## The games of a raw fleet run that finished; unplayed jobs are left out.
  var remote = fleet / "out"
  # A retained run's raw files moved into its store.
  if dirExists(storePath(remote)): remote = storePath(remote)
  for job in parseFile(fleet / "jobs.json"):
    let id = job["id"].getInt
    let (returned, code, timedOut) = fleetExit(remote, id)
    let log = remote / $id & ".log"
    # A game the collection has moved into a result set is read from there.
    if not returned or not fileExists(log): continue
    var game = Game(a: job["a"].getStr, b: job["b"].getStr, map: job["map"].getStr,
      seed: job{"seed"}, log: log)
    if game.seed == nil: game.seed = newJNull()
    readOutcome(log, code, timedOut, game)
    readEconomy(remote / $id & ".result.cols", remote / $id & ".economy.json", game)
    result.add game

proc setGame*(directory: string, entry: JsonNode): Game =
  ## A result set's game with its economy record, when one was written.
  result = Game(a: entry["A"].getStr, b: entry["B"].getStr,
    map: entry["map"].getStr.extractFilename, seed: entry{"seed"},
    status: entry["status"].getStr, rounds: entry{"rounds"}.getInt,
    reason: entry{"reason"}.getStr, record: entry,
    log: gameFile(directory, entry["log"].getStr))
  if result.seed == nil: result.seed = newJNull()
  let winner = entry{"winner_side"}.getStr
  result.winner = if winner == "A": 0 elif winner == "B": 1 else: -1
  if entry{"command"} != nil:
    for part in entry["command"]: result.command.add part.getStr
  let log = entry["log"].getStr
  readEconomy(besideLog(directory, log, ".result.cols"),
    besideLog(directory, log, ".economy.json"), result)

proc loadGames*(paths: seq[string]): seq[Game] =
  ## Every played game under `paths`, once each. A path is a result directory
  ## holding result sets, a raw fleet directory, or a directory holding one as
  ## `fleet/`.
  var seen: Table[string, int]
  proc keep(games: var seq[Game], game: Game) =
    if game.gameId notin seen:
      seen[game.gameId] = games.len
      games.add game
  for given in paths:
    let path = given.absolutePath.normalizedPath
    for fleet in [path, path / "fleet"]:
      if fileExists(fleet / "jobs.json"):
        for game in fleetGames(fleet): result.keep game
    var sets: seq[string]
    for file in walkDirRec(path, {pcFile}):
      if file.extractFilename == "results.json": sets.add file
    sets.sort
    for file in sets:
      for entry in parseFile(file){"games"}:
        result.keep setGame(file.parentDir, entry)

# Brain activation

proc recordedActivation*(directory: string, game: Game, bot: string): seq[Activation] =
  ## `bot`'s sides of a game's activation record; empty when there is none or
  ## it records an error. Nothing is computed.
  let path = besideLog(directory, game.record["log"].getStr, ".activation.cols")
  if not fileExists(path): return
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  if file.stringRow("meta.error", 0).len > 0: return
  var sides: seq[Activation]
  var teams: seq[int]
  for row in 0 ..< file.rowCount("side.team"):
    teams.add int(file.numberAt("side.team", row))
    sides.add Activation(turns: int(file.numberAt("side.turns", row)))
  for row in 0 ..< file.rowCount("node.name"):
    let side = int(file.numberAt("node.side", row))
    let name = file.stringRow("node.name", row)
    sides[side].active.add (name, int(file.numberAt("node.active", row)))
    if file.numberAt("node.leaf", row) != 0: sides[side].leaves.add name
  for position, team in teams:
    if [game.a, game.b][team] == bot: result.add sides[position]
