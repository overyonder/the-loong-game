## Semantic check against independently specified little-endian memory. The
## inline wrappers have nonzero offsets and two distinct elements; tables,
## cell/edge maps and whole-object decoding must read the same facts.

import std/[base64, json]
from ../state import nil

let schema = %*{
  "roots": [{"name": "fixture"}],
  "types": [
    {"name": "Source", "kind": "uint", "size": 1},
    {"name": "bool", "kind": "bool", "size": 1},
    {"name": "int16", "kind": "int", "size": 2},
    {"name": "int64", "kind": "int", "size": 8},
    {"name": "SpawnTimer", "kind": "object", "size": 40, "fields": [
      {"name": "spawns", "offset": 0, "type": 1},
      {"name": "due", "offset": 8, "type": 3},
      {"name": "gapLow", "offset": 16, "type": 3},
      {"name": "gapHigh", "offset": 24, "type": 3},
      {"name": "countdownHigh", "offset": 32, "type": 3}]},
    {"name": "Sourced[SpawnTimer]", "kind": "object", "size": 48, "fields": [
      {"name": "value", "offset": 0, "type": 4},
      {"name": "source", "offset": 40, "type": 0},
      {"name": "round", "offset": 42, "type": 2}]},
    {"name": "Sourced[bool]", "kind": "object", "size": 4, "fields": [
      {"name": "value", "offset": 0, "type": 1},
      {"name": "source", "offset": 1, "type": 0},
      {"name": "round", "offset": 2, "type": 2}]},
    {"name": "Nested", "kind": "object", "size": 64, "fields": [
      {"name": "timer", "offset": 8, "type": 5},
      {"name": "pearl", "offset": 56, "type": 6}]},
    {"name": "Cell", "kind": "object", "size": 96, "fields": [
      {"name": "nest", "offset": 24, "type": 7}]},
    {"name": "seq[Cell]", "kind": "seq", "size": 8, "element": 8},
    {"name": "Fixture", "kind": "object", "size": 32, "fields": [
      {"name": "rows", "offset": 4, "type": 9},
      {"name": "cells", "offset": 12, "type": 9, "draw": "cells"},
      {"name": "edges", "offset": 20, "type": 9, "draw": "edges"}]}
  ]}

var bytes = newString(192)
for index in 0 ..< bytes.len: bytes[index] = char(0x5a)
proc storeWord(offset, size: int, value: int64) =
  let bits = cast[uint64](value)
  for index in 0 ..< size: bytes[offset + index] = char((bits shr (8 * index)) and 255)

# Element zero: nested timer begins at byte 32; its due field at byte 40.
storeWord(32, 1, 1)
storeWord(40, 8, 25)
storeWord(48, 8, 5)
storeWord(56, 8, 9)
storeWord(64, 8, 7)
storeWord(72, 1, 1)
storeWord(74, 2, 3)
storeWord(80, 1, 1)
storeWord(81, 1, 2)
storeWord(82, 2, -1)
# Element one has a different stride, unknown due time and absent pearl.
storeWord(128, 1, 0)
storeWord(136, 8, -1)
storeWord(144, 8, 0)
storeWord(152, 8, 12)
storeWord(160, 8, 0)
storeWord(168, 1, 2)
storeWord(170, 2, 9)
storeWord(176, 1, 0)
storeWord(177, 1, 1)
storeWord(178, 2, 8)

var image: state.Image
state.update(image, %*{"schema": $schema,
  "regions": [[1000, 32, 10, 1, 0], [2000, 192, 8, 2, 1004],
    [3000, 192, 8, 2, 1012], [4000, 192, 8, 2, 1020]],
  "changes": [[1000, 0, encode(newString(32))], [2000, 0, encode(bytes)],
    [3000, 0, encode(bytes)], [4000, 0, encode(bytes)]]})

let decoded = state.decode(image)["fixture"]["rows"]
doAssert decoded[0]["nest"]["timer"]["value"]["due"].getInt == 25
doAssert decoded[1]["nest"]["timer"]["value"]["due"].getInt == -1
doAssert decoded[0]["nest"]["pearl"]["round"].getInt == -1
doAssert decoded[1]["nest"]["pearl"]["value"].getBool == false

let records = state.records(image, 2)
proc tableValue(identifier, column: string, row: int): string =
  for record in records:
    if record{"id"}.getStr != identifier: continue
    for index, name in record["columns"].getElems:
      if name.getStr == column: return record["rows"][row][index].getStr
  raise newException(ValueError, "missing table field: " & identifier & "." & column)

for (identifier, prefix) in [("state.fixture.rows", ""), ("state.fixture.cells", "cells.")]:
  doAssert tableValue(identifier, prefix & "nest.timer.value.due", 0) == "25"
  doAssert tableValue(identifier, prefix & "nest.timer.value.due", 1) == "-1"
  doAssert tableValue(identifier, prefix & "nest.timer.round", 0) == "3"
  doAssert tableValue(identifier, prefix & "nest.pearl.round", 0) == "-1"
  doAssert tableValue(identifier, prefix & "nest.pearl.value", 1) == "false"
doAssert tableValue("state.fixture.edges", "edges.nest.timer.value.due N", 0) == "25"
doAssert tableValue("state.fixture.edges", "edges.nest.timer.value.due W", 0) == "-1"
doAssert tableValue("state.fixture.edges", "edges.nest.pearl.round W", 0) == "8"
echo "PASS nested nonzero offsets: sequence, board, edge and whole-object views"
