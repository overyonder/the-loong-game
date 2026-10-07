## The organisers' judge clang, `clang.wasm` and its sysroot from the pinned
## wheel, run under wasmer: each C or C++ unit compiles alone and the objects
## link, with the flags, source order and link line of the toolkit's
## `clangtool.build` and the judge's `build.cc`, so the artifact is the one
## the judge builds, byte for byte. Part of the compiler adapter
## (`settings.nim`).
##
## Units compile in parallel, `buildJobs()` at once across the host, and an
## object whose key (`objectKeys`) is cached is reused. The link runs twice,
## once stripped for the judge and once keeping the name section, which gives
## `judge.names` for `loong-judge run --profile`.

import std/[algorithm, json, os, osproc, sets, streams, strutils, tempfiles, times]
import ../[locks, processes]
import ../[paths, python_json]
import ../../gamedata/sha256
import snapshot

const
  CSuffix      = ".c"
  CxxSuffixes  = [".cc", ".cpp", ".cxx", ".c++"]
  DriverFlags* = ["--sysroot=/sysroot", "--target=wasm32-wasi", "-resource-dir=/lib/clang/20",
    "-B/bin", "-fintegrated-cc1", "-fwasm-exceptions", "-mllvm", "-wasm-enable-eh", "-mllvm",
    "-wasm-enable-sjlj", "-mllvm", "-wasm-use-legacy-eh=false", "-matomics", "-mbulk-memory",
    "-msimd128", "-mmutable-globals", "-pthread", "-ftls-model=local-exec",
    "-D_WASI_EMULATED_MMAN", "-D_WASI_EMULATED_SIGNAL", "-D_WASI_EMULATED_PROCESS_CLOCKS",
    "-DUSE_TIMEGM", "-Werror=date-time", "-O2", "-I.", "-Isource"]
  LinkFlags = ["-m", "wasm32", "--strip-all", "--threads=1",
    "-L/lib/clang/20/lib/wasm32-unknown-wasi", "-L/sysroot/lib/wasm32-wasi",
    "/sysroot/lib/wasm32-wasi/crt1-command.o", "--shared-memory", "--max-memory=4294967296",
    "--import-memory", "-lunwind"]
  LinkTail = ["-lpthread", "-lc", "/lib/clang/20/lib/wasm32-unknown-wasi/libclang_rt.builtins.a", "-o"]
  ## An object unused this long is pruned after a build.
  ObjectLifetime = initDuration(days = 14)

let JudgeObjects = Root / "build/cache/judge-clang"

proc toolchainHome*(): string =
  ## The judge clang unpacked from the pinned wheel.
  result = toolkitDirectory() / "clang"
  if not fileExists(result / "clang.wasm"):
    raise newException(IOError, result & "/clang.wasm is missing: run just setup")

proc wasmer(): string =
  result = getEnv("LOONG_WASMER", Root / "build/toolkit/wasmer/bin/wasmer")
  if not fileExists(result): raise newException(IOError, result & " is missing: run just setup")

proc isCxx(unit: string): bool = suffix(unit) in CxxSuffixes

proc sources*(directory: string): seq[string] =
  ## `judge/build.cc ListFiles`: every C and C++ source under the bot,
  ## dotfiles apart, in path-string order.
  for entry in walkTree(directory):
    if entry.file and not entry.symlink and not entry.relative.hidden and
        (suffix(entry.relative) == CSuffix or entry.relative.isCxx):
      result.add entry.relative
  result.sort(system.cmp)

proc unitLanguage(unit: string): seq[string] =
  if suffix(unit) == CSuffix: @["-xc", "-std=c17"] else: @["-xc++", "-std=c++20", "-stdlib=libc++"]

proc buildJobs*(): int =
  ## Compiles at once on this host: `LOONG_BUILD_JOBS`, else half its CPUs.
  let jobs = getEnv("LOONG_BUILD_JOBS")
  max(1, if jobs.len > 0: parseInt(jobs) else: countProcessors() div 2)

