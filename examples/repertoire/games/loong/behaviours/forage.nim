## Forage: head for the nearest visible pearl, keeping some room.
from ../../../decision_architectures/hierarchical_state_machine import nil
from ../movement import nil
from ../turn import nil
from ../window import nil

proc objective(state: turn.Turn, first: int): int =
  min(window.room(state.view, first), 10) * 4 - 6 * window.nearestPearl(state.view, first)

proc hsmState*(): hierarchical_state_machine.State[turn.Turn, turn.Action] =
  hierarchical_state_machine.State[turn.Turn, turn.Action](name: "Forage",
    act: proc(state: turn.Turn): turn.Action = movement.best(state, objective))
