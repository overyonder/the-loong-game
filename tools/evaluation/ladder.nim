## `just ladder`: a resumable, frozen offline ladder under the judge's limits.
##
## The ladder copies each entry's source and every map into its directory and
## hashes them. It plays through the shared runner on the fleet or this host,
## using each entry's registered build; it never compiles, and an entry
## without one fails naming `bot-build`. Before playing, each live
## `bots/<entry>` must still match its frozen copy, so the registered build is
## the frozen source's. An entry kept only as a registered build
## (`[registered]` in pool.toml) records its GUID instead. Ratings refit here
## from the results.

import std/[algorithm, json, options, os, sets, strutils, tables]
import arguments, bots, paths, play, python_json, runner, seeds, toml, tournament
import report/summary
import ../gamedata/sha256

const
  ## Recorded in results.json; ladders without it were rated by streaming Elo.
  Rating = "bradley-terry"
  Usage = "usage: just ladder --output DIRECTORY [--config POOL] [--rounds N] [--resume] [options]"

proc pairingRounds*(names: seq[string], rounds: int): seq[seq[(string, string)]] =
  ## Circle schedule: n-1 rounds meet everyone; the next cycle reverses sides.
  if names.len < 2 or names.toHashSet.len != names.len:
    raise newException(ValueError, "Require at least two distinct bots")
  var rotation = names
  if names.len mod 2 == 1: rotation.add ""
  let size = rotation.len
  var cycle: seq[seq[(string, string)]]
  for index in 0 ..< size - 1:
    var pairs: seq[(string, string)]
    for slot in 0 ..< size div 2:
      let (a, b) = (rotation[slot], rotation[size - 1 - slot])
      if a.len > 0 and b.len > 0: pairs.add (a, b)
    if index mod 2 == 1:
      for pair in pairs.mitems: pair = (pair[1], pair[0])
    cycle.add pairs
    rotation = @[rotation[0], rotation[^1]] & rotation[1 ..< ^1]
  for index in 0 ..< rounds:
    var pairs = cycle[index mod cycle.len]
    if (index div cycle.len) mod 2 == 1:
      for pair in pairs.mitems: pair = (pair[1], pair[0])
    result.add pairs

proc headToHead*(bots: seq[string], games: JsonNode): Table[(string, string), float] =
  ## Points each bot scored against each other bot: 1 for a win, 1/2 for a draw.
  for a in bots:
    for b in bots:
      if a != b: result[(a, b)] = 0.0
  for game in games:
    if game["status"].getStr != "completed": continue
    let (a, b) = (game["A"].getStr, game["B"].getStr)
    if game{"winner_side"}.kind == JNull:
      result[(a, b)] += 0.5
      result[(b, a)] += 0.5
    elif game["winner_side"].getStr == "A": result[(a, b)] += 1
    else: result[(b, a)] += 1

proc ratingsJson(bots: seq[string], ratings: Table[string, float]): JsonNode =
  result = newJObject()
  for bot in bots: result[bot] = %ratings[bot]

proc toTable(ratings: JsonNode): Table[string, float] =
  for bot, value in ratings: result[bot] = value.getFloat

proc history(bots: seq[string], games: JsonNode): JsonNode =
  ## The fit to all games up to the end of each played round.
  var start = initTable[string, float]()
  for bot in bots: start[bot] = 1500.0
  result = %*[{"round": 0, "ratings": ratingsJson(bots, start)}]
  var rounds: seq[int]
  for game in games:
    if game["round"].getInt notin rounds: rounds.add game["round"].getInt
  rounds.sort
  for number in rounds:
    var played = newJArray()
    for game in games:
      if game["round"].getInt <= number: played.add game
    let ratings = ratingsOf(bots, played, result[^1]["ratings"].toTable)
    result.add %*{"round": number, "ratings": ratingsJson(bots, ratings)}

proc names(report: JsonNode): seq[string] =
  for name in report["bots"]: result.add name.getStr

