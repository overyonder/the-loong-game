## One recovered turn as readable text (`just decisions`): what the bot
## considered, with eligibility, scores and reasons, then what it chose, its
## target and route, its breakdown, and what changed in its memory. It lays out
## the contract's record kinds (replays/viewer/diagnostics.md) and knows
## nothing of any strategy; every word comes from the bot's own records.

import std/[json, strutils]

const
  MaxRows = 24    ## rows shown of a table; the rest are counted
  MaxChanges = 16 ## changed memory rows shown per retained record
  MaxRoute = 12   ## cells shown of a route

proc cellText(cell: JsonNode, width: int): string =
  if cell == nil or cell.kind != JInt or width <= 0: return $cell
  let index = cell.getInt
  "(" & $(index mod width) & "," & $(index div width) & ")"

proc numberText(value: JsonNode): string =
  if value == nil: return ""
  if value.kind == JFloat: return formatFloat(value.getFloat, ffDecimal, 3).strip(chars = {'0'}, leading = false).strip(chars = {'.'}, leading = false)
  $value

proc nodeState(node: JsonNode): string =
  if node{"active"}.getBool: result = "chosen"
  elif node{"eligible"} == nil: result = "not evaluated"
  elif node["eligible"].getBool: result = "eligible"
  else: result = "ineligible"
  if node{"score"} != nil:
    result.add ", " & (if node{"objective"}.getStr.len > 0: node["objective"].getStr
      else: "score") & " " & numberText(node["score"])

proc describeTree(output: var seq[string], record: JsonNode, parent: string, depth: int) =
  ## A state record's nodes under `parent`, indented by depth, in producer order.
  if depth > 64: return
  for node in record{"nodes"}.getElems:
    if node{"parent"}.getStr != parent: continue
    var line = repeat("  ", depth + 1) & "- " & node{"label"}.getStr & " [" & nodeState(node) & "]"
    if node{"reason"}.getStr.len > 0: line.add ": " & node["reason"].getStr
    output.add line
    describeTree(output, record, node{"id"}.getStr, depth + 1)

proc describeTable(output: var seq[string], record: JsonNode, width: int, rows = MaxRows) =
  let columns = record{"columns"}.getElems
  var names: seq[string]
  for column in columns: names.add column.getStr
  output.add "    " & names.join(" | ")
  let states = record{"row_states"}.getElems
  let cells = record{"row_cells"}.getElems
  let all = record{"rows"}.getElems
  for index, row in all:
    if index >= rows:
      output.add "    ... " & $(all.len - rows) & " more rows"
      break
    var values: seq[string]
    for value in row: values.add value.getStr
    var line = "    " & values.join(" | ")
    if index < cells.len: line = "    " & cellText(cells[index], width) & " " & values.join(" | ")
    if index < states.len and states[index].getStr.len > 0: line.add "  [" & states[index].getStr & "]"
    output.add line

