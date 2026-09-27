## Evade: an enemy head is close, so keep room and open the gap to it.
from ../../../decision_architectures/hierarchical_state_machine import nil
from ../movement import nil
from ../turn import nil
from ../window import nil

proc objective(state: turn.Turn, first: int): int =
  window.room(state.view, first) + 4 * window.gapToEnemy(state.view, first)

proc hsmState*(within: int): hierarchical_state_machine.State[turn.Turn, turn.Action] =
  ## Entered when an enemy head is `within` tiles of ours.
  hierarchical_state_machine.State[turn.Turn, turn.Action](name: "Evade",
    applies: proc(state: turn.Turn): bool = window.gapToEnemy(state.view, window.Head) <= within,
    act: proc(state: turn.Turn): turn.Action = movement.best(state, objective))
