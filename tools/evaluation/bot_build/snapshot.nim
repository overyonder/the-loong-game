## A bot's sources as its build sees them: the pinned library pieces
## assembled where its imports find them (`materialize`), the snapshot a
## GUID names (`snapshotSources`), Rake kernels compiled to the C the judge
## takes (`emitKernels`) and the files C `#embed`s (`stageEmbeds`,
## `embeddedFiles`). Part of the compiler adapter (`settings.nim`).

import std/[algorithm, json, os, osproc, sets, strutils, tempfiles]
import ../[paths, toml]
import ../../gamedata/sha256

const
  ## The files a snapshot keeps: what a build reads.
  SourceSuffixes* = [".c", ".h", ".cc", ".cpp", ".cxx", ".c++", ".hpp", ".hh", ".inc",
                     ".nim", ".cfg", ".toml", ".json", ".rk", ".bin"]
  ## A Nim bot names the library pieces it imports in `library.toml`: `mount`
  ## is where its imports find the library (`repertoire` inside the bot, or
  ## `../repertoire` beside it), and `[files]` maps each library path to one
  ## versioned piece under `bots/` (`<line>/lib/<module>/<nnnn>.<ext>`).
  LibraryManifest* = "library.toml"

let
  LibraryCache = Root / "build/library"
  ## Our sonar secret, kept outside source control. `materialize` stages it
  ## beside every piece that includes it (belief/0001.h); without it they use
  ## a development secret.
  SonarSecret = Root / "assets/secrets/loong_sonar_secret.h"

proc suffix*(path: string): string =
  ## Python's `Path.suffix`: the last extension of the final component.
  let name = path.extractFilename
  let dot = name.rfind('.')
  if dot <= 0 or dot == name.len - 1: "" else: name[dot .. ^1]

proc libraryManifest*(source: string): JsonNode =
  ## The bot's `library.toml`, or nil when it pins no pieces.
  let path = source / LibraryManifest
  if fileExists(path): readToml(path) else: nil

proc botsRoot(source: string): string =
  ## The `bots/` directory a bot sits under, where its pieces are found.
  var directory = resolved(source).parentDir
  while directory.len > 1:
    if directory.extractFilename == "bots": return directory
    directory = directory.parentDir
  raise newException(ValueError, source & " is not under a bots/ directory")

const
  ## The library pieces that shape a network's inputs, as
  ## tools/engine/build-native.sh names them in loong_layout.
  InputPieces = ["events", "rules", "belief", "filters", "sonar", "candidates", "crop", "features", "turn"]

proc inputPieces*(manifest: JsonNode, bots: string): string =
  ## The input-shaping pieces `manifest` mounts, each at its version (0001
  ## unmounted), in build-native.sh's form: "pieces events/0001 ...". A piece
  ## whose inputs equal an earlier version's says so in a line
  ## "// Inputs as NNNN", and is named by that version.
  result = "pieces"
  for piece in InputPieces:
    let key = "games/loong/" & piece & "/0001.h"
    let file = if manifest["files"].hasKey(key): bots / manifest["files"][key].getStr
               else: bots / "expert/lib/games/loong" / piece / "0001.h"
    var version = file.splitFile.name
    if fileExists(file):
      for line in readFile(file).splitLines:
        if line.startsWith("// Inputs as ") and line.len >= 17 and line[13 .. 16].allCharsInSet(Digits):
          version = line[13 .. 16]
          break
    result.add " " & piece & "/" & version

proc checkNetwork(source: string, manifest: JsonNode) =
  ## A bot's network.bin builds only beside the layout it was trained on
  ## (network.bin.layout, tools/engine/layout.h), and only when that names the
  ## input-shaping pieces the bot mounts: a network is never paired with
  ## beliefs, sonar or candidates it didn't train on.
  let network = source / "network.bin"
  if not fileExists(network): return
  let layout = network & ".layout"
  if not fileExists(layout):
    raise newException(ValueError, layout & " is missing: a bot's network carries the layout it was trained on")
  let trained = readFile(layout).strip
  let mounted = inputPieces(manifest, botsRoot(source))
  if not trained.endsWith(mounted):
    raise newException(ValueError, network & " was trained on " & trained & "; this bot mounts " & mounted)

