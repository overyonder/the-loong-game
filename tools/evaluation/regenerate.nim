## Regenerate a recorded game's replay: `just regenerate RESULT_DIR GAME`.
##
## Fleet workers return each game's log, points and result record, and a
## replay only when a run asks for a sample, since downloading every replay
## costs several times the compute. A game is seeded and the judge
## deterministic, so its record (map, seed, both registered build GUIDs and
## their seats) regenerates it exactly: this plays it again in the judge with
## the recorded engine and registered builds, with the debug lines the viewer
## and `just activation` read, checks that its points columns and result
## record match the recorded ones, and writes the replay into the set's store
## beside them.
##
## GAME is a game's stem (its log's name without `.log`) or the number its
## stem starts with, which is its schedule number. A build that isn't
## registered is refused, naming `just bot-build`. `replay(directory, game)`
## returns the replay path, playing the game first only when the store doesn't
## hold it; `just viewer` and `just activation` call it.
##
## `just regenerate GAME_ID` does the same for one of our ladder games. The
## site's replay can't be replayed as it stands: it removes the map's spawn
## gaps and the spawn countdowns our dragons saw, and the other side's bot
## isn't ours. So the judge plays the game again from its seed, with the
## served map's spawns restored from the published map or the served variant
## whose gaps explain the game's pearl spawns and whose replay matches the
## site's, our side as the registered build of the submitted release, and the
## other side replaying its recorded moves, splits and sonar. Every
## observation of ours is then the one the ladder gave, and each of our
## actions is checked against the site's replay, in
## `assets/ladder-replays/<id>.json`.

import std/[algorithm, json, os, strutils, tables, tempfiles, times]
import paths, processes, python_json, runner, tournament
import bot_build/registry
import ../gamedata/[capnp_replay, columns, compare, event_json, sha256]
import ../judge/harness
import ../ladder/map_variants
import ../analysis/economy

let
  Ladder        = Root / "results/online"
  ## Reconstructed ladder games, derived from the site's replays.
  LadderReplays = Root / "assets/ladder-replays"

proc fetchReplay*(game: int, role, reason: string): string

type PointTurn = tuple[round: int, dragon: int, points: float, failure: string]

proc pointTurns(path: string): seq[PointTurn] =
  ## A points file's turns as (round, dragon, points, failure), in order.
  if not fileExists(path): return
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  for row in 0 ..< file.rowCount("turn.round"):
    result.add (int(file.numberAt("turn.round", row)), int(file.numberAt("turn.dragon", row)),
                file.numberAt("turn.points", row), file.stringRow("turn.failure", row))

proc records*(directory: string): JsonNode =
  ## A result set's game records: a runner's `results.json`, or a list.
  for name in ["results.json", "games.json"]:
    if fileExists(directory / name):
      let data = parseFile(directory / name)
      return if data.kind == JObject: data["games"] else: data
  raise newException(ValueError, directory & " has no results.json")

proc stemOf*(record: JsonNode): string =
  let name = record["log"].getStr.extractFilename
  name[0 ..< name.len - ".log".len]

proc findRecord*(directory, game: string): JsonNode =
  ## The record GAME names: a stem, or the number a stem starts with.
  var games: seq[JsonNode]
  for record in records(directory):
    if record.kind == JObject and record.len > 0: games.add record
  for record in games:
    if stemOf(record) == game: return record
  if game.len > 0 and game.allCharsInSet(Digits):
    # Runners number their stems (`003-a-vs-b-map`), batch by position.
    for record in games:
      let number = stemOf(record).split('-', 1)[0]
      if number.len > 0 and number.allCharsInSet(Digits) and parseInt(number) == parseInt(game): return record
    for record in games:
      if record{"position"}.kind == JInt and record["position"].getInt == parseInt(game): return record
  raise newException(ValueError, directory & " records no game " & game)

proc builds*(directory: string, record: JsonNode): JsonNode =
  ## Each seat's registered build GUID: from the record, or for a run from
  ## before records named them, from its fleet run's ledger entry.
  if record{"builds"} != nil and record["builds"].len > 0: return record["builds"]
  var named = newJObject()
  let runs = directory / "fleet-runs.jsonl"
  if fileExists(runs):
    for line in readFile(runs).splitLines:
      if line.len == 0: continue
      for bot, guid in parseJson(line){"builds"}.getFields: named[bot] = guid
  if named.hasKey(record["A"].getStr) and named.hasKey(record["B"].getStr):
    return %*{"A": named[record["A"].getStr], "B": named[record["B"].getStr]}
  raise newException(ValueError, stemOf(record) & ": its record names no builds, so it can't be regenerated")

