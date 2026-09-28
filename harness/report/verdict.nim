## Judge a sequential run: each opponent's test and upset faults, written as
## `verdict.md` and `verdict.json` beside its results.
##
## The run's plan and schedule are harness/compare.py's, which
## documents the tests. Each opponent gets Wald's sequential probability ratio
## test of a 50% score against the effect's score, over the longest completed
## prefix of the schedule. Each game's record names its schedule position, so
## the verdict reads the tests from the records without rebuilding the schedule.
## A game's player is the candidate when it plays, else the baseline, and its
## score is its side's. With a baseline each fixture is the schedule's positions
## 2k (the candidate) and 2k + 1 (the baseline), since every block the schedule
## appends has an even length; a baseline that is also an opponent plays its
## own game on the side the candidate played in that fixture.

import std/[json, math, options, os, osproc, sequtils, strutils, tables]
import records, summary

type
  Sprt* = object
    ## Wald's test of a 50% score against the effect's score, one opponent.
    win, loss, upper, lower: float
    cap, games:              int
    llr:                     float
    decidedAt*:              Option[int]
    trace:                   seq[float]

proc round4(value: float): float = parseFloat(cFormat("%.4f", value))

proc initSprt(plan: JsonNode): Sprt =
  let target = 1 / (1 + pow(10.0, -plan["effect_elo"].getFloat / 400))
  let (alpha, power) = (plan["alpha"].getFloat, plan["power"].getFloat)
  Sprt(win: ln(target / 0.5), loss: ln((1 - target) / 0.5), upper: ln(power / alpha),
    lower: ln((1 - power) / (1 - alpha)), cap: plan["cap"].getInt)

proc done(test: Sprt): bool = test.decidedAt.isSome or test.games >= test.cap

proc add(test: var Sprt, score: float) =
  ## Count one game; a decided or capped test takes no more.
  if test.done: return
  inc test.games
  test.llr += score * test.win + (1 - score) * test.loss
  test.trace.add round4(test.llr)
  if test.llr >= test.upper or test.llr <= test.lower: test.decidedAt = some(test.games)

proc decision*(test: Sprt): string =
  if test.decidedAt.isSome: (if test.llr >= test.upper: "better" else: "not better")
  elif test.games >= test.cap: "no material difference"
  else: "undecided"

proc summaryOf(test: Sprt): Decision =
  Decision(decision: test.decision, llr: round4(test.llr), lower: round4(test.lower),
    upper: round4(test.upper), games: test.games, cap: test.cap, decidedAt: test.decidedAt)

proc toJson(test: Decision): JsonNode =
  %*{"decision": test.decision, "llr": test.llr, "lower": test.lower, "upper": test.upper,
     "games": test.games,
     "decided_at": (if test.decidedAt.isSome: %test.decidedAt.get else: newJNull()),
     "cap": test.cap}

type Judgement* = object
  tests*:         OrderedTable[string, Sprt]
  used:           seq[int]
  ties*, fixtures*: OrderedTable[string, int]
  upsets:         int
  faults:         seq[Game]
  prefix:         int

proc score(game: Game, side: int): Option[float] =
  ## The score of the player on `side`: by side, not name, since a baseline
  ## that is also an opponent plays itself.
  if game.status != "completed": none(float)
  elif game.winner < 0: some(0.5)
  elif game.winner == side: some(1.0)
  else: some(0.0)

proc judge*(plan: JsonNode, played: Table[int, Game]): Judgement =
  ## Every opponent's test over the completed prefix of the schedule. An
  ## errored game ends the prefix like an unplayed one. Without a baseline,
  ## each of the candidate's games against an opponent counts its score. With
  ## one, each fixture both played counts once the second lands: 1 where the
  ## candidate scored more, 0 where the baseline did; a tie counts in `ties`.
  for opponent in plan["opponents"]:
    result.tests[opponent.getStr] = initSprt(plan)
    result.ties[opponent.getStr] = 0
    result.fixtures[opponent.getStr] = 0
  let candidate = plan["candidate"].getStr
  let baseline = plan{"baseline"}.getStr
  var pending: Table[int, tuple[player: string, score: float, position: int]]
  var position = 0
  while position in played:
    let game = played[position]
    let names = [game.a, game.b]
    let side =
      if candidate in names: names.find(candidate)
      elif names[0] != names[1]: names.find(baseline)
      else:
        # The baseline against itself, on the side its fixture's candidate took.
        max(0, [played[position - 1].a, played[position - 1].b].find(candidate))
    let player = names[side]
    let opponent = names[1 - side]
    let result0 = score(game, side)
    if result0.isNone: break
    let value = result0.get
    result.prefix = position + 1
    if opponent notin result.tests:
      inc result.upsets
      if value < 1: result.faults.add game
    elif baseline.len == 0:
      inc result.fixtures[opponent]
      if not result.tests[opponent].done: result.used.add position
      result.tests[opponent].add value
    else:
      let fixture = position div 2
      if fixture notin pending: pending[fixture] = (player, value, position)
      else:
        let (_, earlier, first) = pending[fixture]
        pending.del fixture
        let mine = if player == candidate: value else: earlier
        let theirs = if player == candidate: earlier else: value
        inc result.fixtures[opponent]
        if not result.tests[opponent].done:
          result.used.add [first, position]
          if mine == theirs: inc result.ties[opponent]
          else: result.tests[opponent].add(if mine > theirs: 1.0 else: 0.0)
    inc position

