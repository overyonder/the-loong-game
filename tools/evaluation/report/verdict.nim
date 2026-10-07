## Judge a sequential run: each opponent's test, upset faults, Brain activation
## where the activation stage has recorded it, and cost, written as `verdict.md`
## and `verdict.json` beside its results.
##
## The run's plan and schedule are tools/evaluation/sequential.nim's, which
## documents the tests. Each opponent gets Wald's sequential probability ratio
## test of a 50% score against the effect's score ("better"), or of the margin's
## score against 50% for non-inferiority ("not worse"), over the longest
## completed prefix of the schedule. Each game's record names its schedule position, so
## the verdict walks the plan's schedule and reads each position's player,
## side and fixture from it.

import std/[algorithm, json, math, options, os, osproc, sequtils, strutils, tables]
import records, summary
import ../[bots, sequential]

proc summaryOf(test: Sprt): Decision =
  Decision(decision: test.decision, llr: round4(test.llr), lower: round4(test.lower),
    upper: round4(test.upper), games: test.games, cap: test.cap, decidedAt: test.decidedAt)

proc toJson(test: Decision): JsonNode =
  %*{"decision": test.decision, "llr": test.llr, "lower": test.lower, "upper": test.upper,
     "games": test.games,
     "decided_at": (if test.decidedAt.isSome: %test.decidedAt.get else: newJNull()),
     "cap": test.cap}

proc gFormat(value: float): string = cFormat("%g", value)

