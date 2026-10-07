## Where a result directory's raw per-game files live: one store per result directory,
## staged while a run holds it there, else in the NVMe retained store. Records name
## a stored file as `store/NAME`.

import std/[os, strutils]

const GameStoreLink* = "store"

proc repositoryRoot*(): string =
  ## The checkout or fleet bundle: `LOONG_ROOT`, else the first directory above
  ## the running binary with a justfile, else the working directory.
  result = getEnv("LOONG_ROOT")
  if result.len > 0: return
  var directory = getAppDir()
  while directory.len > 1:
    if fileExists(directory / "justfile"): return directory
    directory = directory.parentDir
  result = getCurrentDir()

proc storageRoot*(): string =
  getEnv("LOONG_STORAGE_ROOT", repositoryRoot() / "assets")

proc storeName*(directory: string): string =
  ## Its path as retained under results/local, with each `/` as `--`.
  let root = repositoryRoot().absolutePath.normalizedPath
  var path = directory.absolutePath.normalizedPath
  if dirExists(path): path = expandFilename(path)
  let running = root / "results/running"
  if path.startsWith(running & "/"):
    path = root / "results/local" / path.relativePath(running)
  let relative =
    if path.startsWith(root & "/"): path.relativePath(root)
    else: path.strip(leading = true, trailing = false, chars = {'/'})
  relative.replace("/", "--")

proc storePath*(directory: string): string =
  ## The store's directory, which may not exist yet.
  let name = storeName(directory)
  let staged = getEnv("LOONG_GAME_STAGING", storageRoot() / "staging") / name
  if dirExists(staged): staged
  else: getEnv("LOONG_GAME_STORE", storageRoot() / "games") / name

proc publicReplays*(): string =
  ## The collected public ladder replays (`loong-sample-replays --replays`).
  getEnv("LOONG_PUBLIC_REPLAYS", storageRoot() / "public-replays")

proc relocatedGamePath*(path: string): string =
  ## Resolve immutable records written before the NVMe layout change.
  let here = path.absolutePath.normalizedPath
  let retained = getEnv("LOONG_GAME_STORE", storageRoot() / "games")
  let staging = getEnv("LOONG_GAME_STAGING", storageRoot() / "staging")
  for previous in [retained, staging, getHomeDir() / ".local/share/loong/games",
      "/mnt/bulk/datasets/the-loong-game/games"]:
    if here.startsWith(previous & "/"):
      let relative = here.relativePath(previous)
      let staged = staging / relative
      return if fileExists(staged) or dirExists(staged): staged else: retained / relative
  let previousBuild = repositoryRoot() / ".build"
  if here.startsWith(previousBuild & "/"):
    let relative = here.relativePath(previousBuild)
    var candidates = @[storageRoot() / relative, storageRoot() / "review" / relative,
      storageRoot() / "benchmarks" / relative, storageRoot() / "learning" / relative]
    let parts = relative.split('/')
    if parts.len > 1 and parts[0] in ["learning", "imitation"]:
      candidates.add storageRoot() / "learning/imitation" / parts[1 .. ^1].join("/")
    if parts.len > 1 and parts[0] == "profiling":
      candidates.add storageRoot() / "benchmarks" / parts[1 .. ^1].join("/")
    if parts.len > 1 and parts[0] == "queen-foundation":
      candidates.add storageRoot() / "review" / parts[1 .. ^1].join("/")
    for candidate in candidates:
      if fileExists(candidate) or dirExists(candidate): return candidate
    return repositoryRoot() / "build" / relative
  let publicPrefix = "/mnt/bulk/datasets/the-loong-game/public-replays"
  if here.startsWith(publicPrefix & "/"):
    return publicReplays() / here.relativePath(publicPrefix)
  here

proc gameFile*(directory, name: string): string =
  ## A file a result set names: `store/NAME` in its game store, `SUB/store/NAME`
  ## (a ladder's `games/store/...`) in the store of `SUB` below it, else in
  ## place, or in the store when it has moved there since. Older records'
  ## NAS, staging and build paths follow the same file into the retained store.
  let parts = name.split('/')
  let at = parts.find(GameStoreLink)
  if at >= 0 and at < parts.high:
    let owner = if at == 0: directory else: directory / parts[0 ..< at].join("/")
    return storePath(owner) / parts[at + 1 .. ^1].join("/")
  # An absolute name is the path itself, as Python joins paths.
  let joined = if name.isAbsolute: name else: directory / name
  let here = relocatedGamePath(joined)
  if here != joined.absolutePath.normalizedPath: return here
  let stored = storePath(here.parentDir) / here.extractFilename
  if not (fileExists(here) or dirExists(here)) and
      (fileExists(stored) or dirExists(stored)): stored
  else: here

proc besideLog*(directory, log, suffix: string): string =
  ## The record another stage wrote beside a game's log, such as `.result.cols`.
  let (parent, name, _) = log.splitFile
  gameFile(directory, parent / (name & suffix))
