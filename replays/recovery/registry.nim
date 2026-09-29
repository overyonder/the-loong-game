## A registered build's directory, checked as harness/
## build_registry.py's resolve_build checks it: the manifest's identity names
## its GUID, and every file the manifest lists has the recorded SHA-256.

import std/[algorithm, json, os, sequtils, sha1, strutils, unicode]
import ../../gamedata/sha256

proc pythonDumps(node: JsonNode, output: var string) =
  ## Python's json.dumps(value, sort_keys=True) with its default separators
  ## and ASCII escaping, which the build identity hashes.
  case node.kind
  of JNull: output.add "null"
  of JBool: output.add(if node.getBool: "true" else: "false")
  of JInt: output.add $node.getBiggestInt
  of JFloat:
    let value = node.getFloat
    output.add(if value == float(int64(value)) and abs(value) < 1e16: $int64(value) & ".0" else: $value)
  of JString:
    output.add '"'
    for rune in node.getStr.runes:
      let code = int(rune)
      case code
      of 0x22: output.add "\\\""
      of 0x5c: output.add "\\\\"
      of 0x0a: output.add "\\n"
      of 0x0d: output.add "\\r"
      of 0x09: output.add "\\t"
      of 0x08: output.add "\\b"
      of 0x0c: output.add "\\f"
      else:
        if code < 0x20 or code > 0x7e:
          if code > 0xffff:
            let reduced = code - 0x10000
            output.add "\\u" & toHex(0xd800 + (reduced shr 10), 4).toLowerAscii
            output.add "\\u" & toHex(0xdc00 + (reduced and 0x3ff), 4).toLowerAscii
          else: output.add "\\u" & toHex(code, 4).toLowerAscii
        else: output.add char(code)
    output.add '"'
  of JArray:
    output.add '['
    for index, item in node.elems:
      if index > 0: output.add ", "
      pythonDumps(item, output)
    output.add ']'
  of JObject:
    output.add '{'
    var keys: seq[string]
    for key in node.keys: keys.add key
    keys.sort   # UTF-8 byte order is code point order, as Python sorts
    for index, key in keys:
      if index > 0: output.add ", "
      pythonDumps(%key, output)
      output.add ": "
      pythonDumps(node[key], output)
    output.add '}'

proc uuid5*(name: string): string =
  ## uuid.uuid5(uuid.NAMESPACE_URL, name), in canonical form.
  const namespace = [0x6b'u8, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4,
    0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
  var input = newString(namespace.len)
  for index, value in namespace: input[index] = char(value)
  input.add name
  let digest = Sha1Digest(secureHash(input))
  var bytes: array[16, uint8]
  for index in 0 ..< 16: bytes[index] = digest[index]
  bytes[6] = (bytes[6] and 0x0f) or 0x50
  bytes[8] = (bytes[8] and 0x3f) or 0x80
  var hex = ""
  for value in bytes: hex.add toHex(value, 2).toLowerAscii
  hex[0 ..< 8] & "-" & hex[8 ..< 12] & "-" & hex[12 ..< 16] & "-" & hex[16 ..< 20] & "-" & hex[20 ..< 32]

proc buildIdentity*(files, settings: JsonNode): string =
  var text = ""
  pythonDumps(%*[files, settings], text)
  uuid5("loong-build-v1:" & sha256Hex(text))

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
  if buildIdentity(manifest["files"], manifest["settings"]) != guid:
    raise newException(ValueError, "Build manifest content identity mismatch")
  var expected: seq[(string, string)]
  for section in ["files", "compiled_sources", "extra_artifacts"]:
    if manifest{section} != nil:
      for name, digest in manifest[section]: expected.add (name, digest.getStr)
  for variant, digest in manifest["artifacts"]: expected.add (variant & ".wasm", digest.getStr)
  let root = directory.expandFilename
  for (name, digest) in expected:
    let path = directory / name
    if symlinkExists(path) or not path.expandFilename.startsWith(root & "/"):
      raise newException(ValueError, "Build manifest path escapes its snapshot")
    if sha256Hex(readFile(path)) != digest:
      raise newException(ValueError, "Build snapshot hash mismatch: " & name)
  (directory, manifest)
