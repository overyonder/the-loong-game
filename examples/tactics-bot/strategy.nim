# The tactics bot: the roles bot's strategy, carried out with two tactics.
#   Coil:     a champion with nothing threatening it curls up against its own body.
#   Forage:   the other longer dragons go looking for pearls.
# Build with -d:noCoil or -d:noFeed to switch a tactic off. -d:deliver adds the
# sacrifice from the Discord question: a grown feeder dies against the champion's
# body so its segments become pearls. In our tests that made the bot worse.

import std/math

const coilEnabled = not defined(noCoil)
const feedEnabled = not defined(noFeed)
const forageEnabled = feedEnabled
const deliverEnabled = feedEnabled and defined(deliver)

# ---- The starter's C helper, called through Nim's FFI ------------------------

type
  Controller {.importc: "UnswbcController", header: "helper.h", incompleteStruct.} = object
  Game {.importc: "UnswbcGame", header: "helper.h", incompleteStruct.} = object
    width, height: cint
  Tile {.importc: "UnswbcTile", header: "helper.h", incompleteStruct.} = object
  Edge {.importc: "UnswbcEdge", header: "helper.h", incompleteStruct.} = object
  Position {.importc: "UnswbcPosition", header: "helper.h".} = object
    x, y: cint
  Entity {.importc: "UnswbcEntity", header: "helper.h", incompleteStruct.} = object
    kind {.importc: "type".}: cint
    dragonId {.importc: "dragon_id".}: cint
    team: cint
    isHead {.importc: "is_head".}: bool
  Direction {.importc: "UnswbcDirection", header: "helper.h".} = distinct cint

