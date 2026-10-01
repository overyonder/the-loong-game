## A process's state shown straight from its memory (replays/viewer/
## diagnostics.md, "State from memory"). `show` lists every region a root
## reaches: the root itself, each ref's object, each sequence's elements and
## each string's characters, with the type of what it holds and the field that
## refers to it. It names that table and a schema of the types on a
## `LOG LOONG_STATE` line, and the inspection judge copies the regions at that
## moment and sends what changed since the last time. The schema describes each
## type once, from the type itself: an object's fields with their offsets, an
## array's or sequence's elements, an enum's names. Nothing is written field by
## field, and nothing runs unless diagnostics are on.
##
## A case object is shown as a variant: the fields every branch has, its tag,
## and each tag value's own fields, and only the active branch is walked.
## Anything that isn't data is opaque bytes: procs, closures and raw
## pointers. A field marked `transient` is working memory a turn or round
## recomputes, such as a memo or a search's buffers: the schema lists it, and
## its contents aren't shown. `perCell` and `perEdge` tell the viewer a
## sequence is laid over the board, so it is shown by cell.
import std/[macros, sets, typetraits]
from gizmos import nil

template transient*() {.pragma.}
  ## Working memory, recomputed within a turn or round: not state to show.
template perCell*() {.pragma.}
  ## A sequence with one element per board cell, by cell index.
template perEdge*() {.pragma.}
  ## A sequence with one element per edge: each cell's north side, then its
  ## west side, numbered cell * 2 + axis.