proc describeTurn*(dragon, round: int32, action: string, record: JsonNode,
    gizmos: seq[JsonNode], width: int): string =
  ## `record` is the turn as streamed (retained records as their changes);
  ## `gizmos` has retained records rebuilt whole.
  var output: seq[string]
  output.add "== D" & $dragon & " r" & $round & ": " & (if action.len > 0: action else: "no action")
  if not record{"gizmo_reliable"}.getBool(true) or record{"gizmo_source"}.getStr == "recorded":
    output.add "  " & record{"gizmo_status"}.getStr
  for error in record{"gizmo_errors"}.getElems: output.add "  ! " & error.getStr
  if gizmos.len == 0: output.add "  No diagnostics recorded"
  # The Brain: its breakdown, its reason and every alternative it weighed.
  for gizmo in gizmos:
    if gizmo{"slot"} != %"brain": continue
    var breakdown: seq[string]
    for entry in gizmo{"breakdown"}.getElems:
      breakdown.add entry{"level"}.getStr & " " & entry{"value"}.getStr
    if breakdown.len > 0: output.add "  Breakdown: " & breakdown.join(" / ")
    output.add "  Brain: " & gizmo{"label"}.getStr &
      (if gizmo{"reason"}.getStr.len > 0: ": " & gizmo["reason"].getStr else: "")
    case gizmo{"kind"}.getStr
    of "state": describeTree(output, gizmo, "", 0)
    of "table": describeTable(output, gizmo, width)
    else: discard
  # Everything else the bot recorded, in its own order. Retained records are
  # memory: only what changed this turn is shown, from the streamed changes.
  for gizmo in gizmos:
    if gizmo{"slot"} == %"brain" or gizmo{"retain"}.getBool: continue
    let label = gizmo{"label"}.getStr
    let under = if gizmo{"parent"}.getStr.len > 0: " (under " & gizmo["parent"].getStr & ")" else: ""
    let reason = if gizmo{"reason"}.getStr.len > 0: ": " & gizmo["reason"].getStr else: ""
    case gizmo{"kind"}.getStr
    of "target":
      var cells: seq[string]
      for point in gizmo{"points"}.getElems: cells.add cellText(point, width)
      output.add "  Target " & label & " at " & cells.join(", ") & under & reason
    of "path", "line":
      let points = gizmo{"points"}.getElems
      var cells: seq[string]
      for index, point in points:
        if index >= MaxRoute:
          cells.add "... " & $(points.len - MaxRoute) & " more"
          break
        cells.add cellText(point, width)
      output.add "  Route " & label & " (" & $points.len & " cells): " & cells.join(" -> ") & under & reason
    of "candidate":
      output.add "  Option " & label & " [" & (if gizmo{"selected"}.getBool: "chosen" else: "not chosen") &
        ", score " & numberText(gizmo{"score"}) & ", " & gizmo{"objective"}.getStr & "]" & under & reason
    of "action":
      output.add "  Action " & label & under & reason
    of "calculation":
      var operands: seq[string]
      for operand in gizmo{"operands"}.getElems:
        operands.add operand{"name"}.getStr & " " & numberText(operand{"value"})
      output.add "  " & label & ": " & gizmo{"expression"}.getStr & " = " &
        (if gizmo{"result"} != nil: numberText(gizmo["result"]) else: "not evaluated") &
        (if operands.len > 0: ", with " & operands.join(", ") else: "") & under
    of "state":
      output.add "  " & label & under & reason
      describeTree(output, gizmo, "", 0)
    of "table":
      let sonar = gizmo{"sonar"}{"role"}.getStr
      output.add "  " & (if sonar.len > 0: "Sonar " & sonar & ": " else: "") & label & under & reason
      describeTable(output, gizmo, width)
    of "positions":
      output.add "  " & label & under
      for entry in gizmo{"positions"}.getElems:
        output.add "    " & entry{"label"}.getStr & " at " & cellText(entry{"cell"}, width) &
          ", within " & $entry{"radius"}.getInt & " cells, " & $entry{"age"}.getInt & " rounds ago" &
          (if entry{"source"}.getStr.len > 0: ", " & entry["source"].getStr else: "")
    of "map", "search":
      output.add "  " & label & ": " & $gizmo{"cells"}.getElems.len & " cells, " & $gizmo{"edges"}.getElems.len & " edges" & under & reason
    else: discard
  for change in record{"gizmos"}.getElems:
    if not change{"retain"}.getBool: continue
    let label = change{"label"}.getStr
    case change{"kind"}.getStr
    of "table":
      let rows = change{"rows"}.getElems.len
      if rows == 0: continue
      output.add "  Memory " & label & ": " & $rows & " rows changed"
      describeTable(output, change, width, MaxChanges)
    of "map":
      let cells = change{"cells"}.getElems
      let edges = change{"edges"}.getElems
      if cells.len + edges.len == 0: continue
      output.add "  Memory " & label & ": " & $cells.len & " cells and " & $edges.len & " edges changed"
      for index, cell in cells:
        if index >= MaxChanges: break
        output.add "    " & cellText(cell{"cell"}, width) & " " & cell{"label"}.getStr
      for index, edge in edges:
        if index >= MaxChanges: break
        output.add "    " & cellText(edge{"cell"}, width) & " " & "NESW"[edge{"direction"}.getInt and 3] &
          " " & edge{"label"}.getStr
    else: discard
  output.join("\n")
