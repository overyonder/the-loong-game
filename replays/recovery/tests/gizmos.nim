## gizmos.nim's validator on the main line's recorded LOONG_GIZMO lines
## (gizmos.jsonl) and on faults made from each, against the verdicts in
## gizmos.verdicts, one character a case in order: 1 accepted, 0 rejected.
##
##   just test-gizmos

import std/[json, os, strutils]
import ../gizmos

proc accepts(record: JsonNode, area: int): bool =
  try:
    validatePrimitive(record.copy, area)
    true
  except ValueError, KeyError: false

var verdicts: string
for text in lines(currentSourcePath.parentDir / "gizmos.jsonl"):
  let fixture = parseJson(text)
  let area = fixture["area"].getInt
  var line = fixture["line"].getStr
  line.removePrefix("LOONG_GIZMO ")
  let record = parseJson(line)
  proc variant(change: proc (r: JsonNode)) =
    let changed = record.copy
    change(changed)
    verdicts.add(if accepts(changed, area): '1' else: '0')
  verdicts.add(if accepts(record, area): '1' else: '0')
  variant(proc (r: JsonNode) = r.delete("label"))
  variant(proc (r: JsonNode) = r["kind"] = %"bogus")
  variant(proc (r: JsonNode) = r["version"] = %2)
  variant(proc (r: JsonNode) = r["version"] = %true)
  variant(proc (r: JsonNode) = r["unknown"] = %1)
  variant(proc (r: JsonNode) = r["label"] = %"é".repeat(512))
  variant(proc (r: JsonNode) = r["label"] = %"é".repeat(513))
  variant(proc (r: JsonNode) = r["color"] = %[1, 2, 3])
  variant(proc (r: JsonNode) = r["selected"] = %1)
  variant(proc (r: JsonNode) = r["score"] = %1e31)
  variant(proc (r: JsonNode) = r["points"] = %[area])
  let breakdown = %*[{"level": "role", "value": "feed"}, {"level": "task", "value": "eat"}]
  variant(proc (r: JsonNode) = r["breakdown"] = breakdown.copy)
  variant(proc (r: JsonNode) = r["breakdown"] = %[breakdown[0]])
  variant(proc (r: JsonNode) = r["breakdown"] = %(breakdown.getElems & breakdown.getElems))
  variant(proc (r: JsonNode) = r["breakdown"] = %*[{"level": "role", "value": ""}])
  variant(proc (r: JsonNode) = r["breakdown"] = %*[{"level": "role"}])
  let position = %*{"cell": 0, "radius": 3, "age": 2, "source": "seen", "label": "D7"}
  proc positions(entry: JsonNode): proc (r: JsonNode) =
    result = proc (r: JsonNode) =
      r["kind"] = %"positions"
      r["positions"] = %[entry]
  proc changedPosition(key: string, value: JsonNode): JsonNode =
    result = position.copy
    result[key] = value
  variant(positions(position))
  variant(positions(%*{"cell": 0}))
  variant(positions(%*{"radius": 1}))
  variant(positions(%*{"cell": area}))
  variant(positions(changedPosition("radius", %(-1))))
  variant(positions(changedPosition("age", %true)))
  variant(positions(changedPosition("why", %"")))
  let belief = %*{"cell": 0, "radius": 2, "dragon": 7, "team": "enemy", "length": 9,
    "length_exact": false, "champion": true}
  variant(positions(belief))
  variant(positions(block:
    let changed = belief.copy
    changed["team"] = %"theirs"
    changed))
  variant(positions(block:
    let changed = belief.copy
    changed["champion"] = %1
    changed))
  variant(positions(block:
    let changed = belief.copy
    changed["length"] = %(-1)
    changed))
  if record{"nodes"} != nil and record["nodes"].len > 0:
    variant(proc (r: JsonNode) = r["nodes"].add r["nodes"][0].copy)
    variant(proc (r: JsonNode) = r["nodes"][0]["active"] = %"yes")
    variant(proc (r: JsonNode) = r["nodes"][0]["parent"] = %"missing")
  if record{"rows"} != nil and record["rows"].len > 0:
    variant(proc (r: JsonNode) = r["rows"][0].add %"extra")
    variant(proc (r: JsonNode) =
      var states = newJArray()
      for _ in 0 .. r["rows"].len: states.add %"selected"
      r["row_states"] = states)
  if record.hasKey("packed_rows"):
    variant(proc (r: JsonNode) = r["packed_rows"] = %(r["packed_rows"].getStr & "!"))
  if record.hasKey("row_cells"):
    variant(proc (r: JsonNode) = r["row_cells"].elems[0] = %area)

let expected = readFile(currentSourcePath.parentDir / "gizmos.verdicts").strip
var disagreements = 0
for index in 0 ..< max(verdicts.len, expected.len):
  if index >= verdicts.len or index >= expected.len or verdicts[index] != expected[index]:
    inc disagreements
doAssert disagreements == 0, $disagreements & " of " & $expected.len & " verdicts differ"
echo "PASS ", verdicts.len, " records (", verdicts.count('1'), " accepted)"
