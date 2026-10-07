## Freeze a line's version in development, as committed (`just freeze`), or
## snapshot a bot as a throwaway trial (`just trial`).
##
## In `bots/<line>/<kind>/`, the highest-numbered version is in development
## and every lower one is frozen. Freezing it keeps it where it is as a frozen
## version, records the commit in its `freeze.json`, adds it to the pool in
## tools/evaluation/pool.toml, and copies it, as committed, to the next number
## as the new version in development. A Nim bot's `library.toml` pins the
## library pieces it imports, and the copy pins the same ones: a piece a
## frozen version pins is never edited again, so changing one means adding its
## next version (`bots/<line>/lib/<module>/<nnnn>.<ext>`) and pinning that.
## Refuses to freeze a source identical to an existing version.
##
## A trial is the same snapshot made as `assets/trials/<name>`, a throwaway
## copy to edit and judge by its path instead of a copy under `bots/`.

import std/[algorithm, json, os, osproc, strutils, tempfiles]
import bots, paths, python_json
import bot_build/snapshot
import ../gamedata/sha256

const
  ## Where a frozen copy records its origin; not part of the bot's identity.
  FreezeRecord = "freeze.json"
  Suffixes = SourceSuffixes

proc fingerprint*(directory: string): string =
  ## A version's identity: its own sources, the repertoire it imports and the
  ## shared runtime files it builds with.
  var digest = initSha256()
  var sources: seq[string]
  for kind, path in walkDir(directory):
    if kind in {pcFile, pcLinkToFile} and suffix(path) in Suffixes and path.extractFilename != FreezeRecord:
      sources.add path
  sources.sort(pathCompare)
  for path in sources:
    var content = readFile(path)
    if path.extractFilename == "strategy.nim":
      # A frozen copy imports its snapshot; the same imports are the same bot.
      content = content.replace("../repertoire/", "repertoire/")
    digest.update(path.extractFilename & "\0" & content)
  let repertoire = repertoireFor(directory)
  if repertoire.len > 0:
    for entry in walkTree(repertoire):
      if entry.file and suffix(entry.relative) in Suffixes:
        digest.update(entry.relative & "\0" & readFile(repertoire / entry.relative))
  let runtime = Root / "bots/common/runtime"
  var shared = @["helper.c", "helper.h"]
  if fileExists(directory / "strategy.nim"): shared.add ["controller.nim", "entry.c"]
  if fileExists(directory / "main.c") and "\"basic_policy.inc\"" in readFile(directory / "main.c"):
    shared.add "basic_policy.inc"
  for name in shared:
    if not fileExists(directory / name) and not dirExists(directory / name):
      digest.update(name & "\0" & readFile(runtime / name))
  digest.finish.hex

proc copyTreeExcept(source, destination: string, skippedSuffix: string) =
  ## Copy a directory, leaving out files ending in `skippedSuffix`.
  createDir(destination)
  for kind, path in walkDir(source, relative = true):
    if path.endsWith(skippedSuffix): continue
    case kind
    of pcDir: copyTreeExcept(source / path, destination / path, skippedSuffix)
    of pcLinkToDir, pcLinkToFile: createSymlink(expandSymlink(source / path), destination / path)
    of pcFile: copyFileWithPermissions(source / path, destination / path)

proc snapshotBot(source, destination: string) =
  ## Copy a bot as a trial, assembling and relocating any pinned Nim library.
  copyTreeExcept(materialize(source), destination, ".excalidraw")
  let repertoire = repertoireFor(source)
  if repertoire.len > 0 and not dirExists(destination / "repertoire"):
    copyTreeExcept(repertoire, destination / "repertoire", ".excalidraw")
    writeFile(destination / "strategy.nim",
      readFile(destination / "strategy.nim").replace("../repertoire/", "repertoire/"))

proc git(arguments: varargs[string]): string =
  let (output, code) = execCmdEx(quoteShellCommand(@["git"] & @arguments), workingDir = Root)
  if code != 0: raise newException(OSError, "git " & arguments.join(" ") & " failed: " & output)
  output

