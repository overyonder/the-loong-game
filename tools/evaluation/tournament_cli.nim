## `loong-tournament`: the stages that play games and the copies they play.
##
##   loong-tournament round-robin ...   every bot against every other (`just round-robin`)
##   loong-tournament batch ...         sequential runs until their tests decide (`just batch`)
##   loong-tournament ladder ...        a frozen offline ladder (`just ladder`)
##   loong-tournament freeze ...        freeze a line's version in development (`just freeze`)
##   loong-tournament trial NAME ...    snapshot a bot as a trial (`just trial`)
##   loong-tournament regenerate ...    replay a recorded game again (`just regenerate`)
##   loong-tournament plot-ladder DIR   a saved ladder's rating and matchup plots (`just plot-ladder`)
##   loong-tournament replay-source TARGET [GAME]  the replay a viewer target names
##   loong-tournament activation --bot BOT DIR...   Brain activation over result sets (`just activation`)
##   loong-tournament games DIR --bot BOT    each game BOT played, as STEM<TAB>SIDE
##   loong-tournament match-command    the judge and engine a match command starts with
##   loong-tournament game-store DIR   a result set's staged game store; publish-store DIR publishes it
##   loong-tournament play-game GAME TIMEOUT   one game, for the runners' own children
##   loong-tournament trace-activation DIR STEM SIDES TARGET   one game, for `activation`'s children
##   loong-tournament check-smoke BOT DIR   judge `just check-head`'s smoke games

import std/[cpuinfo, json, os, strutils]
import arguments, batch, freeze, ladder, ladder_plot, paths, processes, regenerate, round_robin, tournament
import ../ladder/site
import ../analysis/activation_stage
import ../judge/harness

proc freezeCommand(argv: seq[string]): int =
  let line = parseCommandLine(argv, "usage: just freeze --source DIRECTORY [--commit COMMIT]", @[
    OptionSpec(name: "source", arity: One, help: "A line's version in development, such as bots/expert/0001"),
    OptionSpec(name: "commit", arity: One, help: "Commit to freeze from (default: HEAD); never the working tree")])
  if not line.given("source"): line.fail "--source is required"
  echo freeze(line.last("source"), line.last("commit", "HEAD")).relativePath(Root)

proc trialCommand(argv: seq[string]): int =
  let line = parseCommandLine(argv, "usage: just trial NAME [--source DIRECTORY] [--commit COMMIT]", @[
    OptionSpec(name: "source", arity: One, help: "Nim bot directory to copy (default: the expert line's version in development)"),
    OptionSpec(name: "commit", arity: One, help: "Commit to copy from (default: HEAD); never the working tree")])
  if line.positional.len != 1: line.fail "give the trial's NAME"
  echo trial(line.positional[0], line.last("source"), line.last("commit", "HEAD")).relativePath(Root)

