# Sonar: each dragon announces where its head is and how long it is, and
# remembers what its teammates announce.
import std/tables
from ../repertoire/games/loong/controller import nil
from gizmos import nil
from memory import nil
when defined(loongDiagnostics):
  import std/json

const
  Tag = 0x5348'u64  # "SH", in the top 16 bits
  Sides = "NESW"

type Heard = object
  value: uint64
  meaning, outcome: string
  cell: int

var heard: seq[Heard]  # this turn's inbox, for the diagnostics

proc encode(id, x, y, length: int): uint64 =
  ## Tag, then the sender's ID, its head's x and y, and its length.
  (Tag shl 48) or (uint64(id and 0xFFF) shl 36) or (uint64(x and 0x3FF) shl 26) or
    (uint64(y and 0x3FF) shl 16) or uint64(length and 0xFFFF)

proc describe(id, length: int): string =
  "D" & $id & "'s head, length " & $length

proc listen*(ct: ptr controller.Controller, game: ptr controller.Game) =
  let round = int(game.roundNum)
  let ownId = int(controller.unswbc_id(ct))
  var count: cint
  let messages = controller.unswbc_sonar(ct, count.addr)
  heard.setLen 0
  for i in 0 ..< int(count):
    let value = messages[i]
    if value shr 48 != Tag:
      heard.add Heard(value: value, meaning: "?", outcome: "not ours, ignored", cell: -1)
      continue
    let id = int((value shr 36) and 0xFFF)
    let cell = int((value shr 16) and 0x3FF) * int(game.width) + int((value shr 26) and 0x3FF)
    let length = int(value and 0xFFFF)
    if id == ownId:
      # A ray can stop at the sender's own body.
      heard.add Heard(value: value, meaning: describe(id, length), outcome: "own echo", cell: cell)
      continue
    memory.sightings[id] = memory.Sighting(cell: cell, round: round, length: length, ours: true,
      exact: true, source: "sonar r" & $round)
    heard.add Heard(value: value, meaning: describe(id, length),
      outcome: "position of D" & $id & " updated", cell: cell)

proc announce*(ct: ptr controller.Controller, game: ptr controller.Game) =
  ## The same message each way; whichever dragon a ray reaches first hears it.
  let at = controller.unswbc_position(ct)
  let id = int(controller.unswbc_id(ct))
  let length = int(controller.unswbc_length(ct))
  let value = encode(id, int(at.x), int(at.y), length)
  for side in 0 .. 3:
    controller.unswbc_send_sonar_to(controller.UNSWBC_DIRECTIONS[side], value)
  gizmos.diagnosticBlock:
    let cell = memory.cellOf(game, at)
    var sent: seq[JsonNode]
    for side in 0 .. 3:
      sent.add %[$value, describe(id, length), $cell, $Sides[side]]
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "table", "label": "Sonar sent",
      "columns": ["value", "meaning", "cells", "ray"], "rows": sent,
      "sonar": {"role": "sent", "value_column": 0, "meaning_column": 1, "cells_column": 2}})
    var received: seq[JsonNode]
    for message in heard:
      received.add %[$message.value, message.meaning, message.outcome,
        (if message.cell < 0: "" else: $message.cell)]
    gizmos.emitGizmoJson($ %*{"version": 1, "kind": "table", "label": "Sonar received",
      "columns": ["value", "meaning", "outcome", "cells"], "rows": received,
      "sonar": {"role": "received", "value_column": 0, "meaning_column": 1,
        "outcome_column": 2, "cells_column": 3}})
