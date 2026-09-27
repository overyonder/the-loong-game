## Hunt: trade a short dragon for an enemy head, since a head-on collision kills both.
import std/options
from ../../../decision_architectures/hierarchical_state_machine import nil
from ../controller import nil
from ../movement import nil
from ../turn import nil
from ../window import nil

proc objective(state: turn.Turn, first: int): int =
  ## Enough room to live, then get close.
  min(window.room(state.view, first), 6) - 10 * window.gapToEnemy(state.view, first)

proc strike(state: turn.Turn): Option[turn.Action] =
  ## Straight into an adjacent enemy head.
  for side in 0 .. 3:
    let next = window.neighbour(window.Head, side)
    if next in state.view.enemyHeads and state.view.open[window.Head][side]:
      return some(turn.move(controller.UNSWBC_DIRECTIONS[side]))

proc hsmState*(): hierarchical_state_machine.State[turn.Turn, turn.Action] =
  ## Entered when an enemy head is in sight. The only behaviour allowed next to one.
  hierarchical_state_machine.State[turn.Turn, turn.Action](name: "Hunt",
    applies: proc(state: turn.Turn): bool = state.view.enemyHeads.len > 0,
    reflex: strike,
    act: proc(state: turn.Turn): turn.Action =
      movement.best(state, objective, allowEnemyReach = true))