proc unswbc_init(ct: ptr ptr Controller, game: ptr ptr Game) {.importc, header: "helper.h".}
proc unswbc_update(ct: ptr Controller, game: ptr Game): cint {.importc, header: "helper.h".}
proc unswbc_end_turn() {.importc, header: "helper.h".}
proc unswbc_tile_at(ct: ptr Controller, index: cint): ptr Tile {.importc, header: "helper.h".}
proc unswbc_entity(tile: ptr Tile): ptr Entity {.importc, header: "helper.h".}
proc unswbc_has_pearl(tile: ptr Tile): cint {.importc, header: "helper.h".}
proc unswbc_edge(tile: ptr Tile, side: Direction): ptr Edge {.importc, header: "helper.h".}
proc unswbc_passable(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_is_portal(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_move(side: Direction): cint {.importc, discardable, header: "helper.h".}
proc unswbc_facing(ct: ptr Controller): Direction {.importc, header: "helper.h".}
proc unswbc_team(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_length(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_id(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_position(ct: ptr Controller): Position {.importc, header: "helper.h".}
proc unswbc_sonar(ct: ptr Controller, count: ptr cint): ptr UncheckedArray[uint64] {.importc, header: "helper.h".}
proc unswbc_send_sonar_to(side: Direction, message: uint64): cint {.importc, discardable, header: "helper.h".}
proc unswbc_indicator(message: cstring) {.importc, header: "helper.h".}
proc unswbc_can_split(ct: ptr Controller, childSize: cint): cint {.importc, header: "helper.h".}
proc unswbc_split(ct: ptr Controller, childSize: cint): cint {.importc, discardable, header: "helper.h".}
var UNSWBC_DIRECTIONS {.importc, header: "helper.h".}: array[4, Direction]

# ---- What the dragon sees ----------------------------------------------------

const
  Size = 7
  Tiles = Size * Size
  Head = Tiles div 2
  Steps = [(0, -1), (1, 0), (0, 1), (-1, 0)]  # north, east, south, west
  DragonEntity = 1

type
  Window = object
    occupied: array[Tiles, bool]            # any dragon segment, ours included
    ownBody: array[Tiles, bool]             # this dragon's own segments
    championBody: array[Tiles, bool]        # the champion's segments, if we know its ID
    championHead: int                       # where the champion's head is, or -1 if out of sight
    pearl: array[Tiles, bool]
    open: array[Tiles, array[4, bool]]      # no kelp and no portal on that side
    portal: array[Tiles, array[4, bool]]
    enemyHeads: seq[int]

proc readWindow(ct: ptr Controller, championId: int): Window =
  let ourTeam = unswbc_team(ct)
  let ourId = unswbc_id(ct)
  result.championHead = -1
  for i in 0 ..< Tiles:
    let tile = unswbc_tile_at(ct, i.cint)
    let entity = unswbc_entity(tile)
    result.pearl[i] = unswbc_has_pearl(tile) != 0
    if entity != nil and entity.kind == DragonEntity:
      result.occupied[i] = true
      result.ownBody[i] = entity.dragonId == ourId and i != Head
      result.championBody[i] = entity.dragonId == championId and entity.team == ourTeam and not entity.isHead
      if entity.isHead and entity.team != ourTeam:
        result.enemyHeads.add i
      if entity.isHead and entity.team == ourTeam and entity.dragonId == championId:
        result.championHead = i
    for side in 0 .. 3:
      let edge = unswbc_edge(tile, UNSWBC_DIRECTIONS[side])
      result.portal[i][side] = unswbc_is_portal(edge) != 0
      result.open[i][side] = unswbc_passable(edge) != 0 and not result.portal[i][side]

proc neighbour(i, side: int): int =
  let (column, row) = (i mod Size + Steps[side][0], i div Size + Steps[side][1])
  if column notin 0 ..< Size or row notin 0 ..< Size: -1 else: row * Size + column

proc step(w: Window, i, side: int): int =
  let next = neighbour(i, side)
  if next >= 0 and w.open[i][side] and not w.occupied[next]: next else: -1

proc distance(a, b: int): int =
  max(abs(a mod Size - b mod Size), abs(a div Size - b div Size))

proc reachable(w: Window, start, first: int): int =
  var visited: set[0 .. Tiles - 1] = {Head, first, start}
  var queue = @[start]
  var cursor = 0
  while cursor < queue.len:
    for side in 0 .. 3:
      let next = w.step(queue[cursor], side)
      if next >= 0 and next notin visited:
        visited.incl next
        queue.add next
    inc cursor
  queue.len

proc room(w: Window, first: int): int =
  for side in 0 .. 3:
    let second = w.step(first, side)
    if second >= 0 and second != Head:
      result = max(result, w.reachable(second, first))

proc gapToEnemy(w: Window, i: int): int =
  result = Size
  for head in w.enemyHeads: result = min(result, distance(i, head))

proc nearestPearl(w: Window, i: int): int =
  result = Size * 2
  for j in 0 ..< Tiles:
    if w.pearl[j]: result = min(result, distance(i, j))

proc ownBodyAround(w: Window, i: int): int =
  ## How many of our own segments touch this tile. A coil keeps this high.
  for side in 0 .. 3:
    let next = neighbour(i, side)
    if next >= 0 and w.ownBody[next]: inc result

proc wrappedOffset(target, here, size: int): int =
  ## The shortest signed distance from here to target on a wrapping axis.
  result = (target - here) mod size
  if result > size div 2: result -= size
  elif result < -(size div 2): result += size

# ---- Sonar: who we are, and where the champion is ----------------------------

const
  TeamTag = 0x4C4F'u64        # "LO": marks our messages, since sonar carries no sender or team
  MemoryTurns = 12

type Role = enum
  Champion   ## the longest dragon we know of: plays for length, coils when it's safe
  Feeder     ## a mid-sized dragon: forages, then feeds itself to the champion
  Kamikaze   ## a short dragon that trades itself for an enemy head

type Heard = object
  longest, championId, championX, championY, turnsAgo: int

var heard = Heard(turnsAgo: MemoryTurns + 1)

proc encode(id: int, role: Role, length: int, at: Position): uint64 =
  ## 16-bit tag, 16-bit sender ID, 4-bit role, 12-bit length, and the sender's head position.
  (TeamTag shl 48) or (uint64(id and 0xFFFF) shl 32) or (uint64(ord(role)) shl 28) or
    (uint64(length and 0xFFF) shl 16) or (uint64(at.x and 0xFF) shl 8) or uint64(at.y and 0xFF)

proc listen(ct: ptr Controller, ourId: int) =
  var count: cint
  let messages = unswbc_sonar(ct, count.addr)
  inc heard.turnsAgo
  if heard.turnsAgo > MemoryTurns: heard.longest = 0
  for i in 0 ..< count.int:
    let message = messages[i]
    let sender = int((message shr 32) and 0xFFFF)
    if (message shr 48) != TeamTag or sender == ourId: continue   # not ours, or our own echo
    let length = int((message shr 16) and 0xFFF)
    if length >= heard.longest:
      heard = Heard(longest: length, championId: sender, turnsAgo: 0,
                    championX: int((message shr 8) and 0xFF), championY: int(message and 0xFF))

# ---- Safety ------------------------------------------------------------------

proc safeMoves(w: Window, allowEnemyReach: bool): seq[int] =
  for side in 0 .. 3:
    let next = w.step(Head, side)
    if next >= 0 and (allowEnemyReach or w.gapToEnemy(next) > 1):
      result.add side

# ---- Behaviours: each one scores a first move for its mode -------------------

proc roam(w: Window, first: int): int =
  ## Keep the most room.
  w.room(first)

proc evade(w: Window, first: int): int =
  ## Keep room, and open the gap to the nearest enemy head.
  w.room(first) + 4 * w.gapToEnemy(first)

proc hunt(w: Window, first: int): int =
  ## Close on an enemy head: enough room to live, then get close.
  min(w.room(first), 6) - 10 * w.gapToEnemy(first)

proc coil(w: Window, first: int): int =
  ## Hug our own body, but never so tightly that we box ourselves in, and eat any pearl in reach.
  let room = w.room(first)
  (if w.pearl[first]: 100 else: 0) + (if room >= 10: 20 * w.ownBodyAround(first) else: 0) + room

proc forage(w: Window, first: int): int =
  ## Head for the nearest visible pearl, keeping some room.
  min(w.room(first), 10) * 4 - 6 * w.nearestPearl(first)

proc deliver(w: Window, first: int, homeward: (int, int)): int =
  ## Travel towards where the champion was last heard from.
  let (dx, dy) = homeward
  let (column, row) = (first mod Size - Head mod Size, first div Size - Head div Size)
  min(w.room(first), 10) * 4 + 8 * (column * sgn(dx) + row * sgn(dy))

proc headOnMove(w: Window): int =
  ## A move straight into an adjacent enemy head, which kills both dragons.
  for side in 0 .. 3:
    let next = neighbour(Head, side)
    if next in w.enemyHeads and w.open[Head][side]: return side
  -1

proc deliveryMove(w: Window): int =
  ## A move straight into the champion's body, close to its head. Only the mover dies, and its
  ## segments become pearls right where the champion can reach them.
  if w.championHead < 0: return -1
  for side in 0 .. 3:
    let next = neighbour(Head, side)
    if next >= 0 and w.championBody[next] and w.open[Head][side] and distance(Head, w.championHead) <= 2:
      return side
  -1

# ---- The state machine: a role, then a mode, then that mode's behaviour ------

type Mode = enum
  Roam
  Evade
  Hunt
  Coil
  Forage
  Deliver

const FeederDeliversAt = 6    # a feeder heads home once it has grown this long

proc chooseRole(length: int): Role =
  if length >= heard.longest: Champion
  elif length <= 3: Kamikaze
  else: Feeder

proc chooseMode(w: Window, role: Role, length: int): Mode =
  ## Each role may only use some modes.
  let gap = w.gapToEnemy(Head)
  case role
  of Kamikaze: (if w.enemyHeads.len > 0: Hunt else: Roam)
  of Champion:
    if gap <= 2: Evade
    elif coilEnabled and gap > 3: Coil
    else: Roam
  of Feeder:
    if gap <= 2: Evade
    elif deliverEnabled and length >= FeederDeliversAt and heard.turnsAgo <= MemoryTurns: Deliver
    elif forageEnabled: Forage
    else: Roam

proc score(w: Window, mode: Mode, side: int, homeward: (int, int)): int =
  let first = w.step(Head, side)
  case mode   # one socket per mode, each filled by a behaviour
  of Roam: w.roam(first)
  of Evade: w.evade(first)
  of Hunt: w.hunt(first)
  of Coil: w.coil(first)
  of Forage: w.forage(first)
  of Deliver: w.deliver(first, homeward)

proc chooseMove(w: Window, mode: Mode, homeward: (int, int), fallback: Direction): Direction =
  if mode == Hunt:
    let strike = w.headOnMove
    if strike >= 0: return UNSWBC_DIRECTIONS[strike]
  if mode == Deliver:
    let sacrifice = w.deliveryMove
    if sacrifice >= 0: return UNSWBC_DIRECTIONS[sacrifice]
  var candidates = w.safeMoves(allowEnemyReach = mode == Hunt)
  if candidates.len == 0: candidates = w.safeMoves(allowEnemyReach = true)
  if candidates.len == 0:
    for side in 0 .. 3:
      if w.portal[Head][side] and not w.occupied[neighbour(Head, side)]: return UNSWBC_DIRECTIONS[side]
    return fallback
  var best = candidates[0]
  for side in candidates:
    if w.score(mode, side, homeward) > w.score(mode, best, homeward): best = side
  UNSWBC_DIRECTIONS[best]

# ---- The turn loop -----------------------------------------------------------

var ct: ptr Controller
var game: ptr Game
unswbc_init(ct.addr, game.addr)
while unswbc_update(ct, game) != 0:
  let id = unswbc_id(ct).int
  ct.listen(id)
  let length = unswbc_length(ct).int
  let at = unswbc_position(ct)
  let role = chooseRole(length)
  let w = readWindow(ct, heard.championId)
  let mode = w.chooseMode(role, length)
  let homeward = (wrappedOffset(heard.championX, at.x, game.width), wrappedOffset(heard.championY, at.y, game.height))
  unswbc_indicator(cstring($role & " " & $mode))
  if role == Champion and length >= 10 and unswbc_can_split(ct, 3) != 0:
    unswbc_split(ct, 3)
  else:
    unswbc_move(w.chooseMove(mode, homeward, unswbc_facing(ct)))
  for side in 0 .. 3: unswbc_send_sonar_to(UNSWBC_DIRECTIONS[side], encode(id, role, length, at))
  unswbc_end_turn()
