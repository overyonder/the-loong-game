## Map geometry and live dragon bodies, advanced event by event, for replay
## analyses that need no headings: kelp and a broken portal pair stop a move
## instead of failing, as the Python analyses' World did. The observations and
## sonar rebuild the stricter board in board.nim.

import std/[math, strutils, tables]
import capnp_replay

const Offsets = [(0, -1), (1, 0), (0, 1), (-1, 0)]    ## N, E, S, W

type
  Square* = tuple[x, y: int]
  EdgeKey* = tuple[x, y: int, west: bool]

  World* = object
    ## Map geometry and live dragon bodies, advanced event by event.
    width*, height*, kelp*: int
    name*, symmetry*:      string
    edges*:               Table[EdgeKey, int]          ## -1 kelp, else the portal
    portals*:             Table[int, seq[EdgeKey]]
    gaps*:                seq[(int, int)]
    bodies*:              OrderedTable[int, seq[Square]]
    teams*:               Table[int, int]
    occupied*:            Table[Square, int]
    initial*:            Table[int, int]              ## each starting dragon's length

proc initWorld*(mapText: string): World =
  var initial: seq[(int, seq[Square])]
  for line in mapText.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 0: continue
    case fields[0]
    of "MAP": (result.width, result.height) = (parseInt(fields[1]), parseInt(fields[2]))
    of "MAP_NAME": result.name = fields[1 .. ^1].join(" ")
    of "SYMMETRY": result.symmetry = fields[1]
    of "TILE": result.gaps.add (parseInt(fields[3]), parseInt(fields[4]))
    of "EDGE":
      let (identifier, kind, portal) = (parseInt(fields[1]), parseInt(fields[2]), parseInt(fields[3]))
      let (row, x) = (identifier div (result.width + 1), identifier mod (result.width + 1))
      let key: EdgeKey = (x mod result.width, (row div 2) mod result.height, row mod 2 == 1)
      if kind == 1:
        result.edges[key] = -1
        inc result.kelp
      elif kind == 2:
        result.edges[key] = portal
        if key notin result.portals.mgetOrPut(portal, @[]): result.portals[portal].add key
    of "DRAGON":
      var values: seq[int]
      for field in fields[1 .. ^1]: values.add parseInt(field)
      var body: seq[Square]
      var at = 2
      while at + 1 < values.len:
        body.add (values[at], values[at + 1])
        at += 2
      initial.add (values[0], body)
    else: discard
  for identifier, (team, body) in initial:
    result.initial[identifier] = body.len
    result.bodies[identifier] = body
    result.teams[identifier] = team
    for square in body: result.occupied[square] = identifier

proc adjacent*(world: World, square: Square, index: int): Square =
  (floorMod(square.x + Offsets[index][0], world.width), floorMod(square.y + Offsets[index][1], world.height))

proc step*(world: World, square: Square, index: int, found: var bool): Square =
  ## Destination of one move; `found` false for kelp. Portal-aware.
  found = true
  let target = if index in [1, 2]: world.adjacent(square, index) else: square
  let key: EdgeKey = (target.x, target.y, index in [1, 3])
  if key notin world.edges: return world.adjacent(square, index)
  let edge = world.edges[key]
  if edge == -1:
    found = false
    return
  var partners: seq[EdgeKey]
  for other in world.portals.getOrDefault(edge):
    if other != key: partners.add other
  if partners.len != 1:
    found = false
    return
  let destination: Square = (partners[0].x, partners[0].y)
  if index in [0, 3]: world.adjacent(destination, index) else: destination

proc free*(world: World, square: Square): seq[Square] =
  ## Reachable, unoccupied neighbours of a square.
  for index in 0 .. 3:
    var found: bool
    let target = world.step(square, index, found)
    if found and target notin world.occupied: result.add target

proc near*(world: World, a, b: Square, radius: int): bool =
  let (dx, dy) = (abs(a.x - b.x), abs(a.y - b.y))
  min(dx, world.width - dx) <= radius and min(dy, world.height - dy) <= radius

proc place*(world: var World, identifier: int, body: seq[Square]) =
  world.bodies[identifier] = body
  for square in body: world.occupied[square] = identifier

proc lift*(world: var World, identifier: int) =
  for square in world.bodies[identifier]:
    if world.occupied.getOrDefault(square, -1) == identifier: world.occupied.del square

proc squareOf*(message: CapnpMessage, point: CapnpStruct): Square =
  (int(message.int32Field(point, 0)), int(message.int32Field(point, 1)))
