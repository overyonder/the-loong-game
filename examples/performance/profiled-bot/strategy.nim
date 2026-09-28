# The Nim flood-fill bot from "The choice", with a points profiler: each turn it logs how
# many CPU points each part of the turn took, read from the judge's clock, which
# advances one nanosecond per point.
from ../../repertoire/games/loong/controller import nil

# ---- Profiler: points per part of the turn ---------------------------------------

type Part = enum Input, ReadWindow, ChooseMove, Output
var spent: array[Part, uint64]
var floodFills = 0

template profile(part: Part, body: untyped): untyped =
  let started = controller.clockNanoseconds()
  body
  spent[part] += controller.clockNanoseconds() - started

const
  Size = 7
  Head = 24
  Steps = [(0, -1), (1, 0), (0, 1), (-1, 0)]

type Window = object
  occupied: array[49, bool]
  open: array[49, array[4, bool]]

proc readWindow(ct: ptr controller.Controller, game: ptr controller.Game): Window =
  let head = controller.unswbc_position(ct)
  for i in 0 ..< 49:
    let tile = controller.unswbc_tile_at(ct, i.cint)
    let entity = controller.unswbc_entity(tile)
    let (x, y) = (head.x + i mod Size - 3, head.y + i div Size - 3)
    let offMap = x notin 0 ..< game.width or y notin 0 ..< game.height
    result.occupied[i] = offMap or (entity != nil and entity.kind == 1)
    for side in 0 .. 3:
      result.open[i][side] = controller.unswbc_passable(controller.unswbc_edge(tile, controller.UNSWBC_DIRECTIONS[side])) != 0

proc step(w: Window, i, side: int): int =
  let (column, row) = (i mod Size + Steps[side][0], i div Size + Steps[side][1])
  if column notin 0 ..< Size or row notin 0 ..< Size: return -1
  let next = row * Size + column
  if w.open[i][side] and not w.occupied[next]: next else: -1

proc reachable(w: Window, start, first: int): int =
  inc floodFills
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

proc chooseMove(w: Window, fallback: controller.Direction): controller.Direction =
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
      (result, bestRoom) = (controller.UNSWBC_DIRECTIONS[firstSide], room)

var ct: ptr controller.Controller
var game: ptr controller.Game
controller.unswbc_init(ct.addr, game.addr)
var turnStarted = controller.clockNanoseconds()
while true:
  # The whole of the previous turn, now that its output fee has been paid.
  let previousTurn = controller.clockNanoseconds() - turnStarted
  turnStarted = controller.clockNanoseconds()
  var updated: bool
  profile(Input): updated = controller.unswbc_update(ct, game) != 0
  if not updated: break
  var w: Window
  profile(ReadWindow): w = readWindow(ct, game)
  var move: controller.Direction
  profile(ChooseMove): move = w.chooseMove(controller.unswbc_facing(ct))
  controller.unswbc_move(move)
  var line = "profile"
  for part in Part: line.add " " & $part & "=" & $spent[part]
  line.add " floodFills=" & $floodFills & " previousTurn=" & $previousTurn
  controller.unswbc_log(cstring(line))
  for part in Part: spent[part] = 0
  floodFills = 0
  profile(Output): controller.unswbc_end_turn()
