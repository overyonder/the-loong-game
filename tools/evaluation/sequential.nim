## Decide whether a candidate is better than its opponents, sequentially.
##
## A run is planned by power (Kieran, 28 September). The effect to detect
## (default +70 Elo, a 60% score), the one-sided error α (0.05) and the power
## (80%) give each opponent's planned maximum: the games a fixed-size test at
## the same error rates would need, 155 at the defaults.
##
## Each opponent gets Wald's sequential probability ratio test of a 50% score
## against the effect's score, on the candidate's direct games scored 1, ½ or
## 0. After every game the log-likelihood ratio moves by ln(p/0.5) for a win
## and ln((1 − p)/0.5) for a loss, a draw by half of each. The test stops at
## ln((1 − β)/α) ("better") or ln(β/(1 − α)) ("not better"), where β = 1 −
## power. Straight wins decide in 16 games at the defaults. A test still
## undecided at the planned maximum reads "no material difference".
##
## `--margin M` asks the non-inferiority question instead: whether the
## candidate is no more than M Elo worse (70 when given without a value,
## "clearly worse" at the effect's bar). Each test is then Wald's test of the
## score of −M Elo against 50%, stopping at "not worse" or "worse", with the
## planned maximum from the same power formula. The plan records the form, so
## a resumed run can't mix the two.
##
## The schedule interleaves from the first game: each map, shuffled per seed,
## is played against every opponent as a side-swapped pair before the next
## map, so an early stop rests on many maps, both sides and every opponent.
## The test reads the longest completed prefix of that order, never arrival
## order, so games that finish quickly cannot decide a run by arriving first.
## Ten games against random, spread over the first maps, check for upsets: any
## loss is a fault to watch in the viewer.
##
## Opponents default to the champion (the latest frozen main line committed at
## HEAD and in the pool) and the released random baseline. Register additional
## opponents explicitly for a meaningful comparison.
##
## Close versions of one line win by side, not by strength, so a candidate
## from the champion's own line is judged by matched pairs instead: the
## champion becomes its baseline, both play every fixture (map, seed, side,
## opponent) against the configured common opponents,
## and each test counts only the fixtures the two play differently, 1 where
## the candidate scores more and 0 where the baseline does. Ties are counted
## and reported. The planned maximum then counts these discordant fixtures,
## with at most twice as many fixtures played.

import std/[algorithm, json, math, options, os, osproc, sets, strutils, tables]
import bots, paths, python_random, seeds

const
  ## Default public baseline. Pass explicit opponents for a stronger comparison.
  Bar* = "random"
  ## Default second baseline for matched pairs.
  Predecessor* = "random"
  RandomBot*   = "random"
  EffectElo*   = 70.0
  MarginElo*   = 70.0
  Alpha*       = 0.05
  Power*       = 0.8
  UpsetGames*  = 10

let Mainline = Root / "bots/expert"

proc defaultMaps*(): seq[string] =
  for folder in ["tools/evaluation/maps", "tools/evaluation/maps/community",
                 "tools/evaluation/maps/generated", "tools/evaluation/maps/kept"]:
    var found: seq[string]
    for path in walkFiles(Root / folder / "*.map"): found.add path
    found.sort(system.cmp)
    result.add found

proc champions*(): seq[string] =
  ## Frozen main-line versions a verdict may play, oldest first. Only copies
  ## committed at HEAD and listed in pool.toml count, so a freeze that is
  ## uncommitted or half done never changes what a verdict measures.
  let committed = execProcess("git", workingDir = Root, args = ["ls-files", "--", "bots/expert"],
                              options = {poUsePath}).splitWhitespace.toHashSet
  let pool = poolBots().toHashSet
  if not dirExists(Mainline) or versions(Mainline).len == 0: return
  for version in frozenVersions(development()):
    if botName(version) in pool and version.relativePath(Root) & "/strategy.nim" in committed:
      result.add version

proc lineOf(name: string): string =
  ## The bot line a bot belongs to: a trial's source, or a frozen copy's line.
  let directory = botDirectory(name)
  if fileExists(directory / "trial.json"): return parseFile(directory / "trial.json")["source"].getStr
  let relative = resolved(directory).relativePath(Root)
  # A frozen copy's two-digit suffix names its line.
  if relative.len > 3 and relative[^3] == '_' and relative[^2 .. ^1].allCharsInSet(Digits):
    relative[0 ..< ^3]
  else: relative

