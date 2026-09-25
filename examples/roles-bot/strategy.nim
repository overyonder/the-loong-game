# The roles bot: the first bot's safety layer and modes, plus a role that decides which modes a dragon may use.
# Every dragon runs this same program. Its role comes from its own length and what its teammates tell it by sonar.

# ---- The starter's C helper, called through Nim's FFI ----------------------

type
  Controller {.importc: "UnswbcController", header: "helper.h", incompleteStruct.} = object
  Game {.importc: "UnswbcGame", header: "helper.h", incompleteStruct.} = object
  Tile {.importc: "UnswbcTile", header: "helper.h", incompleteStruct.} = object
  Edge {.importc: "UnswbcEdge", header: "helper.h", incompleteStruct.} = object
  Entity {.importc: "UnswbcEntity", header: "helper.h", incompleteStruct.} = object
    kind {.importc: "type".}: cint
    team: cint
    isHead {.importc: "is_head".}: bool
  Direction {.importc: "UnswbcDirection", header: "helper.h".} = distinct cint

proc unswbc_init(ct: ptr ptr Controller, game: ptr ptr Game) {.importc, header: "helper.h".}
proc unswbc_update(ct: ptr Controller, game: ptr Game): cint {.importc, header: "helper.h".}
proc unswbc_end_turn() {.importc, header: "helper.h".}
proc unswbc_tile_at(ct: ptr Controller, index: cint): ptr Tile {.importc, header: "helper.h".}
proc unswbc_entity(tile: ptr Tile): ptr Entity {.importc, header: "helper.h".}
proc unswbc_edge(tile: ptr Tile, side: Direction): ptr Edge {.importc, header: "helper.h".}
proc unswbc_passable(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_is_portal(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_move(side: Direction): cint {.importc, discardable, header: "helper.h".}
proc unswbc_facing(ct: ptr Controller): Direction {.importc, header: "helper.h".}
proc unswbc_team(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_length(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_id(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_sonar(ct: ptr Controller, count: ptr cint): ptr UncheckedArray[uint64] {.importc, header: "helper.h".}
proc unswbc_send_sonar_to(side: Direction, message: uint64): cint {.importc, discardable, header: "helper.h".}
proc unswbc_indicator(message: cstring) {.importc, header: "helper.h".}
proc unswbc_can_split(ct: ptr Controller, childSize: cint): cint {.importc, header: "helper.h".}
proc unswbc_split(ct: ptr Controller, childSize: cint): cint {.importc, discardable, header: "helper.h".}
var UNSWBC_DIRECTIONS {.importc, header: "helper.h".}: array[4, Direction]

# ---- What the dragon sees --------------------------------------------------

const
  Size = 7
  Tiles = Size * Size
  Head = Tiles div 2
  Steps = [(0, -1), (1, 0), (0, 1), (-1, 0)]  # north, east, south, west
  DragonEntity = 1

type
  Window = object
    occupied: array[Tiles, bool]            # any dragon segment, ours included
    open: array[Tiles, array[4, bool]]      # no kelp and no portal on that side
    portal: array[Tiles, array[4, bool]]
    enemyHeads: seq[int]

proc readWindow(ct: ptr Controller): Window =
  let ourTeam = unswbc_team(ct)
  for i in 0 ..< Tiles:
    let tile = unswbc_tile_at(ct, i.cint)
    let entity = unswbc_entity(tile)
    if entity != nil and entity.kind == DragonEntity:
      result.occupied[i] = true
      if entity.isHead and entity.team != ourTeam:
        result.enemyHeads.add i
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

# ---- Sonar: telling teammates who we are ------------------------------------

const
  TeamTag = 0x4C4F4F4E'u64    # "LOON": marks our messages, since sonar carries no sender or team
  MemoryTurns = 12            # how long a heard length counts before we forget it

type Role = enum
  Worker     ## the first bot's behaviour: roam, and evade enemy heads
  Champion   ## the longest dragon we know of: plays for length and splits off kamikazes
  Kamikaze   ## a short dragon that trades itself for an enemy head

proc encode(id: int, role: Role, length: int): uint64 =
  ## Tag in the top 32 bits, then the sender's ID, its role and its length.
  (TeamTag shl 32) or (uint64(id and 0xFFFF) shl 16) or (uint64(ord(role)) shl 12) or uint64(length and 0xFFF)

proc decodeLength(message: uint64, ourId: int): int =
  ## A teammate's length, or -1 if the message isn't from a teammate.
  ## A ray can stop at the sender's own body, so our own messages come back to us.
  if (message shr 32) != TeamTag or int((message shr 16) and 0xFFFF) == ourId: -1
  else: int(message and 0xFFF)

var longestTeammateHeard = 0      # this dragon's memory: the longest teammate it has heard of recently
var turnsSinceHeard = MemoryTurns

proc listen(ct: ptr Controller, ourId: int) =
  var count: cint
  let messages = unswbc_sonar(ct, count.addr)
  inc turnsSinceHeard
  if turnsSinceHeard > MemoryTurns: longestTeammateHeard = 0
  for i in 0 ..< count.int:
    let length = decodeLength(messages[i], ourId)
    if length > 0:
      longestTeammateHeard = max(longestTeammateHeard, length)
      turnsSinceHeard = 0

proc chooseRole(length: int): Role =
  if length >= longestTeammateHeard: Champion
  elif length <= 3: Kamikaze
  else: Worker

proc announce(id: int, role: Role, length: int) =
  ## One message each way. Whichever teammate a ray reaches first hears us.
  for side in 0 .. 3: unswbc_send_sonar_to(UNSWBC_DIRECTIONS[side], encode(id, role, length))

# ---- Safety: moves no mode may overrule -------------------------------------

proc nextToEnemyHead(w: Window, i: int): bool = w.gapToEnemy(i) <= 1

proc safeMoves(w: Window, allowEnemyReach: bool): seq[int] =
  for side in 0 .. 3:
    let next = w.step(Head, side)
    if next >= 0 and (allowEnemyReach or not w.nextToEnemyHead(next)):
      result.add side

# ---- Modes, and which ones each role may use ---------------------------------

type Mode = enum
  Roam    ## keep the most room
  Evade   ## keep room and open the gap to the nearest enemy head
  Hunt    ## close on an enemy head and hit it

proc chooseMode(w: Window, role: Role): Mode =
  let gap = w.gapToEnemy(Head)
  case role
  of Kamikaze: (if w.enemyHeads.len > 0: Hunt else: Roam)
  of Champion: (if gap <= 2: Evade else: Roam)         # a wider berth made it too timid to win on length
  of Worker: (if gap <= 2: Evade else: Roam)

proc headOnMove(w: Window): int =
  ## A move straight into an adjacent enemy head, which kills both dragons.
  for side in 0 .. 3:
    let next = neighbour(Head, side)
    if next in w.enemyHeads and w.open[Head][side]: return side
  -1

proc score(w: Window, mode: Mode, side: int): int =
  let first = w.step(Head, side)
  case mode
  of Roam: w.room(first)
  of Evade: w.room(first) + 4 * w.gapToEnemy(first)
  of Hunt: min(w.room(first), 6) - 10 * w.gapToEnemy(first)   # enough room to live, then get close

proc chooseMove(w: Window, role: Role, fallback: Direction): Direction =
  let mode = w.chooseMode(role)
  if mode == Hunt:
    let strike = w.headOnMove
    if strike >= 0: return UNSWBC_DIRECTIONS[strike]
  var candidates = w.safeMoves(allowEnemyReach = mode == Hunt)
  if candidates.len == 0: candidates = w.safeMoves(allowEnemyReach = true)
  if candidates.len == 0:
    for side in 0 .. 3:
      if w.portal[Head][side] and not w.occupied[neighbour(Head, side)]: return UNSWBC_DIRECTIONS[side]
    return fallback
  var best = candidates[0]
  for side in candidates:
    if w.score(mode, side) > w.score(mode, best): best = side
  UNSWBC_DIRECTIONS[best]

# ---- The turn loop ------------------------------------------------------------

var ct: ptr Controller
var game: ptr Game
unswbc_init(ct.addr, game.addr)
while unswbc_update(ct, game) != 0:
  let id = unswbc_id(ct).int
  ct.listen(id)
  let length = unswbc_length(ct).int
  let role = chooseRole(length)
  unswbc_indicator(cstring($role))
  let w = readWindow(ct)
  if role == Champion and length >= 10 and unswbc_can_split(ct, 3) != 0:
    # The last three segments become a new dragon running this same program. It will hear
    # that a longer teammate exists and take the kamikaze role.
    unswbc_split(ct, 3)
  else:
    unswbc_move(w.chooseMove(role, unswbc_facing(ct)))
  announce(id, role, length)
  unswbc_end_turn()
