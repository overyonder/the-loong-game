## Play scheduled games in the judge and retain each game's evidence: its log,
## replay, points and result record in its result directory's game store, and
## its record in the runner's `results.json`. Seeded games are deterministic,
## so a finished one is reused from the game cache instead of played again.

import std/[algorithm, json, math, options, os, sets, strutils, tables, times]
import bots, locks, outcome, paths, processes, python_json
import report/[rating, records, summary]
import ../gamedata/sha256
import ../judge/harness

type Game* = object
  ## One scheduled game and where its evidence goes: `<directory>/<stem>.*`.
  directory*: string
  stem*:      string
  mapPath*:   string
  seed*:      Option[int64]
  a*, b*:     string
  ## "judge-toolkit-accounting" plays in the judge charging a process's first
  ## read as the toolkit did; every other game plays in the judge as the
  ## ladder does.
  engine*:    string

let GameCache = Root / "build/game-cache"
const BuildOutputs = [".unswbc-build", "__pycache__", "gen-native"]

proc seedJson*(game: Game): JsonNode =
  if game.seed.isSome: %game.seed.get else: newJNull()

proc record*(game: Game, outcome: JsonNode, expectReplay = true, extra = newJObject()): JsonNode =
  ## The game's record: its sides, map and seed, where its log and replay are,
  ## `extra`, then how it ended. A replay is in the store: every local game's,
  ## and a fleet run's sample. Older result directories kept their sample
  ## beside their results.
  var replay = ""
  for path in [storePath(game.directory) / game.stem & ".replay", game.directory / game.stem & ".replay"]:
    if fileExists(path):
      replay = path
      break
  var outcome = outcome
  if expectReplay and replay.len == 0 and outcome["status"].getStr == "completed":
    outcome = outcome.copy
    outcome["status"] = %"error"
    outcome["error"] = %"Replay was not written"
  result = %*{"A": game.a, "B": game.b, "map": game.mapPath, "seed": game.seedJson,
              "log": "store/" & game.stem & ".log"}
  result["replay"] =
    if replay.len == 0: newJNull()
    elif replay.isRelativeTo(game.directory): %replay.relativePath(game.directory)
    else: %("store/" & replay.extractFilename)
  for key, value in extra: result[key] = value
  for key, value in outcome: result[key] = value

proc gameId*(record: JsonNode): string =
  ## A scheduled game's identity within a result set: sides, map and seed.
  [record["A"].getStr, record["B"].getStr, record["map"].getStr.extractFilename,
   $record{"seed"}].join("\t")

proc gameId*(game: Game): string =
  [game.a, game.b, game.mapPath.extractFilename, $game.seedJson].join("\t")

proc contentHash*(path: string): string =
  ## Hash of a map file, or of every file in a bot directory except build outputs.
  var digest = initSha256()
  let parent = path.parentDir
  var files: seq[string]
  if fileExists(path): files.add path
  else:
    for entry in walkTree(path):
      if not entry.file: continue
      var skip = false
      for part in entry.relative.split('/'):
        if part in BuildOutputs: skip = true
      if not skip: files.add path / entry.relative
  for file in files: digest.update(file.relativePath(parent) & "\0" & readFile(file))
  digest.finish.hex

proc gameKey*(command: seq[string]): string =
  ## A key for a match that always plays out the same way, or "" if it might
  ## not. Only seeded sandbox matches are deterministic: the seed fixes pearls
  ## and both bots' random numbers, and the judge runs on a virtual clock. The
  ## key covers every argument except the replay path, with each map, bot or
  ## engine path replaced by its name and content, plus the toolkit version
  ## and the judge by content, so an edited bot, map, engine or judge never
  ## reuses an old result.
  if "--sandbox" notin command or "--seed" notin command or not isMatchCommand(command): return ""
  var parts = @[toolkitVersion(), "loong-judge:" & contentHash(command[0])]
  var skip = false
  for argument in command[1 .. ^1]:
    if skip: skip = false
    elif argument in ["-o", "--registry"]: skip = true
    else:
      let candidate = if argument.isAbsolute: argument else: Root / argument
      if argument.len > 0 and (fileExists(candidate) or dirExists(candidate)):
        let path = resolved(candidate)
        parts.add path.extractFilename & ":" & contentHash(path)
      else: parts.add argument
  sha256Hex(parts.join("\0"))

proc resultHash(path: string): JsonNode =
  if path.len > 0 and fileExists(path): %sha256File(path) else: newJNull()