proc judgeBuild(name, guid: string): string =
  if not fileExists(Registry / guid / "judge.wasm"):
    raise newException(ValueError, name & "'s build " & guid & " isn't registered here: run just " &
      "bot-build for its source at the commit that built it")
  try: resolveBuild(Registry, guid)[0] / "judge.wasm"
  except CatchableError as error:
    raise newException(ValueError, name & "'s registered build " & guid & " failed verification: " & error.msg)

proc regenerate*(directory: string, record: JsonNode): string =
  ## Play the recorded game again and store its replay, after checking it.
  let stem = stemOf(record)
  let seed = record{"seed"}
  if seed.isNil or seed.kind != JInt or seed.getBiggestInt < 0:
    raise newException(ValueError, stem & ": reconstruction needs its recorded uint64 seed")
  let seats = builds(directory, record)
  let wasm = [judgeBuild(record["A"].getStr, seats["A"].getStr), judgeBuild(record["B"].getStr, seats["B"].getStr)]
  let mapPath = resolved(gameFile(Root, record["map"].getStr))
  if not fileExists(mapPath): raise newException(ValueError, stem & ": its map " & record["map"].getStr & " is missing")
  let mapBytes = readFile(mapPath)
  let engine = record{"engine"}.getStr("judge")
  if engine == "toolkit":
    raise newException(ValueError, stem & ": recorded in the organisers' toolkit, which nothing runs any more")
  if engine notin ["judge", "judge-toolkit-accounting"]:
    raise newException(ValueError, stem & ": unsupported recorded engine " & engine)
  if record{"map_sha256"}.getStr.len > 0 and sha256Hex(mapBytes) != record["map_sha256"].getStr:
    raise newException(ValueError, stem & ": map hash differs from its recorded map")
  let prefix = matchCommand()
  # The engine is compared by content: releases that ship the same engine
  # replay the same games.
  if record{"toolkit"} != nil and record["toolkit"]{"engine_sha256"}.getStr.len > 0 and
      sha256File(prefix[2]) != record["toolkit"]["engine_sha256"].getStr:
    raise newException(ValueError, stem & ": judge selected a different engine hash")
  let recordedResult = gameFile(directory, "store/" & stem & ".result.cols")
  let recordedPoints = gameFile(directory, "store/" & stem & ".points.cols")
  let store = gameStore(directory)
  createDir(Root / "build")
  let work = createTempDir("", "", Root / "build")
  defer: removeDir(work)
  writeFile(work / mapPath.extractFilename, mapBytes)
  let replay = work / stem & ".replay"
  var command = prefix & @["run", "--sandbox", "--seed", $seed.getBiggestInt,
    "--team-a", record["A"].getStr, "--team-b", record["B"].getStr]
  if engine == "judge-toolkit-accounting": command.add "--charge-first-read"
  command.add ["-o", replay, work / mapPath.extractFilename, wasm[0], wasm[1]]
  let (code, timedOut) = play(command, work / stem & ".log", GameTimeout)
  if code != 0 or timedOut or not fileExists(replay):
    raise newException(ValueError, stem & ": " & engine & " failed to replay it (exit " & $code & ")")
  let result0 = work / stem & ".result.cols"
  writeResult(result0, replay, mapPath.extractFilename, seed.getBiggestInt, record["A"].getStr,
              record["B"].getStr, 0, false)
  # The result record's game fields, not its timings, must match.
  if fileExists(recordedResult) and not sameFields(readResult(result0)[0], readResult(recordedResult)[0]):
    raise newException(ValueError, stem & ": the regenerated result differs from the record")
  let points = work / stem & ".points.cols"
  if fileExists(recordedPoints) and pointTurns(points) != pointTurns(recordedPoints):
    raise newException(ValueError, stem & ": the regenerated points differ from the record")
  copyFile(replay, store / stem & ".replay")
  if not fileExists(recordedPoints) and fileExists(points): copyFile(points, store / points.extractFilename)
  publishStore(directory)
  gameFile(directory, "store/" & stem & ".replay")

proc replay*(directory, game: string): string =
  ## GAME's replay, regenerated into the store first if it doesn't hold it.
  let record = findRecord(directory, game)
  if record{"replay"}.getStr.len > 0 and fileExists(gameFile(directory, record["replay"].getStr)):
    return gameFile(directory, record["replay"].getStr)
  let stored = gameFile(directory, "store/" & stemOf(record) & ".replay")
  if fileExists(stored): stored else: regenerate(directory, record)

