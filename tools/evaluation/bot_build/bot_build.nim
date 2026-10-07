## `loong-build`: the build stage. `just bot-build` registers a bot's judge
## build under its GUID, or copies a registered one out; the build recipes
## (tools/commands/build.just) call the other commands.
##
##   loong-build bot-build SOURCE OUTPUT [judge|native]
##   loong-build bot-build --guid GUID OUTPUT
##   loong-build materialize SOURCE           the assembled copy a build reads
##   loong-build source-roots SOURCE...       every root a build reads, for watching
##   loong-build emit-kernels ROOT...         every Rake kernel's header, emitting missing ones
##   loong-build stage-embeds GENERATED ROOT...
##   loong-build compile-c SOURCE OUTPUT      the judge clang adapter (`_compile-bot`)
##   loong-build vector-remarks GUID PROFILE TEAM TOP

import std/[json, os, osproc, sets, strutils, tempfiles]
import ../[paths, python_json]
import compile, judge_clang, registry, remarks, settings, snapshot

proc fail(message: string) {.noreturn.} =
  stderr.writeLine message
  quit 1

proc printSelection(guid, variant, output: string) =
  echo pythonDumps(%*{"guid": guid, "variant": variant, "output": output})

proc botBuild(arguments: seq[string]) =
  if arguments.len >= 1 and arguments[0] == "--guid":
    if arguments.len != 3: fail "usage: just bot-build --guid GUID OUTPUT"
    let (guid, output) = (arguments[1], resolved(arguments[2]))
    var directory: string
    try: directory = resolveBuild(Registry, guid)[0]
    except CatchableError as error:
      fail "Registered build " & guid & " failed verification: " & error.msg
    copyArtifact(directory, "judge", output)
    printSelection(guid, "judge", output)
    return
  if arguments.len notin [2, 3]:
    fail "usage: just bot-build SOURCE OUTPUT [judge|native]\n" &
      "       just bot-build --guid GUID OUTPUT"
  let (source, output) = (resolved(arguments[0]), resolved(arguments[1]))
  let variant = if arguments.len == 3: arguments[2] else: "judge"
  if variant notin ["judge", "native"]: fail "Mode must be judge or native"
  if variant == "native":
    quit execCmd(quoteShellCommand(["just", "_build-bot", source, output, variant]))
  let registryRoot = resolved(Registry)
  createDir(registryRoot)
  createDir(Root / "build")
  let temporary = createTempDir(".pending-", "", Root / "build")
  defer: removeDir(temporary)
  let pending = temporary / "build"
  let (guid, files, settings) = stageBuild(source, "bots/common/runtime", pending)
  withBuildLock(registryRoot, guid) do ():
    if not dirExists(registryRoot / guid):
      if getEnv("LOONG_BUILD_REGISTERED_ONLY").len > 0:
        # Runners reuse registered builds; compiling is this stage's job.
        fail source & " has no registered build: run just bot-build " & source & " OUTPUT (or --fleet for many bots, on AWS workers)"
      compileBuild(pending)
    let destination = register(registryRoot, pending, guid, files, settings)
    copyArtifact(destination, variant, output)
  printSelection(guid, variant, output)

proc main() =
  let arguments = commandLineParams()
  if arguments.len == 0: fail "usage: loong-build COMMAND ...; see tools/evaluation/README.md"
  let rest = arguments[1 .. ^1]
  try:
    case arguments[0]
    of "bot-build": botBuild(rest)
    of "materialize":
      if rest.len != 1: fail "usage: loong-build materialize SOURCE"
      echo materialize(rest[0])
    of "source-roots":
      var seen = initHashSet[string]()
      for bot in rest:
        for (_, root) in sourceRoots(bot, "bots/common/runtime"):
          if not seen.containsOrIncl(root): echo root
    of "emit-kernels":
      for root in rest:
        for header in emitKernels(root, missing = true): echo header
    of "stage-embeds":
      if rest.len < 1: fail "usage: loong-build stage-embeds GENERATED ROOT..."
      discard stageEmbeds(rest[0], rest[1 .. ^1])
    of "compile-c":
      if rest.len != 2: fail "usage: loong-build compile-c SOURCE OUTPUT"
      compileBot(rest[0], rest[1], getEnv("LOONG_BUILD_RUNTIME", Root / "bots/common/runtime"))
    of "vector-remarks":
      if rest.len != 4: fail "usage: loong-build vector-remarks GUID PROFILE TEAM TOP"
      vectorRemarks(rest[0], rest[1], rest[2], parseInt(rest[3]))
    of "compile-object":
      compileObjectCommand(rest[0], rest[1], parseInt(rest[2]), rest[3], parseInt(rest[4]))
    else: fail "unknown command " & arguments[0]
  except CatchableError as error:
    fail error.msg

main()
