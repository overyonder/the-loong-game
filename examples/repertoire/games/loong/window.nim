## What the dragon sees: its 7×7 window, and the room a move leaves in it.
from controller import nil

const
  Size* = 7
  Tiles* = Size * Size
  Head* = Tiles div 2
  Steps = [(0, -1), (1, 0), (0, 1), (-1, 0)]  # north, east, south, west
  DragonEntity = 1

type
  Window* = object
    occupied*: array[Tiles, bool]            # any dragon segment, ours included
    open*: array[Tiles, array[4, bool]]      # no kelp and no portal on that side
    portal*: array[Tiles, array[4, bool]]
    enemyHeads*: seq[int]
    pearl*: array[Tiles, bool]
    ownBody*: array[Tiles, bool]             # this dragon's own segments
    championBody*: array[Tiles, bool]        # the champion's segments, if we know its ID
    championHead*: int                       # where the champion's head is, or -1 if out of sight

proc read*(ct: ptr controller.Controller, championId: int): Window =
  let ourTeam = controller.unswbc_team(ct)
  let ourId = controller.unswbc_id(ct)
  result.championHead = -1
  for i in 0 ..< Tiles:
    let tile = controller.unswbc_tile_at(ct, i.cint)
    let entity = controller.unswbc_entity(tile)
    result.pearl[i] = controller.unswbc_has_pearl(tile) != 0
    if entity != nil and entity.kind == DragonEntity:
      result.occupied[i] = true
      result.ownBody[i] = entity.dragonId == ourId and i != Head
      result.championBody[i] = entity.dragonId == championId and entity.team == ourTeam and not entity.isHead
      if entity.isHead and entity.team != ourTeam:
        result.enemyHeads.add i
      if entity.isHead and entity.team == ourTeam and entity.dragonId == championId:
        result.championHead = i
    for side in 0 .. 3:
      let edge = controller.unswbc_edge(tile, controller.UNSWBC_DIRECTIONS[side])
      result.portal[i][side] = controller.unswbc_is_portal(edge) != 0
      result.open[i][side] = controller.unswbc_passable(edge) != 0 and not result.portal[i][side]

proc neighbour*(i, side: int): int =
  ## The window index across one side, or -1 off the window.
  let (column, row) = (i mod Size + Steps[side][0], i div Size + Steps[side][1])
  if column notin 0 ..< Size or row notin 0 ..< Size: -1 else: row * Size + column

proc step*(w: Window, i, side: int): int =
  let next = neighbour(i, side)
  if next >= 0 and w.open[i][side] and not w.occupied[next]: next else: -1

proc distance*(a, b: int): int =
  max(abs(a mod Size - b mod Size), abs(a div Size - b div Size))

proc gapToEnemy*(w: Window, i: int): int =
  result = Size
  for head in w.enemyHeads: result = min(result, distance(i, head))

proc nearestPearl*(w: Window, i: int): int =
  result = Size * 2
  for j in 0 ..< Tiles:
    if w.pearl[j]: result = min(result, distance(i, j))

proc ownBodyAround*(w: Window, i: int): int =
  ## How many of our own segments touch this tile.
  for side in 0 .. 3:
    let next = neighbour(i, side)
    if next >= 0 and w.ownBody[next]: inc result

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

proc room*(w: Window, first: int): int =
  ## The most tiles any second move leaves us, as in the flood-fill bot.
  for side in 0 .. 3:
    let second = w.step(first, side)
    if second >= 0 and second != Head:
      result = max(result, w.reachable(second, first))