proc toolchainDigest*(home: string): string =
  ## The judge clang and its sysroot, by content.
  var digest = initSha256()
  for entry in walkTree(home):
    if entry.symlink:
      digest.update(entry.relative & "\0" & expandSymlink(home / entry.relative))
    elif entry.file:
      digest.update(entry.relative & "\0")
      digest.update(sha256File(home / entry.relative).parseHexStr)

proc objectKeys(staged: string, units: seq[string], toolchain: string): seq[string] =
  ## Name each unit's object by every input clang can read for it: the unit,
  ## the toolchain and flags, the names of all staged files and the contents
  ## of every staged file that isn't itself a unit, plus any unit another file
  ## includes. A computed include makes every file an input.
  var files: seq[(string, string)]
  for entry in walkTree(staged):
    if entry.file: files.add (entry.relative, readFile(staged / entry.relative))
  var everything = false
  var names = initHashSet[string]()
  for (_, text) in files:
    let (literal, found) = includedNames(text)
    if not literal: everything = true
    for name in found: names.incl name
  let compiled = units.toHashSet
  var listed = newJArray()
  var sortedNames: seq[string]
  for (name, _) in files: sortedNames.add name
  sortedNames.sort(system.cmp)
  for name in sortedNames: listed.add %name
  var shared = initSha256()
  shared.update(pythonDumps(listed))
  for (name, data) in files:
    if everything or name notin compiled or name.extractFilename in names:
      shared.update(name & "\0" & sha256Hex(data).parseHexStr)
  let sharedDigest = shared.finish.bytes
  for unit in units:
    var unitData = ""
    for (name, data) in files:
      if name == unit: unitData = data
    var key = initSha256()
    key.update(pythonDumps(%*[toolchain, DriverFlags, unitLanguage(unit), unit]))
    key.update(sha256Hex(unitData).parseHexStr)
    key.update(sharedDigest)
    result.add key.finish.hex

proc runInToolchain(program, home, staged, work: string, arguments: openArray[string], what: string) =
  ## One step of the judge's build, as the sandbox ran it: the toolchain's
  ## root at `/`, the bot at `/src` (the working directory), and `/out` and
  ## `/tmp` from `work`.
  var command = @[wasmer(), "run", "--volume", home / "root" & ":/",
    "--volume", staged & ":/src", "--volume", work / "out" & ":/out",
    "--volume", work / "tmp" & ":/tmp", "--cwd", "/src",
    "--env", "TERM=dumb", "--env", "PATH=/bin", "--env", "TMPDIR=/tmp", program, "--"]
  command.add arguments
  let (output, code) = execCmdEx(quoteShellCommand(command),
    options = {poStdErrToStdOut}, env = nil)
  if code != 0:
    raise newException(OSError, if output.strip.len > 0: what & "\n" & output.strip else: what)

proc holdSlot(jobs: int): File =
  ## One of `jobs` host-wide compile slots, shared by every build here; held
  ## until the returned file closes.
  let slots = JudgeObjects / "slots"
  createDir(slots)
  while true:
    for index in 0 ..< jobs:
      let file = open(slots / $index, fmWrite)
      if tryLockExclusive(file): return file
      file.close()
    sleep(50)

proc compileObject(home, staged, unit: string, index: int, key: string, jobs: int): string =
  ## One unit's object from the cache, or compiled in a host slot and cached.
  let cached = JudgeObjects / "objects" / key[0 ..< 2] / key & ".o"
  if fileExists(cached):
    setLastModificationTime(cached, getTime())
    return readFile(cached)
  let slot = holdSlot(jobs)
  defer: slot.close()
  createDir(JudgeObjects)
  let work = createTempDir("work-", "", JudgeObjects)
  defer: removeDir(work)
  createDir(work / "out")
  createDir(work / "tmp")
  var arguments = @DriverFlags
  arguments.add ["-c", "-o", "/tmp/" & $index & ".o"]
  arguments.add unitLanguage(unit)
  arguments.add unit
  runInToolchain(home / "clang.wasm", home, staged, work, arguments, "compiling " & unit)
  result = readFile(work / "tmp" / $index & ".o")
  createDir(cached.parentDir)
  let partial = cached.changeFileExt("." & $getCurrentProcessId())
  writeFile(partial, result)
  moveFile(partial, cached)

