## The judge's compiler adapter for C: stage a bot's C and C++ as the judge
## receives it and build it with the judge clang (`just _compile-bot`, which
## `_build-bot` calls with Nim's generated C). Part of the compiler adapter
## (`settings.nim`).

import std/[algorithm, json, os, strutils, tempfiles]
import ../[paths, python_json, toml]
import ../../gamedata/sha256
import judge_clang, snapshot

const CSources = [".c", ".h", ".cc", ".cpp", ".cxx", ".c++", ".hpp", ".hh", ".inc"]

proc compileBot*(source, output, runtime: string) =
  ## Compile the C bot at `source` to the judge artifact `output`, with
  ## `<output stem>.json` describing it. With `LOONG_BUILD_STAGED_SOURCE`
  ## set, the exact files submitted are copied there with their `bot.toml`.
  var source = resolved(source)
  let output = resolved(output)
  createDir(Root / "build")
  let botfile = source / "bot.toml"
  let project = if fileExists(botfile): readToml(botfile){"project"} else: nil
  if not project.isNil and project{"language"}.getStr in ["py", "python"]:
    raise newException(ValueError, source & " is a Python bot, which the judge path doesn't build")
  # Rake kernels compile to C: a staged build carries each kernel's header
  # (emitKernels), and an unstaged source gets them here, in a copy, so the
  # source tree is never written.
  var kernelCopy = ""
  for entry in walkTree(source):
    if entry.relative.endsWith(".rk") and not fileExists(source / entry.relative.changeFileExt(".h")):
      kernelCopy = createTempDir("rake-", "", Root / "build")
      copyDir(source, kernelCopy / "bot")
      source = kernelCopy / "bot"
      discard emitKernels(source, missing = true)
      break
  defer:
    if kernelCopy.len > 0: removeDir(kernelCopy)
  var inputs: seq[string]
  for entry in walkTree(source):
    if entry.file and not entry.symlink and not entry.relative.hidden and
        suffix(entry.relative) in CSources:
      inputs.add entry.relative
  # Files the C `#embed`s, such as weights, are staged and submitted with it.
  var embedded: seq[string]
  for path in embeddedFiles(source, inputs):
    if path notin inputs: embedded.add path
  inputs.add embedded
  inputs.sort(pathCompare)
  var shared: seq[string]
  if not fileExists(source / "helper.c"): shared.add [runtime / "helper.c", runtime / "helper.h"]
  if fileExists(source / "main.c") and "\"basic_policy.inc\"" in readFile(source / "main.c"):
    shared.add runtime / "basic_policy.inc"
  if not fileExists(source / "gizmos.h"): shared.add runtime / "gizmos.h"
  let everyTurn = not project.isNil and project{"protocol_every_turn"}.getBool(false)
  var digest = initSha256()
  digest.update(if everyTurn: "True" else: "False")
  for path in shared: digest.update(path.extractFilename & "\0" & readFile(path))
  for path in inputs: digest.update(path & "\0" & readFile(source / path))
  let fingerprint = digest.finish.hex
  let temporary = createTempDir("judge-", "", Root / "build")
  defer: removeDir(temporary)
  let staged = temporary / "bot"
  createDir(staged)
  for path in inputs:
    createDir((staged / path).parentDir)
    copyFile(source / path, staged / path)
  for path in shared:
    var content = readFile(path)
    if path.endsWith(".c") and everyTurn: content = "#define LOONG_PROTOCOL_EVERY_TURN 1\n" & content
    writeFile(staged / path.extractFilename, content)
  let snapshotDirectory = getEnv("LOONG_BUILD_STAGED_SOURCE")
  if snapshotDirectory.len > 0:
    copyDir(staged, snapshotDirectory)
    var submitted: seq[string]
    var cxx = false
    for entry in walkTree(staged):
      if entry.file: submitted.add entry.relative
      if suffix(entry.relative) in [".cc", ".cpp", ".cxx", ".c++"]: cxx = true
    submitted.sort(system.cmp)
    var listed = newJArray()
    for name in submitted: listed.add %name
    writeFile(snapshotDirectory / "bot.toml", "[project]\nlanguage = \"" &
      (if cxx: "cpp" else: "c") & "\"\ninclude = " & pythonDumps(listed) & "\n")
  judgeClang(staged, output)
  let metadata = %*{
    "source_sha256": fingerprint,
    "wasm_sha256": sha256File(output),
    "toolchain": "unswbc judge clang 20",
    "flags": DriverFlags,
    "bytes": getFileSize(output),
  }
  writeFile(output.changeFileExt(".json"), pythonDumps(metadata, indent = 2) & "\n")
  echo output