proc retainedResultPath(path: string): string =
  ## A stable cache reference through store publication and run retention.
  let path = resolved(path)
  if path.isRelativeTo(GameStaging): GameStore / path.relativePath(GameStaging)
  elif path.isRelativeTo(Root / "results/running"):
    Root / "results/local" / path.relativePath(Root / "results/running")
  else: path

proc linkTo(link, target: string) =
  ## Replace `link` with a relative symbolic link to `target`, between their
  ## real locations: either may sit behind a store link.
  createDir(link.parentDir)
  if symlinkExists(link) or fileExists(link): removeFile(link)
  createSymlink(resolved(target).relativePath(resolved(link.parentDir)), link)

proc playMatch(command: seq[string], log: string, timeout: float): tuple[code: int, timedOut: bool] =
  ## One game's process in the judge. Rerunning into a reused result must not
  ## overwrite another game's evidence, so a linked output is unlinked first.
  var outputs = @[log]
  let at = command.find("-o")
  if at >= 0:
    outputs.add command[at + 1]
    outputs.add command[at + 1].changeFileExt("points.cols")
  for output in outputs:
    if symlinkExists(output): removeFile(output)
  play(command, resolved(log), timeout, cwd = Root)

proc runGame*(command: seq[string], log: string, timeout: float): tuple[code: int, timedOut: bool] =
  ## Play one match, or reuse a finished identical one from the game cache.
  ## Several processes may ask for the same match at once, for example two
  ## tournaments sharing a pairing: a lock per match makes the others wait for
  ## the first and then read its result instead of playing it again. Only
  ## completed matches are cached, so timeouts and failures play again.
  let key = gameKey(command)
  if key.len == 0: return playMatch(command, log, timeout)
  let at = command.find("-o")
  let replay = if at >= 0: command[at + 1] else: ""
  let entry = GameCache / key & ".json"
  createDir(GameCache)
  let lock = open(GameCache / key & ".lock", fmWrite)
  defer: lock.close()
  lockExclusive(lock)
  if fileExists(entry):
    let cached = parseFile(entry)
    let previousLog = gameFile(Root, cached["log"].getStr)
    let previousReplay = if cached{"replay"}.getStr.len > 0: gameFile(Root, cached["replay"].getStr) else: ""
    let previousPoints = if previousReplay.len > 0: previousReplay.changeFileExt("points.cols") else: ""
    if fileExists(previousLog) and cached{"log_sha256"} == resultHash(previousLog) and
        readOutcomeFile(previousLog, 0, false).completed and
        (replay.len == 0 or previousReplay.len > 0 and fileExists(previousReplay) and
         cached{"replay_sha256"} == resultHash(previousReplay) and
         fileExists(previousPoints) and cached{"points_sha256"} == resultHash(previousPoints)):
      if resolved(log) != resolved(previousLog): linkTo(log, previousLog)
      if replay.len > 0 and resolved(replay) != resolved(previousReplay): linkTo(replay, previousReplay)
      if replay.len > 0:
        let points = replay.changeFileExt("points.cols")
        if resolved(points) != resolved(previousPoints): linkTo(points, previousPoints)
      return (0, false)
  result = playMatch(command, log, timeout)
  if not readOutcomeFile(log, result.code, result.timedOut).completed: return
  let cachedReplay = if replay.len > 0 and fileExists(replay):
                       %retainedResultPath(replay).relativePath(Root) else: newJNull()
  writeFile(entry, pythonDumps(%*{"log": retainedResultPath(log).relativePath(Root),
    "log_sha256": resultHash(log), "replay_sha256": resultHash(replay),
    "points_sha256": resultHash(if replay.len > 0: replay.changeFileExt("points.cols") else: ""),
    "replay": cachedReplay}) & "\n")

proc gameStore*(directory: string): string =
  ## A result directory's store, made on first use: a new store is staged,
  ## one already published is written in place.
  result = storePath(directory)
  if not dirExists(result):
    result = GameStaging / result.extractFilename
    createDir(result)