proc defaultOpponents*(candidate: string): (string, seq[string]) =
  ## A run's baseline ("" for none) and opponents when none are named. A
  ## candidate from the champion's own line is judged by matched pairs against
  ## the champion over the common opponents Bar and Predecessor; any other
  ## candidate plays the champion and Bar directly.
  let versions = champions()
  let champion = if versions.len > 0: botName(versions[^1]) else: ""
  if champion.len > 0 and lineOf(candidate) == lineOf(champion):
    return (champion, @[Bar, Predecessor])
  result[1] = if champion.len > 0 and champion != Bar: @[champion, Bar] else: @[Bar]

proc winRate*(edge: float): float =
  ## The expected score of an Elo edge.
  1 / (1 + pow(10.0, -edge / 400))

proc nonInferiority*(plan: JsonNode): bool =
  plan{"margin_elo"} != nil and plan["margin_elo"].kind != JNull

proc hypotheses*(plan: JsonNode): (float, float) =
  ## The scores the plan's test separates, (null, alternative): 50% against
  ## the effect's score, or the margin's score against 50% for non-inferiority.
  if plan.nonInferiority: (winRate(-plan["margin_elo"].getFloat), 0.5)
  else: (0.5, winRate(plan["effect_elo"].getFloat))

proc normalQuantile(p: float): float =
  ## The standard normal distribution's inverse CDF, Wichura's AS241, as
  ## CPython's `statistics.NormalDist().inv_cdf` computes it.
  let q = p - 0.5
  if abs(q) <= 0.425:
    let r = 0.180625 - q * q
    let num = (((((((2.5090809287301226727e+3 * r + 3.3430575583588128105e+4) * r +
      6.7265770927008700853e+4) * r + 4.5921953931549871457e+4) * r +
      1.3731693765509461125e+4) * r + 1.9715909503065514427e+3) * r +
      1.3314166789178437745e+2) * r + 3.3871328727963666080e+0) * q
    let den = (((((((5.2264952788528545610e+3 * r + 2.8729085735721942674e+4) * r +
      3.9307895800092710610e+4) * r + 2.1213794301586595867e+4) * r +
      5.3941960214247511077e+3) * r + 6.8718700749205790830e+2) * r +
      4.2313330701600911252e+1) * r + 1.0)
    return num / den
  var r = if q <= 0.0: p else: 1.0 - p
  r = sqrt(-ln(r))
  var num, den: float
  if r <= 5.0:
    r = r - 1.6
    num = (((((((7.74545014278341407640e-4 * r + 2.27238449892691845833e-2) * r +
      2.41780725177450611770e-1) * r + 1.27045825245236838258e+0) * r +
      3.64784832476320460504e+0) * r + 5.76949722146069140550e+0) * r +
      4.63033784615654529590e+0) * r + 1.42343711074968357734e+0)
    den = (((((((1.05075007164441684324e-9 * r + 5.47593808499534494600e-4) * r +
      1.51986665636164571966e-2) * r + 1.48103976427480074590e-1) * r +
      6.89767334985100004550e-1) * r + 1.67638483018380384940e+0) * r +
      2.05319162663775882187e+0) * r + 1.0)
  else:
    r = r - 5.0
    num = (((((((2.01033439929228813265e-7 * r + 2.71155556874348757815e-5) * r +
      1.24266094738807843860e-3) * r + 2.65321895265761230930e-2) * r +
      2.96560571828504891230e-1) * r + 1.78482653991729133580e+0) * r +
      5.46378491116411436990e+0) * r + 6.65790464350110377720e+0)
    den = (((((((2.04426310338993978564e-15 * r + 1.42151175831644588870e-7) * r +
      1.84631831751005468180e-5) * r + 7.86869131145613259100e-4) * r +
      1.48753612908506148525e-2) * r + 1.36929880922735805310e-1) * r +
      5.99832206555887937690e-1) * r + 1.0)
  result = num / den
  if q < 0.0: result = -result

