## The public gizmo records of replays/viewer/diagnostics.md, validated:
## a record outside the contract is rejected rather than interpreted, and the
## producer's grouping is resolved without reading its policy. A rejected
## record raises ValueError. This is the contract's only validator; `just
## test-gizmos` checks it on recorded records and faults made from them.

import std/[base64, json, math, sequtils, sets, strutils, tables, unicode]

const
  MaxGizmos* = 1024
  BuildPrefix* = "LOONG_BUILD "
  GizmoPrefix* = "LOONG_GIZMO "
  Kinds = ["line", "target", "path", "search", "map", "candidate", "action", "state", "table",
    "calculation", "positions"]
  Allowed = ["version", "id", "parent", "slot", "positions", "layout", "row_states", "row_ids", "expression",
    "operands", "result", "consensus", "sonar", "kind", "label", "objective", "reason", "color",
    "points", "cells", "edges", "score", "selected", "nodes", "links", "columns", "rows",
    "row_cells", "retain", "packed_rows", "truth_columns", "packed_columns", "cell_range",
    "column_formats", "column_encodings", "display_column", "evaluated_column",
    "display_format", "display_position", "display_overlay", "breakdown"]
  TruthQuantities = ["", "spawn_due", "spawn_min", "spawn_max", "spawn_mean", "edges", "pearl"]
  RowStates = ["selected", "eligible", "ineligible", "not_evaluated"]
  ListKeys = ["points", "cells", "edges", "nodes", "links", "columns", "rows", "row_cells",
    "row_states", "operands", "positions"]

template fail(message: string) = raise newException(ValueError, message)

proc has(record: JsonNode, key: string): bool = record.kind == JObject and record.hasKey(key)

proc truthy*(node: JsonNode): bool =
  ## Python truthiness of a JSON value.
  if node == nil: return false
  case node.kind
  of JNull: false
  of JBool: node.getBool
  of JInt: node.getBiggestInt != 0
  of JFloat: node.getFloat != 0
  of JString: node.getStr.len > 0
  of JArray: node.len > 0
  of JObject: node.len > 0

proc keysWithin(node: JsonNode, allowed: openArray[string]): bool =
  if node.kind != JObject: return false
  for key in node.keys:
    if key notin allowed: return false
  true

proc label(value: JsonNode) =
  if value == nil or value.kind != JString or value.getStr.runeLen > 512:
    fail "Diagnostic labels must be strings of at most 512 characters"

proc number(value: JsonNode) =
  if value == nil or value.kind notin {JInt, JFloat}: fail "Diagnostic numbers must be finite and fit the display"
  let x = if value.kind == JInt: float(value.getBiggestInt) else: value.getFloat
  if x.classify in {fcNan, fcInf, fcNegInf} or abs(x) > 1e30:
    fail "Diagnostic numbers must be finite and fit the display"

proc numberValue(value: JsonNode): float =
  if value.kind == JInt: float(value.getBiggestInt) else: value.getFloat

proc cell(value: JsonNode, area: int) =
  if value == nil or value.kind != JInt or value.getBiggestInt < 0 or value.getBiggestInt >= area:
    fail "Diagnostic cell is outside the board"

proc color(value: JsonNode) =
  if value == nil or value.kind != JArray or value.len != 4: fail "Diagnostic color must be four RGBA bytes"
  for item in value:
    if item.kind != JInt or item.getBiggestInt < 0 or item.getBiggestInt > 255:
      fail "Diagnostic color must be four RGBA bytes"

proc field(record: JsonNode, key: string): JsonNode =
  ## `record[key]`, failing as Python's KeyError does.
  if record.kind != JObject or not record.hasKey(key): fail "missing " & key
  record[key]

proc listOr(record: JsonNode, key: string): seq[JsonNode] =
  if record.has(key): record[key].elems else: @[]

proc zigzag(bytes: string, onValue: proc (value: int64)) =
  ## Zigzag varints end to end, as the packed table transports write them.
  var value, shift = 0'i64
  for character in bytes:
    let byte = int64(ord(character))
    value = value or ((byte and 127) shl shift)
    if (byte and 128) != 0:
      shift += 7
      if shift > 56: fail "Column integer overflow"
    else:
      onValue((value shr 1) xor -(value and 1))
      (value, shift) = (0'i64, 0'i64)
  if shift != 0: fail "Column row count mismatch"