proc functionNames*(blob: string): seq[(int, string)] =
  ## A module's function names, by function index, from its name section.
  var at = 0
  proc uleb(at: var int): int =
    var shift = 0
    while true:
      let byte = uint8(blob[at])
      inc at
      result = result or (int(byte and 0x7f) shl shift)
      shift += 7
      if (byte and 0x80) == 0: return
  at = 8
  while at < blob.len:
    let section = uint8(blob[at])
    inc at
    let size = uleb(at)
    let ending = at + size
    if section == 0:
      var body = at
      let length = uleb(body)
      if blob[body ..< body + length] == "name":
        at = body + length
        while at < ending:
          let kind = uint8(blob[at])
          inc at
          let subsectionSize = uleb(at)
          if kind == 1:
            let count = uleb(at)
            for _ in 0 ..< count:
              let index = uleb(at)
              let nameLength = uleb(at)
              result.add (index, blob[at ..< at + nameLength])
              at += nameLength
            return
          at += subsectionSize
    at = ending

proc judgeClang*(staged, output: string) =
  ## Build `staged` to `output` as the judge does, byte for byte, with the
  ## function names beside it in `<output stem>.names`.
  let units = sources(staged)
  if units.len == 0: raise newException(ValueError, staged & ": no .c, .cc or .cpp sources")
  let home = toolchainHome()
  let keys = objectKeys(staged, units, toolchainDigest(home))
  let jobs = buildJobs()
  # Each unit compiles in its own thread of work: a child process per unit,
  # at most `jobs` across the host through the slots.
  var objects = newSeq[string](units.len)
  var failure = ""
  var pending: seq[(int, Process)]
  let self = selfExecutable()
  for index, unit in units:
    let cached = JudgeObjects / "objects" / keys[index][0 ..< 2] / keys[index] & ".o"
    if fileExists(cached):
      setLastModificationTime(cached, getTime())
      objects[index] = readFile(cached)
    else:
      pending.add (index, startProcess(self, args = ["compile-object", staged, unit, $index,
                                                      keys[index], $jobs],
                                       options = {poStdErrToStdOut}))
  for (index, process) in pending:
    let text = process.outputStream.readAll
    if process.waitForExit != 0 and failure.len == 0: failure = text.strip
    process.close
  if failure.len > 0: raise newException(OSError, failure)
  for (index, _) in pending:
    let key = keys[index]
    objects[index] = readFile(JudgeObjects / "objects" / key[0 ..< 2] / key & ".o")
  createDir(JudgeObjects)
  let work = createTempDir("link-", "", JudgeObjects)
  defer: removeDir(work)
  createDir(work / "out")
  createDir(work / "tmp")
  var names: seq[string]
  for index, data in objects:
    writeFile(work / "tmp" / $index & ".o", data)
    names.add "/tmp/" & $index & ".o"
  var cxx = false
  for unit in units: cxx = cxx or unit.isCxx
  proc link(linked: string, strip: bool) =
    var arguments: seq[string]
    for flag in LinkFlags:
      if strip or flag != "--strip-all": arguments.add flag
    if cxx: arguments.add ["-lc++", "-lc++abi"]
    arguments.add names
    arguments.add LinkTail
    arguments.add "/out/" & linked
    runInToolchain(home / "root/bin/wasm-ld", home, staged, work, arguments, "linking")
  link("bot.wasm", strip = true)
  link("named.wasm", strip = false)
  createDir(output.parentDir)
  copyFile(work / "out/bot.wasm", output)
  var table = ""
  for (index, name) in functionNames(readFile(work / "out/named.wasm")):
    table.add $index & "\t" & name & "\n"
  writeFile(output.changeFileExt(".names"), table)
  let expired = getTime() - ObjectLifetime
  for shard in walkDirs(JudgeObjects / "objects/*"):
    for cached in walkFiles(shard / "*.o"):
      try:
        if getLastModificationTime(cached) < expired: removeFile(cached)
      except OSError: discard

proc compileObjectCommand*(staged, unit: string, index: int, key: string, jobs: int) =
  ## The child `judgeClang` runs per uncached unit.
  discard compileObject(toolchainHome(), staged, unit, index, key, jobs)
