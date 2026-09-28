## `loong-report`: the evaluation stages that read finished games. `summary`
## renders the standard `summary.md` for any result directories, `verdict`
## judges a sequential run, and `ratings` fits Bradley–Terry ratings. None of
## them plays a game or writes a missing record; `Usage` lists the commands.

import std/[json, os, strutils, tables]
import rating, records, summary, verdict

const Usage = """
loong-report summary RESULTS... [--output DIR] [--title TITLE] [--candidates BOT...] [--context TEXT] [--allow-empty]
  Render the standard summary.md for result directories into DIR (default:
  the first RESULTS), keeping the insights already written there, and print it.
  Candidates default to every bot. A set with no played games is an error
  unless --allow-empty, which a runner passes when it renders a set before its
  first game lands.

loong-report verdict --output DIR --candidate BOT
  Judge the sequential run `batch --output DIR` played for BOT: write
  DIR/<candidate>/verdict.md and verdict.json from its results.json and result
  records, and print verdict.md. Exits 0 only when the verdict is better with
  no upset faults.

loong-report ratings
  Read {"bots": [...], "games": [{"A", "B", "winner_side", "status"}...],
  "start": {bot: rating}} on standard input and print {bot: rating}: a
  Bradley–Terry fit on the Elo scale, pool mean 1500, errored games left out.
"""

proc parseArguments(arguments: seq[string], lists: openArray[string]): (seq[string], Table[string, seq[string]]) =
  ## Positional arguments, and each option's values: `--name VALUE` or
  ## `--name=VALUE`, and for an option in `lists` every value up to the next
  ## option, comma-separated or not.
  var positional: seq[string]
  var options: Table[string, seq[string]]
  if "--help" in arguments or "-h" in arguments: quit(Usage, 0)
  let flags = ["allow-empty"]
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
      options.mgetOrPut(name, @[]).add(if name in lists: value.split(',') else: @[value])
  (positional, options)

proc option(options: Table[string, seq[string]], name, default: string): string =
  if name in options: options[name][^1] else: default

proc summaryCommand(arguments: seq[string]): int =
  let (given, options) = parseArguments(arguments, ["candidates"])
  for name in options.keys:
    if name notin ["output", "title", "candidates", "context", "allow-empty"]: quit("unknown option --" & name & "\n" & Usage, 2)
  if given.len == 0: quit(Usage, 2)
  var paths: seq[string]
  for path in given: paths.add path.absolutePath.normalizedPath
  let output = options.option("output", paths[0]).absolutePath.normalizedPath
  let games = loadGames(paths)
  if games.len == 0 and "allow-empty" notin options: quit("No played games found", 2)
  createDir(output)
  let path = output / "summary.md"
  let report = Report(games: games, title: options.option("title", output.extractFilename),
    candidates: options.getOrDefault("candidates"),
    context: options.option("context", ""), insights: existingInsights(path))
  let text = render(report)
  writeFile(path, text)
  stdout.write text

proc verdictCommand(arguments: seq[string]): int =
  let (given, options) = parseArguments(arguments, [])
  for name in options.keys:
    if name notin ["output", "candidate"]: quit("unknown option --" & name & "\n" & Usage, 2)
  if given.len > 0 or "output" notin options or "candidate" notin options: quit(Usage, 2)
  verdict(options["candidate"][^1], options["output"][^1])

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

when isMainModule:
  let arguments = commandLineParams()
  if arguments.len == 0: quit(Usage, 2)
  let rest = arguments[1 .. ^1]
  if arguments[0] in ["-h", "--help", "help"]: quit(Usage, 0)
  quit(case arguments[0]
    of "summary": summaryCommand(rest)
    of "verdict": verdictCommand(rest)
    of "ratings": ratingsCommand()
    else: (echo Usage; 2))