when defined(loongDiagnostics):
  var
    types: seq[string]     ## Each type's schema entry, by its ID.
    roots: seq[string]
    schema: string         ## The whole schema once `show` first runs.
    table: seq[uint32]     ## The region count, then five words per region.
    kept: seq[proc ()]     ## Each further root's walk, as `keep` registered it.
    pending: seq[proc ()]  ## `keep`'s registrations, made at the first `show`.
    ends: seq[string]      ## The end-of-turn roots' schema entries.
    endKept: seq[proc ()]  ## Each end-of-turn root's walk.
    walked: HashSet[pointer] ## The objects refs reached in this capture.

  proc printf(format: cstring) {.importc, varargs, header: "<stdio.h>".}
  proc fflush(stream: pointer): cint {.importc, header: "<stdio.h>".}
  var cstdout {.importc: "stdout", header: "<stdio.h>".}: pointer
  var diagnosticsSwitch {.importc: "loong_diagnostics_enabled", header: "gizmos.h".}: cint
  var summarySwitch: cint ## Set by the inspection judge: summarise quiet turns too.
  proc rawPoints(): uint64 {.importc: "loong_raw_points", header: "gizmos.h".}
  var diagnosticPoints {.importc: "loong_diagnostic_points", header: "gizmos.h".}: uint64

  macro caseObject(T: typedesc): bool =
    ## Whether T is an object with a case section.
    var body = getTypeImpl(T)
    if body.kind == nnkBracketExpr: body = getTypeImpl(body[1])
    proc search(node: NimNode): bool =
      if node.kind == nnkRecCase: return true
      for child in node:
        if search(child): return true
    newLit(body.kind == nnkObjectTy and search(body))

  proc quoted(text: string): string =
    result = "\""
    for character in text:
      case character
      of '"': result.add "\\\""
      of '\\': result.add "\\\\"
      of '\n': result.add "\\n"
      else:
        if character < ' ': result.add ' '
        else: result.add character
    result.add '"'

  type Variant = object
    ## A case object's shape: its fields before the case, its tag, and each
    ## branch's values and fields.
    common: seq[NimNode]
    tag: NimNode
    branches: seq[tuple[values: seq[NimNode], fields: seq[NimNode]]]
    others: bool   ## An `else` branch, whose fields aren't shown.

  proc shape(T: NimNode): Variant =
    var body = getTypeImpl(T)
    if body.kind == nnkBracketExpr: body = getTypeImpl(body[1])
    proc names(definitions: NimNode): seq[NimNode] =
      if definitions.kind == nnkIdentDefs:
        for index in 0 ..< definitions.len - 2: result.add definitions[index]
      elif definitions.kind == nnkRecList:
        for child in definitions: result.add names(child)
    for part in body[2]:
      if part.kind == nnkRecCase:
        result.tag = part[0][0]
        for branch in part[1 .. ^1]:
          if branch.kind != nnkOfBranch:
            result.others = true
            continue
          result.branches.add((branch[0 .. ^2], names(branch[^1])))
      else: result.common.add names(part)

  proc idOf[T](): int

  proc fieldText(name: string, offset, id: int): string =
    "{\"name\":" & quoted(name) & ",\"offset\":" & $offset & ",\"type\":" & $id & "}"

  macro variantEntry(T: typedesc): string =
    ## T's schema entry as a variant: the fields every branch has, the tag,
    ## and each tag value's own fields at their offsets.
    let shape = shape(T)
    let (entry, probe) = (ident"entry", ident"probe")
    result = newStmtList()
    result.add quote do:
      var `entry` = "{\"name\":" & quoted($`T`) & ",\"kind\":\"variant\",\"size\":" &
        $sizeof(`T`) & ",\"fields\":["
    var first = true
    for member in shape.common & @[shape.tag]:
      let (name, field) = (newLit($member), ident($member))
      let separator = newLit(if first: "" else: ",")
      first = false
      result.add quote do:
        block:
          var `probe`: `T`
          `entry`.add `separator` & fieldText(`name`, offsetOf(`T`, `field`),
            idOf[typeof(`probe`.`field`)]())
    let tagName = newLit($shape.tag)
    result.add quote do:
      `entry`.add "],\"tag\":" & quoted(`tagName`) & ",\"branches\":["
    var firstBranch = true
    for (values, fields) in shape.branches:
      for value in values:
        let tag = ident($shape.tag)
        var adding = newStmtList()
        var firstField = true
        for member in fields:
          let (name, field) = (newLit($member), ident($member))
          let separator = newLit(if firstField: "" else: ",")
          firstField = false
          adding.add quote do:
            `entry`.add `separator` & fieldText(`name`, offsetOf(`T`, `field`),
              idOf[typeof(`probe`.`field`)]())
        let separator = newLit(if firstBranch: "" else: ",")
        firstBranch = false
        result.add quote do:
          block:
            var `probe` = `T`(`tag`: `value`)
            `entry`.add `separator` & "[" & $ord(`value`) & ",["
            `adding`
            `entry`.add "]]"
    result.add quote do:
      `entry`.add "]}"
      `entry`
    result = newBlockStmt(result)

  macro visitVariant(value: typed, visitor: untyped) =
    ## Visit what the active branch of the case object `value` holds.
    let shape = shape(getTypeInst(value))
    result = newStmtList()
    for member in shape.common:
      let field = ident($member)
      result.add quote do:
        `visitor`(`value`.`field`, addr `value`.`field`)
    var branches = nnkCaseStmt.newTree(newDotExpr(value, ident($shape.tag)))
    for (values, fields) in shape.branches:
      var body = newStmtList(nnkDiscardStmt.newTree(newEmptyNode()))
      for member in fields:
        let field = ident($member)
        body.add quote do:
          `visitor`(`value`.`field`, addr `value`.`field`)
      var branch = nnkOfBranch.newTree()
      for value in values: branch.add value
      branch.add body
      branches.add branch
    if shape.others: branches.add nnkElse.newTree(nnkDiscardStmt.newTree(newEmptyNode()))
    result.add branches


  proc heap[T](): bool {.compileTime.} =
    ## Whether a T holds a ref, sequence or string, so its regions are walked.
    when T is ref or T is seq or T is string: true
    elif T is object and caseObject(T): true
    elif T is (object or tuple) and not caseObject(T):
      var any = false
      for _, field in fieldPairs(default(T)):
        when heap[typeof(field)](): any = true
      any
    elif T is array: heap[typeof(default(T)[low(T)])]()
    else: false

  proc describe[T](): string =
    ## T's schema entry.
    let name = quoted($T)
    when T is ref:
      "{\"name\":" & name & ",\"kind\":\"ref\",\"target\":" & $idOf[typeof(default(T)[])]() & "}"
    elif T is string:
      "{\"name\":" & name & ",\"kind\":\"string\",\"element\":" & $idOf[char]() & "}"
    elif T is seq:
      "{\"name\":" & name & ",\"kind\":\"seq\",\"element\":" & $idOf[typeof(default(T)[0])]() & "}"
    elif T is array:
      "{\"name\":" & name & ",\"kind\":\"array\",\"size\":" & $sizeof(T) & ",\"count\":" &
        $len(default(T)) & ",\"element\":" & $idOf[typeof(default(T)[low(T)])]() & "}"
    elif T is object and caseObject(T): variantEntry(T)
    elif T is (object or tuple) and not caseObject(T):
      var probe: T
      var fields: seq[string]
      for field, value in fieldPairs(probe):
        fields.add "{\"name\":" & quoted(field) & ",\"offset\":" &
          $(cast[int](addr value) - cast[int](addr probe)) & ",\"type\":" &
          $idOf[typeof(value)]() &
          (when value.hasCustomPragma(transient): ",\"transient\":true" else: "") &
          (when value.hasCustomPragma(perCell): ",\"draw\":\"cells\"" else: "") &
          (when value.hasCustomPragma(perEdge): ",\"draw\":\"edges\"" else: "") & "}"
      var joined = ""
      for index, field in fields:
        if index > 0: joined.add ','
        joined.add field
      "{\"name\":" & name & ",\"kind\":\"object\",\"size\":" & $sizeof(T) &
        ",\"fields\":[" & joined & "]}"
    elif T is enum:
      var names = ""
      for value in T:
        if names.len > 0: names.add ','
        names.add "[" & $ord(value) & "," & quoted($value) & "]"
      "{\"name\":" & name & ",\"kind\":\"enum\",\"size\":" & $sizeof(T) & ",\"names\":[" & names & "]}"
    elif T is set:
      "{\"name\":" & name & ",\"kind\":\"set\",\"size\":" & $sizeof(T) & ",\"low\":" &
        $ord(low(elementType(default(T)))) & "}"
    elif T is bool: "{\"name\":" & name & ",\"kind\":\"bool\",\"size\":1}"
    elif T is char: "{\"name\":" & name & ",\"kind\":\"char\",\"size\":1}"
    elif T is distinct: "{\"name\":" & name & ",\"kind\":\"alias\",\"target\":" & $idOf[distinctBase(T)]() & "}"
    elif T is SomeFloat: "{\"name\":" & name & ",\"kind\":\"float\",\"size\":" & $sizeof(T) & "}"
    elif T is SomeUnsignedInt: "{\"name\":" & name & ",\"kind\":\"uint\",\"size\":" & $sizeof(T) & "}"
    elif T is SomeSignedInt or T is range:
      "{\"name\":" & name & ",\"kind\":\"" & (if low(T) < 0: "int" else: "uint") & "\",\"size\":" & $sizeof(T) & "}"
    else: "{\"name\":" & name & ",\"kind\":\"opaque\",\"size\":" & $sizeof(T) & "}"

  proc idOf[T](): int =
    ## T's place in the schema, describing it the first time.
    var id {.global.} = -1
    if id < 0:
      id = types.len
      types.add ""
      let entry = describe[T]()
      types[id] = entry
    id

  proc region(address: pointer, bytes, kind, count: int, owner: pointer) =
    table.add [uint32(cast[uint](address)), uint32(bytes), uint32(kind), uint32(count),
      uint32(cast[uint](owner))]

  proc visit[T](value: var T, owner: pointer) =
    ## The regions `value` reaches beyond itself.
    when T is ref:
      # Each ref is listed, so every owner finds its object, and the object is
      # walked once, so a cycle such as a state's parent ends.
      if value != nil:
        region(cast[pointer](value), sizeof(value[]), idOf[typeof(value[])](), 1, owner)
        if not walked.containsOrIncl(cast[pointer](value)): visit(value[], nil)
    elif T is seq or T is string:
      if value.len > 0:
        region(addr value[0], value.len * sizeof(value[0]), idOf[typeof(value[0])](), value.len, owner)
        when heap[typeof(value[0])]():
          for item in value.mitems: visit(item, addr item)
    elif T is object and caseObject(T): visitVariant(value, visit)
    elif T is (object or tuple) and not caseObject(T):
      when heap[T]():
        for _, field in fieldPairs(value):
          when heap[typeof(field)]() and not field.hasCustomPragma(transient):
            visit(field, addr field)
    elif T is array:
      when heap[typeof(value[low(T)])]():
        for item in value.mitems: visit(item, addr item)