proc ladderMaps(served: string, seed: uint64, spawns: seq[tuple[round: int, tile: (int, int)]]): seq[string] =
  ## The served map as the judge may have played it, once for each table that
  ## explains the game's spawns; replaying the game picks the one. The site's
  ## replay removes spawn gaps, so the tiles come from the published map or a
  ## variant whose gaps explain the game's pearl spawns with its seed. Every
  ## other line is the served map's: the ladder serves some maps with edges
  ## that differ from the published file, and the served DRAGON lines seat the
  ## teams. The tiles must be the same cells in the same order.
  var lines = served.splitLines
  if lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
  var name = ""
  for line in lines:
    if line.startsWith("MAP_NAME "):
      name = line[9 .. ^1]
      break
  let paths = picks(name, seed, spawns)
  if paths.len == 0:
    raise newException(ValueError, "no published map or known variant of " & name &
      " explains this game's pearl spawns; run `just map-variants '" & name & "'` to fit the variant")
  proc cells(text: seq[string]): seq[seq[string]] =
    for line in text:
      if line.startsWith("TILE "): result.add line.splitWhitespace[1 .. 2]
  for path in paths:
    var ours = readFile(path).splitLines
    if ours.len > 0 and ours[^1].len == 0: ours.setLen(ours.len - 1)
    if cells(ours) != cells(lines): raise newException(ValueError, path.extractFilename & "'s tiles aren't the served map's")
    var tiles: seq[string]
    for line in ours:
      if line.startsWith("TILE "): tiles.add line
    var at = 0
    var text: seq[string]
    for line in lines:
      if line.startsWith("TILE "):
        text.add tiles[at]
        inc at
      else: text.add line
    result.add text.join("\n") & "\n"

proc teamsOf(served: string, message: CapnpMessage, events: CapnpList): Table[int, int] =
  ## Each dragon's team: the map's DRAGON lines in order, then each split's.
  var index = 0
  for line in served.splitLines:
    if line.startsWith("DRAGON "):
      result[index] = parseInt(line.splitWhitespace[1])
      inc index
  for at in 0 ..< events.count:
    let event = events.listStruct(at)
    if message.uint16Field(event, 0) == DragonSplit:
      let member = message.structField(event, 0)
      result[int(message.int32Field(member, 1))] = int(message.uint16Field(member, 4))

proc actions(path: string, team: int, served: string): OrderedTable[(int, int), string] =
  ## Each of `team`'s actions by (round, dragon), as JSON.
  let message = loadReplay(path)
  let events = message.eventList(path)
  let teams = teamsOf(served, message, events)
  var round = -1
  for at in 0 ..< events.count:
    let event = events.listStruct(at)
    let member = message.structField(event, 0)
    case message.uint16Field(event, 0)
    of RoundStart: round = int(message.int32Field(member, 0))
    of DragonAction:
      let id = int(message.int32Field(member, 0))
      if teams.getOrDefault(id, -1) == team:
        result[(round, id)] = if message.hasPointer(member, 0):
                                pythonDumps(message.playerAction(message.structField(member, 0)))
                              else: "null"
    else: discard

proc stateEvent(path: string, at: int): JsonNode =
  ## An event as the state comparison sees it: without its instruction count,
  ## and a turn the site marks as run out of time as the empty reply the
  ## judge's engine plays, a suicide.
  if at < 0: return newJNull()
  let message = loadReplay(path)
  result = message.eventJson(message.eventList(path).listStruct(at))
  if result["type"].getStr == "dragonAction":
    if result.hasKey("instructions"): result.delete("instructions")
    if truthy(result{"tle"}) and (result{"action"}.isNil or result["action"].kind == JNull):
      result["action"] = %*{"suicide": nil}
      result["tle"] = %false

proc stateDifference(site, played: string): JsonNode =
  ## Where the regenerated game's state first departs from the site's, if it
  ## does: the round, the index among the compared events, and both events.
  let (differs, at) = firstStateDifference(site, played)
  if not differs: return newJNull()
  %*{"round": at.round, "event": at.event, "site": stateEvent(site, at.site), "judge": stateEvent(played, at.judge)}

proc seedCache(): JsonNode =
  if fileExists(Seeds): parseFile(Seeds) else: newJObject()

