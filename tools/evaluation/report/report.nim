## `loong-report`: the evaluation stages that read finished games. `summary`
## renders the standard `summary.md` for any result directories, `verdict`
## judges a sequential run, and `ratings` fits Bradley–Terry ratings. None of
## them plays a game or writes a missing record; `Usage` lists the commands.

import std/[json, os, strutils, tables]
import economy, knowledge, likeness, rating, records, summary, verdict
from native_pilot import nil
from native_schedule import nil
from native_profile import nil

const Usage = """
loong-report native-workload-schedule PREFIX --store STORE --maps DIR --a A.wasm --b B.wasm [--games N]
  Extend the verified SDK22/both-seat prefix into 44..10000 paired games
  (default 10000). Write schedule.tsv and canonical jobs.tsv, with no build or
  game execution. Refuse existing schedules.

loong-report native-workload STORE --output DIR --maps DIR [--backend cpu|cuda|kvm] [--games N] [--reference STORE] [--bot-failures reject|record]
  Check every scheduled complete replay, recorded seed and exact map text.
  Read actual jobs aggregates for CPU/CUDA, or per-process timings for KVM.
  Optionally require byte-identical replays against a complete reference batch.
  Write native-workload.cols and workload-timings.json; failure reports an
  incomplete batch without shrinking the scheduled denominator. Default N=10000.
  Bot failures reject by default. Explicit record mode retains terminal games
  and reports actual CPU/CUDA failed-turn counts; KVM counts remain unknown.

loong-report native-pilot STORE --output DIR [--backend kvm|cpu|cuda] [--reference STORE]
  Verify completed replay pairs and GNU time measurements; include retained
  KVM/CPU concurrency batches, or CUDA jobs with --reference. Write
  STORE/native-pilot.cols and DIR/timings.json. CUDA compares aggregate points,
  not its unexported per-turn counters. CPU rechecks serial per-turn points
  and batch aggregates, writing native-cpu-pilot.cols and cpu-timings.json.

loong-report native-workload-profile STORE --output DIR [--games N] [--expect enabled|disabled]
  Read native-profile TSV1 from judge.log into native-profile.cols and a small
  profile-summary.json. Require the previous native-workload.cols validation
  with exact reference replays/known SDK aggregate points and matching
  profile-mode.txt. Enabled mode requires complete 24-row batches and one
  serialize call per game. Disabled mode keeps absent profile data unknown.
  Host/device spans overlap; no summed decomposition or throughput claim.

loong-report summary RESULTS... [--output DIR] [--title TITLE] [--candidates BOT...] [--context TEXT] [--allow-empty]
  Render the standard summary.md (tools/evaluation/README.md) for result
  directories, or raw fleet directories (jobs.json and out/), into DIR (default:
  the first RESULTS), keeping the insights already written there, and print it.
  Candidates default to every bot that isn't a baseline. A set with no played
  games is an error unless --allow-empty, which a runner passes when it renders
  a set before its first game lands.

loong-report verdict --output DIR [--candidate BOT]
  Judge the sequential run `batch --output DIR` played for BOT (default
  expert/0001): write DIR/<candidate>/verdict.md and verdict.json from its
  results.json, result records and activation records, and print verdict.md.
  Exits 0 only when the verdict is better with no upset faults.

loong-report likeness --census ROWS.cols --bots TEAMS.tsv --output DIR [--min-games N] [--bar X] RESULTS...
  The mimics' behavioural likeness (roadmap item 5): for each ordered pair of
  mimic teams, the ladder score of one team against the other in the census
  (`loong-census measure`) beside the score of its mimic against the other's in
  the result sets RESULTS (bots named to teams by TEAMS.tsv, `bot<TAB>team`),
  wins plus half the draws. A mimic passes when its mean absolute difference
  over the pairs with at least N ladder games (default 10) is at most X
  (default 0.15). Writes DIR/likeness.tsv and likeness.md and prints the
  latter. Exits 0 only when every mimic with a counted pair passes.

loong-report economy PATH... [--bot BOT] [--points] [--worst N]
  Whole-game economy per side: pearls per dragon-turn, dragon-turns, splits,
  deaths, final units, longest and total length, head coverage. A PATH is a
  replay, or with --bot a result directory, whose games lacking a `result`
  record get one written beside their log from their replay. --points instead
  prints each replay's judge points per dragon turn: distribution, failed
  turns, the N worst turns (default 10) and each dragon's peak.

loong-report knowledge RESULTS...
  Each team's knowledge in every game under the result directories that has a
  knowledge record (`just knowledge` writes them): connectivity, agreement,
  coverage and validity per belief, pooled over the game and at rounds 100,
  250, 400 and 480. summary.md shows the same measures pooled over games.

loong-report ratings
  Read {"bots": [...], "games": [{"A", "B", "winner_side", "status"}...],
  "start": {bot: rating}} on standard input and print {bot: rating}: a
  Bradley–Terry fit on the Elo scale, pool mean 1500, errored games left out.
"""

