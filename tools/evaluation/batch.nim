## `just batch`: play sequential runs for one candidate or several at once.
##
## Each candidate's interleaved schedule (sequential.nim) plays in one pool or
## one fleet run, and a candidate's games stop starting once its tests have
## decided. At most `--in-flight` games play at once, so a run stops close to
## where its tests decide. Each candidate's plan and games land in
## `OUTPUT/<candidate>/results.json`, or `OUTPUT/NAME/results.json` for a
## trial, every game with its schedule position; a rerun keeps the completed
## games and carries on. Judging is its own stage: batch prints each
## candidate's `verdict` command.

import std/[json, options, os, sets, strutils, tables]
import arguments, bots, paths, play, python_json, runner, sequential, tournament
import report/summary

const
  InFlight = 32
  Usage = "usage: just batch --bots CANDIDATE... --output DIRECTORY [options]"

proc planOptions*(): seq[OptionSpec] =
  ## The options that fix a sequential run's plan; the runner records them.
  @[OptionSpec(name: "opponents", arity: Many, help: "Opponents, each with its own test " &
      "(default: see --baseline); add pool bots or random to include them"),
    OptionSpec(name: "baseline", arity: One, help: "Judge by matched pairs against this bot " &
      "over the common opponents, as for close versions of one line (default: the champion " &
      "when the candidate is from its line; `none` plays opponents directly)"),
    OptionSpec(name: "effect-elo", arity: One, help: "Smallest edge worth detecting (default 70 Elo)"),
    OptionSpec(name: "margin", arity: Optional, help: "Test non-inferiority instead: whether the " &
      "candidate is no more than this many Elo worse (default 70 when given bare)"),
    OptionSpec(name: "alpha", arity: One, help: "One-sided error (default 0.05)"),
    OptionSpec(name: "power", arity: One, help: "Power (default 0.8)"),
    OptionSpec(name: "upset-games", arity: One, help: "Games against random, any loss a fault (default 10)"),
    OptionSpec(name: "maps", arity: Many, help: "Maps (default: the bundled, community, generated and kept maps)"),
    OptionSpec(name: "seed-start", arity: One, help: "First seed index; a confirmation run uses seeds it never played")]

proc planArguments*(line: CommandLine): PlanArguments =
  result.opponents = line.all("opponents")
  result.baseline = line.last("baseline")
  let effect = line.number("effect-elo", 0)
  if effect != 0: result.effectElo = some(effect)
  if line.given("margin"): result.margin = some(line.number("margin", MarginElo))
  result.alpha = line.number("alpha", Alpha)
  result.power = line.number("power", Power)
  result.upsetGames = line.integer("upset-games", UpsetGames)
  for path in line.all("maps"): result.maps.add(if path.isAbsolute: path else: Root / path)
  result.seedStart = line.integer("seed-start", 0)

proc writeReport(output, candidate: string, report: JsonNode) =
  writeFile(resultDirectory(output, candidate) / "results.json", pythonDumps(report, indent = 2) & "\n")

