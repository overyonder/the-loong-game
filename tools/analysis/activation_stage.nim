## `just activation`: how many turns each Brain node was active in a result
## set's games. `loong-audit activation` (audit/activation.nim) replays each
## traced dragon's recorded observations through its registered build, marked
## for inspection, on the judge, and writes the game's `activation` columns
## (tools/gamedata/format.md) beside its log as `<stem>.activation.cols`; it
## documents what counts as active, a mismatch and a leaf. This stage runs it
## over a result set and reads the records back. It is its own stage: runners
## only play. A game whose replay the store doesn't hold is regenerated from its
## record first (`replay` in tools/evaluation/regenerate.nim). Run it on demand,
## here for a sample or as a fleet script job (`just fleet script`) for a large
## set.
##
##     just activation --bot expert/0001 results/local/compare/<run>/<set>/seed-0

import std/[algorithm, json, os, osproc, posix, strutils, tables]
import ../evaluation/[arguments, bots, paths, processes, python_math, regenerate]
import ../gamedata/columns
import ../judge/harness

type Trace* = object
  ## One side's record: its traced turns, the turns after a divergence, and
  ## the turns each node was active, in the record's node order.
  turns*, mismatches*: int
  active*:             seq[(string, int)]
  leaves*:             seq[string]    # the nodes no other node names as parent

proc readActivation*(path: string): (string, OrderedTable[string, Trace]) =
  ## The record `loong-audit activation` stored: its error, or each side's trace.
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  let error = file.stringRow("meta.error", 0)
  if error.len > 0: return (error, initOrderedTable[string, Trace]())
  var sides: seq[string]
  var traces = initOrderedTable[string, Trace]()
  for row in 0 ..< file.rowCount("side.team"):
    let side = $"AB"[int(file.numberAt("side.team", row))]
    sides.add side
    traces[side] = Trace(turns: int(file.numberAt("side.turns", row)),
                         mismatches: int(file.numberAt("side.mismatches", row)))
  for row in 0 ..< file.rowCount("node.name"):
    let side = sides[int(file.numberAt("node.side", row))]
    let name = file.stringRow("node.name", row)
    traces[side].active.add (name, int(file.numberAt("node.active", row)))
    if file.numberAt("node.leaf", row) != 0: traces[side].leaves.add name
  ("", traces)

proc activationPath(directory: string, game: JsonNode): string =
  besideLog(directory, game["log"].getStr, ".activation.cols")

proc traceGame*(directory, stem, sides, target: string) =
  ## Regenerate a game's replay if the store lacks it and write its
  ## `activation` columns with loong-audit, naming each side's registered
  ## build from the game's record, since builds announce none in play.
  let record = findRecord(directory, stem)
  let replayPath = resolved(replay(directory, stem))
  let named = builds(directory, record)
  var audit = Root / "build/bin/loong-audit"
  if not fileExists(audit): audit = Root / "bin/loong-audit"   # a fleet worker's bundle
  if not fileExists(Judge): raise newException(IOError, Judge & " is missing: run just zig-judge-build")
  var command = @["activation", replayPath, target, "--sides", sides, "--registry", Registry, "--judge", Judge]
  for side, guid in named: command.add ["--build", side, guid.getStr]
  let process = startProcess(audit, args = command, options = {poParentStreams})
  defer: process.close()
  let code = process.waitForExit()
  if code != 0: raise newException(IOError, "loong-audit activation failed for " & stem & ": exit " & $code)

proc activations*(directory, bot: string, workers: int): OrderedTable[string, Trace] =
  ## (map, side, seed) -> Brain activation of `bot` in each game of a result set.
  let report = parseFile(directory / "results.json")
  var found = initOrderedTable[string, (string, OrderedTable[string, Trace])]()
  var keys = initTable[string, seq[(string, string)]]()
  var tasks: seq[(JsonNode, string, string)]
  for game in report["games"]:
    var sides = ""
    for side in ["A", "B"]:
      if game[side].getStr == bot: sides.add side
    if sides.len == 0: continue
    # A record an earlier run wrote needs no replay; the replay is needed only
    # to trace here.
    let target = activationPath(directory, game)
    var sideKeys: seq[(string, string)]
    for side in sides:
      sideKeys.add ($side, [game["map"].getStr.extractFilename, $side, $game{"seed"}].join("\t"))
    keys[target] = sideKeys
    if fileExists(target):
      found[target] = readActivation(target)
      continue
    if game["status"].getStr != "completed": continue
    # A fleet run keeps only a sample of replays; the rest regenerate from
    # their records and registered builds.
    tasks.add (game, sides, target)
  var children: seq[Child]
  var next = 0
  var traced = newSeq[bool](tasks.len)
  while next < tasks.len or children.len > 0:
    while next < tasks.len and children.len < max(1, workers):
      let (game, sides, target) = tasks[next]
      var stem = game["log"].getStr.extractFilename
      stem.removeSuffix(".log")
      children.add spawnChild(@[getAppFilename(), "trace-activation", directory, stem, sides, target], next, cwd = Root)
      inc next
    let (index, code, _) = waitAnyChild(children)
    if code == 0: traced[index] = true
    elif code != 3: raise newException(IOError, "tracing failed: exit " & $code)
  for index, task in tasks:
    if traced[index]: found[task[2]] = readActivation(task[2])
  for target, (error, traces) in found:
    if error.len > 0: continue
    for (side, key) in keys[target]:
      if side in traces and traces[side].turns > 0: result[key] = traces[side]