proc materialize*(source: string): string =
  ## The bot as its build sees it: for a bot with `library.toml`, a copy under
  ## build/library with every piece at its mounted path, keyed by the content
  ## of everything copied. Any other bot is returned as it is.
  let source = resolved(source)
  let manifest = libraryManifest(source)
  if manifest.isNil: return source
  checkNetwork(source, manifest)
  let bots = botsRoot(source)
  var pieces: seq[(string, string)]
  for relative, piece in manifest["files"]: pieces.add (relative, bots / piece.getStr)
  var own: seq[string]
  for entry in walkTree(source):
    if entry.file and entry.relative != LibraryManifest and not entry.relative.hidden:
      own.add entry.relative
  var digest = initSha256()
  digest.update(manifest["mount"].getStr)
  for relative in own: digest.update(relative & "\0" & readFile(source / relative))
  var sortedPieces = pieces
  sortedPieces.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  for (relative, piece) in sortedPieces: digest.update(relative & "\0" & readFile(piece))
  let secret = if fileExists(SonarSecret): readFile(SonarSecret) else: ""
  digest.update("secret\0" & secret)
  let root = LibraryCache / digest.finish.hex[0 ..< 24]
  result = root / "source"
  if dirExists(result): return
  createDir(LibraryCache)
  let work = createTempDir(".assembling-", "", LibraryCache)
  for relative in own:
    createDir((work / "source" / relative).parentDir)
    copyFile(source / relative, work / "source" / relative)
  let mount = work / "source" / manifest["mount"].getStr
  for (relative, piece) in pieces:
    let target = mount / relative
    createDir(target.parentDir)
    copyFile(piece, target)
    if secret.len > 0 and "\"loong_sonar_secret.h\"" in readFile(piece):
      writeFile(target.parentDir / SonarSecret.extractFilename, secret)
  try: moveDir(work, root)
  except OSError: removeDir(work)

proc repertoireFor*(source: string): string =
  ## The repertoire a Nim bot imports, first match wins, or "" for none:
  ## the library its `library.toml` mounts, assembled by `materialize`; a
  ## copy's own `repertoire/` snapshot, as trials have; the sibling
  ## `../repertoire`. A bot without `strategy.nim`, such as a C bot, imports none.
  let manifest = libraryManifest(resolved(source))
  if not manifest.isNil:
    return resolved(materialize(source) / manifest["mount"].getStr)
  let source = resolved(source)
  if not fileExists(source / "strategy.nim"): return ""
  for candidate in [source / "repertoire", source.parentDir / "repertoire"]:
    if symlinkExists(candidate):
      raise newException(ValueError, "Build snapshots require regular sources: " & candidate)
    if dirExists(candidate): return candidate

proc sourceRoots*(source, runtime: string): seq[(string, string)] =
  ## The roots a build reads and a watch follows, by owner: the bot, the
  ## runtime, and the repertoire it imports when that is outside the bot.
  let built = materialize(source)
  result = @[("source", built), ("runtime", runtime)]
  let repertoire = repertoireFor(source)
  if repertoire.len > 0 and repertoire.parentDir != built:
    result.add ("repertoire", repertoire)

proc emitKernels*(root: string, missing = false): seq[string] =
  ## Compile every Rake kernel under `root` to the C the judge takes. rakec
  ## first verifies that each function stays vector code (`--verify-native`),
  ## then writes the kernel's header of WebAssembly SIMD intrinsics beside it.
  ## With `missing`, only kernels without a header yet. Returns every
  ## kernel's header.
  for entry in walkTree(root):
    if entry.relative.hidden or not entry.relative.endsWith(".rk"): continue
    let kernel = root / entry.relative
    let header = kernel.changeFileExt(".h")
    result.add header
    if missing and fileExists(header): continue
    let temporary = createTempDir("rake-", "")
    defer: removeDir(temporary)
    for (flag, product) in [("--verify-native", temporary / "kernel.o"), ("--emit-asm", header)]:
      let code = execCmd(quoteShellCommand(["rakec", flag, "--target", "wasm-simd128",
                                            "-o", product, kernel]))
      if code != 0:
        raise newException(OSError, "rakec " & flag & " failed for " & kernel)

