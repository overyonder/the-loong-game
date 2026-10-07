## Games in loong-judge, which plays the organisers' engine
## (`unswbc_engine.wasm`) against bot modules it meters itself. Every match a
## runner plays starts with `matchCommand()`, which takes the arguments of a
## sandboxed `run` and writes the game's log, replay and points columns
## (src/run.zig). Building the judge is its own stage.

import std/[math, os, strutils, times]
import ../evaluation/[paths, processes]
import ../gamedata/sha256

let
  ## A fleet worker names its bundle's static judge.
  Judge* = getEnv("LOONG_JUDGE", Root / "build/zig-judge/bin/loong-judge")

const
  ## The exit code of a game the judge's `--timeout` ended (src/main.zig).
  TimedOut* = 124

proc checkJudge*(judge, build: string): string =
  ## `judge`, refused when missing or older than the sources it is built
  ## from; `build` is the `just` recipe that builds it. With
  ## `LOONG_JUDGE_SOURCE_MANIFEST`, a manifest of SHA-256 sums must cover the
  ## judge and every source it is built from.
  if not fileExists(judge): raise newException(IOError, judge & " is missing: run just " & build)
  let sources = Root / "tools/judge"
  let manifestPath = getEnv("LOONG_JUDGE_SOURCE_MANIFEST")
  if manifestPath.len > 0:
    let manifest = resolved(manifestPath)
    var required = @[resolved(judge)]
    if judge.extractFilename == "loong-judge-rake-0002":
      for path in walkFiles(sources / "0002-rake/*.rk"): required.add resolved(path)
      for name in ["native-abi.h", "build.sh"]: required.add resolved(sources / "0002-rake" / name)
    else:
      required.add resolved(sources / "build.zig")
      for path in walkFiles(sources / "src/*.zig"): required.add resolved(path)
    var checked: seq[string]
    for line in readFile(manifest).splitLines:
      if line.len == 0: continue
      let separator = line.find("  ")
      let expected = if separator >= 0: line[0 ..< separator] else: ""
      if separator < 0 or expected.len != 64 or not expected.allCharsInSet({'0' .. '9', 'a' .. 'f'}):
        raise newException(ValueError, "Invalid judge source manifest: " & manifest)
      let path = resolved(manifest.parentDir / line[separator + 2 .. ^1])
      if sha256File(path) != expected:
        raise newException(ValueError, judge & " source/artifact hash differs: " & path)
      checked.add path
    var missing: seq[string]
    for path in required:
      if path notin checked: missing.add path
    if missing.len > 0:
      raise newException(ValueError, "Judge manifest omits required inputs: " & missing.join(", "))
    return judge
  let built = getLastModificationTime(judge)
  var stale = fileExists(sources / "build.zig") and getLastModificationTime(sources / "build.zig") > built
  for source in walkFiles(sources / "src/*.zig"):
    stale = stale or getLastModificationTime(source) > built
  if stale: raise newException(IOError, judge & " is older than its sources: run just " & build)
  judge

proc matchCommand*(): seq[string] =
  ## The judge and its engine, to which a sandboxed `run ...` is appended.
  @[checkJudge(Judge, "zig-judge-build"), "--engine", engineWasm()]

proc isMatchCommand*(command: seq[string]): bool =
  ## Whether this command runs the selected judge, including renamed hosts.
  command.len > 0 and resolved(command[0]) == resolved(Judge)

proc play*(command: seq[string], log: string, timeout: float, cwd = ""): tuple[code: int, timedOut: bool] =
  ## Play a `matchCommand()` game with its output in `log`, ended at
  ## `timeout` wall seconds: its exit code and whether the limit ended it.
  ## The judge ends itself; one still running a minute later is killed.
  let at = command.find("run")
  let arguments = command[0 ..< at] & @["--log", log, "--timeout", $int(ceil(timeout))] & command[at .. ^1]
  createDir(log.parentDir)
  let (code, killed) = runQuietly(arguments, cwd, timeout + 60)
  if killed: (-9, true) else: (code, code == TimedOut)
