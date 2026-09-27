## Choosing a step: hard constraints first, then the behaviour's own objective.
from controller import nil
from turn import nil
from window import nil

type Objective* = proc(state: turn.Turn, first: int): int
  ## How good a first step is, by one behaviour's measure.

proc safeSteps(w: window.Window, allowEnemyReach: bool): seq[int] =
  ## First steps that avoid kelp, portals, bodies and, unless allowed, tiles an enemy head could also reach.
  for side in 0 .. 3:
    let next = window.step(w, window.Head, side)
    if next >= 0 and (allowEnemyReach or window.gapToEnemy(w, next) > 1):
      result.add side

proc best*(state: turn.Turn, objective: Objective, allowEnemyReach = false): turn.Action =
  ## The safe step the objective scores highest, or the least bad one when nothing is safe.
  let w = state.view
  var candidates = safeSteps(w, allowEnemyReach)
  if candidates.len == 0:
    # Nothing is fully safe. Accept an enemy head's reach before a certain death.
    candidates = safeSteps(w, allowEnemyReach = true)
  if candidates.len == 0:
    # Only a portal or nothing is left. A portal leads somewhere we can't see, which beats a wall.
    for side in 0 .. 3:
      if w.portal[window.Head][side] and not w.occupied[window.neighbour(window.Head, side)]:
        return turn.move(controller.UNSWBC_DIRECTIONS[side])
    return turn.move(state.facing)
  let score = proc(side: int): int = objective(state, window.step(w, window.Head, side))
  var chosen = candidates[0]
  for side in candidates:
    if score(side) > score(chosen): chosen = side
  turn.move(controller.UNSWBC_DIRECTIONS[chosen])