proc strictBase64(text: string): string =
  ## base64 with validate=True: only the alphabet and correct padding.
  if text.len mod 4 != 0: fail "Invalid base64"
  for index, character in text:
    if character notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '+', '/', '='}: fail "Invalid base64"
    if character == '=' and index < text.len - 2: fail "Invalid base64"
  try: decode(text) except ValueError: fail "Invalid base64"

proc pyFloatText(value: float32): string =
  ## Python's str() of a float32 widened to float64.
  let wide = float64(value)
  if wide == trunc(wide) and abs(wide) < 1e16: $int64(wide) & ".0" else: $wide

proc parseEdges(value: string, area: int) =
  ## Four N/E/S/W edge claims, as mental_map.parse_edges reads them.
  let tokens = value.split(' ')
  if tokens.len != 4: fail "Edge claims need four N/E/S/W tokens"
  for direction, token in tokens:
    if token.len < 2 or token[0] != "NESW"[direction]: fail "Invalid edge claim"
    let code = token[1 .. ^1]
    if code in ["?", "s", ".", "w", "c"]: continue
    if code[0] != 'p': fail "Invalid edge claim"
    var rest = code[1 .. ^1]
    let arrow = rest.find('>')
    var portal = if arrow >= 0: rest[0 ..< arrow] else: rest
    let landing = if arrow >= 0: rest[arrow + 1 .. ^1] else: ""
    if portal.startsWith('-'): portal = portal[1 .. ^1]
    if not portal.allCharsInSet(Digits): fail "Invalid edge claim"
    if arrow >= 0:
      if landing.len == 0 or not landing.allCharsInSet(Digits): fail "Invalid edge claim"
      if parseBiggestInt(landing) >= area: fail "Portal landing outside the board"

