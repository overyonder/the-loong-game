## A registered build's GUID: a name-based UUID over its source snapshot's
## file hashes and the settings it compiled with. Part of the compiler
## adapter (`settings.nim`), so changing it changes new builds' GUIDs.

import std/[json, strutils]
# UUIDv5 requires SHA-1. Keep the pinned Nim standard implementation and the
# registered identity algorithm.
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
import ../python_json
import ../../gamedata/sha256

proc uuid5(name: string): string =
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
  ## The GUID of a snapshot's `files` (path to SHA-256) and `settings`.
  uuid5("loong-build-v1:" & sha256Hex(pythonDumps(%*[files, settings], sortKeys = true)))

proc opaqueIdentity*(wasmSha256: string): string =
  ## The GUID of an entry registered from a judge wasm alone, as the foil's
  ## builds were before it built from source: named by the wasm's hash.
  uuid5("loong-build-opaque-v1:" & wasmSha256)