proc ladderSeed(game: int): uint64 =
  ## A ladder game's seed, cached with `map_variants`' seeds.
  let cache = seedCache()
  let known = cache.hasKey($game)
  result = seedOf(game, cache)
  if not known:
    createDir(Seeds.parentDir)
    writeFile(Seeds, pythonDumps(cache))

proc playScripted(command: seq[string], work, target: string): tuple[failed: bool, code: int, tail: string] =
  ## Play a scripted regeneration: whether it failed, its exit code and the
  ## end of its log.
  let (code, timedOut) = play(command, work / "log", GameTimeout)
  if code != 0 or timedOut or not fileExists(target):
    let log = if fileExists(work / "log"): readFile(work / "log") else: ""
    return (true, code, log[max(0, log.len - 400) .. ^1])

proc header(path: string): (string, string, string) =
  ## A replay's served map and both teams' names.
  let message = loadReplay(path)
  (message.textField(message.root, 0), message.textField(message.root, 1), message.textField(message.root, 2))

proc ladder*(game: int, again = false, build = "", siteReplay = "", side = ""): string =
  ## A ladder game played again in the judge: our side's registered build of
  ## the submitted release, the other side replaying its recorded actions and
  ## sonar, from the match seed and the served map with its spawns restored.
  ## The foil's releases aren't in releases.json, so for one of its games a
  ## registered `build` is named instead, with the `siteReplay` and our `side`;
  ## the replay and report go to `LadderReplays/foil/`.
  var output, site, releaseName, wasm: string
  var ours: int
  if build.len > 0:
    if siteReplay.len == 0 or side notin ["A", "B"]:
      raise newException(ValueError, "--build needs --replay and --side A or B")
    output = LadderReplays / "foil"
    result = output / $game & "." & build[0 ..< 8] & ".replay"
    if fileExists(result) and not again: return
    releaseName = "build " & build
    wasm = judgeBuild(build, build)
    ours = if side == "A": 0 else: 1
    site = siteReplay
  else:
    output = LadderReplays
    result = output / $game & ".replay"
    if fileExists(result) and not again: return
    let entry = parseFile(Ladder / "replays-manifest.json"){$game & ".replay"}
    if entry.isNil or not truthy(entry{"ours"}):
      raise newException(ValueError, "ladder game " & $game & " isn't one of ours in the manifest")
    # releases.json holds our line's releases; a foil game names its build.
    let release = parseFile(Ladder / "releases.json"){$entry["submission"].getInt}
    if release.isNil:
      raise newException(ValueError, "ladder game " & $game & "'s submission " & $entry["submission"].getInt &
        " isn't one of our releases in releases.json")
    releaseName = release["name"].getStr
    wasm = judgeBuild(releaseName, release["build_guid"].getStr)
    if sha256File(wasm) != release["wasm_sha256"].getStr:
      raise newException(ValueError, releaseName & "'s registered judge WASM isn't the submitted one")
    site = publicReplays() / $game & ".replay"
    if not fileExists(site): site = fetchReplay(game, "viewer", "regenerated")
    ours = if entry["side"].getStr == "A": 0 else: 1
  createDir(output)
  createDir(LadderReplays)
  let seed = ladderSeed(game)
  let (served, teamA, teamB) = header(site)
  createDir(Root / "build")
  let work = createTempDir("", "", Root / "build")
  defer: removeDir(work)
  let scripts = @[work / "a", work / "b"]
  let spawns = spawnsOf(site, scripts)
  for mapText in ladderMaps(served, seed, spawns):
    writeFile(work / "map", mapText)
    let bots = if ours == 0: @[wasm, "-"] else: @["-", wasm]
    let command = matchCommand() & @["run", "--sandbox", "--seed", $seed, "--team-a", teamA,
      "--team-b", teamB, "--script-" & $"ab"[1 - ours], scripts[1 - ours], "-o", result, work / "map"] & bots
    let (failed, code, tail) = playScripted(command, work, result)
    if failed: raise newException(ValueError, "ladder game " & $game & ": the judge failed (exit " & $code & "): " & tail)
    if stateDifference(site, result).kind == JNull: break
  let recorded = actions(site, ours, served)
  let played = actions(result, ours, served)
  var matching = 0
  var first = newJNull()
  var ordered: seq[(int, int)]
  for turn in recorded.keys: ordered.add turn
  ordered.sort
  for turn in ordered:
    let action = recorded[turn]
    if played.getOrDefault(turn) == action: inc matching
    elif first.kind == JNull:
      first = %*{"round": turn[0], "dragon": turn[1], "site": action,
                 "judge": if turn in played: %played[turn] else: newJNull()}
  # Turns in (round, dragon) order, as the site recorded them.
  var turns = 0
  for _ in recorded.keys: inc turns
  let report = %*{"game": game, "release": releaseName, "seed": toHex(seed, 16).toLowerAscii,
    "our_turns": turns, "matching_turns": matching, "first_divergence": first,
    # Our observations are exact only up to here: past it the game's state,
    # and so what our dragons saw, may differ from the ladder's.
    "first_state_difference": stateDifference(site, result)}
  writeFile(result.changeFileExt(".json"), pythonDumps(report, indent = 1) & "\n")

