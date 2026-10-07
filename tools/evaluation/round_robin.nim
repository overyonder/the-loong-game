## `just round-robin`: every selected bot against every other (or, with
## `--anchor`, one bot against every other) on each map
## and seed, both sides, keeping each game's evidence; on this host, or on the
## fleet with `--fleet-vcpus`. An interrupted set stays in
## results/running and resumes there, playing again only the games that didn't
## complete; a finished one moves to its final directory.

import std/[algorithm, json, options, os, osproc, sequtils, sets, strutils, tables, times]
import arguments, bots, paths, play, processes, python_json, runner, seeds, tournament
import bot_build/registry
import ../gamedata/sha256

const Usage = "usage: just round-robin [--bots BOT...] [--maps MAP...] [--seeds N] [options]"

proc roundRobin*(argv: seq[string]): int =
  let line = parseCommandLine(argv, Usage, @[
    OptionSpec(name: "bots", arity: Many, help: "Bot names; default: the pool"),
    OptionSpec(name: "maps", arity: Many, help: "Map files (default: arena)"),
    OptionSpec(name: "sandbox", arity: Flag, help: "Accepted for older command lines: every game plays in the judge's sandbox"),
    OptionSpec(name: "build", arity: One, help: "BOT=GUID: play an exact registered judge build for a named bot; repeat per bot"),
    OptionSpec(name: "anchor", arity: One, help: "One selected bot: play only its pairings, against every other selected bot"),
    OptionSpec(name: "dry-run", arity: Flag, help: "Print the schedule without running"),
    OptionSpec(name: "output", arity: One, help: "Final result directory; an existing one is resumed, playing again only the games that did not complete"),
    OptionSpec(name: "workers", arity: One, help: "Local games at once"),
    OptionSpec(name: "seeds", arity: One, help: "Seeded games per map and side; 0 leaves seeding random"),
    OptionSpec(name: "seed-start", arity: One, help: "Index of the first seed per map"),
    OptionSpec(name: "engine", arity: One, help: "judge (the only engine; the toolkit is no longer played)")] &
    runnerOptions())
  if line.positional.len > 0: line.fail "unexpected " & line.positional.join(" ")
  if line.last("engine", "judge") != "judge": line.fail "--engine judge is the only engine"
  let place = line.placement
  let workers = line.integer("workers", cpuWorkers())
  if workers < 1: line.fail "workers must be positive"
  let (seedCount, seedStart) = (line.integer("seeds", 0), line.integer("seed-start", 0))
  let known = discoverBots()
  var selected = if line.given("bots"): line.all("bots") else: poolBots()
  # Naming one bot twice plays it against itself once per map and seed.
  let selfPlay = selected.len == 2 and selected[0] == selected[1]
  if not selfPlay and (selected.toHashSet.len != selected.len or selected.len < 2):
    line.fail "Select at least two distinct bots, or one bot twice for self-play"
  var unknown: seq[string]
  for name in selected:
    if not known.hasKey(name) and name notin unknown: unknown.add name
  if unknown.len > 0:
    unknown.sort(system.cmp)
    line.fail "Unknown bots: " & unknown.join(", ")
  var botsUsed = newJObject()
  for name in selected:
    if not botsUsed.hasKey(name): botsUsed[name] = known[name]
  var selectedBuilds = newJObject()
  for selection in line.each("build"):
    let separator = selection.find('=')
    let (name, guid) = if separator > 0: (selection[0 ..< separator], selection[separator + 1 .. ^1]) else: ("", "")
    if name.len == 0 or not botsUsed.hasKey(name) or selectedBuilds.hasKey(name):
      line.fail "Each --build must name one selected bot as BOT=GUID, once"
    try: discard resolveBuild(Registry, guid)
    except CatchableError as error: line.fail "Registered build " & guid & " failed verification: " & error.msg
    selectedBuilds[name] = %guid
  var maps: seq[string]
  for path in (if line.given("maps"): line.all("maps") else: @["tools/evaluation/maps/arena.map"]):
    maps.add resolved(if path.isAbsolute: path else: Root / path)
  var names = initHashSet[string]()
  for path in maps:
    if not fileExists(path) or maps.count(path) > 1: line.fail "Maps must be distinct existing files"
    names.incl path.extractFilename
  if names.len != maps.len: line.fail "Map basenames must be distinct for recorded schedules and fleet bundles"
  for name, bot in botsUsed:
    if not bot["sandbox"].getBool: line.fail name & " cannot run in the judge sandbox"
    if not line.given("dry-run"):
      for variable in bot["required_env"]:
        if getEnv(variable.getStr).len == 0: line.fail name & " requires " & variable.getStr
  # Seeds depend only on the map and its index, so every pairing and both
  # sides meet the same pearl schedules and results stay reproducible.
  var pairs: seq[(string, string)]
  if selfPlay: pairs.add (selected[0], selected[0])
  else:
    var order: seq[string]
    for name, _ in botsUsed: order.add name
    for left in 0 ..< order.len:
      for right in left + 1 ..< order.len:
        pairs.add (order[left], order[right])
        pairs.add (order[right], order[left])
  if line.given("anchor"):
    let anchor = line.last("anchor")
    if selfPlay or not botsUsed.hasKey(anchor): line.fail "--anchor names one of two or more distinct selected bots"
    pairs = pairs.filterIt(it[0] == anchor or it[1] == anchor)
  var schedule: seq[tuple[map: string, a, b: string, seed: Option[int64]]]
  for path in maps:
    var mapSeeds: seq[Option[int64]]
    for index in seedStart ..< seedStart + seedCount: mapSeeds.add some(gameSeed(path.extractFilename, index))
    if mapSeeds.len == 0: mapSeeds.add none(int64)
    for seed in mapSeeds:
      for (a, b) in pairs: schedule.add (path, a, b, seed)
  for index, game in schedule:
    let seeded = if game.seed.isSome: " seed " & $game.seed.get else: ""
    echo index + 1, ": ", game.a, " (A) vs ", game.b, " (B) on ", game.map.extractFilename, seeded
  for name, guid in selectedBuilds: echo "Registered build: ", name, " = ", guid.getStr
  if line.given("dry-run"): return 0
  let destination = resolved(line.last("output",
    Root / "results/local/round-robin" / now().utc.format("yyyyMMdd'T'HHmmssffffff'Z'")))
  let localResults = Root / "results/local"
  # An interrupted set is still in results/running and resumes there; a
  # retained one resumes in place.
  let running = if destination.isRelativeTo(localResults):
                  Root / "results/running" / destination.relativePath(localResults)
                else: destination
  var directory = running
  var resumed = false
  if fileExists(running / "results.json"): resumed = true
  else:
    resumed = fileExists(destination / "results.json")
    if dirExists(destination) and not resumed: line.fail "Result directory already exists: " & destination
    if resumed: directory = destination
  createDir(directory)
  var previous = if resumed: parseFile(directory / "results.json") else: newJObject()
  var provenance = newJNull()
  if not (resumed and place.collectOnly):
    var mapHashes = newJObject()
    for path in maps: mapHashes[path.extractFilename] = %sha256File(path)
    provenance = %*{"toolkit": environmentProvenance(), "engine": "judge", "maps": mapHashes}
  if resumed:
    if place.collectOnly: provenance = previous{"provenance"}
    else:
      let recorded = previous{"provenance"}
      if recorded.isNil or not sameEnvironment(recorded{"toolkit"}, provenance["toolkit"]) or
          recorded{"engine"} != provenance["engine"] or not sameFields(recorded{"maps"}, provenance["maps"]):
        line.fail "Cannot resume with changed or unrecorded SDK, engine or maps; use a new --output"
      let recordedBuilds = if previous{"selected_builds"}.isNil: newJObject() else: previous["selected_builds"]
      if not sameFields(recordedBuilds, selectedBuilds):
        line.fail "Cannot resume with changed --build selections; use a new --output"
  # A resumed set keeps its completed games and plays the rest again;
  # collecting keeps its errored games too.
  let kept = reusableGames(directory, errors = place.collectOnly)
  var report = %*{
    "workers": workers,
    "created_at": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'ffffff'+00:00'"),
    "mode": "sandbox",
    "status": "running",
    "bots": botsUsed,
    "selected_builds": if resumed and place.collectOnly: previous{"selected_builds"} else: selectedBuilds,
    "scheduled_games": schedule.len,
    "games": [],
    "provenance": provenance,
  }
  if report["selected_builds"].isNil: report["selected_builds"] = newJObject()
  report["source_revision"] =
    if resumed: previous{"source_revision"}
    else: %execProcess("git", workingDir = Root, args = ["rev-parse", "HEAD"], options = {poUsePath}).strip
  if report["source_revision"].isNil: report["source_revision"] = newJNull()
  var games: seq[Game]
  for index, entry in schedule:
    let key = [entry.a, entry.b, entry.map.extractFilename,
               if entry.seed.isSome: $entry.seed.get else: "null"].join("\t")
    if key in kept:
      report["games"].add kept[key]
      continue
    let stem = align($(index + 1), 3, '0') & "-" & entry.a.replace("/", "-") & "-vs-" &
      entry.b.replace("/", "-") & "-" & entry.map.splitFile.name
    forgetGame(directory, stem & ".log")
    games.add Game(directory: directory, stem: stem, mapPath: entry.map, seed: entry.seed,
                   a: entry.a, b: entry.b, engine: "judge")
  discard saveResults(directory, report)
  # Only bots with games still to play need registered builds; games an
  # earlier fleet run returned are collected under the builds it recorded.
  if not place.collectOnly:
    var directories: seq[string]
    for name in botsToPlay(games, directory / "fleet"): directories.add botDirectory(name)
    var guids: seq[(string, string)]
    for name, guid in selectedBuilds: guids.add (botDirectory(name), guid.getStr)
    prepareBots(directories, workers, registeredOnly = true, buildGuids = guids)
  let vcpus = fleetAllowance(place, games)
  if vcpus > 0 and not place.collectOnly:
    echo "Playing ", games.len, " games on the fleet (", vcpus, " vCPUs)"
  var savedAt = 0.0
  proc landed(index: int, record: JsonNode) =
    report["games"].add record
    # Each save refits the ratings and rebuilds the summary over every game so
    # far, so a large set saves at most every 30 seconds, and again at its end.
    if epochTime() - savedAt >= 30:
      discard saveResults(directory, report)
      savedAt = epochTime()
    echo "[", report["games"].len, "/", schedule.len, "] ", record["A"].getStr, " vs ",
      record["B"].getStr, ": ", record["status"].getStr
  try:
    discard playGames(games, place, workers, vcpus, directory / "fleet", landed)
  except InterruptError:
    report["status"] = %"interrupted"
    discard saveResults(directory, report)
    echo "Interrupted; completed results saved in ", directory
    return 130
  except CatchableError as error:
    report["status"] = %"error"
    report["error"] = %error.msg
    discard saveResults(directory, report)
    raise
  let lacking = schedule.len - report["games"].len
  if place.collectOnly and lacking > 0:
    # Only collecting: the set stays in results/running to resume.
    discard saveResults(directory, report)
    echo lacking, " of ", schedule.len, " scheduled games not played"
    return 0
  var failed = false
  for game in report["games"]: failed = failed or game["status"].getStr == "error"
  report["status"] = %(if failed: "completed_with_errors" else: "completed")
  echo saveResults(directory, report)
  retainTournament(directory, destination)
  echo "Results: ", destination
  int(failed)