proc regenerateCommand(argv: seq[string]): int =
  let line = parseCommandLine(argv, "usage: just regenerate RESULT_DIR GAME | GAME_ID | --public OUT GAME_ID... [options]", @[
    OptionSpec(name: "build", arity: One, help: "For a ladder game ID the foil played: the registered build to play its side, with --replay and --side"),
    OptionSpec(name: "replay", arity: One, help: "The site's replay of that game"),
    OptionSpec(name: "side", arity: One, help: "Our side in that game, A or B"),
    OptionSpec(name: "again", arity: Flag, help: "Play it again even if its replay is already there"),
    OptionSpec(name: "public", arity: One, help: "Play public ladder game IDs again with both sides scripted into OUT; a target `@FILE` reads the IDs from a file's first column"),
    OptionSpec(name: "threads", arity: One, help: "Games at once with --public (default: every CPU)")])
  let targets = line.positional
  if targets.len == 0: line.fail "give RESULT_DIR GAME, or a ladder game ID"
  if line.given("public"):
    let output = line.last("public")
    var games: seq[int]
    for target in targets:
      if target.startsWith("@"):
        for row in readFile(target[1 .. ^1]).splitLines:
          if row.len > 0 and row[0].isDigit: games.add parseInt(row.splitWhitespace[0])
      else: games.add parseInt(target)
    fetchSeeds(games)   # the site's seeds, once each, before the games
    let threads = line.integer("threads", countProcessors())
    var reports = newSeq[JsonNode](games.len)
    var running: seq[Child]
    var next, printed, dropped = 0
    while printed < games.len:
      while next < games.len and running.len < threads:
        running.add spawnChild(@[selfExecutable(), "regenerate-public-one", $games[next], output,
                                 (if line.given("again"): "again" else: "")], next, cwd = Root)
        inc next
      let (index, code, text) = waitAnyChild(running)
      if code != 0: raise newException(IOError, "regenerating game " & $games[index] & " failed")
      reports[index] = parseJson(text)
      # Reports print in the games' order, as each one's turn comes.
      while printed < games.len and not reports[printed].isNil:
        let report = reports[printed]
        if report{"dropped"}.kind == JString:
          inc dropped
          echo report["game"].getInt, ": dropped, ", report["dropped"].getStr
        inc printed
    echo games.len - dropped, " of ", games.len, " games regenerated into ", output
    return 0
  if targets.len == 1 and targets[0].allCharsInSet(Digits):
    let path = ladder(parseInt(targets[0]), line.given("again"), line.last("build"), line.last("replay"), line.last("side"))
    stdout.write readFile(path.changeFileExt(".json"))
    echo path
  elif targets.len == 2:
    let directory = resolved(targets[0])
    echo(if line.given("again"): regenerate(directory, findRecord(directory, targets[1]))
         else: replay(directory, targets[1]))
  else: line.fail "give RESULT_DIR GAME, or a ladder game ID"
  0

proc main(): int =
  installInterrupt()
  let argv = commandLineParams()
  if argv.len == 0:
    stderr.writeLine "usage: loong-tournament COMMAND ...; see tools/evaluation/README.md"
    return 2
  let rest = argv[1 .. ^1]
  try:
    case argv[0]
    of "round-robin": roundRobin(rest)
    of "batch": batch(rest)
    of "ladder": ladder(rest)
    of "freeze": freezeCommand(rest)
    of "trial": trialCommand(rest)
    of "regenerate": regenerateCommand(rest)
    of "plot-ladder":
      if rest.len != 1:
        stderr.writeLine "usage: just plot-ladder DIRECTORY"
        return 2
      plotLadder(rest[0])
      0
    of "replay-source":
      # Standard output carries only the answer; anything else goes to stderr.
      for line in replaySource(if rest.len > 0: rest[0] else: "latest-loss", if rest.len > 1: rest[1] else: ""): echo line
      0
    of "regenerate-public-one":
      stdout.write $public(parseInt(rest[0]), rest[1], rest.len > 2 and rest[2] == "again")
      0
    of "site-seed":
      stdout.write apiRequest("/battles/" & rest[0])["match"]["seed"].getStr
      0
    of "activation": activationCommand(rest)
    of "trace-activation": traceActivationCommand(rest)
    of "check-smoke": smokeCommand(rest)
    of "match-command":
      echo matchCommand().join(" ")
      0
    of "game-store":
      echo gameStore(rest[0])
      0
    of "publish-store":
      publishStore(rest[0])
      0
    of "games":
      let line = parseCommandLine(rest, "usage: loong-tournament games DIRECTORY --bot BOT", @[
        OptionSpec(name: "bot", arity: One, help: "the bot whose games to list")])
      if line.positional.len != 1 or not line.given("bot"): line.fail "give one result directory and --bot"
      for record in records(line.positional[0]):
        if record.kind != JObject or record.len == 0: continue
        for side in ["A", "B"]:
          if record{side}.getStr == line.last("bot"): echo stemOf(record), "\t", side
      0
    of "play-game":
      stdout.write $playOneGame(gameFromJson(parseJson(rest[0])), parseFloat(rest[1]))
      0
    else:
      stderr.writeLine "unknown command " & argv[0]
      2
  except InterruptError:
    stderr.writeLine "interrupted"
    130
  except CatchableError as error:
    stderr.writeLine error.msg
    1

quit main()