proc save(directory: string, report: JsonNode) =
  let ratings = report["history"][^1]["ratings"]
  report["ratings"] = ratings
  # Atomic replacement leaves the preceding complete round resumable on interruption.
  writeFile(directory / "results.json.tmp", pythonDumps(report, indent = 2) & "\n")
  moveFile(directory / "results.json.tmp", directory / "results.json")
  let bots = report.names
  var csv = "round," & bots.join(",") & "\r\n"
  for snapshot in report["history"]:
    var row = @[$snapshot["round"].getInt]
    for name in bots: row.add pythonFloat(snapshot["ratings"][name].getFloat)
    csv.add row.join(",") & "\r\n"
  writeFile(directory / "ratings.csv", csv)
  let history = report["history"]
  let last = history.getElems[max(0, history.len - 21) .. ^1]
  let earlier = last[0]["ratings"]
  var lines = @["# Offline ladder", "",
    "State: " & report["status"].getStr & ". " & $(history.len - 1) & "/" & $report["rounds"].getInt &
      " rounds; " & $report["games"].len & " games.",
    "Bradley–Terry ratings fitted to every game so far, on the Elo scale " &
      "(400 points is ten-to-one odds; the pool averages 1500). " &
      "A draw is half a win each way; failed executions are unscored.",
    "", "| Bot | Rating | W–D–L | Errors | Last 20 rounds Δ | Last 20 range |",
    "| --- | ---: | ---: | ---: | ---: | ---: |"]
  var ranked: seq[string]
  for name, _ in ratings: ranked.add name
  ranked.sort(proc (x, y: string): int = cmp(ratings[y].getFloat, ratings[x].getFloat))
  for name in ranked:
    var wins, draws, losses, errors = 0
    for game in report["games"]:
      if name notin [game["A"].getStr, game["B"].getStr]: continue
      if game["status"].getStr != "completed": inc errors
      elif game{"winner_side"}.kind == JNull: inc draws
      elif game[game["winner_side"].getStr].getStr == name: inc wins
      else: inc losses
    var low = last[0]["ratings"][name].getFloat
    var high = low
    for snapshot in last:
      low = min(low, snapshot["ratings"][name].getFloat)
      high = max(high, snapshot["ratings"][name].getFloat)
    var change = formatFloat(ratings[name].getFloat - earlier[name].getFloat, ffDecimal, 1)
    if not change.startsWith('-'): change = "+" & change
    lines.add "| " & name & " | " & formatFloat(ratings[name].getFloat, ffDecimal, 1) & " | " &
      $wins & "–" & $draws & "–" & $losses & " | " & $errors & " | " &
      change & " | " & formatFloat(low, ffDecimal, 1) & "–" &
      formatFloat(high, ffDecimal, 1) & " |"
  # One rating per bot hides a circle (A beats B beats C beats A); the table
  # shows it as a lower-rated row with more than half the points.
  let scores = headToHead(ranked, report["games"])
  var header = "| Bot | " & ranked.join(" | ") & " |"
  var rule = "| --- |"
  for _ in ranked: rule.add " ---: |"
  lines.add ["", "Points each row bot scored against each column bot, of the rated games " &
    "between them (a draw is half a point):", "", header, rule]
  for name in ranked:
    var cells: seq[string]
    for other in ranked:
      cells.add(if other == name: "·" else: cFormat("%g", scores[(name, other)]) & "/" &
        cFormat("%g", scores[(name, other)] + scores[(other, name)]))
    lines.add "| " & name & " | " & cells.join(" | ") & " |"
  lines.add ["", "Each round has at most one game per bot (one rotating bye for odd pools). " &
    "Pairings rotate, sides reverse every " &
    "opponent cycle, and maps rotate after both sides have been played. " &
    "Each game's seed comes from its map and round, " &
    "so reruns replay the same games. Games play on the fleet or this host " &
    "through the shared runner, which keeps every game's replay in the game store.",
    "", "These ratings describe this fixed pool and map schedule; " &
    "they are not official competition Elo.", "",
    "[Rating history](ratings.csv) · [Full results](results.json)", ""]
  writeFile(directory / "summary.md", lines.join("\n"))

