# The four things a dragon can choose to do, each scored for this turn on one
# utility scale. The highest eligible score wins.
from ../repertoire/games/loong/window import nil
from diagnostic_descriptions import nil

diagnostic_descriptions.describedEnum(purpose):
  type Option* = enum
    Flee {.purpose: "Step away from an enemy head that could reach us".}
    Eat {.purpose: "Take the nearest pearl we can reach".}
    Split {.purpose: "Split off a child once long enough and unthreatened".}
    Explore {.purpose: "Keep the most room when nothing else applies".}

const
  Unsafe* = -1.0e9   # a side's measure when that step is ruled out
  Sides* = "NESW"

type
  Evaluation* = object
    eligible*: bool
    score*: float          # utility, comparable across options
    reason*: string
    measure*: string       # what `sides` measures, for this option alone
    sides*: array[4, float]  # each first step by `measure`, or Unsafe
    formula*: string
    operands*: seq[(string, float)]

  Look* = object
    ## What every option reads: the window and a few facts drawn from it.
    view*: window.Window
    length*: int
    canSplit*: bool
    safe*: array[4, int]      # the window tile each safe first step reaches, or -1
    threat*: int              # the nearest enemy head's distance, window.Size if none
    threatAt*: int            # its window tile, or -1
    pearlSteps*: int          # moves to the nearest reachable pearl, -1 if none
    pearlAt*: int             # its window tile
    route*: seq[int]          # window tiles from the head to that pearl
    reached*: seq[(int, int)] # every tile the search reached, with its distance

proc search(view: window.Window, start: int): seq[(int, int)] =
  ## Breadth-first over open, unoccupied tiles: (tile, distance), nearest first.
  var distance: array[window.Tiles, int]
  for tile in distance.mitems: tile = -1
  distance[start] = 0
  result.add (start, 0)
  var cursor = 0
  while cursor < result.len:
    let (tile, steps) = result[cursor]
    for side in 0 .. 3:
      let next = window.step(view, tile, side)
      if next >= 0 and distance[next] < 0:
        distance[next] = steps + 1
        result.add (next, steps + 1)
    inc cursor

proc stepsTo(view: window.Window, start, goal: int): int =
  for (tile, steps) in search(view, start):
    if tile == goal: return steps
  -1

proc look*(view: window.Window, length: int, canSplit: bool): Look =
  result = Look(view: view, length: length, canSplit: canSplit, pearlSteps: -1, pearlAt: -1,
    threatAt: -1, threat: window.Size)
  for head in view.enemyHeads:
    if window.distance(window.Head, head) < result.threat:
      result.threat = window.distance(window.Head, head)
      result.threatAt = head
  var safe: array[4, int]
  var any = false
  for side in 0 .. 3:
    safe[side] = window.step(view, window.Head, side)
    if safe[side] >= 0 and window.gapToEnemy(view, safe[side]) > 1: any = true
  for side in 0 .. 3:
    # Where some step keeps out of an enemy head's reach, only those steps are safe.
    if safe[side] >= 0 and any and window.gapToEnemy(view, safe[side]) <= 1: safe[side] = -1
  result.safe = safe
  # The search starts from the head: the head's own tile counts as occupied,
  # so the search steps off it first.
  var parent: array[window.Tiles, int]
  var seen: set[0 .. window.Tiles - 1] = {window.Head}
  var frontier = @[window.Head]
  var steps = 0
  while frontier.len > 0 and result.pearlAt < 0:
    inc steps
    var next: seq[int]
    for tile in frontier:
      for side in 0 .. 3:
        let reached = window.step(view, tile, side)
        if reached < 0 or reached in seen: continue
        if tile == window.Head and safe[side] < 0: continue
        seen.incl reached
        parent[reached] = tile
        next.add reached
        if view.pearl[reached] and result.pearlAt < 0:
          result.pearlAt = reached
          result.pearlSteps = steps
    frontier = next
  if result.pearlAt >= 0:
    var tile = result.pearlAt
    while tile != window.Head:
      result.route.insert(tile, 0)
      tile = parent[tile]
    result.route.insert(window.Head, 0)
  result.reached = search(view, window.Head)

proc evaluate*(option: Option, look: Look): Evaluation =
  for side in 0 .. 3: result.sides[side] = Unsafe
  case option
  of Flee:
    result.eligible = look.threat <= 2
    result.measure = "distance from the enemy head"
    result.score = 10.0 - 3.0 * float(look.threat)
    result.formula = "utility = 10 - 3 × distance"
    result.operands = @[("distance", float(look.threat))]
    result.reason = if result.eligible: "An enemy head is " & $look.threat & " away"
      else: "No enemy head within 2"
    for side in 0 .. 3:
      if look.safe[side] >= 0: result.sides[side] = float(window.gapToEnemy(look.view, look.safe[side]))
  of Eat:
    result.eligible = look.pearlSteps > 0
    result.measure = "moves to the pearl"
    result.score = 8.0 - float(look.pearlSteps)
    result.formula = "utility = 8 - moves"
    result.operands = @[("moves", float(look.pearlSteps))]
    result.reason = if result.eligible: "A pearl is " & $look.pearlSteps & " moves away"
      else: "No pearl reachable in view"
    if result.eligible:
      for side in 0 .. 3:
        if look.safe[side] >= 0:
          let steps = stepsTo(look.view, look.safe[side], look.pearlAt)
          if steps >= 0: result.sides[side] = -float(steps)
  of Split:
    result.eligible = look.length >= 8 and look.canSplit and look.threat > 3
    result.measure = "child size"
    result.score = float(look.length - 6)
    result.formula = "utility = length - 6"
    result.operands = @[("length", float(look.length))]
    result.reason =
      if look.length < 8: "Length " & $look.length & " is under 8"
      elif not look.canSplit: "The team is at its dragon limit"
      elif look.threat <= 3: "An enemy head is within 3"
      else: "Length " & $look.length & " and no enemy head within 3"
  of Explore:
    result.eligible = true
    result.measure = "room after two moves"
    result.score = 1.0
    result.formula = "utility = 1"
    result.reason = "Always available"
    for side in 0 .. 3:
      if look.safe[side] >= 0: result.sides[side] = float(window.room(look.view, look.safe[side]))

proc best*(evaluation: Evaluation): int =
  ## The side with the best measure, or -1 when every side is ruled out.
  result = -1
  for side in 0 .. 3:
    if evaluation.sides[side] > Unsafe and (result < 0 or evaluation.sides[side] > evaluation.sides[result]):
      result = side