proc publishStore*(directory: string) =
  ## Publish a staged store by renaming it within the storage filesystem. A
  ## failure leaves files staged for the next publication attempt. Cached
  ## aliases become relative to their final location; links to another
  ## staged store wait for its matching published copy.
  let staged = GameStaging / storeName(directory)
  if not dirExists(staged): return
  var empty = true
  for _ in walkDir(staged):
    empty = false
    break
  if empty: return
  let destination = GameStore / staged.extractFilename
  if dirExists(destination) or fileExists(destination):
    echo destination, " exists: ", staged, " stays staged"
    return
  var links: seq[tuple[link, original, target: string]]
  for entry in walkTree(staged):
    if not entry.symlink: continue
    let link = staged / entry.relative
    # A cached alias can still name staging after its source was moved.
    let recordedTarget = expandSymlink(link)
    let targetPath = if recordedTarget.isAbsolute: recordedTarget else: link.parentDir / recordedTarget
    var target = gameFile(Root, resolved(targetPath))
    if not fileExists(target):
      echo link, " has no readable target: ", staged, " stays staged"
      return
    if target.isRelativeTo(staged): target = destination / target.relativePath(staged)
    elif target.isRelativeTo(GameStaging):
      let published = GameStore / target.relativePath(GameStaging)
      if not fileExists(published) or sha256File(published) != sha256File(target):
        echo link, " awaits its verified copy at ", published, ": ", staged, " stays staged"
        return
      target = published
    elif not target.isRelativeTo(GameStore):
      echo link, " targets evidence outside the game store: ", staged, " stays staged"
      return
    let futureLink = destination / entry.relative
    links.add (link, expandSymlink(link), target.relativePath(futureLink.parentDir))
  try:
    for (link, _, target) in links:
      removeFile(link)
      createSymlink(target, link)
    createDir(destination.parentDir)
    moveDir(staged, destination)
  except OSError as error:
    echo "Publication of ", staged, " failed, so it stays staged: ", error.msg
  finally:
    # Links prepared for publication may temporarily be unreadable in
    # staging. A failed move must leave staging usable.
    if dirExists(staged):
      for (link, original, _) in links:
        if symlinkExists(link) or fileExists(link): removeFile(link)
        createSymlink(original, link)

proc forgetGame*(directory, log: string) =
  ## Delete a game's evidence and what was derived from it before it is replayed.
  let stem = log.extractFilename[0 ..< ^4]   # without `.log`
  for folder in [directory, storePath(directory)]:
    if not dirExists(folder): continue
    for kind, path in walkDir(folder):
      if path.extractFilename.startsWith(stem & ".") and kind != pcDir: removeFile(path)

proc reusableGames*(directory: string, errors = false): Table[string, JsonNode] =
  ## A result set's completed games by `gameId`, the ones a resume keeps.
  ## Errored games are left out, so a resumed set plays them again rather than
  ## judging on them; with `errors`, as `--collect-only` keeps them, they stay.
  let path = directory / "results.json"
  if not fileExists(path): return
  for game in parseFile(path)["games"]:
    if errors or game["status"].getStr == "completed": result[game.gameId] = game

proc retainTournament*(directory, destination: string) =
  ## Move finished evidence once, preserving links to previously cached matches.
  if directory == destination: return
  if dirExists(destination) or fileExists(destination):
    raise newException(IOError, destination & " exists")
  var links: seq[(string, string)]
  for entry in walkTree(directory):
    if entry.symlink: links.add (entry.relative, resolved(directory / entry.relative))
  createDir(destination.parentDir)
  moveDir(directory, destination)
  for (relative, original) in links:
    var target = original
    if target.isRelativeTo(directory): target = destination / target.relativePath(directory)
    let link = destination / relative
    removeFile(link)
    createSymlink(target.relativePath(link.parentDir), link)

proc environmentProvenance*(): JsonNode =
  ## The selected toolkit release and the engine the judge plays, by content.
  %*{"version": toolkitVersion(), "engine_sha256": sha256File(engineWasm())}

proc sameEnvironment*(recorded, actual: JsonNode): bool =
  ## Whether a run's recorded toolkit is this one. Records from before the
  ## port also hash the toolkit's Python wrapper, which judge games never ran.
  if recorded.isNil or recorded.kind != JObject: return false
  recorded{"version"} == actual["version"] and recorded{"engine_sha256"} == actual["engine_sha256"]