proc gameFor(directory: string, job: JsonNode): Game =
  ## A scheduled game; its seed depends only on the map and round, never on
  ## the bots, so renaming or refreezing a bot doesn't change which games it plays.
  let round = job["round"].getInt
  Game(directory: directory / "games",
       stem: "r" & align($round, 3, '0') & "-" & job["A"].getStr.replace("/", "-") & "-vs-" &
         job["B"].getStr.replace("/", "-"),
       mapPath: directory / "maps" / job["map"].getStr,
       seed: some(gameSeed(job["map"].getStr, round)), a: job["A"].getStr, b: job["B"].getStr,
       engine: "judge")

proc checkFrozen(directory: string, report: JsonNode) =
  ## The ladder's copies, and each live entry, still match the frozen hashes.
  ## An entry kept only as a registered build must keep the GUID it started with.
  let registered = report{"registered_builds"}
  var opponents = initTable[string, string]()
  for (name, guid) in registeredOpponents(): opponents[name] = guid
  if not registered.isNil:
    for name, guid in registered:
      if opponents.getOrDefault(name) != guid.getStr:
        raise newException(ValueError, "Frozen ladder entry " & name & " no longer names registered build " & guid.getStr)
  for name in report.names:
    if not registered.isNil and registered.hasKey(name): continue
    var added: seq[string]
    for entry in walkTree(Root / "bots" / name):
      if not entry.file: continue
      if "__pycache__" in entry.relative.split('/') or ".unswbc-build" in entry.relative.split('/'): continue
      let relative = "bots/" & name & "/" & entry.relative
      if not report["source_hashes"].hasKey(relative): added.add relative
    if added.len > 0:
      added.sort
      raise newException(ValueError, "Frozen ladder entry " & name & " gained " & added.join(", ") &
        "; a ladder plays only the sources it froze")
  for relative, expected in report["source_hashes"]:
    var copies = @[directory / relative]
    if relative.startsWith("bots/"): copies.add Root / relative
    for path in copies:
      if not fileExists(path) or sha256File(path) != expected.getStr:
        raise newException(ValueError, "Frozen ladder input changed: " & path &
          "; a ladder plays only the sources it froze")