proc keep*[T](name: string, root: ptr T) =
  ## Show `root` beside the state `show` is given: state a module or a
  ## behaviour holds outside it. Call it before the first `show`, which makes
  ## the registration, so play without diagnostics never does.
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    pending.add proc () =
      roots.add "{\"name\":" & quoted(name) & ",\"type\":" & $idOf[T]() & "}"
      kept.add proc () =
        region(root, sizeof(T), idOf[T](), 1, nil)
        visit(root[], root)

proc keep*[T: ref](name: string, root: T) =
  ## Show the object `root` refers to, as `keep` does a variable.
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    type Target = typeof(root[])
    pending.add proc () =
      roots.add "{\"name\":" & quoted(name) & ",\"type\":" & $idOf[Target]() & "}"
      kept.add proc () =
        # An empty region keeps a nil root in its place among the roots.
        if root == nil: region(nil, 0, idOf[Target](), 0, nil)
        else:
          region(cast[pointer](root), sizeof(Target), idOf[Target](), 1, nil)
          if not walked.containsOrIncl(cast[pointer](root)): visit(root[], nil)

proc keepAtEnd*[T](name: string, root: ptr T) =
  ## Show `root` when `close` runs at the end of each turn: what the turn
  ## decided rather than what it knew. Call it before the first `show`.
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    pending.add proc () =
      ends.add "{\"name\":" & quoted(name) & ",\"type\":" & $idOf[T]() & "}"
      endKept.add proc () =
        region(root, sizeof(T), idOf[T](), 1, nil)
        visit(root[], root)

