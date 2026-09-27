## Hierarchical state machine, entered from the root every turn.
## Each state guards its own entry, and the first child whose guard holds is
## entered. A state on the path may act before its children, as a reflex; if
## none does, the deepest state reached acts. Transitions are all re-evaluated
## from the root, so the machine keeps no state between turns.
import std/options

type
  State*[Context, Action] = ref object
    name*: string
    applies*: proc(context: Context): bool ## Nil: always.
    reflex*: proc(context: Context): Option[Action] ## Optional: pre-empts the children.
    act*: proc(context: Context): Action ## Required on leaves.
    children*: seq[State[Context, Action]]

proc path*[Context, Action](root: State[Context, Action],
    context: Context): seq[State[Context, Action]] =
  ## The states entered this turn, root first.
  var state = root
  result.add(state)
  while state.children.len > 0:
    var entered = false
    for child in state.children:
      if child.applies == nil or child.applies(context):
        state = child
        entered = true
        break
    doAssert entered, state.name & " has no child whose guard holds"
    result.add(state)

proc decide*[Context, Action](path: openArray[State[Context, Action]],
    context: Context): Action =
  for state in path:
    if state.reflex != nil:
      let action = state.reflex(context)
      if action.isSome: return action.get
  path[^1].act(context)