proc ladder*(argv: seq[string]): int =
  let line = parseCommandLine(argv, Usage, @[
    OptionSpec(name: "config", arity: One, help: "Pool of bots and maps (default: pool.toml)"),
    OptionSpec(name: "output", arity: One, help: "New ladder directory"),
    OptionSpec(name: "rounds", arity: One, help: "Rounds; each gives every bot one game (default 100)"),
    OptionSpec(name: "workers", arity: One, help: "Local games at once"),
    OptionSpec(name: "resume", arity: Flag, help: "Continue the ladder in --output")] & runnerOptions())
  if not line.given("output"): line.fail "--output is required"
  let (rounds, workers) = (line.integer("rounds", 100), line.integer("workers", cpuWorkers()))
  if rounds < 1 or workers < 1: line.fail "rounds and workers must be positive"
  let place = line.placement
  let directory = resolved(line.last("output"))
  var report: JsonNode
  if line.given("resume"):
    report = parseFile(directory / "results.json")
    if report{"rating"}.getStr != Rating:
      # A ladder started under streaming Elo is refitted from its games.
      report.delete("initial_elo")
      report.delete("k_factor")
      report["rating"] = %Rating
      report["history"] = history(report.names, report["games"])
  else:
    var settings = readToml(line.last("config", Pool))
    if settings.hasKey("initial_elo"): settings.delete("initial_elo")
    if settings.hasKey("k_factor"): settings.delete("k_factor")
    let known = discoverBots()
    var names: seq[string]
    for name in settings["bots"]: names.add name.getStr
    let schedule = pairingRounds(names, rounds)
    for name in names:
      if not known.hasKey(name) or not known[name]["sandbox"].getBool:
        raise newException(ValueError, "Every ladder entry must be a known sandbox bot")
    if dirExists(directory): raise newException(IOError, directory & " exists")
    createDir(directory / "games")
    createDir(directory / "maps")
    var registered = newJObject()
    for (name, guid) in registeredOpponents():
      if name in names and not dirExists(Root / "bots" / name): registered[name] = %guid
    for name in names:
      if registered.hasKey(name): continue
      copyDir(Root / "bots" / name, directory / "bots" / name)
      for entry in walkTree(directory / "bots" / name):
        let parts = entry.relative.split('/')
        if "__pycache__" in parts or ".unswbc-build" in parts:
          removeFile(directory / "bots" / name / entry.relative)
    for source in settings["maps"]:
      copyFile(Root / source.getStr, directory / "maps" / source.getStr.extractFilename)
    var hashes = newJObject()
    for entry in walkTree(directory / "bots"):
      if entry.file: hashes["bots/" & entry.relative] = %sha256File(directory / "bots" / entry.relative)
    var mapFiles: seq[string]
    for kind, path in walkDir(directory / "maps", relative = true):
      if kind == pcFile: mapFiles.add path
    mapFiles.sort
    for name in mapFiles: hashes["maps/" & name] = %sha256File(directory / "maps" / name)
    report = settings.copy
    report["rating"] = %Rating
    report["rounds"] = %rounds
    report["games"] = newJArray()
    report["status"] = %"running"
    report["source_hashes"] = hashes
    report["registered_builds"] = registered
    report["history"] = history(names, newJArray())
    var rounded = newJArray()
    let cycle = 2 * (names.len - 1 + names.len mod 2)
    for index, pairs in schedule:
      var round = newJArray()
      for (a, b) in pairs:
        let map = settings["maps"][(index div cycle) mod settings["maps"].len].getStr.extractFilename
        round.add %*{"round": index + 1, "A": a, "B": b, "map": map}
      rounded.add round
    report["schedule"] = rounded
    save(directory, report)
  checkFrozen(directory, report)
  report["status"] = %"running"
  let remaining = report["schedule"].getElems[report["history"].len - 1 .. ^1]
  var jobs: seq[JsonNode]
  for pairs in remaining:
    for job in pairs: jobs.add job
  var games: seq[Game]
  for job in jobs: games.add gameFor(directory, job)
  let vcpus = fleetAllowance(place, games)
  # Copies each registered build with a game still to play into place; never
  # compiles. Games an earlier fleet run returned keep the builds it recorded.
  if not place.collectOnly:
    var directories: seq[string]
    for name in botsToPlay(games, directory / "fleet"): directories.add Root / "bots" / name
    prepareBots(directories, workers, registeredOnly = true)
  report["workers"] = %workers
  report["fleet_vcpus"] = %vcpus
  let records = playGames(games, place, workers, vcpus, directory / "fleet")
  var at = 0
  for pairs in remaining:
    var results: seq[JsonNode]
    var allPlayed = true
    for job in pairs:
      let (game, record) = (games[at], records[at])
      inc at
      if record.isNil:
        # Only collecting, and this game isn't collected: unplayed.
        allPlayed = false
        continue
      var entry = job.copy
      for key, value in record: entry[key] = value
      entry["map"] = job["map"]
      # The record names the game's files in its directory's store.
      entry["log"] = %(game.directory / record["log"].getStr).relativePath(directory)
      entry["replay"] = if record{"replay"}.kind == JNull: newJNull()
                         else: %(game.directory / record["replay"].getStr).relativePath(directory)
      allPlayed = allPlayed and fileExists(gameFile(game.directory, record["log"].getStr))
      results.add entry
    if not allPlayed:
      # A game the fleet never started leaves no log: this round and those
      # after it stay unsaved, and a resume plays them.
      break
    for result in results: report["games"].add result
    let ratings = ratingsOf(report.names, report["games"], report["history"][^1]["ratings"].toTable)
    report["history"].add %*{"round": pairs[0]["round"], "ratings": ratingsJson(report.names, ratings)}
    save(directory, report)
    var errors = 0
    for result in results:
      if result["status"].getStr != "completed": inc errors
    var leader = report.names[0]
    for name in report.names:
      if ratings[name] > ratings[leader]: leader = name
    echo "Round ", pairs[0]["round"].getInt, "/", report["rounds"].getInt, ": ", leader, " ",
      cFormat("%.0f", ratings[leader]), "; errors=", errors
  let finished = report["history"].len - 1 == report["schedule"].len
  var failed = false
  for game in report["games"]: failed = failed or game["status"].getStr != "completed"
  report["status"] = %(if not finished: "incomplete" elif failed: "completed_with_errors" else: "completed")
  save(directory, report)
  echo readFile(directory / "summary.md")
  0
