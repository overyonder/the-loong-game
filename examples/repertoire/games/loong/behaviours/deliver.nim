## Deliver: a grown dragon travels to the champion and dies against its body,
## so its segments become pearls where the champion can reach them.
import std/[math, options]
from ../../../decision_architectures/hierarchical_state_machine import nil
from ../controller import nil
from ../movement import nil
from ../turn import nil
from ../window import nil

proc objective(state: turn.Turn, first: int): int =
  ## Travel towards where the champion was last heard from.
  let (dx, dy) = turn.homeward(state)
  let (column, row) = (first mod window.Size - window.Head mod window.Size,
    first div window.Size - window.Head div window.Size)
  min(window.room(state.view, first), 10) * 4 + 8 * (column * sgn(dx) + row * sgn(dy))

proc sacrifice(state: turn.Turn): Option[turn.Action] =
  ## Straight into the champion's body, close to its head. Only the mover dies.
  let w = state.view
  if w.championHead < 0: return
  for side in 0 .. 3:
    let next = window.neighbour(window.Head, side)
    if next >= 0 and w.championBody[next] and w.open[window.Head][side] and
        window.distance(window.Head, w.championHead) <= 2:
      return some(turn.move(controller.UNSWBC_DIRECTIONS[side]))

proc hsmState*(atLength, memoryTurns: int): hierarchical_state_machine.State[turn.Turn, turn.Action] =
  ## Entered at `atLength` segments, while the champion was heard within `memoryTurns`.
  hierarchical_state_machine.State[turn.Turn, turn.Action](name: "Deliver",
    applies: proc(state: turn.Turn): bool =
      state.length >= atLength and state.heard.turnsAgo <= memoryTurns,
    reflex: sacrifice,
    act: proc(state: turn.Turn): turn.Action = movement.best(state, objective))