proc verdict*(root, candidateArgument, outputArgument: string): int =
  let name = botName(botDirectory(candidateArgument))
  let output = outputArgument.absolutePath.normalizedPath
  let directory = resultDirectory(output, name)
  let path = directory / "results.json"
  if not fileExists(path):
    quit(path & " is missing: `just batch --bots " & name & "` plays it", 2)
  let results = parseFile(path)
  let plan = results["plan"]
  var played: Table[int, JsonNode]
  for entry in results["games"]: played[entry["position"].getInt] = entry
  var state = judge(plan, played, schedule(plan))
  var tests: OrderedTable[string, Decision]
  for opponent, test in state.tests: tests[opponent] = test.summaryOf
  # The games each test used, up to where it stopped.
  let usedGames = state.used.mapIt(setGame(directory, played[it]))
  let usedIds = usedGames.mapIt(it.gameId)
  let games = loadGames(@[directory]).filterIt(it.gameId in usedIds)

  # The runner, so a result traces back to commits.
  var tools = execCmdEx("git rev-parse HEAD", workingDir = root).output.strip
  if execCmdEx("git diff --quiet HEAD -- tools", workingDir = root).exitCode != 0:
    tools &= " with uncommitted tools/ changes"
  let baseline = plan{"baseline"}.getStr
  let opponents = plan["opponents"].mapIt(it.getStr)
  # With a baseline every opponent's matched test decides; otherwise the first
  # opponent, the champion, does.
  let decisions = toSeq(tests.values).mapIt(it.decision)
  let (accepted, rejected) = (state.tests[opponents[0]].accepted, state.tests[opponents[0]].rejected)
  let result0 =
    if baseline.len == 0: tests[opponents[0]].decision
    elif accepted in decisions and rejected notin decisions: accepted
    elif rejected in decisions: rejected
    else: decisions[0]
  let judged = if baseline.len > 0: "matched against `" & baseline & "`"
               else: "against `" & opponents[0] & "`"
  let question =
    if plan.nonInferiority:
      "Non-inferiority, planned by power: a " &
        cFormat("%.1f", winRate(-plan["margin_elo"].getFloat) * 100) & "% score (" &
        gFormat(plan["margin_elo"].getFloat) & " Elo worse) against an even one"
    else: "Planned by power: +" & gFormat(plan["effect_elo"].getFloat) & " Elo to detect"
  var context = question & ", α " & gFormat(plan["alpha"].getFloat) & ", power " &
    cFormat("%.0f", plan["power"].getFloat * 100) & "%, at most " & $plan["cap"].getInt & " " &
    (if baseline.len > 0: "discordant fixtures" else: "games") &
    " per opponent; each sequential probability ratio test reads the " &
    "interleaved schedule through position " & $state.prefix & ", past the positions a " &
    "decided test no longer plays; " & $state.used.len & " of " & $results["games"].len &
    " played games used. Tools at `" & tools & "`. "
  if state.failures.len > 0:
    var failed: seq[string]
    for opponent, count in state.failures: failed.add opponent & " " & $count
    context &= "Games against " & failed.join(", ") & " errored because a bot failed: " &
      "they count no score and the tests read on past them. "
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
    paths: @[directory], candidates: @[name] & (if baseline.len > 0: @[baseline] else: @[]),
    context: context)
  for opponent, test in tests: report.decisions[(name, opponent)] = test
  var lines = @[render(report, root).strip(leading = false, chars = {'\n'}), "",
    "## Upsets and behaviour", "",
    "Upset check: " & $state.upsets & " of " & $plan["upset_games"].getInt &
    " games against random played, " & $state.faults.len & " not won."]
  var faults = newJArray()
  for (_, fault) in state.faults:
    faults.add fault
    let (a, b) = (botDirectory(fault["A"].getStr), botDirectory(fault["B"].getStr))
    let map = fault["map"].getStr
    lines.add "- " & map.extractFilename & ", seed " & $fault{"seed"} & ": " & fault["status"].getStr &
      ", winner " & fault{"winner_side"}.getStr("none") & "; watch with `just watch " &
      a.relativePath(root) & " " & b.relativePath(root) & " " & map.relativePath(root) & " " &
      $fault{"seed"} & "`"
  # Behaviour comes from the activation stage's records, leaves only.
  var shares: OrderedTable[string, int]
  var traced, tracedGames = 0
  for game in usedGames:
    let activation = recordedActivation(directory, game, name).filterIt(it.turns > 0)
    for trace in activation:
      traced += trace.turns
      let leaves = if trace.leaves.len > 0: trace.leaves else: trace.active.mapIt(it.node)
      for (node, count) in trace.active:
        if node in leaves: shares[node] = shares.getOrDefault(node) + count
    if activation.len > 0: inc tracedGames
  var ranked = toSeq(shares.pairs)
  ranked.sort(proc (x, y: (string, int)): int = cmp(y[1], x[1]))
  # Runners only play; activation is its own stage over the stored replays.
  if traced == 0:
    lines.add ["", "Brain activation: not recorded for these games. Run `just activation --bot " &
      name & " " & directory.relativePath(root) & "` for it, then this verdict again."]
  else:
    lines.add ["", "Brain activation over " & $traced & " traced turns of " & name & " in " &
      $tracedGames & " of " & $usedGames.len & " games (" &
      cFormat("%.0f", (if usedGames.len > 0: tracedGames / usedGames.len else: 0.0) * 100) & "%). " &
      "Share of turns each leaf behaviour was chosen:", "",
      "| Behaviour | Share of turns |", "| --- | ---: |"]
    for (node, count) in ranked:
      lines.add "| " & node & " | " & cFormat("%.1f", count / traced * 100) & "% |"
  var testsJson, traces = newJObject()
  for opponent, test in tests: testsJson[opponent] = test.toJson
  for opponent, test in state.tests: traces[opponent] = %test.trace
  let record = %*{"verdict": result0, "plan": plan, "tests": testsJson,
    "schedule_read": state.prefix, "games_used": state.used.len, "played": results["games"].len, "upsets": state.upsets,
    "faults": faults, "candidate_origin": (let origin = trialOrigin(botDirectory(name)); if origin.len > 0: %origin else: newJNull()),
    "tools_commit": tools, "traced_turns": traced, "traced_games": tracedGames,
    "traces": traces}
  writeFile(directory / "verdict.json", record.pretty(2) & "\n")
  writeFile(directory / "verdict.md", lines.join("\n") & "\n")
  echo lines.join("\n")
  if result0 == accepted and state.faults.len == 0: 0 else: 1