proc writeResult*(output, replay, mapName: string, seed: int64, a, b: string,
                  exitCode: int, timedOut: bool, elapsed = -1.0, slotSeconds = -1.0,
                  keepGame = false) =
  ## Write a game's `result` record (tools/gamedata/format.md) with
  ## loong-gamedata. The replay's game columns are written beside `output`
  ## first and removed after unless `keepGame`. A game that left no replay
  ## records its harness facts only. `LOONG_GAMEDATA` names the binary, as on
  ## fleet workers.
  let binary = getEnv("LOONG_GAMEDATA", Root / "build/bin/loong-gamedata")
  let game = output[0 ..< output.len - ".result.cols".len] & ".cols"
  let converted = replay.len > 0 and fileExists(replay) and
    runQuietly(@[binary, replay, game], timeout = 300).code == 0
  var command = @[binary, "result", output, "--map", mapName, "--seed", $seed,
                  "--bot-a", a, "--bot-b", b, "--exit-code", $exitCode]
  if converted: command.add ["--game", game]
  if timedOut: command.add "--timed-out"
  if elapsed >= 0: command.add ["--elapsed", formatFloat(elapsed, ffDecimal, 3)]
  if slotSeconds >= 0: command.add ["--slot-seconds", formatFloat(slotSeconds, ffDecimal, 3)]
  let (code, killed) = runQuietly(command, timeout = 300)
  if code != 0 or killed: raise newException(IOError, "loong-gamedata result failed for " & output)
  if converted and not keepGame: removeFile(game)

proc matchArguments*(game: Game, store: string): seq[string] =
  ## The game's `run` arguments after the judge and its engine.
  result = @["run", "-o", store / game.stem & ".replay", "--sandbox"]
  if game.seed.isSome: result.add ["--seed", $game.seed.get]
  # The judge names each team by its bot, wherever its build lives.
  result.add ["--team-a", game.a, "--team-b", game.b]
  if game.engine == "judge-toolkit-accounting": result.add "--charge-first-read"
  result.add game.mapPath
  for bot in [game.a, game.b]: result.add launcher(botDirectory(bot))

proc gameToJson*(game: Game): JsonNode =
  %*{"directory": game.directory, "stem": game.stem, "map": game.mapPath,
     "seed": game.seedJson, "a": game.a, "b": game.b, "engine": game.engine}

proc gameFromJson*(node: JsonNode): Game =
  Game(directory: node["directory"].getStr, stem: node["stem"].getStr, mapPath: node["map"].getStr,
       seed: (if node["seed"].kind == JNull: none(int64) else: some(node["seed"].getBiggestInt.int64)),
       a: node["a"].getStr, b: node["b"].getStr, engine: node["engine"].getStr)

proc playOneGame*(game: Game, timeout: float): JsonNode =
  ## Play a game locally, cache permitting, once more if it ran past
  ## `timeout`, and write its result record: its command, outcome and seconds.
  let store = gameStore(game.directory)
  let log = store / game.stem & ".log"
  let command = matchCommand() & matchArguments(game, store)
  let started = epochTime()
  var (code, timedOut) = runGame(command, log, timeout)
  if timedOut: (code, timedOut) = runGame(command, log, timeout)
  let outcome = readOutcomeFile(log, code, timedOut)
  let seconds = round(epochTime() - started, 3)
  writeResult(store / game.stem & ".result.cols", store / game.stem & ".replay",
              game.mapPath.extractFilename, game.seed.get(0), game.a, game.b, code, timedOut, seconds)
  %*{"command": command, "seconds": seconds, "outcome": outcome.toJson}

proc builtGuids*(games: seq[Game]): Table[string, string] =
  ## Each bot's prepared build, by the GUID its build metadata names.
  for game in games:
    for bot in [game.a, game.b]:
      let metadata = compiledBotPath(botDirectory(bot)).changeFileExt(".json")
      if bot notin result and fileExists(metadata): result[bot] = parseFile(metadata)["guid"].getStr

proc seats*(game: Game, builds: Table[string, string]): JsonNode =
  ## The record's `builds`, when both seats' builds are known.
  result = newJObject()
  if game.a in builds and game.b in builds:
    result["builds"] = %*{"A": builds[game.a], "B": builds[game.b]}

type
  Landed* = proc (index: int, record: JsonNode)
  Chooser* = proc (landed: Table[int, JsonNode], running: HashSet[int]): seq[int]