proc repositoryRoot(): string =
  ## The checkout the binary was built in, or LOONG_ROOT.
  getEnv("LOONG_ROOT", getAppDir().parentDir.parentDir)

proc parseArguments(arguments: seq[string], lists: openArray[string]): (seq[
    string], Table[string, seq[string]]) =
  ## Positional arguments, and each option's values: `--name VALUE` or
  ## `--name=VALUE`, and for an option in `lists` every value up to the next
  ## option, comma-separated or not.
  var positional: seq[string]
  var options: Table[string, seq[string]]
  if "--help" in arguments or "-h" in arguments: quit(Usage, 0)
  let flags = ["allow-empty", "points"]
  var at = 0
  while at < arguments.len:
    let argument = arguments[at]
    inc at
    if not argument.startsWith("--"):
      positional.add argument
      continue
    if argument[2 .. ^1] in flags:
      options[argument[2 .. ^1]] = @[""]
      continue
    let (name, given) = if '=' in argument: (argument[2 ..< argument.find('=')],
      argument[argument.find('=') + 1 .. ^1]) else: (argument[2 .. ^1], "")
    var values = if '=' in argument: @[given] else: @[]
    if values.len == 0 or name in lists:
      while at < arguments.len and not arguments[at].startsWith("--") and
          (values.len == 0 or name in lists):
        values.add arguments[at]
        inc at
    if values.len == 0: quit("--" & name & " needs a value\n" & Usage, 2)
    for value in values:
      options.mgetOrPut(name, @[]).add(if name in lists: value.split(
          ',') else: @[value])
  (positional, options)

proc option(options: Table[string, seq[string]], name,
    default: string): string =
  if name in options: options[name][^1] else: default

proc summaryCommand(arguments: seq[string]): int =
  let (given, options) = parseArguments(arguments, ["candidates"])
  for name in options.keys:
    if name notin ["output", "title", "candidates", "context",
        "allow-empty"]: quit("unknown option --" & name & "\n" & Usage, 2)
  if given.len == 0: quit(Usage, 2)
  var paths: seq[string]
  for path in given: paths.add path.absolutePath.normalizedPath
  let output = options.option("output", paths[0]).absolutePath.normalizedPath
  if loadGames(paths).len == 0 and "allow-empty" notin options: quit("No played games found", 2)
  stdout.write writeSummary(paths, output, options.option("title", output.extractFilename),
    options.option("context", ""), options.getOrDefault("candidates"), repositoryRoot())