proc resultDirectory(output, candidate: string): string =
  ## A candidate's results in OUTPUT, by its directory's name, as `batch` puts it.
  output / candidate.strip(leading = false, chars = {'/'}).extractFilename

proc gFormat(value: float): string = cFormat("%g", value)

proc repositoryRoot(): string =
  ## The checkout the binary was built in, or LOONG_ROOT.
  getEnv("LOONG_ROOT", getAppDir().parentDir.parentDir)

proc verdict*(candidate, outputArgument: string): int =
  let output = outputArgument.absolutePath.normalizedPath
  let directory = resultDirectory(output, candidate)
  let path = directory / "results.json"
  if not fileExists(path):
    quit(path & " is missing: `just batch --bots " & candidate & "` plays it", 2)
  let results = parseFile(path)
  let plan = results["plan"]
  let name = plan["candidate"].getStr
  var played: Table[int, Game]
  for entry in results["games"]: played[entry["position"].getInt] = setGame(directory, entry)
  var state = judge(plan, played)
  var tests: OrderedTable[string, Decision]
  for opponent, test in state.tests: tests[opponent] = test.summaryOf
  # The games each test used, up to where it stopped.
  let usedIds = state.used.mapIt(played[it].gameId)
  let games = loadGames(@[directory]).filterIt(it.gameId in usedIds)

  # The tools' commit, so a result traces back to the code that judged it.
  let root = repositoryRoot()
  let (head, code) = execCmdEx("git rev-parse HEAD", workingDir = root)
  var tools = if code == 0: head.strip else: "a copy outside Git"
  if code == 0 and
      execCmdEx("git diff --quiet HEAD -- harness gamedata", workingDir = root).exitCode != 0:
    tools &= " with uncommitted harness or gamedata changes"
  let baseline = plan{"baseline"}.getStr
  let opponents = plan["opponents"].mapIt(it.getStr)
  # With a baseline every opponent's matched test decides; otherwise the first
  # opponent does.
  let decisions = toSeq(tests.values).mapIt(it.decision)
  let result0 =
    if baseline.len == 0: tests[opponents[0]].decision
    elif "better" in decisions and "not better" notin decisions: "better"
    elif "not better" in decisions: "not better"
    else: decisions[0]
  let judged = if baseline.len > 0: "matched against `" & baseline & "`"
               else: "against `" & opponents[0] & "`"
  var context = "Planned by power: +" & gFormat(plan["effect_elo"].getFloat) &
    " Elo to detect, α " & gFormat(plan["alpha"].getFloat) & ", power " &
    cFormat("%.0f", plan["power"].getFloat * 100) & "%, at most " & $plan["cap"].getInt & " " &
    (if baseline.len > 0: "discordant fixtures" else: "games") &
    " per opponent; each sequential probability ratio test reads the " &
    "interleaved schedule through position " & $state.prefix & ", past the positions a " &
    "decided test no longer plays; " & $state.used.len & " of " & $results["games"].len &
    " played games used. Tools at `" & tools & "`. "
  if baseline.len > 0:
    var ties: seq[string]
    for opponent, count in state.ties: ties.add opponent & ": " & $count & " ties"
    context &= "With a baseline, each fixture (map, seed, side, opponent) is played " &
      "by " & name & " and " & baseline & "; a fixture counts 1 when " & name & " scores " &
      "more and 0 when the baseline does, and ties carry no evidence (" & ties.join(", ") &
      "). Head to head, close versions of one line win by side, so " &
      "their direct games are not played for the decision. "
  context &= "Verdict " & judged & ": **" & result0 & "**."
  var report = Report(games: games, title: name & " against " & opponents.join(", "),
    candidates: @[name] & (if baseline.len > 0: @[baseline] else: @[]),
    context: context)
  for opponent, test in tests: report.decisions[(name, opponent)] = test
  var lines = @[render(report).strip(leading = false, chars = {'\n'}), "",
    "## Upsets", "",
    "Upset check: " & $state.upsets & " of " & $plan["upset_games"].getInt &
    " games against `" & plan["upset_bot"].getStr & "` played, " & $state.faults.len &
    " not won."]
  var faults = newJArray()
  for fault in state.faults:
    faults.add fault.record
    let replay = fault.record{"replay"}.getStr
    lines.add "- " & fault.map & ", seed " & $fault.seed & ": " & fault.status &
      ", winner " & fault.record{"winner_side"}.getStr("none") &
      (if replay.len > 0: "; watch with `just viewer " & (directory / replay) & "`" else: "")
  var testsJson, traces = newJObject()
  for opponent, test in tests: testsJson[opponent] = test.toJson
  for opponent, test in state.tests: traces[opponent] = %test.trace
  let record = %*{"verdict": result0, "plan": plan, "tests": testsJson,
    "schedule_read": state.prefix, "games_used": state.used.len, "played": results["games"].len, "upsets": state.upsets,
    "faults": faults, "tools_commit": tools, "traces": traces}
  writeFile(directory / "verdict.json", record.pretty(2) & "\n")
  writeFile(directory / "verdict.md", lines.join("\n") & "\n")
  echo lines.join("\n")
  if result0 == "better" and state.faults.len == 0: 0 else: 1
