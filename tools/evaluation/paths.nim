## Where the evaluation tools find the repository, the registry, the game
## store (tools/gamedata/store.nim owns its layout) and the pinned toolkit's
## files, and how they walk and order paths as the records name them.

import std/[algorithm, os, strutils]
import ../gamedata/store
export store

let
  Root*          = repositoryRoot()
  GameStore*     = getEnv("LOONG_GAME_STORE", storageRoot() / "games")
  GameStaging*   = expandTilde(getEnv("LOONG_GAME_STAGING", storageRoot() / "staging"))
  ## Every registered build, `Registry/GUID/`.
  Registry*      = getEnv("LOONG_BUILD_REGISTRY", Root / "assets/registry")

proc toolkitDirectory*(): string =
  ## The pinned toolkit's files, which `just setup` unpacks from its wheel
  ## (the justfile owns the pin): `unswbc_engine.wasm`, the judge clang in
  ## `clang/` and the release in `version`.
  getEnv("LOONG_TOOLKIT", Root / "build/toolkit/unswbc")

proc toolkitVersion*(): string =
  readFile(toolkitDirectory() / "version").strip

proc engineWasm*(): string =
  ## The organisers' engine the judge plays.
  result = toolkitDirectory() / "unswbc_engine.wasm"
  if not fileExists(result):
    raise newException(IOError, result & " is missing: run just setup")

proc resolved*(path: string): string =
  ## The absolute path with symlinks resolved where the path exists, as
  ## Python's `Path.resolve()`: a missing tail is kept as written.
  var absolute = absolutePath(path).normalizedPath
  var tail: seq[string]
  while not (fileExists(absolute) or dirExists(absolute) or symlinkExists(absolute)):
    if absolute == "/": break
    tail.insert(absolute.extractFilename, 0)
    absolute = absolute.parentDir
  try: absolute = expandFilename(absolute)
  except OSError: discard
  for part in tail: absolute = absolute / part
  absolute

proc pathCompare*(a, b: string): int =
  ## Python's ordering of paths: component by component, so `a/b` sorts
  ## before `a-b/c`.
  let (left, right) = (a.split('/'), b.split('/'))
  for index in 0 ..< min(left.len, right.len):
    let order = cmp(left[index], right[index])
    if order != 0: return order
  cmp(left.len, right.len)

type TreeEntry* = object
  relative*: string   # path below the walked root, `/`-separated
  symlink*:  bool     # the entry itself is a symbolic link
  file*:     bool     # it is a file, or a link to one

proc walkTree*(root: string): seq[TreeEntry] =
  ## Every file and link below `root`, as Python's `Path.rglob("*")` finds
  ## them: symlinked directories are listed but not entered. Sorted as
  ## Python sorts paths (`pathCompare`). Directories are left out.
  var pending = @[""]
  while pending.len > 0:
    let relative = pending.pop
    for kind, path in walkDir(root / relative, relative = true):
      let child = if relative.len == 0: path else: relative & "/" & path
      case kind
      of pcDir: pending.add child
      of pcFile: result.add TreeEntry(relative: child, file: true)
      of pcLinkToFile: result.add TreeEntry(relative: child, symlink: true, file: true)
      of pcLinkToDir: result.add TreeEntry(relative: child, symlink: true)
  result.sort(proc (a, b: TreeEntry): int = pathCompare(a.relative, b.relative))

proc hidden*(relative: string): bool =
  ## Whether any component of a relative path starts with a dot.
  for part in relative.split('/'):
    if part.startsWith('.'): return true
