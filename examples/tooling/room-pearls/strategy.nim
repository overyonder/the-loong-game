# The flood-fill bot from "The choice" with one rule added: among first moves that leave
# plenty of room, head for the nearest visible pearl.
from ../../repertoire/games/loong/controller import nil

const
  Size = 7
  Tiles = Size * Size
  Head = Tiles div 2
  Steps = [(0, -1), (1, 0), (0, 1), (-1, 0)]  # north, east, south, west
  DragonEntity = 1

type Window = object
  occupied: array[Tiles, bool]            # off the map, or any dragon segment
  open: array[Tiles, array[4, bool]]      # no kelp on that side
  pearl: array[Tiles, bool]

proc readWindow(ct: ptr controller.Controller, game: ptr controller.Game): Window =
  let head = controller.unswbc_position(ct)
  for i in 0 ..< Tiles:
    let tile = controller.unswbc_tile_at(ct, i.cint)
    let entity = controller.unswbc_entity(tile)
    let (x, y) = (head.x + i mod Size - 3, head.y + i div Size - 3)
    let offMap = x notin 0 ..< game.width or y notin 0 ..< game.height
    result.occupied[i] = offMap or (entity != nil and entity.kind == DragonEntity)
    result.pearl[i] = controller.unswbc_has_pearl(tile) != 0
    for side in 0 .. 3:
      let edge = controller.unswbc_edge(tile, controller.UNSWBC_DIRECTIONS[side])
      result.open[i][side] = controller.unswbc_passable(edge) != 0

proc step(w: Window, i, side: int): int =
  ## The window index across one side, or -1 off the window or blocked.
  let (column, row) = (i mod Size + Steps[side][0], i div Size + Steps[side][1])
  if column notin 0 ..< Size or row notin 0 ..< Size: return -1
  let next = row * Size + column
  if w.open[i][side] and not w.occupied[next]: next else: -1

proc reachable(w: Window, start, first: int): int =
  ## Tiles reachable from start without crossing the two tiles of our path.
  var visited: set[0 .. Tiles - 1] = {Head, first, start}
  var queue: array[Tiles, int]
  queue[0] = start
  var length = 1
  var cursor = 0
  while cursor < length:
    for side in 0 .. 3:
      let next = w.step(queue[cursor], side)
      if next >= 0 and next notin visited:
        visited.incl next
        queue[length] = next
        inc length
    inc cursor
  length

proc stepsToPearl(w: Window, start: int): int =
  ## Steps from start to the nearest visible pearl, or the window size if none is reachable.
  var visited: set[0 .. Tiles - 1] = {Head, start}
  var queue, distance: array[Tiles, int]
  queue[0] = start
  var length = 1
  var cursor = 0
  while cursor < length:
    if w.pearl[queue[cursor]]: return distance[cursor]
    for side in 0 .. 3:
      let next = w.step(queue[cursor], side)
      if next >= 0 and next notin visited:
        visited.incl next
        queue[length] = next
        distance[length] = distance[cursor] + 1
        inc length
    inc cursor
  Tiles

proc chooseMove(w: Window, fallback: controller.Direction): (controller.Direction, bool) =
  ## Score each first move by the most room any second move leaves us, and say whether
  ## heading for a pearl picked a different move from the one room alone would pick.
  var (best, roomiest) = (fallback, fallback)
  var (bestScore, bestRoom) = (-1, -1)
  for firstSide in 0 .. 3:
    let first = w.step(Head, firstSide)
    if first < 0: continue
    var room = 0
    for secondSide in 0 .. 3:
      let second = w.step(first, secondSide)
      if second >= 0 and second != Head:
        room = max(room, w.reachable(second, first))
    if room > bestRoom:
      (roomiest, bestRoom) = (controller.UNSWBC_DIRECTIONS[firstSide], room)
    # Room matters most. Among moves with room to spare, head for the nearest pearl.
    let score = (if room < 8: room * 100 else: 800) - w.stepsToPearl(first)
    if score > bestScore:
      (best, bestScore) = (controller.UNSWBC_DIRECTIONS[firstSide], score)
  (best, best.cint != roomiest.cint)

var ct: ptr controller.Controller
var game: ptr controller.Game
controller.unswbc_init(ct.addr, game.addr)
while controller.unswbc_update(ct, game) != 0:
  let (move, pearlDecided) = readWindow(ct, game).chooseMove(controller.unswbc_facing(ct))
  controller.unswbc_move(move)
  # Name the behaviour on the turns it decided, so the verdict can weigh games by it.
  if pearlDecided: controller.unswbc_indicator("Pearl")
  controller.unswbc_end_turn()
