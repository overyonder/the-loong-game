## A bot's state rebuilt from what the inspection judge captured of its memory
## (tools/viewer/diagnostics.md, "State from memory"). Each region's
## bytes are kept by address and brought up to date by each turn's changes; the
## schema, sent once, says how to read them. A value is read by its type from
## each root: an object's fields at their offsets, an array's elements in place,
## and a sequence, string or ref through the region whose owner is the field
## that refers to it. It knows nothing of any bot.

import std/[algorithm, base64, intsets, json, strutils, tables]

type
  Field = object
    name: string
    offset, kind: int
    transient: bool   ## Working memory the bot doesn't show.
    draw: string      ## "cells" or "edges" for a sequence laid over the board.

  TypeInfo = object
    name, kind: string
    size, count, element, target, low: int
    fields: seq[Field]
    names: Table[int, string]
    tag: string                     ## A variant's tag field.
    branches: Table[int, seq[Field]] ## A variant's fields by tag value.


  Region* = object
    address*, bytes*, kind*, count*, owner*: int

  Image* = object
    ## One dragon's state as last captured: at the start of its turn, or at
    ## its end, whose roots are the schema's `ends`.
    ending*: bool
    types: seq[TypeInfo]
    roots*: seq[string]      ## Each root's name, in the schema's order.
    rootRegions: seq[int]    ## Each root's region: the regions with no owner, in order.
    regions*: seq[Region]
    byOwner: Table[int, int] ## Owner address -> region index.
    memory: Table[int, seq[byte]]
    changed*: seq[(int, int, int)] ## This turn's (address, offset, bytes) changes.
    shown*: Table[string, Table[int, string]] ## Each retained table or map's rows as last sent.

proc ready*(image: Image): bool = image.types.len > 0 and image.regions.len > 0

proc update*(image: var Image, state: JsonNode) =
  ## Bring the image up to the turn's capture.
  if state == nil or state.kind != JObject: return
  if state{"schema"} != nil:
    let schema = parseJson(state["schema"].getStr)
    image.types.setLen(0)
    for entry in schema["types"]:
      var info = TypeInfo(name: entry{"name"}.getStr, kind: entry{"kind"}.getStr,
        size: entry{"size"}.getInt, count: entry{"count"}.getInt,
        element: entry{"element"}.getInt(-1), target: entry{"target"}.getInt(-1),
        low: entry{"low"}.getInt)
      for field in entry{"fields"}.getElems:
        info.fields.add Field(name: field["name"].getStr, offset: field["offset"].getInt,
          kind: field["type"].getInt, transient: field{"transient"}.getBool,
          draw: field{"draw"}.getStr)
      for pair in entry{"names"}.getElems: info.names[pair[0].getInt] = pair[1].getStr
      info.tag = entry{"tag"}.getStr
      for branch in entry{"branches"}.getElems:
        var fields: seq[Field]
        for field in branch[1].getElems:
          fields.add Field(name: field["name"].getStr, offset: field["offset"].getInt,
            kind: field["type"].getInt)
        info.branches[branch[0].getInt] = fields
      image.types.add info
    image.roots.setLen(0)
    for root in schema{if image.ending: "ends" else: "roots"}.getElems:
      image.roots.add root["name"].getStr
  image.regions.setLen(0)
  image.rootRegions.setLen(0)
  image.byOwner.clear()
  var listed: Table[int, bool]
  for entry in state{"regions"}.getElems:
    let region = Region(address: entry[0].getInt, bytes: entry[1].getInt, kind: entry[2].getInt,
      count: entry[3].getInt, owner: entry[4].getInt)
    if region.owner == 0: image.rootRegions.add image.regions.len
    else: image.byOwner[region.owner] = image.regions.len
    image.regions.add region
    listed[region.address] = true
  image.changed.setLen(0)
  for change in state{"changes"}.getElems:
    let address = change[0].getInt
    let offset = change[1].getInt
    let data = decode(change[2].getStr)
    var bytes = image.memory.getOrDefault(address)
    if offset == 0 and bytes.len != data.len and offset + data.len >= bytes.len: bytes.setLen(0)
    if bytes.len < offset + data.len: bytes.setLen(offset + data.len)
    for index, character in data: bytes[offset + index] = byte(character)
    image.memory[address] = bytes
    image.changed.add (address, offset, data.len)
  # A region that shrank at its address keeps only its listed bytes, not the
  # tail of what was there before.
  for region in image.regions:
    if image.memory.hasKey(region.address) and image.memory[region.address].len > region.bytes:
      image.memory[region.address].setLen(region.bytes)
  var stale: seq[int]
  for address in image.memory.keys:
    if address notin listed: stale.add address
  for address in stale: image.memory.del address

