## The bots evaluation plays, by the names records give them: a bot is named
## by its path under bots/ (`expert/0001`), a trial or a judge test bot by
## its path from the repository root. A line's versions under `bots/<line>/`
## are numbered; the highest plain number is in development, and an
## experiment is the version it branched from with a letter (`0001a-search`).
## Each bot plays its registered judge build, copied into place under build/ by
## `just bot-build` (`prepareBots`).

import std/[algorithm, json, os, osproc, sets, streams, strutils, times]
import paths, toml
import ../gamedata/sha256

let
  ## Throwaway source snapshots (`just trial`), named by their path from the
  ## repository root.
  Trials*     = resolved(Root / "assets/trials")
  ## Bots that test the judge, such as its fidelity check's deliberate failures.
  JudgeTests* = resolved(Root / "tools/judge/tests")
  Pool*       = Root / "tools/evaluation/pool.toml"

proc botName*(directory: string): string =
  ## The canonical evaluation identifier of a bot's source directory.
  let path = resolved(directory)
  if path.isRelativeTo(Trials): "assets/trials/" & path.relativePath(Trials)
  elif path.isRelativeTo(JudgeTests): "tools/judge/tests/" & path.relativePath(JudgeTests)
  else: absolutePath(directory).normalizedPath.relativePath(Root / "bots")

proc botDirectory*(name: string): string =
  ## The source directory of the bot `botName` names.
  let path = resolved(gameFile(Root, name))
  if path.isRelativeTo(Trials) or path.isRelativeTo(JudgeTests): path else: Root / "bots" / name

proc registeredOpponents*(): seq[(string, string)] =
  ## Opponents whose source is deleted, kept as registered builds: name to
  ## GUID, in pool.toml's order. The name is the bot's former path under
  ## bots/, so its results keep their identity.
  let registered = readToml(Pool){"registered"}
  if registered != nil:
    for name, guid in registered: result.add (name, guid.getStr)

proc poolBots*(): seq[string] =
  for name in readToml(Pool)["bots"]: result.add name.getStr

proc versions*(line: string): seq[string] =
  ## A line's numbered versions, such as bots/expert/0001, oldest first: plain
  ## numbers only, not the lettered experiments beside them.
  for item, path in walkDir(line):
    let name = path.extractFilename
    if item in {pcDir, pcLinkToDir} and name.len == 4 and name.allCharsInSet(Digits):
      result.add path
  result.sort(system.cmp)

proc development*(line = "expert"): string =
  ## A line's version in development: its highest plain number.
  versions(Root / "bots" / line)[^1]

proc frozenVersions*(line: string): seq[string] =
  ## The frozen versions before a version in development, oldest first.
  for path in versions(line.parentDir):
    if path.extractFilename < line.extractFilename: result.add path

proc trialOrigin*(directory: string): string =
  ## `source@commit` for a trial, so a result names the code it measured; ""
  ## for any other bot.
  let record = directory / "trial.json"
  if not fileExists(record): return ""
  let origin = parseFile(record)
  let commit = origin["commit"].getStr
  origin["source"].getStr & "@" & commit[0 ..< min(12, commit.len)]

proc discoverBots*(): JsonNode =
  ## Every bot evaluation can name, with how it plays: bots with a manifest
  ## or a Nim strategy under bots/, registered opponents, and trials.
  result = newJObject()
  let botRoot = Root / "bots"
  var stack = @[botRoot]
  while stack.len > 0:
    let directory = stack.pop
    var children: seq[string]
    var files = initHashSet[string]()
    for kind, path in walkDir(directory, relative = true):
      if kind == pcDir and not path.startsWith('.'): children.add path
      elif kind in {pcFile, pcLinkToFile}: files.incl path
    children.sort(system.cmp)
    for index in countdown(children.high, 0): stack.add directory / children[index]
    let name = directory.relativePath(botRoot)
    if "bot.toml" in files:
      let manifest = directory / "bot.toml"
      let configuration = readToml(manifest){"evaluation"}
      let configured = if configuration.isNil: newJObject() else: configuration
      let launcher = resolved(directory / configured{"launcher"}.getStr("."))
      if not launcher.isRelativeTo(resolved(directory)) or not (fileExists(launcher) or dirExists(launcher)):
        raise newException(ValueError, "Invalid launcher in " & manifest.relativePath(Root))
      result[name] = %*{
        "launcher": launcher.relativePath(Root),
        "sandbox": configured{"sandbox"}.getBool(true),
        "status": configured{"status"}.getStr("active"),
        "required_env": if configured{"required_env"}.isNil: newJArray() else: configured["required_env"],
      }
    elif "strategy.nim" in files:
      result[name] = %*{"launcher": directory.relativePath(Root), "sandbox": true,
        "sandbox_only": true, "status": "active", "required_env": []}
  for (name, guid) in registeredOpponents():
    if not result.hasKey(name):
      result[name] = %*{"launcher": "bots/" & name, "sandbox": true, "sandbox_only": true,
        "status": "registered build " & guid, "required_env": []}
  var trials: seq[string]
  for kind, path in walkDir(Trials):
    if kind in {pcDir, pcLinkToDir}: trials.add path
  trials.sort(system.cmp)
  for directory in trials:
    if not (fileExists(directory / "strategy.nim") or fileExists(directory / "main.c")): continue
    let origin = trialOrigin(directory)
    result[botName(directory)] = %*{"launcher": directory.relativePath(Root), "sandbox": true,
      "sandbox_only": true, "status": "trial of " & (if origin.len > 0: origin else: "unknown code"),
      "required_env": []}