proc activationCommand*(argv: seq[string]): int =
  let line = parseCommandLine(argv, "usage: just activation --bot BOT DIRECTORY... [--workers N]", @[
    OptionSpec(name: "bot", arity: One, help: "Our Nim bot whose sides to trace, as under bots/"),
    OptionSpec(name: "workers", arity: One, help: "Parallel processes")])
  if not line.given("bot"): line.fail "--bot is required"
  if line.positional.len == 0: line.fail "give the result directories from a runner"
  var total = initOrderedTable[string, int]()
  var (turns, mismatches) = (0, 0)
  for directory in line.positional:
    for trace in activations(directory, line.last("bot"), line.integer("workers", cpuWorkers())).values:
      for (name, count) in trace.active: total[name] = total.getOrDefault(name, 0) + count
      turns += trace.turns
      mismatches += trace.mismatches
  echo turns, " turns traced, ", mismatches, " unreliable after a divergence"
  var order: seq[(int, int, string)]
  var position = 0
  for name, count in total:
    order.add (-count, position, name)
    inc position
  order.sort
  for (negative, _, name) in order:
    let count = -negative
    echo alignLeft(name, 16), " ", align($count, 8), " ",
      align(pythonFixed(float(count) / float(max(turns, 1)) * 100, 1) & "%", 7)
  0

proc traceActivationCommand*(argv: seq[string]): int =
  ## One game, for `activations`' own children: exit 3 when it can't be
  ## regenerated, which leaves it untraced rather than failing the stage.
  discard dup2(2, 1)   # the audit's output goes to the terminal, not the parent's pipe
  try:
    traceGame(argv[0], argv[1], argv[2], argv[3])
    0
  except ValueError as error:
    stderr.writeLine argv[1], ": not traced: ", error.msg
    3

proc smokeCommand*(argv: seq[string]): int =
  ## Judge the smoke games `just check-head` plays and traces: the bot
  ## survives both games against random, `just activation` traced them, and
  ## no leaf behaviour holds more than 90% of its turns.
  let (bot, directory) = (argv[0], argv[1])
  var failures: seq[string]
  let report = parseFile(directory / "results.json")
  for game in report["games"]:
    let side = if game["A"].getStr == bot: "A" else: "B"
    let label = game["map"].getStr.splitFile.name & " as " & side
    if game["status"].getStr != "completed":
      failures.add label & ": " & (if game{"error"}.kind == JString: game["error"].getStr else: "None")
    elif game{"winner_side"}.kind != JNull and game["winner_side"].getStr notin [side, game[side].getStr]:
      let rounds = if game{"rounds"}.kind == JInt: $game["rounds"].getInt else: "None"
      failures.add label & ": lost to random " & game{"reason"}.getStr("None") & " in " & rounds
  var turns = 0
  var active = initOrderedTable[string, int]()
  var leaves: seq[string]
  for trace in activations(directory, bot, 2).values:
    turns += trace.turns
    for leaf in trace.leaves:
      if leaf notin leaves: leaves.add leaf
    for (node, count) in trace.active: active[node] = active.getOrDefault(node, 0) + count
  for game in report["games"]:
    let record = activationPath(directory, game)
    if fileExists(record):
      let (error, _) = readActivation(record)
      if error.len > 0: failures.add "tracing " & record.extractFilename & ": " & error
  if turns == 0: failures.add "no turns traced, so behaviour shares are unknown"
  # Parents such as the role node are active whenever a child is; judge leaves.
  var order: seq[(int, int, string)]
  var position = 0
  for node, count in active:
    order.add (-count, position, node)
    inc position
  order.sort
  for (negative, _, node) in order:
    let count = -negative
    if node in leaves and turns > 0 and count / turns > 0.9:
      failures.add node & " active on " & pythonFixed(count / turns * 100, 0) & "% of " & $turns & " turns"
  for failure in failures: echo "FAILED  smoke: ", failure
  if failures.len == 0: echo "ok      smoke: 2 games against random, ", turns, " turns traced"
  ord(failures.len > 0)