proc extract(source, commit, work: string): (string, string) =
  ## Extract `source` and the library pieces it pins, as committed, into
  ## `work`: the full commit and the extracted source directory. Trials and
  ## freezes copy from here, never from the shared working tree, where other
  ## sessions' edits may be half done.
  let revision = git("rev-parse", "--verify", commit & "^{commit}").strip
  var paths = @[source.relativePath(Root)]
  let manifest = libraryManifest(source)
  if not manifest.isNil:
    for _, piece in manifest["files"]: paths.add "bots/" & piece.getStr
  let command = quoteShellCommand(@["git", "archive", revision, "--"] & paths) & " | tar -x -C " & quoteShell(work)
  let (output, code) = execCmdEx("set -o pipefail; " & command, workingDir = Root)
  if code != 0: raise newException(OSError, "extracting " & source & " at " & revision & " failed: " & output)
  (revision, work / source.relativePath(Root))

proc recordOrigin(path, source, revision: string) =
  writeFile(path, pythonDumps(%*{"source": source.relativePath(Root), "commit": revision}) & "\n")

proc trial*(name: string, source = "", commit = "HEAD"): string =
  ## Snapshot a bot as `assets/trials/<name>` to edit and judge by its path.
  ## `trial.json` records the source and commit, and runners report them.
  let source = resolved(if source.len > 0: source else: development())
  result = Root / "assets/trials" / name
  if dirExists(result) or fileExists(result):
    raise newException(ValueError, result.relativePath(Root) & " exists; edit or delete it")
  let work = createTempDir("trial-", "")
  defer: removeDir(work)
  let (revision, committed) = extract(source, commit, work)
  snapshotBot(committed, result)
  recordOrigin(result / "trial.json", source, revision)

proc freeze*(source: string, commit = "HEAD"): string =
  ## Freeze `source`, a line's version in development, and copy it as
  ## committed to the next number as the new version in development.
  let source = resolved(source)
  if source != versions(source.parentDir)[^1]:
    raise newException(ValueError, source.relativePath(Root) & " is not its line's version in development")
  if git("status", "--porcelain", "--", source.relativePath(Root)).len > 0:
    raise newException(ValueError, source.relativePath(Root) & " has uncommitted changes; commit them first")
  let work = createTempDir("freeze-", "")
  defer: removeDir(work)
  let (revision, committed) = extract(source, commit, work)
  let sourceHash = fingerprint(committed)
  for version in frozenVersions(source):
    if fingerprint(version) == sourceHash:
      raise newException(ValueError, source.relativePath(Root) & " at " & revision[0 ..< 12] &
        " is already frozen as " & version.extractFilename)
  result = source.parentDir / align($(parseInt(source.extractFilename[0 ..< 4]) + 1), 4, '0')
  copyDir(committed, result)
  let manifest = source / "bot.toml"
  if fileExists(manifest):
    var text = readFile(manifest)
    var at = text.find("status = \"")
    while at >= 0:
      let close = text.find('"', at + 10)
      if close < 0: break
      text = text[0 ..< at] & "status = \"frozen\"" & text[close + 1 .. ^1]
      at = text.find("status = \"", at + 17)
    writeFile(manifest, text)
  recordOrigin(source / FreezeRecord, source, revision)
  # The pool's `bots = [...]` line gains the frozen version.
  var lines = readFile(Pool).split('\n')
  for index, line in lines:
    if line.startsWith("bots = [") and line.endsWith("]"):
      var names: seq[string]
      for name in line["bots = [".len ..< ^1].split(','):
        names.add name.strip.strip(chars = {'"'})
      names.add source.relativePath(Root / "bots")
      var listed: seq[string]
      for name in names: listed.add "\"" & name & "\""
      lines[index] = "bots = [" & listed.join(", ") & "]"
      break
  writeFile(Pool, lines.join("\n"))
