# The same strategy as the C and Python bots, calling the C starter helper.
type
  Controller {.importc: "UnswbcController", header: "helper.h", incompleteStruct.} = object
  Game {.importc: "UnswbcGame", header: "helper.h", incompleteStruct.} = object
    width, height: cint
  Position {.importc: "UnswbcPosition", header: "helper.h".} = object
    x, y: cint
  Tile {.importc: "UnswbcTile", header: "helper.h", incompleteStruct.} = object
  Edge {.importc: "UnswbcEdge", header: "helper.h", incompleteStruct.} = object
  Entity {.importc: "UnswbcEntity", header: "helper.h", incompleteStruct.} = object
    kind {.importc: "type".}: cint
  Direction {.importc: "UnswbcDirection", header: "helper.h".} = distinct cint

proc unswbc_init(ct: ptr ptr Controller, game: ptr ptr Game) {.importc, header: "helper.h".}
proc unswbc_update(ct: ptr Controller, game: ptr Game): cint {.importc, header: "helper.h".}
proc unswbc_end_turn() {.importc, header: "helper.h".}
proc unswbc_tile_at(ct: ptr Controller, index: cint): ptr Tile {.importc, header: "helper.h".}
proc unswbc_entity(tile: ptr Tile): ptr Entity {.importc, header: "helper.h".}
proc unswbc_edge(tile: ptr Tile, side: Direction): ptr Edge {.importc, header: "helper.h".}
proc unswbc_passable(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_move(side: Direction): cint {.importc, discardable, header: "helper.h".}
proc unswbc_position(ct: ptr Controller): Position {.importc, header: "helper.h".}
proc unswbc_facing(ct: ptr Controller): Direction {.importc, header: "helper.h".}
var UNSWBC_DIRECTIONS {.importc, header: "helper.h".}: array[4, Direction]

const
  Size = 7
  Head = 24
  Steps = [(0, -1), (1, 0), (0, 1), (-1, 0)]

type Window = object
  occupied: array[49, bool]
  open: array[49, array[4, bool]]

proc readWindow(ct: ptr Controller, game: ptr Game): Window =
  let head = unswbc_position(ct)
  for i in 0 ..< 49:
    let tile = unswbc_tile_at(ct, i.cint)
    let entity = unswbc_entity(tile)
    let (x, y) = (head.x + i mod Size - 3, head.y + i div Size - 3)
    let offMap = x notin 0 ..< game.width or y notin 0 ..< game.height
    result.occupied[i] = offMap or (entity != nil and entity.kind == 1)
    for side in 0 .. 3:
      result.open[i][side] = unswbc_passable(unswbc_edge(tile, UNSWBC_DIRECTIONS[side])) != 0

proc step(w: Window, i, side: int): int =
  let (column, row) = (i mod Size + Steps[side][0], i div Size + Steps[side][1])
  if column notin 0 ..< Size or row notin 0 ..< Size: return -1
  let next = row * Size + column
  if w.open[i][side] and not w.occupied[next]: next else: -1

proc reachable(w: Window, start, first: int): int =
  var visited: set[0 .. 48] = {Head, first, start}
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

proc chooseMove(w: Window, fallback: Direction): Direction =
  result = fallback
  var bestRoom = -1
  for firstSide in 0 .. 3:
    let first = w.step(Head, firstSide)
    if first < 0: continue
    var room = 0
    for secondSide in 0 .. 3:
      let second = w.step(first, secondSide)
      if second >= 0 and second != Head:
        room = max(room, w.reachable(second, first))
    if room > bestRoom:
      (result, bestRoom) = (UNSWBC_DIRECTIONS[firstSide], room)

var ct: ptr Controller
var game: ptr Game
unswbc_init(ct.addr, game.addr)
while unswbc_update(ct, game) != 0:
  unswbc_move(readWindow(ct, game).chooseMove(unswbc_facing(ct)))
  unswbc_end_turn()
