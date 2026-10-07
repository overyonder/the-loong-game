## Everything besides a bot's sources that decides what its build compiles
## to, which its GUID hashes with the snapshot: the judge clang's flags and
## toolchain by content, the Nim version, and `compiler_adapter_sha256` over
## what compiles a bot: the build recipes (tools/commands/build.just) and the
## modules that stage, identify and compile it, as compiled into this binary.
## Edits elsewhere leave every GUID unchanged.

import std/[json, os, osproc]
import ../paths
import ../../gamedata/sha256
import identity, judge_clang, snapshot

const AdapterSources = [
  staticRead("identity.nim"), staticRead("snapshot.nim"), staticRead("judge_clang.nim"),
  staticRead("compile.nim"), staticRead("settings.nim")]

let BuildRecipes = Root / "tools/commands/build.just"

proc nimVersion(): string =
  let (output, code) = execCmdEx("nim --version")
  if code != 0: raise newException(OSError, "nim --version failed: " & output)
  output

proc buildSettings*(source: string): JsonNode =
  var adapter = initSha256()
  adapter.update(readFile(BuildRecipes))
  for text in AdapterSources: adapter.update(text)
  %*{
    "contract": 2,
    # Diagnostics are compiled in and switched on at run time by our
    # inspection harness, so the judge artifact is also inspected.
    "diagnostics": "runtime",
    "driver_flags": DriverFlags,
    "compiler_adapter_sha256": adapter.finish.hex,
    "toolchain_sha256": toolchainDigest(toolchainHome()),
    "nim": if fileExists(source / "strategy.nim"): nimVersion() else: "",
  }

proc stageBuild*(source, runtime, pending: string): (string, JsonNode, JsonNode) =
  ## Snapshot a bot into `pending` and name its build: (GUID, files, settings).
  let files = snapshotSources(source, runtime, pending)
  let settings = buildSettings(source)
  (buildIdentity(files, settings), files, settings)

proc compileBuild*(pending: string, cwd = "") =
  ## Compile a staged build's judge artifact through Just. It plays and, with
  ## diagnostics switched on at run time, is inspected. `cwd` holds the
  ## justfile with the build recipes.
  var command = @["just", "_build-bot", pending / "source", pending / "judge.wasm", "judge"]
  let cacheRoot = getEnv("LOONG_CACHE_ROOT")
  if cacheRoot.len > 0 and fileExists(pending / "source/strategy.nim"):
    # The recipe recreates /tmp/loong-nim-build. Bind its parent so that
    # recreation and the shared lock stay on cache, without changing the
    # absolute module names Nim hashes or mounting over the host's /tmp.
    let temporaryRoot = resolved(cacheRoot) / "private/build/tmp/nim-build"
    createDir(temporaryRoot)
    command = @["bwrap", "--die-with-parent", "--bind", "/", "/", "--bind", temporaryRoot,
                "/tmp", "--"] & command
  putEnv("LOONG_BUILD_RUNTIME", pending / "runtime")
  putEnv("LOONG_BUILD_STAGED_SOURCE", pending / "judge-source")
  let process = startProcess(command[0], workingDir = cwd, args = command[1 .. ^1],
                             options = {poParentStreams, poUsePath})
  let code = process.waitForExit
  process.close
  delEnv("LOONG_BUILD_RUNTIME")
  delEnv("LOONG_BUILD_STAGED_SOURCE")
  if code != 0: raise newException(OSError, "the build of " & pending & " failed")