proc fetchReplay*(game: int, role, reason: string): string =
  ## A ladder game's replay from the store, which the replay collector
  ## (`loong-sample-replays`) fetches, pinned for `role`, when it isn't there.
  result = publicReplays() / $game & ".replay"
  if fileExists(result): return
  stderr.writeLine "fetching replay ", game
  let (code, _) = runQuietly(@[Root / "build/bin/loong-sample-replays", "--output", Ladder,
    "--interval", "0.2", "--replays", publicReplays(), "--battles", $game,
    "--pin-role", role, "--pin-reason", reason], output = "/dev/stderr")
  if code != 0: raise newException(IOError, "loong-sample-replays failed for game " & $game)
  if not fileExists(result): raise newException(IOError, "the site serves no replay of game " & $game)

proc fetchSeeds*(games: seq[int], workers = 4) =
  ## Cache the seeds of `games` the map variants' cache lacks: from the
  ## manifest where it has them, else from the site, `workers` requests at a
  ## time with their starts at least half a second apart, inside the API's 120
  ## requests a minute, so a request's latency doesn't idle the rest.
  let cache = seedCache()
  var missing: seq[int]
  for game in games:
    if cache.hasKey($game): continue
    let stored = storedSeed(game)
    if stored.len > 0: cache[$game] = %stored
    else: missing.add game
  var running: seq[Child]
  var started = 0.0
  for index, game in missing:
    let wait = started + 0.5 - epochTime()
    if wait > 0: sleep(int(wait * 1000))
    started = epochTime()
    running.add spawnChild(@[selfExecutable(), "site-seed", $game], index, cwd = Root)
    if running.len >= workers or index == missing.high:
      while running.len > 0 and (running.len >= workers or index == missing.high):
        let (at, code, output) = waitAnyChild(running)
        if code != 0: raise newException(IOError, "fetching the seed of game " & $missing[at] & " failed")
        cache[$missing[at]] = %output.strip
        if cache.len mod 50 == 0: writeFile(Seeds, pythonDumps(cache))
  createDir(Seeds.parentDir)
  writeFile(Seeds, pythonDumps(cache))

proc writeRecord(output: string, game: int, mapText, replies: string) =
  ## A regenerated game's record, what replays it exactly from its seed:
  ## `<id>.map`, the map it was played on with its spawn gaps, and
  ## `<id>.script`, both sides' replies, one `ROUND<TAB>DRAGON<TAB>REPLY` a
  ## line. Training replays games from their records.
  writeFile(output / $game & ".map", mapText)
  writeFile(output / $game & ".script", replies)

