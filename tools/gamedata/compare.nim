## `loong-gamedata compare SITE PLAYED`: where a regenerated replay's game
## state first departs from the site's, for `just regenerate --public`.
##
## Both replays' events are compared in order, without the kinds a site replay
## leaves out or can't match (debug output, engine logs and pearl countdowns)
## and without each action's instruction count. Two events are equal when their
## pycapnp `to_dict` mappings are: a pointer field
## that is null is absent, so it differs from an empty or zero one, while a
## union's active member is always present, so a null `move` equals an empty
## one. The site marks a turn its bot ran out of time on (`tle`, no action),
## and the judge's engine plays it as the empty reply it is, a suicide, so such
## a turn compares as a suicide without `tle`.

import capnp_replay, gzip_inflate

const
  RoundStart* = 0'u16
  TurnStart* = 1'u16
  TileChange* = 3'u16
  DragonAction* = 4'u16
  DragonUpdate* = 9'u16
  DragonSplit* = 10'u16
  DragonDeath* = 11'u16
  SonarPing* = 12'u16
  ## pearlCountdown, engineLog, dragonLog, dragonIndicator and debugDraw.
  Uncompared = {2'u16, 5'u16, 6'u16, 7'u16, 8'u16}
  LastKind = 12'u16

type
  StateReplay = object
    message: CapnpMessage
    events: CapnpList
    kept: seq[int]   ## each compared event's index among all the events

  Difference* = object
    round*: int32    ## the round of the last equal roundStart, or -1
    event*: int      ## the index among compared events
    site*, judge*: int  ## each replay's index among all its events, or -1 past its end

proc loadReplay*(path: string): CapnpMessage =
  ## A replay file's message, gunzipped when the file is compressed.
  var packed = readFile(path)
  if packed.isGzip: packed = packed.gunzip
  readCapnpPackedMessage(packed.toOpenArrayByte(0, packed.high))

proc eventList*(message: CapnpMessage, path: string): CapnpList =
  ## The replay's events, refused when they hold a kind this reader doesn't know.
  result = message.listField(message.root, 3)
  if result.count > 0 and result.elementSize != 7:
    raise newException(UnreadableReplay, path & ": events aren't a struct list")
  for index in 0 ..< result.count:
    let kind = message.uint16Field(result.listStruct(index), 0)
    if kind > LastKind:
      raise newException(UnreadableReplay, path & ": unknown event kind " & $kind)

proc loadState(path: string): StateReplay =
  result.message = loadReplay(path)
  result.events = result.message.eventList(path)
  for index in 0 ..< result.events.count:
    if result.message.uint16Field(result.events.listStruct(index), 0) notin Uncompared:
      result.kept.add index

proc samePoint(a: CapnpMessage, pa: CapnpStruct, b: CapnpMessage, pb: CapnpStruct): bool =
  a.int32Field(pa, 0) == b.int32Field(pb, 0) and a.int32Field(pa, 1) == b.int32Field(pb, 1)

proc samePointField(a: CapnpMessage, sa: CapnpStruct, b: CapnpMessage, sb: CapnpStruct,
    index: int): bool =
  let present = a.hasPointer(sa, index)
  if present != b.hasPointer(sb, index): return false
  not present or samePoint(a, a.structField(sa, index), b, b.structField(sb, index))

proc samePointList(a: CapnpMessage, sa: CapnpStruct, b: CapnpMessage, sb: CapnpStruct,
    index: int): bool =
  let present = a.hasPointer(sa, index)
  if present != b.hasPointer(sb, index): return false
  if not present: return true
  let la = a.listField(sa, index)
  let lb = b.listField(sb, index)
  if la.count != lb.count: return false
  for at in 0 ..< la.count:
    if not samePoint(a, a.structElement(la, at), b, b.structElement(lb, at)): return false
  true

type ActionView = object
  present, tle: bool
  action: CapnpStruct

proc actionOf(message: CapnpMessage, event: CapnpStruct): ActionView =
  result.present = message.hasPointer(event, 0)
  result.tle = message.boolField(event, 32)
  if result.present: result.action = message.structField(event, 0)

proc sameAction(a: CapnpMessage, ea: CapnpStruct, b: CapnpMessage, eb: CapnpStruct): bool =
  var va = a.actionOf(ea)
  var vb = b.actionOf(eb)
  # The suicide a timed-out turn is: present, with the union's member 2.
  let suicideA = va.tle and not va.present
  let suicideB = vb.tle and not vb.present
  if suicideA: va.tle = false
  if suicideB: vb.tle = false
  let presentA = va.present or suicideA
  if va.tle != vb.tle or presentA != (vb.present or suicideB): return false
  if not presentA: return true
  let kindA = if suicideA: 2'u16 else: a.uint16Field(va.action, 0)
  let kindB = if suicideB: 2'u16 else: b.uint16Field(vb.action, 0)
  if kindA > 2 or kindB > 2:
    raise newException(UnreadableReplay, "unknown action kind " & $max(kindA, kindB))
  if kindA != kindB: return false
  case kindA
  of 0:
    let ma = a.listField(va.action, 0)
    let mb = b.listField(vb.action, 0)
    if ma.count != mb.count: return false
    for at in 0 ..< ma.count:
      if a.enumElement(ma, at) != b.enumElement(mb, at): return false
    true
  of 1: a.int32Field(va.action, 1) == b.int32Field(vb.action, 1)
  else: true

proc sameEvent(a: StateReplay, ia: int, b: StateReplay, ib: int): bool =
  let ea = a.events.listStruct(ia)
  let eb = b.events.listStruct(ib)
  let kind = a.message.uint16Field(ea, 0)
  if kind != b.message.uint16Field(eb, 0): return false
  let ma = a.message
  let mb = b.message
  let pa = ma.structField(ea, 0)
  let pb = mb.structField(eb, 0)
  template sameInt32(slot: int): bool = ma.int32Field(pa, slot) == mb.int32Field(pb, slot)
  template sameUint16(slot: int): bool = ma.uint16Field(pa, slot) == mb.uint16Field(pb, slot)
  case kind
  of RoundStart, TurnStart: sameInt32(0)
  of TileChange:
    samePointField(ma, pa, mb, pb, 0) and ma.boolField(pa, 0) == mb.boolField(pb, 0)
  of DragonAction: sameInt32(0) and sameAction(ma, pa, mb, pb)
  of DragonUpdate:
    sameInt32(0) and sameUint16(2) and samePointField(ma, pa, mb, pb, 0) and
      samePointField(ma, pa, mb, pb, 1)
  of DragonSplit:
    sameInt32(0) and sameInt32(1) and sameUint16(4) and sameUint16(5) and
      samePointList(ma, pa, mb, pb, 0) and samePointList(ma, pa, mb, pb, 1)
  of DragonDeath: sameInt32(0) and sameUint16(2)
  of SonarPing:
    let hitA = ma.uint16Field(pa, 3)
    let hitB = mb.uint16Field(pb, 3)
    if hitA > 1 or hitB > 1:
      raise newException(UnreadableReplay, "unknown sonar hit kind " & $max(hitA, hitB))
    sameInt32(0) and sameUint16(2) and ma.uint32Field(pa, 2) == mb.uint32Field(pb, 2) and
      samePointField(ma, pa, mb, pb, 0) and samePointField(ma, pa, mb, pb, 1) and
      hitA == hitB and (hitA == 0 or sameInt32(3)) and
      ma.uint64Field(pa, 2) == mb.uint64Field(pb, 2) and sameUint16(12)
  else: true  # uncompared kinds never reach here

proc firstStateDifference*(site, played: string): (bool, Difference) =
  ## Whether the replays' states differ, and where they first do.
  let a = loadState(site)
  let b = loadState(played)
  var round = -1'i32
  for index in 0 ..< max(a.kept.len, b.kept.len):
    if index >= a.kept.len or index >= b.kept.len or
        not sameEvent(a, a.kept[index], b, b.kept[index]):
      return (true, Difference(round: round, event: index,
        site: (if index < a.kept.len: a.kept[index] else: -1),
        judge: (if index < b.kept.len: b.kept[index] else: -1)))
    let event = a.events.listStruct(a.kept[index])
    if a.message.uint16Field(event, 0) == RoundStart:
      round = a.message.int32Field(a.message.structField(event, 0), 0)
  (false, Difference())