proc plannedGames*(null, alternative, alpha, power: float): int =
  ## Games a fixed-size one-sided test needs to tell `alternative` from
  ## `null`: the sequential test's planned maximum per opponent.
  let spread = normalQuantile(1 - alpha) * sqrt(null * (1 - null)) +
    normalQuantile(power) * sqrt(alternative * (1 - alternative))
  int(ceil(pow(spread / (alternative - null), 2)))

type PlanArguments* = object
  ## The options that fix a sequential run's plan; the runner records them.
  opponents*: seq[string]       ## empty for the default
  baseline*:  string            ## "" for the default, "none" for none
  effectElo*: Option[float]
  margin*:    Option[float]
  alpha*:     float
  power*:     float
  upsetGames*: int
  maps*:      seq[string]       ## empty for the default
  seedStart*: int

proc plan*(arguments: PlanArguments, candidate: string): JsonNode =
  ## A run's plan, as the runner records it.
  var maps: seq[string]
  for path in (if arguments.maps.len > 0: arguments.maps else: defaultMaps()):
    maps.add resolved(path).relativePath(Root)
  var (baseline, opponents) = defaultOpponents(candidate)
  if arguments.baseline.len > 0:
    baseline = if arguments.baseline == "none": "" else: arguments.baseline
  if baseline.len > 0: baseline = botName(botDirectory(baseline))
  if arguments.margin.isSome and arguments.effectElo.isSome:
    raise newException(ValueError, "--margin and --effect-elo ask different questions; give one")
  result = %*{"candidate": candidate, "baseline": if baseline.len > 0: %baseline else: newJNull(),
              "opponents": if arguments.opponents.len > 0: arguments.opponents else: opponents}
  # The form is recorded by its key, so a plan from before margins still resumes.
  if arguments.margin.isSome: result["margin_elo"] = %arguments.margin.get
  else: result["effect_elo"] = %arguments.effectElo.get(EffectElo)
  result["alpha"] = %arguments.alpha
  result["power"] = %arguments.power
  let (null, alternative) = hypotheses(result)
  result["cap"] = %plannedGames(null, alternative, arguments.alpha, arguments.power)
  result["upset_games"] = %arguments.upsetGames
  result["maps"] = %maps
  result["seed_start"] = %arguments.seedStart

type Sprt* = object
  ## Wald's test of the plan's null score against its alternative, one
  ## opponent: "better" than 50%, or "not worse" than the margin.
  win, loss, upper*, lower*: float
  accepted*, rejected*:      string
  cap*, games*:              int
  llr*:                      float
  decidedAt*:                Option[int]
  trace*:                    seq[float]

proc round4*(value: float): float =
  ## Python's `round(value, 4)`: the nearest value with four decimals.
  parseFloat(formatFloat(value, ffDecimal, 4))

proc initSprt*(plan: JsonNode): Sprt =
  let (null, alternative) = hypotheses(plan)
  let (alpha, power) = (plan["alpha"].getFloat, plan["power"].getFloat)
  let (accepted, rejected) = if plan.nonInferiority: ("not worse", "worse") else: ("better", "not better")
  Sprt(win: ln(alternative / null), loss: ln((1 - alternative) / (1 - null)),
    upper: ln(power / alpha), lower: ln((1 - power) / (1 - alpha)),
    cap: plannedGames(null, alternative, alpha, power), accepted: accepted, rejected: rejected)

proc done*(test: Sprt): bool = test.decidedAt.isSome or test.games >= test.cap

proc add*(test: var Sprt, score: float) =
  ## Count one game; a decided or capped test takes no more.
  if test.done: return
  inc test.games
  test.llr += score * test.win + (1 - score) * test.loss
  test.trace.add round4(test.llr)
  if test.llr >= test.upper or test.llr <= test.lower: test.decidedAt = some(test.games)

proc decision*(test: Sprt): string =
  if test.decidedAt.isSome: (if test.llr >= test.upper: test.accepted else: test.rejected)
  elif test.games >= test.cap: "no material difference"
  else: "undecided"

type ScheduleEntry* = object
  ## One position of the interleaved schedule.
  opponent*, player*, map*: string   ## `map` relative to the repository root
  seed*:     int64
  side*:     int                     ## 0 A, 1 B: the side `player` plays
  fixture*:  int