proc public*(game: int, output: string, again = false): JsonNode =
  ## A public ladder game played again in the judge with both sides replaying
  ## their recorded moves, splits and sonar, from the game's seed and the
  ## served map with its spawns restored. Writes `<id>.replay` when its state
  ## matches the site's throughout, and `<id>.json`, its report: `dropped`
  ## names why a game wasn't regenerated (no known map variant explains its
  ## spawns, the judge failed, or its state differs).
  let target = output / $game & ".replay"
  let reportPath = target.changeFileExt(".json")
  if fileExists(reportPath) and not again: return parseFile(reportPath)
  createDir(output)
  var report = %*{"game": game}
  proc finish(dropped: string): JsonNode =
    report["dropped"] = if dropped.len > 0: %dropped else: newJNull()
    if dropped.len > 0 and fileExists(target): removeFile(target)
    writeFile(reportPath, pythonDumps(report, indent = 1) & "\n")
    report
  let site = publicReplays() / $game & ".replay"
  if not fileExists(site): return finish("no site replay")
  let seed = ladderSeed(game)
  report["seed"] = %toHex(seed, 16).toLowerAscii
  let (served, teamA, teamB) = header(site)
  createDir(Root / "build")
  let work = createTempDir("", "", Root / "build")
  defer: removeDir(work)
  let scripts = @[work / "a", work / "b"]
  let spawns = spawnsOf(site, scripts)
  var mapTexts: seq[string]
  try: mapTexts = ladderMaps(served, seed, spawns)
  except ValueError as error: return finish("map: " & error.msg)
  # With both sides scripted the judge runs no bot, but still loads a module
  # from the first bot argument; any registered build serves.
  var modules: seq[string]
  for path in walkFiles(Registry / "*/judge.wasm"): modules.add path
  modules.sort
  var difference = newJNull()
  var played = ""
  for mapText in mapTexts:
    writeFile(work / "map", mapText)
    let command = matchCommand() & @["run", "--sandbox", "--seed", $seed, "--team-a", teamA,
      "--team-b", teamB, "--script-a", scripts[0], "--script-b", scripts[1], "-o", target,
      work / "map", modules[0], "-"]
    let (failed, code, tail) = playScripted(command, work, target)
    if failed: return finish("judge exit " & $code & ": " & tail)
    played = mapText
    difference = stateDifference(site, target)
    if difference.kind == JNull: break
  if difference.kind != JNull:
    report["first_state_difference"] = difference
    return finish("state differs from round " & $difference["round"].getInt)
  writeRecord(output, game, played, readFile(scripts[0]) & readFile(scripts[1]))
  finish("")

proc latestLoss(): (int, JsonNode) =
  ## The newest ladder game that is ours and that we lost: game ids rise
  ## over time, so the largest is the most recent.
  let manifest = if fileExists(Ladder / "replays-manifest.json"): parseFile(Ladder / "replays-manifest.json")
                 else: newJObject()
  result = (-1, newJNull())
  for name, entry in manifest:
    if truthy(entry{"ours"}) and truthy(entry{"lost"}):
      let game = parseInt(name.split('.')[0])
      if game > result[0]: result = (game, entry)
  if result[0] < 0: raise newException(ValueError, "No game in the ladder manifest is marked ours and lost")

proc regenerated(game: int): string =
  ## Our ladder game played again from its record, with how exactly it
  ## reproduces the site's; the site's replay if it can't be regenerated.
  try: result = ladder(game)
  except ValueError as error:
    stderr.writeLine "not regenerated, opening the site's replay: ", error.msg
    return publicReplays() / $game & ".replay"
  let report = parseFile(LadderReplays / $game & ".json")
  let difference = report{"first_state_difference"}
  stderr.writeLine "regenerated game ", game, ": ", report["matching_turns"].getInt, " of ",
    report["our_turns"].getInt, " of our actions match the site's; ",
    (if difference.isNil or difference.kind == JNull: "every other event matches"
     else: "observations may be inexact from round " & $difference["round"].getInt)
  result = resolved(result)

proc replaySource*(target: string, game = ""): seq[string] =
  ## The replay `just viewer` opens: a path, a ladder game id, `latest-loss`,
  ## or a result directory and one of its games; then, for a result set's
  ## game, `loong-recover`'s `--seat SIDE GUID BOT` arguments one to a line.
  var path: string
  if game.len > 0:
    let record = findRecord(target, game)
    path = resolved(replay(target, game))
    result = @[path]
    try:
      let named = builds(target, record)
      for side in ["A", "B"]:
        if named{side}.getStr.len > 0: result.add ["--seat", side, named[side].getStr, record[side].getStr]
    except ValueError: discard
  else:
    var identifier = -1
    if target == "latest-loss":
      let (found, entry) = latestLoss()
      identifier = found
      stderr.writeLine "latest loss: game ", found, ", ", entry{"map"}.getStr("unknown map"), " against ",
        entry{"opponent"}.getStr("unknown"), ", we played ", entry{"side"}.getStr("?")
    elif target.len > 0 and target.allCharsInSet(Digits): identifier = parseInt(target)
    if identifier < 0: path = resolved(target)
    else:
      let manifest = if fileExists(Ladder / "replays-manifest.json"): parseFile(Ladder / "replays-manifest.json")
                     else: newJObject()
      path = if truthy(manifest{$identifier & ".replay"}{"ours"}): regenerated(identifier)
             else: resolved(fetchReplay(identifier, "viewer", "opened in the viewer"))
    result = @[path]
  if not fileExists(path): raise newException(IOError, path & " does not exist")
