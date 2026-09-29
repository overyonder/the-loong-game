## The judge's interface: the starter's C helper through Nim's FFI, the point clock and
## the program's entry point.

type
  Controller* {.importc: "UnswbcController", header: "helper.h", incompleteStruct.} = object
  Game* {.importc: "UnswbcGame", header: "helper.h", incompleteStruct.} = object
    roundNum* {.importc: "round_num".}: cint
    width*, height*: cint
  Tile* {.importc: "UnswbcTile", header: "helper.h", incompleteStruct.} = object
    position*: Position                        # already wrapped
    pearlTime* {.importc: "pearl_time".}: cint  # rounds until a pearl tries to spawn; -1 never
  Edge* {.importc: "UnswbcEdge", header: "helper.h", incompleteStruct.} = object
    present*: bool                             # this turn's window carried it
  Position* {.importc: "UnswbcPosition", header: "helper.h".} = object
    x*, y*: cint
  Entity* {.importc: "UnswbcEntity", header: "helper.h", incompleteStruct.} = object
    kind* {.importc: "type".}: cint
    team*: cint
    dragonId* {.importc: "dragon_id".}: cint
    isHead* {.importc: "is_head".}: bool
  Direction* {.importc: "UnswbcDirection", header: "helper.h".} = distinct cint

proc unswbc_init*(ct: ptr ptr Controller, game: ptr ptr Game) {.importc, header: "helper.h".}
proc unswbc_update*(ct: ptr Controller, game: ptr Game): cint {.importc, header: "helper.h".}
proc unswbc_end_turn*() {.importc, header: "helper.h".}
proc unswbc_tile_at*(ct: ptr Controller, index: cint): ptr Tile {.importc, header: "helper.h".}
proc unswbc_entity*(tile: ptr Tile): ptr Entity {.importc, header: "helper.h".}
proc unswbc_edge*(tile: ptr Tile, side: Direction): ptr Edge {.importc, header: "helper.h".}
proc unswbc_passable*(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_is_portal*(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_portal_id*(edge: ptr Edge): cint {.importc, header: "helper.h".}
proc unswbc_has_pearl*(tile: ptr Tile): cint {.importc, header: "helper.h".}
proc unswbc_move*(side: Direction): cint {.importc, discardable, header: "helper.h".}
proc unswbc_facing*(ct: ptr Controller): Direction {.importc, header: "helper.h".}
proc unswbc_team*(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_length*(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_id*(ct: ptr Controller): cint {.importc, header: "helper.h".}
proc unswbc_position*(ct: ptr Controller): Position {.importc, header: "helper.h".}
proc unswbc_sonar*(ct: ptr Controller, count: ptr cint): ptr UncheckedArray[uint64] {.importc, header: "helper.h".}
proc unswbc_send_sonar_to*(side: Direction, message: uint64): cint {.importc, discardable, header: "helper.h".}
proc unswbc_indicator*(message: cstring) {.importc, header: "helper.h".}
proc unswbc_log*(message: cstring) {.importc, header: "helper.h".}
proc unswbc_can_split*(ct: ptr Controller, childSize: cint): cint {.importc, header: "helper.h".}
proc unswbc_split*(ct: ptr Controller, childSize: cint): cint {.importc, discardable, header: "helper.h".}
var UNSWBC_DIRECTIONS* {.importc, header: "helper.h".}: array[4, Direction]

proc wasi_clock_time_get(id: uint32, precision: uint64, time: ptr uint64): uint16 {.importc: "__wasi_clock_time_get", header: "<wasi/api.h>".}

proc clockNanoseconds*(): uint64 =
  ## The monotonic clock. In the judge it advances one nanosecond per CPU point, so this
  ## reads points spent.
  discard wasi_clock_time_get(1, 1, result.addr)  # 1 is WASI's monotonic clock

proc NimMain() {.importc, cdecl.}

proc main(): cint {.exportc, cdecl.} =
  ## The program's entry point, which runs the bot's turn loop. Each bot's nim.cfg sets
  ## noMain, because wasi-libc can't start the main(argc, argv, env) Nim writes by default.
  NimMain()