proc schedule*(plan: JsonNode): seq[ScheduleEntry] =
  ## The interleaved order a sequential run plays. Per seed index, maps are
  ## shuffled (seeded by the index, so the order is reproducible); each map is
  ## played against every opponent that still needs games as a side-swapped
  ## pair, and the first maps also carry the random upset pairs. With a
  ## baseline, each side of the pair is a fixture both the candidate and the
  ## baseline play, back to back. An opponent is scheduled up to its planned
  ## maximum of fixtures, twice that with a baseline, since only fixtures the
  ## two play differently count.
  var maps: seq[string]
  for name in plan["maps"]: maps.add name.getStr
  var opponents: seq[string]
  for name in plan["opponents"]: opponents.add name.getStr
  let baseline = plan{"baseline"}.getStr
  let players = @[plan["candidate"].getStr] & (if baseline.len > 0: @[baseline] else: @[])
  let fixtures = plan["cap"].getInt * (if baseline.len > 0: 2 else: 1)
  var needed = initOrderedTable[string, int]()
  for opponent in opponents: needed[opponent] = fixtures + fixtures mod 2
  # A run that tests random directly needs no separate upset check.
  let upsetGames = plan["upset_games"].getInt
  var upsets = if RandomBot in opponents: 0 else: upsetGames + upsetGames mod 2
  proc anyNeeded(): bool =
    for count in needed.values:
      if count != 0: return true
  var (index, fixture) = (plan["seed_start"].getInt, 0)
  while anyNeeded() or upsets != 0:
    # Sorted as Python sorts the maps' absolute paths.
    var shuffled = maps
    shuffled.sort(proc (a, b: string): int = pathCompare(a, b))
    var generator = initPythonRandom(index)
    generator.shuffle(shuffled)
    for path in shuffled:
      let seed = gameSeed(path.extractFilename, index)
      var pairs: seq[string]
      for opponent in opponents:
        if needed[opponent] != 0: pairs.add opponent
      if upsets != 0: pairs.add RandomBot
      for opponent in pairs:
        let upset = opponent == RandomBot and opponent notin needed
        for side in 0 .. 1:
          for player in (if upset: players[0 .. 0] else: players):
            result.add ScheduleEntry(opponent: opponent, map: path, seed: seed, side: side,
                                     player: player, fixture: fixture)
          inc fixture
        if upset: upsets -= 2
        else: needed[opponent] -= 2
      if not anyNeeded() and upsets == 0: break
    inc index

proc teams*(entry: ScheduleEntry): (string, string) =
  ## (side A, side B) of a scheduled game.
  if entry.side == 0: (entry.player, entry.opponent) else: (entry.opponent, entry.player)

proc score(game: JsonNode, side: int): Option[float] =
  ## The score of the player on `side` of a game: 1, ½ or 0; none if it
  ## errored. By side, not name: with the baseline also an opponent, the
  ## baseline's own games have it on both sides.
  if game["status"].getStr != "completed": return none(float)
  let winner = game{"winner_side"}
  if winner.isNil or winner.kind == JNull: return some(0.5)
  some(if winner.getStr == $"AB"[side]: 1.0 else: 0.0)

proc botFailed*(game: JsonNode): bool =
  ## A game that errored because a bot failed: kept out of the scores like
  ## every error, but the bot's own fault, which a rerun repeats, so a test
  ## passes over it rather than waiting for one.
  not game.isNil and game["status"].getStr == "error" and
    game{"error"}.getStr.startsWith("Bot execution failure")

type Judgement* = object
  tests*:     OrderedTable[string, Sprt]
  used*:      seq[int]
  ties*:      OrderedTable[string, int]
  fixtures*:  OrderedTable[string, int]
  upsets*:    int
  faults*:    seq[(int, JsonNode)]          ## position and record
  prefix*:    int
  failures*:  OrderedTable[string, int]     ## per opponent, games a bot's failure errored
  done*:      bool

