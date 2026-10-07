## Immutable local builds, addressed by GUID, that our records name: each
## `Registry/GUID/` holds the source snapshot, the judge artifact, the C it
## was compiled from (`judge-source/`) and `manifest.json` with every file's
## SHA-256. `resolveBuild` verifies an entry before anything uses it.

import std/[json, os, strutils, tempfiles]
import ../[locks, paths, python_json]
import ../../gamedata/sha256
import identity

proc canonicalGuid(guid: string): bool =
  ## Whether `guid` is a UUID in lowercase hyphenated form.
  if guid.len != 36: return false
  for index, character in guid:
    if index in [8, 13, 18, 23]:
      if character != '-': return false
    elif character notin HexDigits or character in {'A' .. 'F'}: return false
  true

proc resolveBuild*(registry, guid: string): (string, JsonNode) =
  ## The build's directory and manifest; raises where its files don't match.
  if not canonicalGuid(guid): raise newException(ValueError, "Noncanonical build GUID")
  let directory = registry / guid
  let manifest = parseFile(directory / "manifest.json")
  if manifest{"version"}.getInt != 1 or manifest{"guid"}.getStr != guid:
    raise newException(ValueError, "Build manifest identity/version mismatch")
  if manifest{"opaque"}.getBool:
    let judge = sha256File(directory / "judge.wasm")
    if judge != manifest["artifacts"]["judge"].getStr or opaqueIdentity(judge) != guid:
      raise newException(ValueError, "Opaque build hash mismatch")
    return (directory, manifest)
  if buildIdentity(manifest["files"], manifest["settings"]) != guid:
    raise newException(ValueError, "Build manifest content identity mismatch")
  var expected: seq[(string, string)]
  for section in ["files", "compiled_sources", "extra_artifacts"]:
    if manifest{section} != nil:
      for name, digest in manifest[section]: expected.add (name, digest.getStr)
  for variant, digest in manifest["artifacts"]: expected.add (variant & ".wasm", digest.getStr)
  let root = resolved(directory)
  for (name, digest) in expected:
    let path = directory / name
    if symlinkExists(path) or not resolved(path).isRelativeTo(root):
      raise newException(ValueError, "Build manifest path escapes its snapshot")
    if sha256File(path) != digest:
      raise newException(ValueError, "Build snapshot hash mismatch: " & name)
  (directory, manifest)

proc withBuildLock*(registry, guid: string, body: proc ()) =
  ## Hold a build's registry lock, so one process compiles or registers it.
  withLock(registry / ("." & guid & ".lock"), body)

proc finishRegistration(directory, guid: string, files, settings: JsonNode) =
  var compiled = newJObject()
  for entry in walkTree(directory / "judge-source"):
    if entry.file:
      compiled["judge-source/" & entry.relative] = %sha256File(directory / "judge-source" / entry.relative)
  let manifest = %*{
    "version": 1,
    "guid": guid,
    "files": files,
    "settings": settings,
    "artifacts": {"judge": sha256File(directory / "judge.wasm")},
    "compiled_sources": compiled,
  }
  writeFile(directory / "manifest.json", pythonDumps(manifest, indent = 2) & "\n")

proc copyTree(source, destination: string) =
  ## Copy a directory, keeping symbolic links as links.
  createDir(destination)
  for kind, path in walkDir(source, relative = true):
    case kind
    of pcDir: copyTree(source / path, destination / path)
    of pcLinkToFile, pcLinkToDir: createSymlink(expandSymlink(source / path), destination / path)
    of pcFile: copyFileWithPermissions(source / path, destination / path)

proc register*(registry, pending, guid: string, files, settings: JsonNode): string =
  ## Move a compiled build into the registry under its GUID; call holding
  ## `withBuildLock`.
  result = registry / guid
  if not dirExists(result):
    finishRegistration(pending, guid, files, settings)
    # Cache and retained storage are different subvolumes. Publish a complete
    # verified copy within the registry so readers never see a partial GUID.
    let temporary = createTempDir(".publishing-", "", registry)
    defer: removeDir(temporary)
    copyTree(pending, temporary / guid)
    discard resolveBuild(temporary, guid)
    moveDir(temporary / guid, result)
  discard resolveBuild(registry, guid)

proc copyArtifact*(directory, variant, output: string) =
  ## A registered artifact at `output`, with its function names and its
  ## metadata naming the build beside it.
  createDir(output.parentDir)
  copyFileWithPermissions(directory / variant & ".wasm", output)
  setLastModificationTime(output, getLastModificationTime(directory / variant & ".wasm"))
  let names = directory / variant & ".names"
  if fileExists(names):
    copyFileWithPermissions(names, output.changeFileExt(".names"))
    setLastModificationTime(output.changeFileExt(".names"), getLastModificationTime(names))
  var metadata = parseFile(directory / variant & ".json")
  metadata["guid"] = %directory.extractFilename
  metadata["variant"] = %variant
  metadata["registry"] = %resolved(directory.parentDir)
  writeFile(output.changeFileExt(".json"), pythonDumps(metadata, indent = 2) & "\n")
