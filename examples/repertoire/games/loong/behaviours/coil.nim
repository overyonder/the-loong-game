## Coil: curl up against our own body, never so tightly that we box ourselves in.
from ../../../decision_architectures/hierarchical_state_machine import nil
from ../movement import nil
from ../turn import nil
from ../window import nil

proc objective(state: turn.Turn, first: int): int =
  ## Eat any pearl in reach, hug our own body while there's room to spare, and keep room.
  let room = window.room(state.view, first)
  (if state.view.pearl[first]: 100 else: 0) +
    (if room >= 10: 20 * window.ownBodyAround(state.view, first) else: 0) + room

proc hsmState*(clearOf: int): hierarchical_state_machine.State[turn.Turn, turn.Action] =
  ## Entered when no enemy head is within `clearOf` tiles.
  hierarchical_state_machine.State[turn.Turn, turn.Action](name: "Coil",
    applies: proc(state: turn.Turn): bool = window.gapToEnemy(state.view, window.Head) > clearOf,
    act: proc(state: turn.Turn): turn.Action = movement.best(state, objective))