proc playLocally*(games: seq[Game], timeout: float, workers: int, onResult: Landed = nil,
                  choose: Chooser = nil, inFlight = 0): seq[JsonNode] =
  ## Play `games` on this host, `workers` at once (at most `inFlight`), and
  ## return their records in order; games never started stay nil. Each game
  ## plays in a child process of this binary (`play-game`), so the game cache
  ## locks work across runners. `choose(landed, running)` returns the indices
  ## worth starting next; without it every game plays.
  result = newSeq[JsonNode](games.len)
  if games.len == 0: return
  let gamedata = getEnv("LOONG_GAMEDATA", Root / "build/bin/loong-gamedata")
  if not fileExists(gamedata): raise newException(IOError, gamedata & " is missing: run just tools-build")
  for game in games: discard gameStore(game.directory)
  # Refuse a missing or stale judge once, before any game starts.
  discard matchCommand()
  let environment = environmentProvenance()
  var mapHashes: Table[string, string]
  for game in games:
    if game.mapPath.extractFilename notin mapHashes:
      mapHashes[game.mapPath.extractFilename] = sha256File(game.mapPath)
  let builds = builtGuids(games)
  var landed: Table[int, JsonNode]
  var children: seq[Child]
  let limit = min(workers, if inFlight > 0: inFlight else: workers)
  proc next(running: HashSet[int]): seq[int] =
    if choose != nil:
      for index in choose(landed, running):
        if index notin running: result.add index
    else:
      for index in 0 ..< games.len:
        if index notin landed and index notin running: result.add index
  while true:
    var running = initHashSet[int]()
    for child in children: running.incl child.tag
    let fresh = next(running)
    for index in fresh[0 ..< min(fresh.len, limit - children.len)]:
      children.add spawnChild(@[selfExecutable(), "play-game", $gameToJson(games[index]), $timeout],
                              index, cwd = Root)
    if children.len == 0: break
    let (index, code, output) = waitAnyChild(children)
    checkInterrupt()
    if code != 0: raise newException(IOError, "game " & games[index].stem & " failed to play: exit " & $code)
    let played = parseJson(output)
    let game = games[index]
    var extra = %*{"command": played["command"], "seconds": played["seconds"], "engine": game.engine,
                   "toolkit": environment, "map_sha256": mapHashes[game.mapPath.extractFilename]}
    for key, value in seats(game, builds): extra[key] = value
    let record = game.record(played["outcome"], extra = extra)
    result[index] = record
    landed[index] = record
    if onResult != nil: onResult(index, record)
  var directories = initHashSet[string]()
  for game in games: directories.incl game.directory
  for directory in directories: publishStore(directory)

proc ratingsOf*(bots: seq[string], games: JsonNode, start = initTable[string, float]()): Table[string, float] =
  ## Bradley–Terry ratings on the Elo scale, pool mean 1500; errored games
  ## are left out.
  var outcomes: seq[Outcome]
  for game in games:
    if game["status"].getStr != "completed": continue
    let winner = game{"winner_side"}.getStr
    outcomes.add Outcome(a: game["A"].getStr, b: game["B"].getStr,
      winner: if winner == "A": 0 elif winner == "B": 1 else: -1)
  fitRatings(bots, outcomes, start)

proc saveResults*(directory: string, report: JsonNode): string =
  ## Standings with ratings into `results.json`, and the summary, returned.
  var names: seq[string]
  for name, _ in report["bots"]: names.add name
  var standings = initOrderedTable[string, JsonNode]()
  for name, bot in report["bots"]:
    standings[name] = %*{"bot": name, "status": bot["status"], "wins": 0, "draws": 0,
                         "losses": 0, "errors": 0, "points": 0.0}
  for game in report["games"]:
    for side in ["A", "B"]:
      let row = standings[game[side].getStr]
      if game["status"].getStr == "error": row["errors"] = %(row["errors"].getInt + 1)
      elif game{"winner_side"}.kind == JNull:
        row["draws"] = %(row["draws"].getInt + 1)
        row["points"] = %(row["points"].getFloat + 0.5)
      elif game["winner_side"].getStr == side:
        row["wins"] = %(row["wins"].getInt + 1)
        row["points"] = %(row["points"].getFloat + 1)
      else: row["losses"] = %(row["losses"].getInt + 1)
  let ratings = ratingsOf(names, report["games"])
  var rows: seq[JsonNode]
  for name, row in standings:
    row["rating"] = %ratings[name]
    rows.add row
  rows.sort(proc (x, y: JsonNode): int =
    result = cmp(y["points"].getFloat, x["points"].getFloat)
    if result == 0: result = cmp(x["bot"].getStr, y["bot"].getStr))
  report["standings"] = %rows
  writeFile(directory / "results.json", pythonDumps(report, indent = 2) & "\n")
  var listed: seq[string]
  for row in rows: listed.add "`" & row["bot"].getStr & "` " & cFormat("%.0f", row["rating"].getFloat)
  writeSummary(@[directory], directory, "Round-robin results",
    "Mode " & report["mode"].getStr & ", " & $report["scheduled_games"].getInt &
    " scheduled games, state " & report["status"].getStr &
    ". Bradley–Terry ratings on the Elo scale, pool mean 1500: " & listed.join(", ") & ".",
    @[], Root)
