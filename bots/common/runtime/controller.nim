## Complete interface to helper.h. Borrowed observations and returned pointers
## remain valid until readTurn; treat pointers as read-only.
## Protocol Direction values are letters; integer directions use 0=N, 1=E, 2=S, 3=W.
## The toolkit owns parsing and buffered output; all policy lives in Nim.
const
  MaximumRounds* = 500
  VisionRadius* = 3
  VisionSize* = 2 * VisionRadius + 1
  VisionTiles* = VisionSize * VisionSize
  InitialLength* = 3
  MinimumSize* = 2
  ProtocolMajor* = 3

type
  Direction* {.importc: "UnswbcDirection", header: "helper.h".} = distinct cint
  Position* {.importc: "UnswbcPosition", header: "helper.h", bycopy.} = object
    x*: cint
    y*: cint
  Entity* {.importc: "UnswbcEntity", header: "helper.h", bycopy.} = object
    position*: Position
    kind* {.importc: "type".}: cint
    dragonId* {.importc: "dragon_id".}: cint
    team*: cint
    direction* {.importc: "dir".}: Direction
    isHead* {.importc: "is_head".}: bool
  Edge* {.importc: "UnswbcEdge", header: "helper.h", bycopy.} = object
    horizontal* {.importc: "is_horizontal".}: bool
    present*: bool
    kind* {.importc: "type".}: cint
    portalId* {.importc: "portal_id".}: cint
  VisibleTile* {.importc: "UnswbcTile", header: "helper.h", bycopy.} = object
    position*: Position
    pearlCountdown* {.importc: "pearl_time".}: cint
    hasPearl* {.importc: "has_pearl".}: bool
    entity*: Entity
    edges*: array[4, Edge]
  SonarEchoes* {.importc: "UnswbcSonarEchoes", header: "helper.h",
      bycopy.} = object
    kelp*: cint
    ally*: cint
    alliedHead* {.importc: "ally_head".}: cint
    enemy*: cint
    enemyHead* {.importc: "enemy_head".}: cint
  Observation* {.importc: "UnswbcController", header: "helper.h",
      bycopy.} = object
    length*: cint
    unitCount* {.importc: "unit_count".}: cint
    unitLimit* {.importc: "unit_limit".}: cint
    head*: Entity
    tiles*: array[VisionTiles, VisibleTile]
    tileCount* {.importc: "tile_count".}: cint
    sonar*: ptr UncheckedArray[uint64]
    sonarCount* {.importc: "sonar_count".}: cint
    sonarCapacity* {.importc: "sonar_cap".}: cint
    echoes* {.importc: "sonar_echoes".}: SonarEchoes
  Game* {.importc: "UnswbcGame", header: "helper.h", bycopy.} = object
    roundNumber* {.importc: "round_num".}: cint
    width*: cint
    height*: cint
    unitLimit* {.importc: "unit_limit".}: cint


const
  North* = Direction(ord('N'))
  East* = Direction(ord('E'))
  South* = Direction(ord('S'))
  West* = Direction(ord('W'))
  TeamA* = cint(ord('A'))
  TeamB* = cint(ord('B'))
  EntityNone* = cint(0)
  EntityDragon* = cint(1)
  EntityPearl* = cint(2)
  EdgeEmpty* = cint(0)
  EdgeKelp* = cint(1)
  EdgePortal* = cint(2)

proc initialiseHelper(observation: ptr ptr Observation, game: ptr ptr Game)
  {.importc: "unswbc_init", header: "helper.h".}

proc updateHelper(observation: ptr Observation, game: ptr Game): cint
  {.importc: "unswbc_update", header: "helper.h".}

proc finishTurn*() {.importc: "unswbc_end_turn", header: "helper.h".}
  ## unswbc_end_turn: Ends the turn and flushes buffered output.

proc helperCanSplit(observation: ptr Observation, length: cint): cint
  {.importc: "unswbc_can_split", header: "helper.h".}

proc helperSplit(observation: ptr Observation, length: cint): cint
  {.importc: "unswbc_split", header: "helper.h".}

proc helperMoves(observation: ptr Observation, directions: ptr Direction,
    count: cint): cint
  {.importc: "unswbc_moves", header: "helper.h".}

proc helperSonar(direction: Direction, message: uint64): cint
  {.importc: "unswbc_send_sonar_to", header: "helper.h".}
let protocolDirections* {.importc: "UNSWBC_DIRECTIONS",
    header: "helper.h".}: array[4, Direction]

var
  currentObservation: ptr Observation
  currentGame: ptr Game


proc initialise*() =
  ## unswbc_init: Reads the spawn block once and buffers output.
  initialiseHelper(addr currentObservation, addr currentGame)

proc readTurn*(): bool =
  ## unswbc_update: Reads a turn; false on ENDGAME. Replaces borrowed data.
  updateHelper(currentObservation, currentGame) != 0

proc observation*(): lent Observation = currentObservation[]

proc game*(): lent Game = currentGame[]

proc canSplit*(length: int): bool =
  ## unswbc_can_split: Checks parent/child minimum lengths and team unit limit.
  helperCanSplit(currentObservation, cint(length)) != 0