proc verdictCommand(arguments: seq[string]): int =
  let (given, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["output", "candidate"]: quit("unknown option --" & name &
        "\n" & Usage, 2)
  if given.len > 0 or "output" notin options: quit(Usage, 2)
  verdict(repositoryRoot(), options.option("candidate", "expert/0001"),
      options["output"][^1])

proc likenessCommand(arguments: seq[string]): int =
  let (given, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["census", "bots", "output", "min-games", "bar"]: quit("unknown option --" & name & "\n" & Usage, 2)
  if given.len == 0 or "census" notin options or "bots" notin options or "output" notin options: quit(Usage, 2)
  likeness(options["census"][^1], given, options["bots"][^1], options["output"][^1],
           parseInt(options.option("min-games", "10")), parseFloat(options.option("bar", "0.15")))

proc economyArguments(arguments: seq[string]): int =
  let (paths, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["bot", "points", "worst"]: quit("unknown option --" & name &
        "\n" & Usage, 2)
  if paths.len == 0: quit(Usage, 2)
  economyCommand(paths, options.option("bot", ""), "points" in options,
    parseInt(options.option("worst", "10")))

proc ratingsCommand(): int =
  let input = parseJson(stdin.readAll)
  var bots: seq[string]
  for bot in input["bots"]: bots.add bot.getStr
  var games: seq[Outcome]
  for game in input["games"]:
    if game["status"].getStr != "completed": continue
    let winner = game{"winner_side"}.getStr
    games.add Outcome(a: game["A"].getStr, b: game["B"].getStr,
      winner: if winner == "A": 0 elif winner == "B": 1 else: -1)
  var start: Table[string, float]
  if input{"start"} != nil:
    for bot, value in input["start"]: start[bot] = value.getFloat
  var ratings = newJObject()
  let fitted = fitRatings(bots, games, start)
  for bot in bots: ratings[bot] = %fitted[bot]
  echo $ratings

proc nativePilotCommand(arguments: seq[string]): int =
  let (paths, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["output", "backend", "reference"]: quit("unknown option --" &
        name & "\n" & Usage, 2)
  if paths.len != 1 or "output" notin options: quit(Usage, 2)
  native_pilot.writeNativePilotReport(paths[0], options["output"][^1],
    options.option("backend", "kvm"), options.option("reference", ""))

proc nativeWorkloadScheduleCommand(arguments: seq[string]): int =
  let (paths, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["store", "maps", "a", "b", "games"]:
      quit("unknown option --" & name & "\n" & Usage, 2)
  if paths.len != 1 or "store" notin options or "maps" notin options or
      "a" notin options or "b" notin options: quit(Usage, 2)
  native_schedule.prepareNativeWorkloadSchedule(paths[0].absolutePath,
    options["store"][^1].absolutePath, options["maps"][^1].absolutePath,
    options["a"][^1].absolutePath, options["b"][^1].absolutePath,
    parseInt(options.option("games", "10000")))

proc nativeWorkloadCommand(arguments: seq[string]): int =
  let (paths, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["output", "backend", "reference", "games", "maps",
        "bot-failures"]:
      quit("unknown option --" & name & "\n" & Usage, 2)
  if paths.len != 1 or "output" notin options or "maps" notin options:
    quit(Usage, 2)
  let botFailures = options.option("bot-failures", "reject")
  if botFailures notin ["reject", "record"]:
    quit("--bot-failures needs reject or record\n" & Usage, 2)
  native_pilot.writeNativeWorkloadReport(paths[0], options["output"][^1],
    options["maps"][^1], options.option("backend", "cpu"),
    parseInt(options.option("games", "10000")),
    options.option("reference", ""), botFailures == "record")

proc nativeWorkloadProfileCommand(arguments: seq[string]): int =
  let (paths, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["output", "games", "expect"]:
      quit("unknown option --" & name & "\n" & Usage, 2)
  if paths.len != 1 or "output" notin options: quit(Usage, 2)
  native_profile.writeNativeProfileReport(paths[0], options["output"][^1],
    parseInt(options.option("games", "44")), options.option("expect", "enabled"))

when isMainModule:
  let arguments = commandLineParams()
  if arguments.len == 0: quit(Usage, 2)
  let rest = arguments[1 .. ^1]
  if arguments[0] in ["-h", "--help", "help"]: quit(Usage, 0)
  quit(case arguments[0]
    of "summary": summaryCommand(rest)
    of "verdict": verdictCommand(rest)
    of "likeness": likenessCommand(rest)
    of "ratings": ratingsCommand()
    of "native-pilot": nativePilotCommand(rest)
    of "native-workload-schedule": nativeWorkloadScheduleCommand(rest)
    of "native-workload": nativeWorkloadCommand(rest)
    of "native-workload-profile": nativeWorkloadProfileCommand(rest)
    of "economy": economyArguments(rest)
    of "knowledge": (if rest.len == 0: (echo Usage; 2) else: knowledgeCommand(rest))
    else: (echo Usage; 2))
