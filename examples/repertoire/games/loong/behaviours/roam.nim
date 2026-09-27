## Roam: nothing threatening in sight, so keep the most room.
from ../../../decision_architectures/hierarchical_state_machine import nil
from ../movement import nil
from ../turn import nil
from ../window import nil

proc objective(state: turn.Turn, first: int): int = window.room(state.view, first)

proc hsmState*(): hierarchical_state_machine.State[turn.Turn, turn.Action] =
  hierarchical_state_machine.State[turn.Turn, turn.Action](name: "Roam",
    act: proc(state: turn.Turn): turn.Action = movement.best(state, objective))