proc splitDragon*(length: int): bool {.discardable.} =
  ## unswbc_split: Sends a split; use canSplit separately to check legality.
  helperSplit(currentObservation, cint(length)) != 0

proc sendMoves*(directions: openArray[Direction]): bool {.discardable.} =
  ## unswbc_moves: Sends every step; n steps cost n-1 segments. No legality check.
  var emptyDirection = North
  let first = if directions.len == 0: addr emptyDirection else: unsafeAddr directions[0]
  helperMoves(currentObservation, first, cint(directions.len)) != 0

proc sendMoves*(directions: openArray[int], count: int): bool {.discardable.} =
  ## Index form of unswbc_moves. Rejects invalid counts or direction indices.
  if count < 0 or count > directions.len: return false
  # Keep the usual sprint on the stack, while supporting longer C-helper inputs.
  var shortMoves: array[3, Direction]
  var longMoves: seq[Direction]
  if count > shortMoves.len: longMoves = newSeq[Direction](count)
  for index in 0 ..< count:
    if directions[index] notin 0 .. 3: return false
    if count <= shortMoves.len: shortMoves[index] = protocolDirections[
        directions[index]]
    else: longMoves[index] = protocolDirections[directions[index]]
  if count <= shortMoves.len:
    helperMoves(currentObservation, addr shortMoves[0], cint(count)) != 0
  else:
    helperMoves(currentObservation, addr longMoves[0], cint(count)) != 0

proc sendSonar*(direction: Direction, message: uint64): bool {.discardable.} =
  ## unswbc_send_sonar_to: Sends a full 64-bit directed message.
  helperSonar(direction, message) != 0

proc sendSonar*(direction: int, message: uint64): bool {.discardable.} =
  ## Index form of directed sonar; false for an invalid index.
  if direction notin 0 .. 3: return false
  sendSonar(protocolDirections[direction], message)

proc directionIndex*(direction: Direction): int =
  for index in 0 ..< 4:
    if cint(protocolDirections[index]) == cint(direction): return index
  0

iterator visibleTiles*(): lent VisibleTile =
  for index in 0 ..< int(currentObservation.tileCount):
    yield currentObservation.tiles[index]

## Judge clock extension (not part of helper.h) in instruction points; a failed read returns high(uint64).
proc currentPoints*(): uint64 {.importc: "loong_current_points", cdecl.}

proc offset*(direction: Direction, dx: var cint, dy: var cint)
  {.importc: "unswbc_offset", header: "helper.h".}
  ## unswbc_offset: East/south displacement.

proc opposite*(direction: Direction): Direction
  {.importc: "unswbc_opposite", header: "helper.h".}
  ## unswbc_opposite: Reverse direction.

proc left*(direction: Direction): Direction
  {.importc: "unswbc_left", header: "helper.h".}
  ## unswbc_left: Rotate left.

proc right*(direction: Direction): Direction
  {.importc: "unswbc_right", header: "helper.h".}
  ## unswbc_right: Rotate right.

proc enemy*(team: cint): cint
  {.importc: "unswbc_enemy", header: "helper.h".}
  ## unswbc_enemy: Other team.

proc add*(position: Position, direction: Direction): Position
  {.importc: "unswbc_add", header: "helper.h".}
  ## unswbc_add: Wrapped adjacent position; ignores portals and collisions.

proc getEdge*(tile: ptr VisibleTile, direction: Direction): ptr Edge
  {.importc: "unswbc_edge", header: "helper.h".}
  ## unswbc_edge: Nil for a nil tile or unseen edge.

proc portalId*(edge: ptr Edge): cint
  {.importc: "unswbc_portal_id", header: "helper.h".}
  ## unswbc_portal_id: Portal ID, or -1 for nil/non-portal.

proc getEntity*(tile: ptr VisibleTile): ptr Entity
  {.importc: "unswbc_entity", header: "helper.h".}
  ## unswbc_entity: Nil for a nil or empty tile.

proc log*(message: cstring)
  {.importc: "unswbc_log", header: "helper.h".}
  ## unswbc_log: Replay message; output costs instruction points.

proc dot*(position: Position, red, green, blue: cint)
  {.importc: "unswbc_dot", header: "helper.h".}
  ## unswbc_dot: Draw a replay dot.

proc line*(start, finish: Position, red, green, blue: cint)
  {.importc: "unswbc_line", header: "helper.h".}
  ## unswbc_line: Draw a replay line.

proc indicator*(message: cstring)
  {.importc: "unswbc_indicator", header: "helper.h".}
  ## unswbc_indicator: Label the dragon this turn.

proc inMapHelper(game: ptr Game, position: Position): cint
  {.importc: "unswbc_in_map", header: "helper.h".}

proc inMap*(position: Position): bool =
  ## unswbc_in_map: Board bounds without wrapping.
  inMapHelper(currentGame, position) != 0

proc inVisionHelper(observation: ptr Observation, position: Position): cint
  {.importc: "unswbc_in_vision", header: "helper.h".}