proc word(bytes: seq[byte], at, size: int, signed: bool): BiggestInt =
  ## A little-endian integer of `size` bytes at `at`, 0 outside the bytes.
  if at < 0 or at + size > bytes.len: return 0
  var value: uint64
  for index in countdown(size - 1, 0): value = (value shl 8) or uint64(bytes[at + index])
  if signed and size < 8 and (value and (1'u64 shl (8 * size - 1))) != 0:
    value = value or not ((1'u64 shl (8 * size)) - 1)
  cast[BiggestInt](value)

proc regionOf(image: Image, owner: int): int = image.byOwner.getOrDefault(owner, -1)

proc active(image: Image, info: TypeInfo, bytes: seq[byte], at: int): seq[Field] =
  ## A variant's fields as it stands: those every branch has, its tag, then
  ## the branch its tag names.
  result = info.fields
  for field in info.fields:
    if field.name == info.tag and field.kind in 0 ..< image.types.len:
      let tag = int(word(bytes, at + field.offset, image.types[field.kind].size, false))
      result.add info.branches.getOrDefault(tag)

proc value(image: Image, bytes: seq[byte], base, at, kind, depth: int, seen: var IntSet): JsonNode

proc elements(image: Image, region: int, depth: int, seen: var IntSet): JsonNode =
  ## A region's elements as an array.
  result = newJArray()
  if region < 0: return
  let info = image.regions[region]
  let bytes = image.memory.getOrDefault(info.address)
  let size = if info.count > 0: info.bytes div info.count else: 0
  for index in 0 ..< info.count:
    result.add image.value(bytes, info.address, index * size, info.kind, depth + 1, seen)

proc value(image: Image, bytes: seq[byte], base, at, kind, depth: int, seen: var IntSet): JsonNode =
  ## The value of type `kind` at offset `at` of a region based at `base`. What
  ## a ref points to is read the first time it is reached in `seen`, and is
  ## `{"@": address}` after that, so a cycle ends.
  if kind < 0 or kind >= image.types.len or depth > 32: return newJNull()
  let info = image.types[kind]
  case info.kind
  of "int": %word(bytes, at, info.size, true)
  of "uint": %word(bytes, at, info.size, false)
  of "bool": %(word(bytes, at, 1, false) != 0)
  of "char": %($char(word(bytes, at, 1, false)))
  of "float":
    if info.size == 4: %float(cast[float32](uint32(word(bytes, at, 4, false))))
    else: %cast[float64](word(bytes, at, 8, false))
  of "enum":
    let ordinal = int(word(bytes, at, info.size, false))
    %info.names.getOrDefault(ordinal, $ordinal)
  of "set":
    var members = newJArray()
    for bit in 0 ..< info.size * 8:
      if at + bit div 8 < bytes.len and (bytes[at + bit div 8] and byte(1 shl (bit mod 8))) != 0:
        members.add %(info.low + bit)
    members
  of "alias": image.value(bytes, base, at, info.target, depth, seen)
  of "array":
    var items = newJArray()
    let size = if info.count > 0: info.size div info.count else: 0
    for index in 0 ..< info.count:
      items.add image.value(bytes, base, at + index * size, info.element, depth + 1, seen)
    items
  of "object", "variant":
    var fields = newJObject()
    for field in (if info.kind == "variant": image.active(info, bytes, at) else: info.fields):
      fields[field.name] = image.value(bytes, base, at + field.offset, field.kind, depth + 1, seen)
    fields
  of "seq":
    image.elements(image.regionOf(base + at), depth, seen)
  of "string":
    let region = image.regionOf(base + at)
    if region < 0: return %""
    let text = image.memory.getOrDefault(image.regions[region].address)
    var characters = newString(text.len)
    for index, character in text: characters[index] = char(character)
    %characters
  of "ref":
    let region = image.regionOf(base + at)
    if region < 0: return newJNull()
    let target = image.regions[region]
    if seen.containsOrIncl(target.address): return %*{"@": target.address}
    var found = image.value(image.memory.getOrDefault(target.address), target.address, 0,
      target.kind, depth + 1, seen)
    # What a ref points to keeps its address, so two refs to one object can
    # be told to be the same.
    if found.kind == JObject: found["@"] = %target.address
    found
  else: newJNull()

proc decode*(image: Image): JsonNode =
  ## The whole state, root by root.
  result = newJObject()
  var seen: IntSet
  for index, at in image.rootRegions:
    if index >= image.roots.len: break
    let root = image.regions[at]
    result[image.roots[index]] = image.value(image.memory.getOrDefault(root.address),
      root.address, 0, root.kind, 0, seen)

proc paths*(image: Image): Table[int, string] =
  ## Each region's path from the root, such as `belief.pearls`, by address.
  if not image.ready: return
  proc walk(image: Image, bytes: seq[byte], base, at, kind: int, path: string,
      found: var Table[int, string], depth: int) =
    if kind < 0 or kind >= image.types.len or depth > 32: return
    let info = image.types[kind]
    case info.kind
    of "object", "variant":
      for field in (if info.kind == "variant": image.active(info, bytes, at) else: info.fields):
        walk(image, bytes, base, at + field.offset, field.kind,
          (if path.len > 0: path & "." else: "") & field.name, found, depth + 1)
    of "array":
      let size = if info.count > 0: info.size div info.count else: 0
      for index in 0 ..< info.count:
        walk(image, bytes, base, at + index * size, info.element, path & "[" & $index & "]", found, depth + 1)
    of "alias": walk(image, bytes, base, at, info.target, path, found, depth)
    of "seq", "string", "ref":
      let region = image.regionOf(base + at)
      if region < 0: return
      let target = image.regions[region]
      if target.address in found: return
      found[target.address] = path
      let inner = image.memory.getOrDefault(target.address)
      if info.kind == "ref":
        walk(image, inner, target.address, 0, target.kind, path, found, depth + 1)
      elif info.kind == "seq":
        let size = if target.count > 0: target.bytes div target.count else: 0
        for index in 0 ..< target.count:
          walk(image, inner, target.address, index * size, target.kind, path & "[]", found, depth + 1)
    else: discard
  for index, at in image.rootRegions:
    if index >= image.roots.len: break
    let root = image.regions[at]
    result[root.address] = image.roots[index]
    walk(image, image.memory.getOrDefault(root.address), root.address, 0, root.kind,
      image.roots[index], result, 0)

proc typeName*(image: Image, kind: int): string =
  if kind >= 0 and kind < image.types.len: image.types[kind].name else: "?"

# The state as the contract's table records (diagnostics.md, "State from
# memory"), in the Memory slot: each object's plain fields as rows, each
# object a sequence or ref reaches as a table beneath it, and the sequences an
# object lays over the board gathered into one retained cell table, whose rows
# are the cells that changed this turn.

const
  MaxRows = 64     ## Rows of a sequence's table: the newest, when it holds more.
  MaxText = 160    ## Characters of one value.
  MaxColumns = 64

type Leaf = object
  ## A scalar reached inside a type without leaving its bytes.
  name: string
  offset, kind: int

proc clip(text: string): string =
  if text.len <= MaxText: text else: text[0 ..< MaxText - 3] & "..."

proc plain(image: Image, kind: int): bool =
  ## Whether a value of this type is written in place as one text.
  if kind < 0 or kind >= image.types.len: return true
  let info = image.types[kind]
  case info.kind
  of "object", "variant", "seq", "string", "ref": false
  of "array": image.plain(info.element)
  of "alias": image.plain(info.target)
  else: true

proc leaves(image: Image, kind: int, prefix = "", depth = 0): seq[Leaf] =
  ## An inline object's scalars and arrays with dotted names; a sequence,
  ## string or ref inside it counts as one.
  if kind < 0 or kind >= image.types.len or depth > 8: return
  let info = image.types[kind]
  if info.kind == "object":
    for field in info.fields:
      let name = (if prefix.len > 0: prefix & "." else: "") & field.name
      if image.types[field.kind].kind == "object":
        for nested in image.leaves(field.kind, name, depth + 1):
          result.add Leaf(name: nested.name, offset: field.offset + nested.offset, kind: nested.kind)
      else: result.add Leaf(name: name, offset: field.offset, kind: field.kind)
  else: result.add Leaf(name: (if prefix.len > 0: prefix else: "value"), offset: 0, kind: kind)

proc text(image: Image, bytes: seq[byte], base, at, kind: int, depth = 0): string =
  ## A value as table text.
  if kind < 0 or kind >= image.types.len or depth > 4: return "?"
  let info = image.types[kind]
  case info.kind
  of "float":
    let x = if info.size == 4: float(cast[float32](uint32(word(bytes, at, 4, false))))
      else: cast[float64](word(bytes, at, 8, false))
    formatFloat(x, ffDefault, 3)
  of "seq", "string":
    let region = image.regionOf(base + at)
    if region < 0: return (if info.kind == "string": "" else: "0 items")
    let target = image.regions[region]
    let inner = image.memory.getOrDefault(target.address)
    if info.kind == "string":
      var characters = newString(inner.len)
      for index, character in inner: characters[index] = char(character)
      return clip(characters)
    var parts: seq[string]
    let size = if target.count > 0: target.bytes div target.count else: 0
    var length = 0
    for index in 0 ..< target.count:
      let part = image.text(inner, target.address, index * size, target.kind, depth + 1)
      length += part.len + 1
      if length > MaxText: break
      parts.add part
    $target.count & (if target.count == 1: " item: " else: " items: ") & parts.join(" ")
  of "ref":
    let region = image.regionOf(base + at)
    if region < 0: "nil" else: image.typeName(image.regions[region].kind)
  of "array":
    var parts: seq[string]
    let size = if info.count > 0: info.size div info.count else: 0
    for index in 0 ..< info.count: parts.add image.text(bytes, base, at + index * size, info.element, depth + 1)
    "[" & parts.join(" ") & "]"
  of "object":
    var parts: seq[string]
    for field in info.fields: parts.add image.text(bytes, base, at + field.offset, field.kind, depth + 1)
    "(" & parts.join(" ") & ")"
  of "variant":
    var parts: seq[string]
    for field in image.active(info, bytes, at):
      parts.add field.name & "=" & image.text(bytes, base, at + field.offset, field.kind, depth + 1)
    parts.join(" ")
  of "alias": image.text(bytes, base, at, info.target, depth)
  else:
    var seen: IntSet
    $image.value(bytes, base, at, kind, depth, seen)

proc changedElements(image: Image, region: Region, size: int): seq[int] =
  ## The elements of `region` whose bytes changed this turn, in order.
  if size <= 0: return
  var marked = newSeq[bool](region.count)
  for (address, offset, bytes) in image.changed:
    if address != region.address or bytes <= 0: continue
    for element in offset div size .. min(region.count - 1, (offset + bytes - 1) div size): marked[element] = true
  for element, changed in marked:
    if changed: result.add element

proc table(id, label, parent: string, columns: seq[string], rows: seq[JsonNode]): JsonNode =
  result = %*{"version": 1, "kind": "table", "id": id, "label": label, "columns": columns, "rows": rows}
  if parent.len > 0: result["parent"] = %parent else: result["slot"] = %"memory"

proc objectRecords(image: var Image, bytes: seq[byte], base, at, kind: int, id, label, parent: string,
    area: int, visited: var seq[int], output: var seq[JsonNode], depth: int)

proc sequenceRecord(image: Image, region: Region, id, label, parent: string, area: int,
    visited: var seq[int], output: var seq[JsonNode], depth: int) =
  ## A sequence of objects as a table, a row per element, the newest when it
  ## holds more than a table shows.
  let columns = image.leaves(region.kind)
  var names: seq[string]
  for leaf in columns[0 ..< min(columns.len, MaxColumns - 1)]: names.add leaf.name
  names.insert("#", 0)
  let inner = image.memory.getOrDefault(region.address)
  let size = if region.count > 0: region.bytes div region.count else: 0
  var rows: seq[JsonNode]
  for index in max(0, region.count - MaxRows) ..< region.count:
    var row = newJArray()
    row.add %($index)
    for leaf in columns[0 ..< names.len - 1]:
      row.add %clip(image.text(inner, region.address, index * size + leaf.offset, leaf.kind))
    rows.add row
  var record = table(id, label & " (" & $region.count & ")", parent, names, rows)
  if region.count > MaxRows: record["reason"] = %("The newest " & $MaxRows & " of " & $region.count)
  output.add record

proc boardRecord(image: var Image, bytes: seq[byte], base, at: int, fields: seq[Field], edges: bool,
    id, label, parent: string, area: int, output: var seq[JsonNode]) =
  ## The object's sequences laid over the board as one retained cell table:
  ## a column per scalar of each element (for edges, per side), and a row per
  ## cell whose text changed this turn.
  var columns: seq[string]
  var sources: seq[(Region, seq[Leaf], int)]  # region, its leaves, element size
  var cells: seq[int]
  var chosen: seq[bool] = newSeq[bool](area)
  for field in fields:
    # The columns come from the field's type, so a sequence empty this turn
    # keeps its columns and the retained table keeps its shape.
    let region = image.regionOf(base + at + field.offset)
    let found = if region >= 0: image.regions[region] else: Region()
    let size = if found.count > 0: found.bytes div found.count else: 0
    let elementType = if field.kind in 0 ..< image.types.len: image.types[field.kind].element else: -1
    var leaves = image.leaves(if region >= 0: found.kind else: elementType)
    for leaf in leaves.mitems:
      leaf.name = field.name & (if leaf.name == "value": "" else: "." & leaf.name)
    for leaf in leaves:
      if edges:
        columns.add leaf.name & " N"
        columns.add leaf.name & " W"
      else: columns.add leaf.name
    sources.add (found, leaves, size)
    for element in image.changedElements(found, size):
      let cell = if edges: element div 2 else: element
      if cell >= 0 and cell < area and not chosen[cell]:
        chosen[cell] = true
        cells.add cell
  if columns.len == 0: return
  if columns.len > MaxColumns: columns.setLen(MaxColumns)
  cells.sort
  var rows: seq[JsonNode]
  var sent: seq[int]
  let shown = addr image.shown.mgetOrPut(id, initTable[int, string]())
  for cell in cells:
    var row = newJArray()
    for (region, leaves, size) in sources:
      let inner = image.memory.getOrDefault(region.address)
      for leaf in leaves:
        for axis in (if edges: @[0, 1] else: @[0]):
          if row.len >= columns.len: break
          let element = if edges: 2 * cell + axis else: cell
          row.add %(if element < region.count:
            clip(image.text(inner, region.address, element * size + leaf.offset, leaf.kind)) else: "")
    let text = $row
    if shown[].getOrDefault(cell, "\0") == text: continue
    shown[][cell] = text
    rows.add row
    sent.add cell
  var record = table(id, label, parent, columns, rows)
  record["row_cells"] = %sent
  record["retain"] = %true
  output.add record

proc objectRecords(image: var Image, bytes: seq[byte], base, at, kind: int, id, label, parent: string,
    area: int, visited: var seq[int], output: var seq[JsonNode], depth: int) =
  ## An object's plain fields as one table, then what it reaches beneath it.
  if kind < 0 or kind >= image.types.len or depth > 8: return
  let info = image.types[kind]
  var rows: seq[JsonNode]
  var cellFields, edgeFields: seq[Field]
  # The object's own table goes ahead of what it reaches.
  let own = output.len
  output.add newJNull()
  for field in info.fields:
    let fieldKind = image.types[field.kind]
    let childId = id & "." & field.name
    if field.transient:
      rows.add %[field.name, "working memory, not shown"]
    elif field.draw == "cells": cellFields.add field
    elif field.draw == "edges": edgeFields.add field
    elif fieldKind.kind == "object":
      let (fieldAt, fieldKindId) = (at + field.offset, field.kind)
      objectRecords(image, bytes, base, fieldAt, fieldKindId, childId, field.name, id, area,
        visited, output, depth + 1)
    elif fieldKind.kind == "ref":
      let region = image.regionOf(base + at + field.offset)
      if region < 0 or image.regions[region].address in visited:
        rows.add %[field.name, (if region < 0: "nil" else: "shown above")]
        continue
      let target = image.regions[region]
      visited.add target.address
      objectRecords(image, image.memory.getOrDefault(target.address), target.address, 0, target.kind,
        childId, field.name, id, area, visited, output, depth + 1)
    elif fieldKind.kind == "seq" and not image.plain(fieldKind.element):
      let region = image.regionOf(base + at + field.offset)
      if region < 0:
        rows.add %[field.name, "0 items"]
        continue
      sequenceRecord(image, image.regions[region], childId, field.name, id, area, visited, output, depth + 1)
    else:
      rows.add %[field.name, clip(image.text(bytes, base, at + field.offset, field.kind))]
  output[own] = table(id, label, parent, @["field", "value"], rows)
  if cellFields.len > 0:
    boardRecord(image, bytes, base, at, cellFields, false, id & ".cells", label & " by cell", id, area, output)
  if edgeFields.len > 0:
    boardRecord(image, bytes, base, at, edgeFields, true, id & ".edges", label & " by edge", id, area, output)

proc records*(image: var Image, area: int): seq[JsonNode] =
  ## This turn's state as table records: a State table with a row for each
  ## root that is a plain value, then each root that is an object or a
  ## sequence of them as tables beneath it.
  if not image.ready: return
  var rows: seq[JsonNode]
  var visited: seq[int]
  for at in image.rootRegions: visited.add image.regions[at].address
  var output = @[newJNull()]
  for index, at in image.rootRegions:
    if index >= image.roots.len: break
    let (name, root) = (image.roots[index], image.regions[at])
    let bytes = image.memory.getOrDefault(root.address)
    let kind = if root.kind in 0 ..< image.types.len: image.types[root.kind].kind else: ""
    let id = "state." & name
    if kind == "object":
      objectRecords(image, bytes, root.address, 0, root.kind, id, name, "state", area,
        visited, output, 0)
    elif kind == "seq" and not image.plain(image.types[root.kind].element):
      let region = image.regionOf(root.address)
      if region < 0: rows.add %[name, "0 items"]
      else: sequenceRecord(image, image.regions[region], id, name, "state", area, visited, output, 0)
    elif kind == "ref":
      let region = image.regionOf(root.address)
      if region < 0: rows.add %[name, "nil"]
      else:
        let target = image.regions[region]
        objectRecords(image, image.memory.getOrDefault(target.address), target.address, 0,
          target.kind, id, name, "state", area, visited, output, 0)
    else: rows.add %[name, clip(image.text(bytes, root.address, 0, root.kind))]
  output[0] = table("state", "State", "", @["root", "value"], rows)
  output

proc locate(image: Image, name: string, path: openArray[string]): tuple[found: bool,
    base, offset, kind: int] =
  ## Where the value at `path` in the root `name` lies: its region's address,
  ## its offset there and its type.
  for index, root in image.rootRegions:
    if index >= image.roots.len or image.roots[index] != name: continue
    var base = image.regions[root].address
    var (offset, kind) = (0, image.regions[root].kind)
    for step in path:
      while kind in 0 ..< image.types.len and image.types[kind].kind in ["alias", "ref"]:
        if image.types[kind].kind == "alias":
          kind = image.types[kind].target
          continue
        let region = image.regionOf(base + offset)
        if region < 0: return
        (base, offset, kind) = (image.regions[region].address, 0, image.regions[region].kind)
      if kind notin 0 ..< image.types.len: return
      var found = false
      for field in image.types[kind].fields:
        if field.name == step:
          (offset, kind, found) = (offset + field.offset, field.kind, true)
          break
      if not found: return
    return (true, base, offset, kind)

proc at*(image: Image, name: string, path: varargs[string]): JsonNode =
  ## The value at `path` in the root `name`, a field name per step through
  ## objects and refs, decoded alone; nil when there is none.
  let (found, base, offset, kind) = image.locate(name, path)
  if not found: return nil
  var seen: IntSet
  image.value(image.memory.getOrDefault(base), base, offset, kind, 0, seen)

proc elements*(image: Image, name: string, path: varargs[string]): tuple[bytes: seq[byte],
    count, size: int] =
  ## The sequence at `path` in the root `name` as its raw elements, for a
  ## reader of long sequences: their bytes, how many and each one's size.
  let (found, base, offset, _) = image.locate(name, path)
  if not found: return
  let region = image.regionOf(base + offset)
  if region < 0: return
  let info = image.regions[region]
  (image.memory.getOrDefault(info.address), info.count,
    if info.count > 0: info.bytes div info.count else: 0)

proc enumNames*(image: Image, name: string): seq[string] =
  ## The values of the enum type `name`, by ordinal, as the schema names them.
  for info in image.types:
    if info.kind == "enum" and info.name == name:
      for ordinal in 0 ..< info.names.len: result.add info.names.getOrDefault(ordinal, $ordinal)
      return