proc validatePrimitive*(record: JsonNode, area: int) =
  ## Reject unsupported or malformed records; decodes packed tables in place.
  if record.kind != JObject or not record.has("version") or record["version"].kind != JInt or
      record["version"].getBiggestInt != 1 or not record.has("kind") or
      record["kind"].kind != JString or record["kind"].getStr notin Kinds:
    fail "Unsupported diagnostic version or primitive"
  if not record.keysWithin(Allowed): fail "Unknown diagnostic fields"
  let kind = record["kind"].getStr
  if kind == "map" and record.has("display_overlay"):
    if record["display_overlay"] notin [%"markers", %"mental"]: fail "Unsupported map overlay"
  for key in ["label", "objective", "reason", "id", "parent", "expression"]:
    if record.has(key): label(record[key])
  if record.has("slot") and (record["slot"] notin [%"brain", %"memory"] or truthy(record{"parent"})):
    fail "Display slot must be brain or memory on a root gizmo"
  if not truthy(record{"label"}): fail "Every primitive needs a label"
  if record.has("breakdown"):
    # One or two level/value labels, on the Brain root only, each with how
    # the viewer draws it: an RGB or RGBA colour, an icon and a pattern.
    let entries = record["breakdown"]
    var valid = record{"slot"} == %"brain" and entries.kind == JArray and entries.len in 1 .. 2
    if valid:
      for entry in entries:
        valid = valid and entry.kind == JObject and entry.has("level") and
          entry.has("value") and truthy(entry["level"]) and truthy(entry["value"])
        if valid:
          for key, value in entry:
            valid = valid and key in ["level", "value", "color", "icon", "pattern"]
    if not valid: fail "Breakdown must be one or two level/value labels on the Brain root"
    for entry in entries:
      label(entry["level"])
      label(entry["value"])
      for key in ["icon", "pattern"]:
        if entry.has(key): label(entry[key])
      if entry.has("color"):
        let shade = entry["color"]
        if shade.kind != JArray or shade.len notin 3 .. 4:
          fail "Breakdown color must be three RGB or four RGBA bytes"
        for item in shade:
          if item.kind != JInt or item.getBiggestInt notin 0 .. 255:
            fail "Breakdown color must be three RGB or four RGBA bytes"
  if record.has("color"): color(record["color"])
  if record.has("score"): number(record["score"])
  if record.has("selected") and record["selected"].kind != JBool: fail "Selected must be a boolean"
  for key in ListKeys:
    if record.has(key) and (record[key].kind != JArray or record[key].len > 4096):
      fail "Diagnostic collections must contain at most 4096 entries"
  for point in record.listOr("points"): cell(point, area)
  for entry in record.listOr("positions"):
    if not entry.keysWithin(["cell", "radius", "age", "cells", "source", "label", "color", "dragon",
        "team", "length", "length_exact", "champion"]):
      fail "Invalid position record"
    cell(entry.field("cell"), area)
    if entry.has("cells"):
      if entry["cells"].kind != JArray or entry["cells"].len > area:
        fail "Position cells list at most every cell once"
      for possible in entry["cells"]: cell(possible, area)
    for key in ["radius", "age", "length"]:
      if entry.has(key) and (entry[key].kind != JInt or entry[key].getBiggestInt notin 0'i64 .. 4096'i64):
        fail "Position radius, age and length are whole numbers to 4096"
    # The engine numbers every dragon a game creates, so a game of many
    # splits passes 4096.
    if entry.has("dragon") and (entry["dragon"].kind != JInt or
        entry["dragon"].getBiggestInt notin 0'i64 .. int64(high(int32))):
      fail "Position dragon is a whole number"
    if entry.has("team") and entry["team"] notin [%"ours", %"enemy"]:
      fail "Position team is ours or enemy"
    for key in ["length_exact", "champion"]:
      if entry.has(key) and entry[key].kind != JBool: fail "Position " & key & " is a boolean"
    for key in ["source", "label"]:
      if entry.has(key): label(entry[key])
    if entry.has("color"): color(entry["color"])
  for entry in record.listOr("cells"):
    if not entry.keysWithin(["cell", "value", "label", "color"]): fail "Invalid diagnostic cell record"
    cell(entry.field("cell"), area)
    if entry.has("value"): number(entry["value"])
    if entry.has("label"): label(entry["label"])
    if entry.has("color"): color(entry["color"])
  for edge in record.listOr("edges"):
    if not edge.keysWithin(["cell", "direction", "label", "color"]): fail "Invalid diagnostic edge record"
    cell(edge.field("cell"), area)
    let direction = edge.field("direction")
    if direction.kind != JInt or direction.getBiggestInt notin 0'i64 .. 3'i64:
      fail "Edge direction must be N/E/S/W as 0/1/2/3"
    if edge.has("label"): label(edge["label"])
    if edge.has("color"): color(edge["color"])
  var nodeIds: HashSet[string]
  let tree = record{"layout"} == %"tree"
  for node in record.listOr("nodes"):
    if not node.keysWithin(["id", "label", "x", "y", "active", "parent", "eligible", "score",
        "objective", "reason"]):
      fail "Invalid state node"
    label(node.field("id"))
    label(node.field("label"))
    for key in ["parent", "objective", "reason"]:
      if node.has(key): label(node[key])
    if node.has("eligible") and node["eligible"].kind != JBool:
      fail "State eligibility must be boolean or absent"
    if node.has("score"): number(node["score"])
    for coordinate in ["x", "y"]:
      if tree and not node.has(coordinate): continue
      number(node.field(coordinate))
      let x = numberValue(node[coordinate])
      if x < 0 or x > 1: fail "State node positions use normalized coordinates"
    if node["id"].getStr in nodeIds or (node.has("active") and node["active"].kind != JBool):
      fail "Duplicate state node or invalid active flag"
    nodeIds.incl node["id"].getStr
  for link in record.listOr("links"):
    if not link.keysWithin(["from", "to", "label", "active"]): fail "Invalid state link"
    let (source, target) = (link.field("from"), link.field("to"))
    if source.kind != JString or target.kind != JString or source.getStr notin nodeIds or
        target.getStr notin nodeIds:
      fail "State link references an unknown node"
    label(if link.has("label"): link["label"] else: %"")
    if link.has("active") and link["active"].kind != JBool: fail "Invalid active link flag"
  if record.has("layout") and (kind != "state" or record["layout"] notin [%"tree", %"graph"]):
    fail "Only state trees support automatic layout"
  var parents: OrderedTable[string, string]
  for node in record.listOr("nodes"):
    parents[node["id"].getStr] = (if node.has("parent"): node["parent"].getStr else: "")
  for start in parents.keys:
    var identifier = start
    var visited: HashSet[string]
    while identifier.len > 0:
      if identifier notin parents or identifier in visited:
        fail "State hierarchy has an unknown parent or cycle"
      visited.incl identifier
      if visited.len > 128: fail "Hierarchy exceeds 128 levels"
      identifier = parents[identifier]
  if record.has("row_ids"):
    let ids = record["row_ids"]
    if kind != "table" or ids.kind != JArray or ids.len != record.listOr("rows").len or truthy(record{"retain"}):
      fail "Row IDs require a complete table and must match rows"
    var seen: HashSet[string]
    for identifier in ids:
      label(identifier)
      if identifier.getStr.len == 0: fail "Row IDs must be nonempty"
      seen.incl identifier.getStr
    if seen.len != ids.len: fail "Duplicate row ID"
  if kind == "calculation":
    label(if record.has("expression"): record["expression"] else: %"")
    if not truthy(record{"expression"}): fail "Calculation requires its executable expression"
    var names: HashSet[string]
    for operand in record.listOr("operands"):
      if operand.kind != JObject or operand.len != 2 or not operand.has("name") or not operand.has("value"):
        fail "Calculation operands require name and value"
      label(operand["name"])
      number(operand["value"])
      if operand["name"].getStr in names: fail "Duplicate calculation operand"
      names.incl operand["name"].getStr
    if record.has("result"): number(record["result"])
  elif record.has("expression") or record.has("operands") or record.has("result"):
    fail "Expression fields require calculation kind"
  if record.has("row_states"):
    if kind != "table": fail "Invalid table row outcome"
    for state in record["row_states"]:
      if state.kind != JString or state.getStr notin RowStates: fail "Invalid table row outcome"
  if kind == "line" and record.listOr("points").len != 2: fail "Line requires two points"
  if kind == "target" and record.listOr("points").len != 1: fail "Target requires one point"
  if kind == "candidate" and (not record.has("score") or not truthy(record{"objective"})):
    fail "Candidate requires an explicit score and objective"
  if record.has("retain") and (record["retain"].kind != JBool or kind notin ["table", "map"]):
    fail "Only maps and cell tables support explicit retention"
  if record.has("packed_columns"):
    let columns = record.listOr("columns")
    let packedColumns = record["packed_columns"]
    record.delete("packed_columns")
    let range = record.field("cell_range")
    record.delete("cell_range")
    if range.kind != JArray or range.len != 2: fail "Invalid packed cell range"
    let (start, count) = (range[0], range[1])
    if kind != "table" or record.has("rows") or record.has("packed_rows") or
        packedColumns.kind != JArray or packedColumns.len != columns.len:
      fail "Invalid packed column table"
    if start.kind != JInt or count.kind != JInt or start.getBiggestInt < 0 or
        start.getBiggestInt >= area or count.getBiggestInt < 0 or
        count.getBiggestInt > area - start.getBiggestInt:
      fail "Invalid packed cell range"
    var formats, encodings: seq[string]
    if record.has("column_formats"):
      for item in record["column_formats"]: formats.add(if item.kind == JString: item.getStr else: "?")
      record.delete("column_formats")
    else:
      for _ in columns: formats.add "int"
    if formats.len != columns.len or formats.anyIt(it notin ["int", "f32"]): fail "Invalid packed column formats"
    if record.has("column_encodings"):
      for item in record["column_encodings"]: encodings.add(if item.kind == JString: item.getStr else: "?")
      record.delete("column_encodings")
    else:
      for _ in columns: encodings.add "rle"
    if encodings.len != columns.len or encodings.anyIt(it notin ["raw", "rle"]):
      fail "Invalid packed column encodings"
    let rows = int(count.getBiggestInt)
    var decoded: seq[seq[string]]
    for index, encoded in packedColumns.elems:
      if encoded.kind != JString: fail "Invalid base64"
      let runs = strictBase64(encoded.getStr)
      var data: string
      if encodings[index] == "raw":
        if runs.len > rows * 9: fail "Column bytes exceed its row count"
        data = runs
      else:
        if runs.len mod 2 != 0 or runs.len > 1048576: fail "Invalid column byte runs"
        for at in countup(0, runs.len - 1, 2):
          let repeat = ord(runs[at])
          if repeat == 0 or data.len + repeat > rows * 9: fail "Column expansion exceeds its row count"
          for _ in 0 ..< repeat: data.add runs[at + 1]
      var values: seq[string]
      var previous = 0'i64
      let floats = formats[index] == "f32"
      zigzag(data, proc (delta: int64) =
        previous += delta
        if floats:
          if previous < 0 or previous >= 1'i64 shl 32: fail "Invalid float bits"
          let value = cast[float32](uint32(previous))
          number(%float64(value))
          values.add pyFloatText(value)
        else: values.add $previous)
      if values.len != rows: fail "Column row count mismatch"
      decoded.add values
    var rowCells = newJArray()
    for position in 0 ..< rows: rowCells.add %(start.getBiggestInt + position)
    record["row_cells"] = rowCells
    var table = newJArray()
    if decoded.len > 0:
      for row in 0 ..< rows:
        var line = newJArray()
        for column in decoded: line.add %column[row]
        table.add line
    record["rows"] = table
  if record.has("packed_rows"):
    if kind != "table" or record.has("rows"): fail "Packed rows are an alternative table transport"
    let packed = record["packed_rows"]
    record.delete("packed_rows")
    if packed.kind != JString or packed.getStr.len > 1048576: fail "Invalid packed table"
    var values: seq[string]
    zigzag(strictBase64(packed.getStr), proc (value: int64) = values.add $value)
    let width = record.listOr("columns").len
    if width == 0 or values.len mod width != 0 or values.len > 4096 * width:
      fail "Packed table row shape mismatch"
    var table = newJArray()
    for at in countup(0, values.len - 1, width):
      var line = newJArray()
      for value in values[at ..< at + width]: line.add %value
      table.add line
    record["rows"] = table
  if kind == "table":
    let rows = record.listOr("rows")
    if record.has("row_states") and record["row_states"].len != rows.len:
      fail "Row outcomes must match table rows"
    let columns = record.listOr("columns")
    if record.has("truth_columns"):
      let truth = record["truth_columns"]
      if truth.kind != JArray or (truth.len > 0 and truth.len != columns.len):
        fail "Truth comparison columns must match the table"
      var edges, pearls = 0
      for quantity in truth:
        if quantity.kind != JString or quantity.getStr notin TruthQuantities:
          fail "Unknown or repeated replay truth quantity"
        if quantity.getStr == "edges": inc edges
        if quantity.getStr == "pearl": inc pearls
      if edges > 1 or pearls > 1: fail "Unknown or repeated replay truth quantity"
    if columns.len == 0 or columns.len > 64: fail "Table requires 1..64 named columns"
    for column in columns: label(column)
    for row in rows:
      if row.kind != JArray or row.len != columns.len: fail "Table row width disagrees with columns"
      for value in row:
        if value.kind != JString or value.getStr.runeLen > 16384:
          fail "Table cells must be strings of at most 16384 characters"
    for (key, choices) in [("display_format", @["number", "round_delta"]),
        ("display_position", @["top_left", "top_right"]), ("display_overlay", @["search", "timers"])]:
      if record.has(key) and (record[key].kind != JString or record[key].getStr notin choices):
        fail "Unsupported table " & key
    for key in ["display_column", "evaluated_column"]:
      if record.has(key) and (record[key].kind != JInt or record[key].getBiggestInt < 0 or
          record[key].getBiggestInt >= columns.len):
        fail "Table display column is outside its schema"
    if record.has("row_cells"):
      let cells = record["row_cells"]
      var unique: HashSet[string]
      for position in cells: unique.incl $position
      if cells.len != rows.len or unique.len != cells.len: fail "Cell table needs one unique cell per row"
      for position in cells: cell(position, area)
    if truthy(record{"retain"}) and not record.has("row_cells"): fail "Retained table requires row_cells"
    # Mental-map claims (mental_map.validate_claims).
    let truth = record.listOr("truth_columns")
    if truth.anyIt(it.getStr in ["edges", "pearl"]) and not record.has("row_cells"):
      fail "Mental map comparison requires row_cells"
    for index, quantity in truth:
      if quantity.getStr == "edges":
        for row in rows: parseEdges(row[index].getStr, area)
  if record.has("consensus"):
    # consensus.validate_annotations
    let annotations = record["consensus"]
    if kind != "table" or annotations.kind != JArray or annotations.len > 64:
      fail "Consensus requires a bounded table annotation list"
    let columns = record.listOr("columns")
    for annotation in annotations:
      if not annotation.keysWithin(["category", "column", "known_column", "minimum", "scope", "direction"]):
        fail "Invalid consensus annotation"
      let category = annotation{"category"}
      if category == nil or category.kind != JString or category.getStr.runeLen notin 1 .. 80:
        fail "Invalid consensus category"
      for key in ["column", "known_column"]:
        let value = annotation{key}
        if value == nil or value.kind != JInt or value.getBiggestInt < 0 or value.getBiggestInt >= columns.len:
          fail "Consensus column outside table"
      if annotation{"minimum"} == nil or annotation["minimum"].kind != JInt:
        fail "Consensus needs an explicit knowledge threshold"
      let scope = annotation{"scope"}
      if scope notin [%"singleton", %"cell", %"edge", %"directed_edge"]: fail "Invalid consensus key scope"
      if scope == %"singleton":
        if record.field("rows").len != 1: fail "Singleton consensus requires exactly one row"
      elif not record.has("row_cells"): fail "Spatial consensus requires explicit cells"
      if scope in [%"edge", %"directed_edge"]:
        let direction = annotation{"direction"}
        if direction == nil or direction.kind != JInt or direction.getBiggestInt notin 0'i64 .. 3'i64:
          fail "Consensus edge needs a direction"
      for row in record.field("rows"):
        let marker = row[int(annotation["known_column"].getBiggestInt)].getStr.strip
        let digits = if marker.startsWith('-') or marker.startsWith('+'): marker[1 .. ^1] else: marker
        if digits.len == 0 or not digits.replace("_", "").allCharsInSet(Digits) or
            digits.startsWith('_') or digits.endsWith('_') or "__" in digits:
          fail "Consensus knowledge marker must be an integer"
  if record.has("sonar"):
    # radio.validate_sonar
    let annotation = record["sonar"]
    if kind != "table" or annotation.kind != JObject: fail "Sonar records annotate a table"
    if not annotation.keysWithin(["role", "value_column", "meaning_column", "outcome_column", "cells_column"]) or
        annotation{"role"} notin [%"sent", %"received"]:
      fail "Invalid sonar annotation"
    let width = record.field("columns").len
    for key in ["value_column", "meaning_column", "outcome_column", "cells_column"]:
      let required = key in ["value_column", "meaning_column"]
      if not annotation.has(key) and not required: continue
      let value = annotation{key}
      if value == nil or value.kind != JInt or value.getBiggestInt < 0 or value.getBiggestInt >= width:
        fail "Sonar " & key & " outside table"
    for row in record.field("rows"):
      let value = row[int(annotation["value_column"].getBiggestInt)].getStr
      if value.len == 0 or not value.allCharsInSet(Digits):
        fail "Sonar values are unsigned 64-bit decimals"
      try: discard parseBiggestUInt(value)
      except ValueError: fail "Sonar values are unsigned 64-bit decimals"
      if annotation.has("cells_column"):
        for part in strutils.splitWhitespace(row[int(annotation["cells_column"].getBiggestInt)].getStr):
          if not part.allCharsInSet(Digits): fail "Sonar cells are space-separated cell indices"

proc hierarchyProblem*(records: seq[JsonNode]): (int, string) =
  ## The first record the hierarchy cannot hold and why; (-1, "") when none.
  var slots: HashSet[string]
  var parents: OrderedTable[string, string]
  var owner: Table[string, int]
  for index, record in records:
    let slot = record{"slot"}.getStr
    if slot in ["brain", "memory"]:
      if slot in slots: return (index, "Multiple " & slot & " roots")
      slots.incl slot
    let identifier = record{"id"}.getStr
    if truthy(record{"parent"}) and identifier.len == 0: return (index, "Grouped gizmo requires an ID")
    if truthy(record{"row_ids"}) and identifier.len == 0: return (index, "Table with row IDs requires an ID")
    var attached: seq[(string, string)]
    if identifier.len > 0: attached.add (identifier, record{"parent"}.getStr)
    for rowId in record.listOr("row_ids"): attached.add (rowId.getStr, identifier)
    if identifier.len > 0 or record{"layout"} == %"tree":
      for node in record.listOr("nodes"):
        let parent = node{"parent"}.getStr
        attached.add (node["id"].getStr, if parent.len > 0: parent else: identifier)
    for (name, parent) in attached:
      if name in parents: return (index, "Duplicate hierarchy ID " & name.escape("'", "'"))
      parents[name] = parent
      owner[name] = index
  for start in parents.keys:
    var identifier = start
    var visited: HashSet[string]
    while identifier.len > 0:
      if identifier notin parents or identifier in visited:
        return (owner[start], "Gizmo hierarchy has an unknown parent or cycle at " & identifier.escape("'", "'"))
      visited.incl identifier
      if visited.len > 128: return (owner[start], "Hierarchy exceeds 128 levels")
      identifier = parents[identifier]
  (-1, "")

proc pruneHierarchy*(records: seq[JsonNode], stubs: seq[JsonNode]): (seq[JsonNode], seq[string], HashSet[string]) =
  ## The records the hierarchy holds, one error per dropped record, and the
  ## display slots whose root record was dropped (rejected stubs count too).
  if records.len > MaxGizmos: fail "More than " & $MaxGizmos & " primitives in one turn"
  var kept = records
  var errors: seq[string]
  var dropped = stubs
  while true:
    let (index, reason) = hierarchyProblem(kept)
    if index < 0: break
    let record = kept[index]
    kept.delete(index)
    dropped.add record
    errors.add "Rejected " & $record{"label"} & ": " & reason
  var slots: HashSet[string]
  for record in dropped:
    if truthy(record{"slot"}): slots.incl record["slot"].getStr
  (kept, errors, slots)

proc rejectedStub*(text: string): JsonNode =
  ## A rejected record's label and slot, if it parsed that far.
  result = newJObject()
  var record: JsonNode
  try: record = parseJson(text) except CatchableError: return
  if record.kind != JObject: return
  for key in ["slot", "label"]:
    if record.has(key) and record[key].kind == JString: result[key] = record[key]

proc expandRetained*(records: seq[JsonNode], retained: var Table[(string, string), JsonNode]): seq[JsonNode] =
  ## Explicit cell deltas, isolated per dragon; each result is a fresh snapshot.
  for record in records:
    if not truthy(record{"retain"}):
      result.add record
      continue
    let key = (record["kind"].getStr, record["label"].getStr)
    let old = retained.getOrDefault(key, newJObject())
    var snapshot = record.copy
    if record["kind"].getStr == "map":
      var cells: OrderedTable[string, JsonNode]
      for entry in old.listOr("cells") & record.listOr("cells"): cells[$entry["cell"]] = entry
      var edges: OrderedTable[string, JsonNode]
      for entry in old.listOr("edges") & record.listOr("edges"):
        edges[$entry["cell"] & "," & $entry["direction"]] = entry
      snapshot["cells"] = %toSeq(cells.values)
      snapshot["edges"] = %toSeq(edges.values)
    else:
      if old.len > 0 and old["columns"] != record["columns"]: fail "Retained table columns changed"
      var rows: OrderedTable[string, (JsonNode, JsonNode)]
      for source in [old, record]:
        let cells = source.listOr("row_cells")
        let values = source.listOr("rows")
        if cells.len != values.len: fail "zip() argument lengths differ"
        for index, position in cells: rows[$position] = (position, values[index])
      snapshot["row_cells"] = %toSeq(rows.values).mapIt(it[0])
      snapshot["rows"] = %toSeq(rows.values).mapIt(it[1])
    retained[key] = snapshot
    result.add snapshot

proc parseBuild*(text: string): JsonNode =
  ## A LOONG_BUILD line's identity, checked as parse_build checks it.
  var identity: JsonNode
  try: identity = parseJson(if text.startsWith(BuildPrefix): text[BuildPrefix.len .. ^1] else: text)
  except CatchableError: fail "Unsupported build identity"
  if identity.kind != JObject or identity.len != 3 or not identity.has("version") or
      not identity.has("guid") or not identity.has("variant") or identity["version"].kind != JInt or
      identity["version"].getBiggestInt != 1 or identity["guid"].kind != JString or
      identity["variant"] notin [%"judge", %"diagnostic"]:
    fail "Unsupported build identity"
  let guid = identity["guid"].getStr
  var canonical = guid.len == 36
  for index, character in guid:
    if index in [8, 13, 18, 23]: canonical = canonical and character == '-'
    else: canonical = canonical and character in {'0' .. '9', 'a' .. 'f'}
  if not canonical: fail "Invalid build GUID"
  identity
