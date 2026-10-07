## A replay's events as JSON objects, in the shape pycapnp's `to_dict` gave
## them (tools/gamedata/replay.capnp): `type` first, then a union's active
## member, then the other fields in schema order, a null pointer field
## absent, enums by name and a void member as null. Reports that quote
## events, such as a regeneration's first state difference, keep that shape.

import std/json
import capnp_replay
import ../evaluation/python_json

const
  EventTypes* = ["roundStart", "turnStart", "pearlCountdown", "tileChange", "dragonAction",
                 "engineLog", "dragonLog", "dragonIndicator", "debugDraw", "dragonUpdate",
                 "dragonSplit", "dragonDeath", "sonarPing"]
  Directions = ["north", "east", "south", "west"]
  Teams = ["a", "b"]

proc enumName(names: openArray[string], value: uint16): JsonNode =
  if int(value) < names.len: %names[value]
  else: raise newException(UnreadableReplay, "enum value " & $value & " outside the schema")

proc point(message: CapnpMessage, value: CapnpStruct): JsonNode =
  %*{"x": message.int32Field(value, 0), "y": message.int32Field(value, 1)}

proc pointField(message: CapnpMessage, parent: CapnpStruct, index: int, name: string, into: JsonNode) =
  if message.hasPointer(parent, index): into[name] = message.point(message.structField(parent, index))

proc pointList(message: CapnpMessage, parent: CapnpStruct, index: int, name: string, into: JsonNode) =
  if not message.hasPointer(parent, index): return
  let list = message.listField(parent, index)
  var points = newJArray()
  for at in 0 ..< list.count: points.add message.point(message.structElement(list, at))
  into[name] = points

proc playerAction*(message: CapnpMessage, action: CapnpStruct): JsonNode =
  ## A `PlayerAction`: `{"move": [...]}`, `{"split": n}` or `{"suicide": null}`.
  case message.uint16Field(action, 0)
  of 0:
    var steps = newJArray()
    if message.hasPointer(action, 0):
      let moves = message.listField(action, 0)
      for at in 0 ..< moves.count: steps.add Directions.enumName(message.enumElement(moves, at))
    %*{"move": steps}
  of 1: %*{"split": message.int32Field(action, 1)}
  of 2: %*{"suicide": nil}
  else: raise newException(UnreadableReplay, "unknown action kind")

proc eventJson*(message: CapnpMessage, event: CapnpStruct): JsonNode =
  ## One event as `dict(type=event.which(), **payload.to_dict())`.
  let kind = message.uint16Field(event, 0)
  if int(kind) >= EventTypes.len: raise newException(UnreadableReplay, "unknown event kind " & $kind)
  result = %*{"type": EventTypes[kind]}
  let payload = message.structField(event, 0)
  template int32At(slot: int): JsonNode = %message.int32Field(payload, slot)
  case kind
  of 0: result["round"] = int32At(0)
  of 1: result["id"] = int32At(0)
  of 2:
    message.pointField(payload, 0, "tile", result)
    result["countdown"] = int32At(0)
  of 3:
    message.pointField(payload, 0, "tile", result)
    result["hasPearl"] = %message.boolField(payload, 0)
  of 4:
    result["id"] = int32At(0)
    if message.hasPointer(payload, 0): result["action"] = message.playerAction(message.structField(payload, 0))
    if message.hasPointer(payload, 1):
      let usage = message.structField(payload, 1)
      result["instructions"] = %*{"count": rawNumber(message.uint64Field(usage, 0)),
                                  "exceeded": message.boolField(usage, 64)}
    result["tle"] = %message.boolField(payload, 32)
  of 5, 6, 7:
    result["id"] = int32At(0)
    if message.hasPointer(payload, 0): result["text"] = %message.textField(payload, 0)
  of 8:
    result["id"] = int32At(0)
    if message.hasPointer(payload, 0):
      let draw = message.structField(payload, 0)
      var shape = %*{"shape": message.uint16Field(draw, 0)}
      message.pointField(draw, 0, "from", shape)
      message.pointField(draw, 1, "to", shape)
      let colour = message.uint16Field(draw, 1)
      shape["red"] = %(colour and 0xff)
      shape["green"] = %(colour shr 8)
      shape["blue"] = %(message.uint16Field(draw, 2) and 0xff)
      result["draw"] = shape
  of 9:
    result["id"] = int32At(0)
    result["facing"] = Directions.enumName(message.uint16Field(payload, 2))
    message.pointField(payload, 0, "head", result)
    message.pointField(payload, 1, "tail", result)
  of 10:
    result["parentId"] = int32At(0)
    result["childId"] = int32At(1)
    result["team"] = Teams.enumName(message.uint16Field(payload, 4))
    result["childFacing"] = Directions.enumName(message.uint16Field(payload, 5))
    message.pointList(payload, 0, "parentBody", result)
    message.pointList(payload, 1, "childBody", result)
  of 11:
    result["id"] = int32At(0)
    result["reason"] = %message.uint16Field(payload, 2)
  of 12:
    case message.uint16Field(payload, 3)
    of 0: result["noHit"] = newJNull()
    of 1: result["hitId"] = int32At(3)
    else: raise newException(UnreadableReplay, "unknown sonar hit kind")
    result["senderId"] = int32At(0)
    result["direction"] = Directions.enumName(message.uint16Field(payload, 2))
    result["value"] = %message.uint32Field(payload, 2)
    message.pointField(payload, 0, "origin", result)
    message.pointField(payload, 1, "end", result)
    result["value64"] = rawNumber(message.uint64Field(payload, 2))
    result["hitKind"] = %message.uint16Field(payload, 12)
  else: discard
