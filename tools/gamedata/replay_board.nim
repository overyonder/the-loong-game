## A packed replay's events applied to the rebuilt board (board.nim), as the
## Python ReplayState applied them: a move, split or death of an unknown dragon,
## or a starting body the replay places elsewhere, fails the rebuild.

import std/tables
import board, capnp_replay

proc cellOf*(board: ReconstructedBoard, message: CapnpMessage, point: CapnpStruct): int =
  board.cellAt(int(message.int32Field(point, 0)), int(message.int32Field(point, 1)))

proc eventKind*(message: CapnpMessage, event: CapnpStruct): int = int(message.uint16Field(event, 0))

proc applyReplayEvent*(board: var ReconstructedBoard, message: CapnpMessage, event: CapnpStruct) =
  let member = message.structField(event, 0)
  case message.eventKind(event)
  of 0: board.round = message.int32Field(member, 0)
  of 2:
    board.due[board.cellOf(message, message.structField(member, 0))] =
      board.round + message.int32Field(member, 0)
  of 3: board.pearls[board.cellOf(message, message.structField(member, 0))] = message.boolField(member, 0)
  of 9:
    let dragon = message.int32Field(member, 0)
    if dragon notin board.dragons: raise newException(KeyError, "dragon " & $dragon)
    let head = board.cellOf(message, message.structField(member, 0))
    if board.round < 0:
      if board.dragons[dragon].body[0] != head:
        raise newException(BoardFailure, "Unexpected initial dragon placement")
      return
    board.moveDragon(dragon, head, board.cellOf(message, message.structField(member, 1)),
      Directions[int(message.uint16Field(member, 2))])
  of 10:
    let parent = message.int32Field(member, 0)
    if parent notin board.dragons: raise newException(KeyError, "dragon " & $parent)
    var bodies: array[2, seq[int]]
    for pointerIndex in 0 .. 1:
      let list = message.listField(member, pointerIndex)
      for segment in 0 ..< list.count: bodies[pointerIndex].add board.cellOf(message, list.listStruct(segment))
    board.splitDragon(parent, message.int32Field(member, 1), "AB"[int(message.uint16Field(member, 4))],
      bodies[0], bodies[1], Directions[int(message.uint16Field(member, 5))])
  of 11:
    let dragon = message.int32Field(member, 0)
    if dragon notin board.dragons: raise newException(KeyError, "dragon " & $dragon)
    board.removeDragon(dragon)
  of 12:
    let value = message.uint64Field(member, 2)
    if message.uint16Field(member, 3) == 1:
      board.messages.mgetOrPut(message.int32Field(member, 3), @[]).add value
    let hitKind = int(message.uint16Field(member, 12))
    if hitKind >= 2:
      board.echoes.mgetOrPut(message.int32Field(member, 0), [0, 0, 0, 0, 0])[hitKind - 2] += 1
  else: discard
