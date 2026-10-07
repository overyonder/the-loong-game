## Bradley–Terry ratings fitted offline to every game at once, on the Elo scale.
##
## A bot with strength s beats one with strength t with probability s / (s + t).
## Fitting all games together, instead of updating after each one, makes the
## ratings independent of the order the games were played in. Ratings are
## 1500 + 400 * log10(s), so 400 points is ten-to-one odds. A draw is half a win
## for each side, and failed executions are left out. A prior of one draw against
## a 1500-rated bot keeps a bot that won or lost every game finite. The fit is
## shifted so the pool averages 1500; ratings describe this pool only.

import std/[math, options, tables]

const
  EloScale* = 400 / ln(10.0)
  Z95 = 1.959964   ## two-sided 95% normal quantile, for intervals on a score

type
  Outcome* = object
    ## One game as the fit sees it: its sides, and the winner's index (0 A,
    ## 1 B, -1 a draw). Failed games are left out by the caller.
    a*, b*:  string
    winner*: int

proc elo*(score: float): Option[float] =
  ## The Elo difference an expected score implies; none at or beyond 0 or 1.
  if score <= 0 or score >= 1: none(float)
  else: some(400 * log10(score / (1 - score)))

proc eloInterval*(wins, draws, losses: int): tuple[centre, low, high: Option[float]] =
  ## Implied Elo and its 95% interval from one pairing's games. The score, a
  ## draw counting half, gets a normal-approximation interval of ±1.96
  ## standard errors, each end mapped through `elo`.
  let games = wins + draws + losses
  if games == 0: return
  let score = (float(wins) + float(draws) / 2) / float(games)
  let margin = Z95 * sqrt(score * (1 - score) / float(games))
  (elo(score), elo(score - margin), elo(score + margin))

proc square(size: int): seq[seq[float]] =
  for _ in 0 ..< size: result.add newSeq[float](size)

proc solve(matrix: seq[seq[float]], vector: seq[float]): seq[float] =
  ## A symmetric positive-definite system, by Cholesky decomposition.
  let size = vector.len
  var lower = square(size)
  for i in 0 ..< size:
    for j in 0 .. i:
      var total = matrix[i][j]
      for k in 0 ..< j: total -= lower[i][k] * lower[j][k]
      lower[i][j] = if i == j: sqrt(total) else: total / lower[j][j]
  var forward = newSeq[float](size)
  for i in 0 ..< size:
    var total = vector[i]
    for k in 0 ..< i: total -= lower[i][k] * forward[k]
    forward[i] = total / lower[i][i]
  result = newSeq[float](size)
  for i in countdown(size - 1, 0):
    var total = forward[i]
    for k in i + 1 ..< size: total -= lower[k][i] * result[k]
    result[i] = total / lower[i][i]

proc fitRatings*(bots: seq[string], games: seq[Outcome],
    start = initTable[string, float]()): Table[string, float] =
  ## Maximum a posteriori ratings by Newton's method on the log-posterior. It
  ## is concave in log strength, so each step solves the system its Hessian
  ## gives; `start`, earlier ratings, only saves steps.
  let size = bots.len
  var index: Table[string, int]
  for position, bot in bots: index[bot] = position
  var scores = square(size)
  for game in games:
    let (a, b) = (index[game.a], index[game.b])
    if a == b: continue
    case game.winner
    of 0: scores[a][b] += 1
    of 1: scores[b][a] += 1
    else:
      scores[a][b] += 0.5
      scores[b][a] += 0.5
  var points = newSeq[float](size)
  var played = square(size)
  for i in 0 ..< size:
    points[i] = 0.5
    for j in 0 ..< size:
      if i != j:
        points[i] += scores[i][j]
        played[i][j] = scores[i][j] + scores[j][i]
  var theta = newSeq[float](size)
  for i, bot in bots: theta[i] = (start.getOrDefault(bot, 1500.0) - 1500) / EloScale
  for _ in 0 ..< 100:
    # Gradient and negated Hessian, the prior game against strength 1 included.
    var gradient = points
    var hessian = square(size)
    for i in 0 ..< size:
      var expected = 1 / (1 + exp(-theta[i]))
      gradient[i] -= expected
      hessian[i][i] += expected * (1 - expected)
      for j in 0 ..< size:
        if played[i][j] != 0:
          expected = 1 / (1 + exp(theta[j] - theta[i]))
          gradient[i] -= played[i][j] * expected
          let curvature = played[i][j] * expected * (1 - expected)
          hessian[i][i] += curvature
          hessian[i][j] -= curvature
    let step = solve(hessian, gradient)
    # Far from the optimum a full step can overshoot; one unit is 174 points.
    var largest = 0.0
    for value in step: largest = max(largest, abs(value))
    let scale = if largest > 0: min(1.0, 1 / largest) else: 1.0
    for i in 0 ..< size: theta[i] += scale * step[i]
    if largest < 1e-10: break
  let mean = sum(theta) / float(size)
  for i, bot in bots: result[bot] = 1500 + EloScale * (theta[i] - mean)