proc judge*(plan: JsonNode, played: Table[int, JsonNode], order: seq[ScheduleEntry]): Judgement =
  ## Every opponent's test over the completed prefix of the schedule.
  ## `played` maps schedule positions to game records. An errored game ends
  ## the prefix like an unplayed one: the resumed run plays it again. One a
  ## bot's failure errored takes its place under the cap and counts no score,
  ## and the prefix runs on past it; against random it is a fault. Without a
  ## baseline, each of the candidate's games against an opponent counts its
  ## score. With one, each fixture both played counts once the second lands:
  ## 1 where the candidate scored more, 0 where the baseline did; a tie
  ## carries no evidence and counts in `ties`.
  for opponent in plan["opponents"]:
    result.tests[opponent.getStr] = initSprt(plan)
    result.ties[opponent.getStr] = 0
    result.fixtures[opponent.getStr] = 0
  let candidate = plan["candidate"].getStr
  let baseline = plan{"baseline"}.getStr
  let limit = plan["cap"].getInt * (if baseline.len > 0: 2 else: 1)
  var pending: Table[int, tuple[player: string, score: float, position: int]]
  var counted: Table[(string, string), int]
  for position, entry in order:
    let opponent = entry.opponent
    # A position `wanted` never starts (a decided opponent's, one past the
    # cap, or an upset game past the check's count) is skipped rather than
    # ending the prefix, so one test deciding doesn't freeze the others.
    let allowed =
      if opponent notin result.tests: plan["upset_games"].getInt
      elif result.tests[opponent].done: 0
      else: limit
    let key = (opponent, entry.player)
    if counted.getOrDefault(key) >= allowed: continue
    counted[key] = counted.getOrDefault(key) + 1
    let game = played.getOrDefault(position)
    if game.botFailed:
      result.prefix = position + 1
      result.failures[opponent] = result.failures.getOrDefault(opponent) + 1
      if opponent notin result.tests:
        inc result.upsets
        result.faults.add (position, game)
      continue
    let scored = if game.isNil: none(float) else: score(game, entry.side)
    if scored.isNone: break
    let value = scored.get
    result.prefix = position + 1
    if opponent notin result.tests:
      inc result.upsets
      if value < 1: result.faults.add (position, game)
    elif baseline.len == 0:
      inc result.fixtures[opponent]
      if not result.tests[opponent].done: result.used.add position
      result.tests[opponent].add value
    elif entry.fixture notin pending:
      pending[entry.fixture] = (entry.player, value, position)
    else:
      let (_, earlier, first) = pending[entry.fixture]
      pending.del entry.fixture
      let mine = if entry.player == candidate: value else: earlier
      let theirs = if entry.player == candidate: earlier else: value
      inc result.fixtures[opponent]
      if result.tests[opponent].done: continue
      result.used.add [first, position]
      if mine == theirs: inc result.ties[opponent]
      else: result.tests[opponent].add(if mine > theirs: 1.0 else: 0.0)
  var settled = true
  for opponent, test in result.tests:
    settled = settled and (test.done or result.fixtures[opponent] >= limit)
  result.done = settled and (RandomBot in result.tests or result.upsets >= plan["upset_games"].getInt)

proc wanted*(plan: JsonNode, played: Table[int, JsonNode], running: HashSet[int],
             order: seq[ScheduleEntry]): seq[int] =
  ## Schedule positions still worth starting, in order. An opponent whose
  ## test has decided, or whose fixtures reach the limit, gets no more; nor do
  ## the upset games once the check has enough. A game a bot's failure errored
  ## is settled, since a rerun would fail again.
  let state = judge(plan, played, order)
  let limit = plan["cap"].getInt * (if plan{"baseline"}.getStr.len > 0: 2 else: 1)
  var counted: Table[(string, string), int]
  for position, entry in order:
    let opponent = entry.opponent
    let allowed =
      if opponent notin state.tests: plan["upset_games"].getInt
      elif state.tests[opponent].done: 0
      else: limit
    let key = (opponent, entry.player)
    if counted.getOrDefault(key) >= allowed: continue
    counted[key] = counted.getOrDefault(key) + 1
    let game = played.getOrDefault(position)
    if (game.isNil or game["status"].getStr != "completed") and not game.botFailed:
      if position notin running: result.add position

proc resultDirectory*(output, candidate: string): string =
  ## A candidate's results in a batch's OUTPUT: a trial by its name, since its
  ## `assets/trials/NAME` identifier would be ignored by Git there.
  if botDirectory(candidate).isRelativeTo(Trials): output / candidate.extractFilename
  else: output / candidate
