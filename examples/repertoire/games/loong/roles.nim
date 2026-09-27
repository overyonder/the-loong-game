## Roles: which of a team's jobs this dragon holds, as parent states whose
## children are the behaviours that job may use.
import std/options
from ../../decision_architectures/hierarchical_state_machine import nil
from turn import nil

type
  State = hierarchical_state_machine.State[turn.Turn, turn.Action]
  Reflex = proc(state: turn.Turn): Option[turn.Action]

proc champion*(children: openArray[State], reflex: Reflex = nil): State =
  ## The longest dragon we know of, which carries the team's length at round 500.
  State(name: "Champion", reflex: reflex, children: @children,
    applies: proc(state: turn.Turn): bool = state.length >= state.heard.longest)

proc kamikaze*(children: openArray[State], atMost = 3): State =
  ## A short dragon with a longer teammate, worth little alive.
  State(name: "Kamikaze", children: @children,
    applies: proc(state: turn.Turn): bool = state.length <= atMost)

proc other*(name: string, children: openArray[State]): State =
  ## Everyone else, under the name of the job they do.
  State(name: name, children: @children)
