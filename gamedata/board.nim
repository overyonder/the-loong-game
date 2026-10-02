## The engine's board as bots saw it, rebuilt event by event: bodies with each
## segment's heading, occupancy, pearls, spawn timers and waiting sonar. The
## observations rebuild and the sonar measurements advance it; both raise
## BoardFailure where the recording can't be rebuilt exactly.

import std/[math, strutils, tables]

const
  Directions* = "NESW"
  Offsets     = [(0, -1), (1, 0), (0, 1), (-1, 0)]

type
  BoardFailure* = object of CatchableError
    ## The recorded game can't be rebuilt exactly, such as an ambiguous heading.

  ReconstructedDragon* = object
    team*:       char          ## 'A' or 'B'
    body*:       seq[int]      ## cells, head first
    directions*: seq[char]     ## each segment's heading, parallel to `body`

  Occupant* = object
    present*:    bool
    team*:       char
    dragon*:     int32
    direction*:  char
    head*:       bool

  ReconstructedBoard* = object
    ## The engine's state as the bots saw it (reconstruction.py's ReplayState).
    width*, height*: int
    unitLimit*:     int
    lenient*:       bool
    ambiguous*:     int
    round*:         int32
    edges*:         seq[string]              ## per (cell, side N/W): "w", a portal id, or "."
    portals*:       Table[int, seq[int]]      ## portal id to its edge keys
    dragons*:       Table[int32, ReconstructedDragon]
    occupied*:      seq[Occupant]             ## per cell
    pearls*:        seq[bool]                 ## per cell
    due*:           seq[int32]                ## per cell: spawn round, or NoDue
    messages*:      Table[int32, seq[uint64]] ## sonar values waiting for a dragon
    echoes*:        Table[int32, array[5, int]]

const NoDue* = low(int32)

proc cellAt*(board: ReconstructedBoard, x, y: int): int =
  floorMod(y, board.height) * board.width + floorMod(x, board.width)

proc adjacent*(board: ReconstructedBoard, cell: int, direction: char): int =
  let (dx, dy) = Offsets[Directions.find(direction)]
  board.cellAt(cell mod board.width + dx, cell div board.width + dy)

proc edgeKey*(board: ReconstructedBoard, cell: int, direction: char): int =
  let owner = if direction in "SE": board.adjacent(cell, direction) else: cell
  owner * 2 + (if direction in "NS": 0 else: 1)

proc step*(board: ReconstructedBoard, cell: int, direction: char): int =
  ## Where a move from `cell` lands, through portals; -1 into kelp.
  let key = board.edgeKey(cell, direction)
  let edge = board.edges[key]
  if edge == "w": return -1
  if edge == ".": return board.adjacent(cell, direction)
  var partner = -1
  for other in board.portals.getOrDefault(parseInt(edge)):
    if other != key:
      if partner >= 0: raise newException(BoardFailure, "Invalid portal pair")
      partner = other
  if partner < 0: raise newException(BoardFailure, "Invalid portal pair")
  let destination = partner div 2
  if direction in "NW": board.adjacent(destination, direction) else: destination

proc linkDirection*(board: var ReconstructedBoard, cell, previous: int): char =
  var candidates: seq[char]
  for direction in Directions:
    if board.step(cell, direction) == previous: candidates.add direction
  if candidates.len > 1 and board.lenient:
    inc board.ambiguous
    return candidates[0]
  if candidates.len != 1:
    raise newException(BoardFailure,
      "Ambiguous body heading; observation cannot be reconstructed exactly")
  candidates[0]

proc bodyDirections*(board: var ReconstructedBoard, body: seq[int], facing: char): seq[char] =
  result.add facing
  for index in 1 ..< body.len: result.add board.linkDirection(body[index], body[index - 1])

proc unindexDragon*(board: var ReconstructedBoard, dragon: int32) =
  for cell in board.dragons[dragon].body: board.occupied[cell].present = false

proc indexDragon*(board: var ReconstructedBoard, dragon: int32) =
  let entry = board.dragons[dragon]
  for index, cell in entry.body:
    board.occupied[cell] = Occupant(present: true, team: entry.team, dragon: dragon,
      direction: entry.directions[index], head: index == 0)

proc initialBoard*(mapText: string, lenient: bool): ReconstructedBoard =
  result.lenient = lenient
  result.round = -1
  result.unitLimit = 64
  var starts: seq[(char, seq[int])]
  for line in mapText.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 0 or fields[0].startsWith("#"): continue
    case fields[0]
    of "MAP":
      result.width = parseInt(fields[1])
      result.height = parseInt(fields[2])
      result.edges = newSeq[string](result.width * result.height * 2)
      for edge in result.edges.mitems: edge = "."
    of "UNIT_LIMIT":
      result.unitLimit = parseInt(fields[1])
    of "EDGE":
      let identifier = parseInt(fields[1])
      let kind = parseInt(fields[2])
      let portal = parseInt(fields[3])
      let row = identifier div (result.width + 1)
      let x = identifier mod (result.width + 1)
      let key = result.cellAt(x, row div 2) * 2 + row mod 2
      result.edges[key] = if kind == 1: "w" elif kind == 2: $portal else: "."
      if kind == 2 and key notin result.portals.mgetOrPut(portal, @[]):
        result.portals[portal].add key
    of "DRAGON":
      var values: seq[int]
      for field in fields[1 .. ^1]: values.add parseInt(field)
      var body: seq[int]
      var at = 2
      while at + 1 < values.len:
        body.add result.cellAt(values[at], values[at + 1])
        at += 2
      starts.add ("AB"[values[0]], body)
    else: discard
  let cells = result.width * result.height
  result.occupied = newSeq[Occupant](cells)
  result.pearls = newSeq[bool](cells)
  result.due = newSeq[int32](cells)
  for due in result.due.mitems: due = NoDue
  for identifier, (team, body) in starts:
    var directions: seq[char]
    for index in 1 ..< body.len: directions.add result.linkDirection(body[index], body[index - 1])
    result.dragons[int32(identifier)] = ReconstructedDragon(team: team, body: body,
      directions: @[if directions.len > 0: directions[0] else: 'E'] & directions)
  for identifier in 0 ..< starts.len: result.indexDragon(int32(identifier))

proc moveDragon*(board: var ReconstructedBoard, dragon: int32, head, tail: int, facing: char) =
  ## One step: the new head first, then tail cells dropped until the body ends
  ## at `tail`.
  board.unindexDragon(dragon)
  let entry = addr board.dragons[dragon]
  entry.directions[0] = facing
  entry.body.insert(head, 0)
  entry.directions.insert(facing, 0)
  while entry.body.len > 1 and entry.body[^1] != tail:
    entry.body.setLen(entry.body.len - 1)
    entry.directions.setLen(entry.directions.len - 1)
  board.indexDragon(dragon)

proc splitDragon*(board: var ReconstructedBoard, parent, child: int32, team: char,
    parentBody, childBody: seq[int], childFacing: char) =
  board.unindexDragon(parent)
  let entry = addr board.dragons[parent]
  entry.body = parentBody
  entry.directions.setLen(min(entry.directions.len, entry.body.len))
  board.indexDragon(parent)
  board.dragons[child] = ReconstructedDragon(team: team, body: childBody,
    directions: board.bodyDirections(childBody, childFacing))
  board.indexDragon(child)

proc removeDragon*(board: var ReconstructedBoard, dragon: int32) =
  board.unindexDragon(dragon)
  board.dragons.del dragon