proc keepAtEnd*[T: ref](name: string, root: T) =
  ## Show the object `root` refers to at the end of each turn, as
  ## `keepAtEnd` does a variable.
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    type Target = typeof(root[])
    pending.add proc () =
      ends.add "{\"name\":" & quoted(name) & ",\"type\":" & $idOf[Target]() & "}"
      endKept.add proc () =
        if root == nil: region(nil, 0, idOf[Target](), 0, nil)
        else:
          region(cast[pointer](root), sizeof(Target), idOf[Target](), 1, nil)
          if not walked.containsOrIncl(cast[pointer](root)): visit(root[], nil)

proc announceSwitch*() =
  ## Tell the inspection judge where the diagnostics switch lies, so it can
  ## run turns before the ones it wants with diagnostics off and turn them on
  ## for the rest (the Zig judge's `LOONG_SWITCH`).
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    gizmos.diagnosticBlock:
      discard fflush(cstdout)
      printf("LOG LOONG_SWITCH %u\n", uint32(cast[uint](addr diagnosticsSwitch)))
      printf("LOG LOONG_SUMMARY %u\n", uint32(cast[uint](addr summarySwitch)))
      discard fflush(cstdout)

proc summarising*(): bool =
  ## Whether this turn says its role and task: with diagnostics on, or with
  ## them off when the judge still wants summaries (`LOONG_SUMMARY`).
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    diagnosticsSwitch != 0 or summarySwitch != 0
  else: false

template summary*(record: untyped) =
  ## Emit a turn's summary record whether or not diagnostics are on, its points
  ## kept off the clock the bot reads, as a diagnostic block's are.
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    if inspect.summarising():
      let started = inspect.pointsNow()
      let line = record
      inspect.emitLine(line)
      inspect.addDiagnosticPoints(inspect.pointsNow() - started)

when defined(loongDiagnostics) and sizeof(pointer) == 4:
  proc pointsNow*(): uint64 = rawPoints()
  proc addDiagnosticPoints*(points: uint64) = diagnosticPoints += points
  proc emitLine*(record: string) =
    printf("LOG LOONG_GIZMO %s\n", cstring(record))

proc show*[T](name: string, root: var T) =
  ## Show `root`, the roots `keep` registered, and everything they reach, as
  ## the judge finds them now. Call it where the state is worth seeing, once
  ## a turn; the regions are copied before this returns. Each root is a
  ## region with no owner, in the schema's order of roots.
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    gizmos.diagnosticBlock:
      let id = idOf[T]()
      if schema.len == 0:
        roots.add "{\"name\":" & quoted(name) & ",\"type\":" & $id & "}"
        for register in pending: register()
        pending.setLen(0)
      table.setLen(1)
      walked.clear()
      region(addr root, sizeof(T), id, 1, nil)
      visit(root, addr root)
      for walk in kept: walk()
      table[0] = uint32((table.len - 1) div 5)
      if schema.len == 0:
        var listed = ""
        for index, entry in roots:
          if index > 0: listed.add ','
          listed.add entry
        var ended = ""
        for index, entry in ends:
          if index > 0: ended.add ','
          ended.add entry
        schema = "{\"version\":1,\"roots\":[" & listed & "],\"ends\":[" & ended &
          "],\"types\":["
        for index, entry in types:
          if index > 0: schema.add ','
          schema.add entry
        schema.add "]}"
      discard fflush(cstdout)
      printf("LOG LOONG_STATE %u %u %u\n", uint32(cast[uint](addr table[0])),
        uint32(cast[uint](addr schema[0])), uint32(schema.len))
      discard fflush(cstdout)

proc close*() =
  ## Show the roots `keepAtEnd` registered as the judge finds them now, at
  ## the end of the turn, after `show`.
  when defined(loongDiagnostics) and sizeof(pointer) == 4:
    gizmos.diagnosticBlock:
      if schema.len > 0:
        table.setLen(1)
        walked.clear()
        for walk in endKept: walk()
        table[0] = uint32((table.len - 1) div 5)
        discard fflush(cstdout)
        printf("LOG LOONG_TRACE %u %u %u\n", uint32(cast[uint](addr table[0])),
          uint32(cast[uint](addr schema[0])), uint32(schema.len))
        discard fflush(cstdout)