proc batch*(argv: seq[string]): int =
  let line = parseCommandLine(argv, Usage, @[
    OptionSpec(name: "bots", arity: Many, help: "Candidates: trial paths (assets/trials/NAME) or names under bots/"),
    OptionSpec(name: "output", arity: One, help: "The batch's directory"),
    OptionSpec(name: "workers", arity: One, help: "Local games at once"),
    OptionSpec(name: "in-flight", arity: One, help: "Games playing at once (default 32); a sequential run stops soon after its tests decide")] &
    planOptions() & runnerOptions())
  if not line.given("bots") or not line.given("output"): line.fail "--bots and --output are required"
  let output = resolved(line.last("output"))
  createDir(output)
  let place = line.placement
  let workers = line.integer("workers", cpuWorkers())
  let inFlight = line.integer("in-flight", InFlight)
  let arguments = line.planArguments
  var candidates: seq[string]
  for name in line.all("bots"):
    let directory = botDirectory(name)
    if not (fileExists(directory / "bot.toml") or fileExists(directory / "strategy.nim")):
      line.fail "Not a bot: " & directory
    candidates.add botName(directory)
  # Every candidate's schedule, its games and their positions.
  var plans, reports: OrderedTable[string, JsonNode]
  var orders: Table[string, seq[ScheduleEntry]]
  var played: Table[string, Table[int, JsonNode]]
  var games: seq[Game]
  var where: seq[(string, int)]
  var indexOf: Table[(string, int), int]
  for candidate in candidates:
    let run = plan(arguments, candidate)
    plans[candidate] = run
    let directory = resultDirectory(output, candidate)
    createDir(directory)
    let path = directory / "results.json"
    let previous = if fileExists(path): parseFile(path) else: newJObject()
    if previous.hasKey("plan") and not sameFields(previous["plan"], run):
      line.fail path & " holds another plan; use a new --output"
    # Collecting keeps errored games as recorded; a resume plays them again.
    played[candidate] = initTable[int, JsonNode]()
    var kept = newJArray()
    for game in previous{"games"}.getElems:
      if place.collectOnly or game["status"].getStr == "completed":
        played[candidate][game["position"].getInt] = game
        kept.add game
    reports[candidate] = %*{"status": "running", "plan": run, "games": kept}
    orders[candidate] = schedule(run)
    for position, entry in orders[candidate]:
      let (a, b) = teams(entry)
      let stem = (align($position, 4, '0') & "-" & a & "-vs-" & b & "-" &
                  entry.map.splitFile.name).replace("/", "--")
      if position notin played[candidate]: forgetGame(directory, stem & ".log")
      indexOf[(candidate, position)] = games.len
      games.add Game(directory: directory, stem: stem, mapPath: Root / entry.map,
                     seed: some(entry.seed), a: a, b: b, engine: "judge")
      where.add (candidate, position)
  # Only bots with games still to play need registered builds; games an
  # earlier fleet run returned are collected under the builds it recorded.
  if not place.collectOnly:
    var directories: seq[string]
    for name in botsToPlay(games, output / "fleet"): directories.add botDirectory(name)
    prepareBots(directories, workers, registeredOnly = true)
  proc choose(landed: Table[int, JsonNode], running: HashSet[int]): seq[int] =
    # Each candidate's wanted games, taken in turn so none waits for another.
    var queues: seq[seq[int]]
    for candidate, run in plans:
      var done = played[candidate]
      var flying = initHashSet[int]()
      for index, record in landed:
        if where[index][0] == candidate: done[where[index][1]] = record
      for index in running:
        if where[index][0] == candidate: flying.incl where[index][1]
      var queue: seq[int]
      for position in wanted(run, done, flying, orders[candidate]): queue.add indexOf[(candidate, position)]
      queues.add queue
    var turn = 0
    while true:
      var any = false
      for queue in queues:
        if turn < queue.len:
          result.add queue[turn]
          any = true
      if not any: break
      inc turn
  proc landed(index: int, record: JsonNode) =
    let (candidate, position) = where[index]
    var positioned = record.copy
    positioned["position"] = %position
    if record["status"].getStr == "completed": played[candidate][position] = positioned
    let report = reports[candidate]
    var games = newJArray()
    for game in report["games"]:
      if game["position"].getInt != position: games.add game
    games.add positioned
    report["games"] = games
    writeReport(output, candidate, report)
  var vcpus = fleetAllowance(place, games)
  if vcpus > 0: vcpus = min(vcpus, inFlight)
  let wherePlayed = if vcpus > 0: "the fleet (" & $vcpus & " vCPUs)" else: "this host"
  for candidate, run in plans:
    let measure =
      if run{"baseline"}.getStr.len > 0:
        "matched against " & run["baseline"].getStr & " over at most " & $(2 * run["cap"].getInt) & " fixtures each"
      else: "at most " & $run["cap"].getInt & " games against each"
    let question =
      if run.nonInferiority: "not worse by " & cFormat("%g", run["margin_elo"].getFloat) & " Elo"
      else: "better by +" & cFormat("%g", run["effect_elo"].getFloat) & " Elo"
    var opponents: seq[string]
    for opponent in run["opponents"]: opponents.add opponent.getStr
    echo candidate, ", testing ", question, ": ", measure, " of ", opponents.join(", "), ", and ",
      run["upset_games"].getInt, " against random, on ", wherePlayed, ", ", inFlight, " at a time"
  discard playGames(games, place, workers, vcpus, output / "fleet", landed, choose, inFlight)
  let still = choose(initTable[int, JsonNode](), initHashSet[int]())
  for candidate, report in reports:
    # Incomplete: a deadline or an interruption left games the tests want.
    var incomplete = false
    for index in still: incomplete = incomplete or where[index][0] == candidate
    report["status"] = %(if incomplete: "incomplete" else: "completed")
    writeReport(output, candidate, report)
  echo "Judge each candidate with:"
  for name in candidates: echo "  just verdict --candidate ", name, " --output ", output
  0
