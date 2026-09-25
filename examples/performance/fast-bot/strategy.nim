# The first strategy bot, with its hot path in C: the room each first move leaves is
# counted once a turn by the SIMD bitboard kernel in kernels.c, and room() looks it up.

# ---- The starter's C helper, called through Nim's FFI ------------------------

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
  ## The window index across one side, or -1 off the window.
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

type
  KernelWindow {.importc, header: "kernels.h".} = object
    occupied: array[Tiles, bool]
    open: array[Tiles, array[4, bool]]

proc roomsSimdMasks(w: ptr KernelWindow, rooms: var array[4, cint]) {.importc: "RoomsSimdMasks", header: "kernels.h".}

var roomAfter: array[Tiles, int]   # this turn's room for each first-move tile

proc countRooms(w: Window) =
  ## Count the room behind all four first moves at once, in C.
  var kernelWindow = KernelWindow(occupied: w.occupied, open: w.open)
  var rooms: array[4, cint]
  roomsSimdMasks(kernelWindow.addr, rooms)
  for side in 0 .. 3:
    let first = w.step(Head, side)
    if first >= 0: roomAfter[first] = rooms[side]

proc room(w: Window, first: int): int =
  ## The most tiles any second move leaves us, as in the flood-fill bot.
  roomAfter[first]

# ---- Safety: moves no mode may overrule --------------------------------------

proc nextToEnemyHead(w: Window, i: int): bool =
  for head in w.enemyHeads:
    if distance(i, head) <= 1: return true

proc safeMoves(w: Window): seq[int] =
  ## First moves that avoid kelp, portals, bodies and tiles an enemy head could also reach.
  for side in 0 .. 3:
    let next = w.step(Head, side)
    if next >= 0 and not w.nextToEnemyHead(next):
      result.add side

# ---- Behaviours: each one scores a first move for its mode -------------------

proc roam(w: Window, first: int): int =
  ## Nothing threatening in sight: keep the most room.
  w.room(first)

proc evade(w: Window, first: int): int =
  ## An enemy head within two tiles: keep room, and open the gap to the nearest head.
  var gap = Size
  for head in w.enemyHeads: gap = min(gap, distance(first, head))
  w.room(first) + 4 * gap

# ---- The state machine: a mode, then that mode's behaviour -------------------

type Mode = enum
  Roam
  Evade

proc chooseMode(w: Window): Mode =
  for head in w.enemyHeads:
    if distance(Head, head) <= 2: return Evade
  Roam

proc score(w: Window, mode: Mode, side: int): int =
  let first = w.step(Head, side)
  case mode   # one socket per mode, each filled by a behaviour
  of Roam: w.roam(first)
  of Evade: w.evade(first)

proc chooseMove(w: Window, fallback: Direction): Direction =
  w.countRooms
  let mode = w.chooseMode
  var candidates = w.safeMoves
  if candidates.len == 0:
    # Nothing is fully safe. Accept an enemy head's reach before a certain death.
    for side in 0 .. 3:
      if w.step(Head, side) >= 0: candidates.add side
  if candidates.len == 0:
    # Only a portal or nothing is left. A portal leads somewhere we can't see, which beats a wall.
    for side in 0 .. 3:
      let next = neighbour(Head, side)
      if w.portal[Head][side] and (next < 0 or not w.occupied[next]): return UNSWBC_DIRECTIONS[side]
    return fallback
  var best = candidates[0]
  for side in candidates:
    if w.score(mode, side) > w.score(mode, best): best = side
  UNSWBC_DIRECTIONS[best]

# ---- The turn loop -----------------------------------------------------------

var ct: ptr Controller
var game: ptr Game
unswbc_init(ct.addr, game.addr)
while unswbc_update(ct, game) != 0:
  unswbc_move(readWindow(ct).chooseMove(unswbc_facing(ct)))
  unswbc_end_turn()