proc compiledBotPath*(path: string): string =
  ## Where a bot's judge build is copied: always under the project cache,
  ## outside every source directory.
  let absolute = resolved(gameFile(Root, path))
  if absolute.isRelativeTo(Trials):
    # A trial is source, so its build stays outside it like any other bot's.
    Root / "build/trial-builds" / absolute.relativePath(Trials) / "main.wasm"
  elif absolute.isRelativeTo(Root / "build"): absolute / "main.wasm"
  elif absolute.isRelativeTo(Root): Root / "build" / absolute.relativePath(Root) / "main.wasm"
  else:
    let fingerprint = sha256Hex(absolute)[0 ..< 16]
    Root / "build/external-bots" / (path.extractFilename & "-" & fingerprint) / "main.wasm"

proc launcher*(path: string): string =
  ## The prepared judge build a game plays.
  result = compiledBotPath(path)
  if fileExists(path / "strategy.nim") and not fileExists(result):
    raise newException(IOError, "Nim bot is not built: run just bot-build " & path & " " & result)
  if not fileExists(result): result = path

proc cpuWorkers*(): int = max(1, countProcessors())

proc claimBuild(path, selection: string) =
  ## A bot's build is staged at one path whatever run stages it, so a run
  ## claims it for the build it selects (a GUID, or "source"): a claim by
  ## another live process for a different build refuses this run, since its
  ## games would play whichever build was staged last. A dead process's claim
  ## lapses.
  let claim = compiledBotPath(path) & ".claim"
  let pid = getCurrentProcessId()
  if fileExists(claim):
    let fields = readFile(claim).strip.split(' ')
    if fields.len == 2:
      let holder = try: parseInt(fields[1]) except ValueError: 0
      if holder != pid and holder > 0 and dirExists("/proc/" & $holder) and fields[0] != selection:
        raise newException(IOError, path & " is staged as build " & fields[0] & " by running process " & $holder &
          ", so this run can't play build " & selection & " under the same name; wait for that run or rename the bot")
  createDir(claim.parentDir)
  writeFile(claim, selection & " " & $pid & "\n")

proc prepareBots*(paths: seq[string], workers: int, registeredOnly = false,
                  buildGuids: seq[(string, string)] = @[], deadline = 0.0) =
  ## Copy each bot's registered judge build into place through `just
  ## bot-build`. With `registeredOnly`, as the runners use it, a bot whose
  ## source has no registered build fails, naming the `just bot-build` that
  ## registers it. `buildGuids` selects exact registered snapshots instead of
  ## current source; `deadline` (epoch seconds, 0 for none) bounds the work.
  var guids: seq[(string, string)]
  for (name, guid) in registeredOpponents():
    if not dirExists(Root / "bots" / name): guids.add (resolved(Root / "bots" / name), guid)
  for (path, guid) in buildGuids: guids.add (resolved(path), guid)
  var unique: seq[string]
  for path in paths:
    let path = resolved(path)
    if path notin unique: unique.add path
  unique.sort(system.cmp)
  putEnv("NO_COLOR", "1")
  if registeredOnly: putEnv("LOONG_BUILD_REGISTERED_ONLY", "1")
  defer: delEnv("LOONG_BUILD_REGISTERED_ONLY")
  var running: seq[(string, Process)]
  var failure = ""
  proc finish(entry: (string, Process)) =
    let (path, process) = entry
    let output = process.outputStream.readAll
    let code = process.waitForExit
    process.close
    if code == 0 or failure.len > 0: return
    if registeredOnly and "no registered build" in output:
      for line in output.splitLines:
        if "no registered build" in line:
          failure = line
          return
    failure = "Build failed for " & path & ": " & output
  for path in unique:
    if deadline > 0 and epochTime() >= deadline: raise newException(IOError, "Build deadline exhausted")
    var selection = @[path, compiledBotPath(path), "judge"]
    var chosen = "source"
    for (guided, guid) in guids:
      if guided == path:
        selection = @["--guid", guid, compiledBotPath(path)]
        chosen = guid
    claimBuild(path, chosen)
    running.add (path, startProcess("just", workingDir = Root, args = @["bot-build"] & selection,
                                    options = {poUsePath, poStdErrToStdOut}))
    if running.len >= workers:
      finish(running[0])
      running.delete(0)
  for entry in running: finish(entry)
  if failure.len > 0: raise newException(IOError, failure)