proc inVision*(position: Position): bool =
  ## unswbc_in_vision: Whether the position is in our window.
  inVisionHelper(currentObservation, position) != 0

proc getRoundHelper(game: ptr Game): cint
  {.importc: "unswbc_round", header: "helper.h".}

proc getRound*(): cint =
  ## unswbc_round: Current round.
  getRoundHelper(currentGame)

proc getUnitLimitHelper(game: ptr Game): cint
  {.importc: "unswbc_unit_limit", header: "helper.h".}

proc getUnitLimit*(): cint =
  ## unswbc_unit_limit: Team unit limit.
  getUnitLimitHelper(currentGame)

proc getPositionHelper(observation: ptr Observation): Position
  {.importc: "unswbc_position", header: "helper.h".}

proc getPosition*(): Position =
  ## unswbc_position: Head position.
  getPositionHelper(currentObservation)

proc getLengthHelper(observation: ptr Observation): cint
  {.importc: "unswbc_length", header: "helper.h".}

proc getLength*(): cint =
  ## unswbc_length: Length including head.
  getLengthHelper(currentObservation)

proc getUnitCountHelper(observation: ptr Observation): cint
  {.importc: "unswbc_unit_count", header: "helper.h".}

proc getUnitCount*(): cint =
  ## unswbc_unit_count: Living dragons on our team.
  getUnitCountHelper(currentObservation)

proc getIdHelper(observation: ptr Observation): cint
  {.importc: "unswbc_id", header: "helper.h".}

proc getId*(): cint =
  ## unswbc_id: Unique dragon ID.
  getIdHelper(currentObservation)

proc getTeamHelper(observation: ptr Observation): cint
  {.importc: "unswbc_team", header: "helper.h".}

proc getTeam*(): cint =
  ## unswbc_team: Team letter.
  getTeamHelper(currentObservation)

proc getFacingHelper(observation: ptr Observation): Direction
  {.importc: "unswbc_facing", header: "helper.h".}

proc getFacing*(): Direction =
  ## unswbc_facing: Head heading.
  getFacingHelper(currentObservation)

proc getTileCountHelper(observation: ptr Observation): cint
  {.importc: "unswbc_tile_count", header: "helper.h".}

proc getTileCount*(): cint =
  ## unswbc_tile_count: Observed tile count.
  getTileCountHelper(currentObservation)

proc tileAtHelper(observation: ptr Observation, index: cint): ptr VisibleTile
  {.importc: "unswbc_tile_at", header: "helper.h".}

proc tileAt*(index: int): ptr VisibleTile =
  ## unswbc_tile_at: Nil for an out-of-range index.
  tileAtHelper(currentObservation, cint(index))

proc getTileHelper(observation: ptr Observation,
    position: Position): ptr VisibleTile
  {.importc: "unswbc_tile", header: "helper.h".}

proc getTile*(position: Position): ptr VisibleTile =
  ## unswbc_tile: Nil outside the window.
  getTileHelper(currentObservation, position)

proc passableHelper(edge: ptr Edge): cint
  {.importc: "unswbc_passable", header: "helper.h".}

proc passable*(edge: ptr Edge): bool =
  ## unswbc_passable: False for nil or kelp; does not check occupancy.
  passableHelper(edge) != 0

proc isPortalHelper(edge: ptr Edge): cint
  {.importc: "unswbc_is_portal", header: "helper.h".}

proc isPortal*(edge: ptr Edge): bool =
  ## unswbc_is_portal: Whether crossing teleports.
  isPortalHelper(edge) != 0

proc hasPearlHelper(tile: ptr VisibleTile): cint
  {.importc: "unswbc_has_pearl", header: "helper.h".}

proc hasPearl*(tile: ptr VisibleTile): bool =
  ## unswbc_has_pearl: False for nil or no pearl.
  hasPearlHelper(tile) != 0

proc getSonarHelper(observation: ptr Observation,
    count: ptr cint): ptr UncheckedArray[uint64]
  {.importc: "unswbc_sonar", header: "helper.h".}

proc getSonar*(count: var cint): ptr UncheckedArray[uint64] =
  ## unswbc_sonar: Borrowed messages in sending order; writes count.
  getSonarHelper(currentObservation, addr count)

proc getSonarEchoesHelper(observation: ptr Observation): SonarEchoes
  {.importc: "unswbc_sonar_echoes", header: "helper.h".}

proc getSonarEchoes*(): SonarEchoes =
  ## unswbc_sonar_echoes: Current echo counts.
  getSonarEchoesHelper(currentObservation)

proc sendMoveHelper(direction: Direction): cint
  {.importc: "unswbc_move", header: "helper.h".}

proc sendMove*(direction: Direction): bool {.discardable.} =
  ## unswbc_move: One step; last action printed is applied.
  sendMoveHelper(direction) != 0

proc sendSonarHelper(message: uint64): cint
  {.importc: "unswbc_send_sonar", header: "helper.h".}

proc sendSonar*(message: uint64): bool {.discardable.} =
  ## unswbc_send_sonar: Legacy facing-only message; false above uint32 range.
  sendSonarHelper(message) != 0