proc snapshotSources*(source, runtime, destination: string): JsonNode =
  ## Copy the bot's build inputs into `destination/<owner>/` and return their
  ## SHA-256 by `<owner>/<path>`, Rake kernels' emitted headers included.
  result = newJObject()
  for (owner, root) in sourceRoots(source, runtime):
    for entry in walkTree(root):
      if entry.relative.hidden: continue
      if entry.symlink:
        raise newException(ValueError, "Build snapshots require regular sources: " & root / entry.relative)
      if not entry.file or suffix(entry.relative) notin SourceSuffixes: continue
      let target = destination / owner / entry.relative
      createDir(target.parentDir)
      let data = readFile(root / entry.relative)
      writeFile(target, data)
      result[owner & "/" & entry.relative] = %sha256Hex(data)
    # Rake kernels compile to C here, so the build names the C it submits and
    # fleet workers compile C alone.
    for header in emitKernels(destination / owner):
      result[owner & "/" & header.relativePath(destination / owner)] = %sha256Hex(readFile(header))

proc directiveWord(line: string, start: var int): string =
  ## The preprocessor directive a line opens (`#  include ...`), or "".
  var at = 0
  while at < line.len and line[at] in {' ', '\t'}: inc at
  if at >= line.len or line[at] != '#': return ""
  inc at
  while at < line.len and line[at] in {' ', '\t'}: inc at
  let first = at
  while at < line.len and line[at] in IdentChars: inc at
  start = at
  line[first ..< at]

proc includedNames*(text: string): (bool, seq[string]) =
  ## The file names a C file's directives include, and false if one is computed.
  for line in text.split('\n'):
    var at = 0
    if directiveWord(line, at) notin ["include", "include_next", "import", "embed"]: continue
    while at < line.len and line[at] in {' ', '\t'}: inc at
    let target = line[at .. ^1]
    let close = if target.startsWith('"'): '"' elif target.startsWith('<'): '>' else: '\0'
    let ending = if close == '\0': -1 else: target.find(close, 1)
    if ending <= 1: return (false, @[])
    result[1].add target[1 ..< ending].extractFilename
  result[0] = true

proc embeddedNames*(text: string): seq[string] =
  ## The files a C file's `#embed "NAME"` directives read, as written.
  for line in text.split('\n'):
    var at = 0
    if directiveWord(line, at) != "embed": continue
    let start = at
    while at < line.len and line[at] in {' ', '\t'}: inc at
    if at == start or at >= line.len or line[at] != '"': continue
    let ending = line.find('"', at + 1)
    if ending <= at + 1: continue
    let name = line[at + 1 ..< ending]
    if name.isAbsolute or ".." in name.split('/'):
      raise newException(ValueError, "#embed must name a file inside the bot: " & name)
    result.add name

proc embeddedFiles*(source: string, units: seq[string]): seq[string] =
  ## The files under `source` (relative to it) that the C `units` embed. Each
  ## name resolves beside its unit first, then at the source root, as `-I.`
  ## gives clang.
  var found = initHashSet[string]()
  for unit in units:
    for name in embeddedNames(readFile(source / unit)):
      let beside = (unit.parentDir / name).normalizedPath
      if fileExists(source / beside): found.incl beside
      elif fileExists(source / name): found.incl name.normalizedPath
      else: raise newException(IOError, source / unit & " embeds " & name & ", which isn't in " & source)
  for path in found: result.add path
  result.sort(pathCompare)

proc stageEmbeds*(generated: string, roots: seq[string]): seq[string] =
  ## Copy each file the generated C in `generated` embeds from the first of
  ## `roots` (the bot, then its repertoire) holding it, so the judge source
  ## carries it beside the C. Returns the copies.
  var units: seq[string]
  for kind, path in walkDir(generated, relative = true):
    if kind in {pcFile, pcLinkToFile} and (path.endsWith(".c") or path.endsWith(".h")): units.add path
  units.sort
  for unit in units:
    for name in embeddedNames(readFile(generated / unit)):
      let target = generated / name
      if target in result: continue
      if fileExists(target) or dirExists(target):
        raise newException(IOError, "The embedded file " & name & " clashes with generated C")
      var origin = ""
      for root in roots:
        if fileExists(root / name):
          origin = root / name
          break
      if origin.len == 0:
        raise newException(IOError, unit & " embeds " & name & ", which the bot doesn't hold")
      createDir(target.parentDir)
      copyFile(origin, target)
      result.add target
