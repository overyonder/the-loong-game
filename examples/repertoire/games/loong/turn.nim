## One dragon's turn: what it knows, and what it can do.
from controller import nil
from window import nil

type
  Heard* = object
    ## What sonar has told this dragon about its team.
    longest*: int         # the longest teammate heard recently
    championId*: int      # that teammate's ID, where the protocol carries it
    championX*, championY*: int
    turnsAgo*: int

  Turn* = object
    ct*: ptr controller.Controller
    game*: ptr controller.Game
    id*, length*: int
    at*: controller.Position
    facing*: controller.Direction
    heard*: Heard
    view*: window.Window

  ActionKind* = enum Move, Split
  Action* = object
    case kind*: ActionKind
    of Move: side*: controller.Direction
    of Split: childSize*: int

proc move*(side: controller.Direction): Action = Action(kind: Move, side: side)
proc split*(childSize: int): Action = Action(kind: Split, childSize: childSize)

proc wrappedOffset(target, here, size: int): int =
  ## The shortest signed distance from here to target on a wrapping axis.
  result = (target - here) mod size
  if result > size div 2: result -= size
  elif result < -(size div 2): result += size

proc homeward*(turn: Turn): (int, int) =
  ## The way to where the champion was last heard from.
  (wrappedOffset(turn.heard.championX, turn.at.x, turn.game.width),
   wrappedOffset(turn.heard.championY, turn.at.y, turn.game.height))
