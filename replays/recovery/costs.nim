## `loong-recover costs`: the points each kind of counted work costs, fitted to
## the judge's points per turn. A bot that budgets by counted work (its "Turn
## work" table, diagnostics.md) estimates a turn as the sum of each kind's units
## times its cost; this finds the non-negative costs that best predict the
## judge's points over every turn `loong-recover work` wrote, by least squares
## (Lawson and Hanson, Solving Least Squares Problems, 1974, chapter 23). A kind
## too rare to fit can be held at a cost measured otherwise with `--fix`.

import std/[algorithm, strformat, strutils, tables]

type Turn = object
  units: seq[float]
  points: float   ## The judge's points less the fixed kinds' share.
  total: float    ## The judge's points.

proc solve(normal: seq[seq[float]], target: seq[float], passive: seq[int]): seq[float] =
  ## The least-squares solution over the passive kinds, the others zero, by
  ## Gauss-Jordan elimination with partial pivoting on the normal equations.
  let m = passive.len
  var a = newSeq[seq[float]](m)
  for r in 0 ..< m:
    a[r] = newSeq[float](m + 1)
    for c in 0 ..< m: a[r][c] = normal[passive[r]][passive[c]]
    a[r][m] = target[passive[r]]
  for c in 0 ..< m:
    var pivot = c
    for r in c + 1 ..< m:
      if abs(a[r][c]) > abs(a[pivot][c]): pivot = r
    swap(a[c], a[pivot])
    if a[c][c] == 0: continue
    for r in 0 ..< m:
      if r == c: continue
      let factor = a[r][c] / a[c][c]
      for k in c .. m: a[r][k] -= factor * a[c][k]
  result = newSeq[float](target.len)
  for r in 0 ..< m:
    if a[r][r] != 0: result[passive[r]] = a[r][m] / a[r][r]

proc nonNegative(normal: seq[seq[float]], target: seq[float]): seq[float] =
  ## Lawson and Hanson's active-set method: add the kind whose cost would most
  ## reduce the error, solve over the kinds added, and step back to the
  ## boundary whenever a cost would go negative.
  let n = target.len
  result = newSeq[float](n)
  var passive: seq[int]
  for iteration in 0 ..< 4 * n:
    var best = -1
    var gain = 0.0
    for i in 0 ..< n:
      if i in passive: continue
      var gradient = target[i]
      for j in 0 ..< n: gradient -= normal[i][j] * result[j]
      if gradient > 1e-9 * (abs(target[i]) + 1) and gradient > gain: (best, gain) = (i, gradient)
    if best < 0: return
    passive.add best
    while true:
      let step = solve(normal, target, passive)
      var alpha = 1.0
      var bounded = false
      for i in passive:
        if step[i] <= 0:
          bounded = true
          alpha = min(alpha, result[i] / (result[i] - step[i]))
      if not bounded:
        result = step
        break
      for i in 0 ..< n: result[i] += alpha * (step[i] - result[i])
      var kept: seq[int]
      for i in passive:
        if result[i] > 1e-9: kept.add i
        else: result[i] = 0
      passive = kept

proc costs*(arguments: seq[string]): int =
  ## Fit the costs over the files `loong-recover work` wrote and print them,
  ## with how well they predict each turn's points; 1 when there are no turns.
  var fixed: Table[string, float]
  var files: seq[string]
  var index = 0
  while index < arguments.len:
    if arguments[index] == "--fix" and index + 1 < arguments.len:
      let pair = arguments[index + 1].split('=')
      if pair.len != 2: quit "--fix takes KIND=COST"
      fixed[pair[0]] = parseFloat(pair[1])
      index += 2
    else:
      files.add arguments[index]
      index += 1
  if files.len == 0: quit "usage: loong-recover costs [--fix KIND=COST]... WORK.tsv..."
  var kinds: seq[string]
  var turns: seq[Turn]
  for file in files:
    for line in lines(file):
      let fields = line.split('\t')
      if fields.len < 4: continue
      var turn = Turn(points: parseFloat(fields[2]), total: parseFloat(fields[2]))
      for pair in fields[3].splitWhitespace:
        let parts = pair.split('=')
        let units = parseFloat(parts[1])
        if parts[0] in fixed:
          turn.points -= units * fixed[parts[0]]
          continue
        var kind = kinds.find(parts[0])
        if kind < 0:
          kinds.add parts[0]
          kind = kinds.high
        if turn.units.len <= kind: turn.units.setLen(kind + 1)
        turn.units[kind] += units
      turns.add turn
  if turns.len == 0:
    stderr.writeLine "No turns to fit"
    return 1
  let n = kinds.len
  var normal = newSeq[seq[float]](n)
  for row in normal.mitems: row = newSeq[float](n)
  var target = newSeq[float](n)
  for turn in turns.mitems:
    turn.units.setLen(n)
    for i in 0 ..< n:
      target[i] += turn.units[i] * turn.points
      for j in 0 ..< n: normal[i][j] += turn.units[i] * turn.units[j]
  let cost = nonNegative(normal, target)
  echo &"{turns.len} turns"
  for i in 0 ..< n: echo &"{kinds[i]:<16}{int(cost[i] + 0.5):>14}"
  for kind, value in fixed: echo &"{kind:<16}{int(value + 0.5):>14}  (fixed)"
  # How the fit predicts each turn: the ratio's spread, and the turns it
  # underestimates most, which a budget has to leave room for.
  var ratios, actual: seq[float]
  var under: seq[(float, float, float)]
  for turn in turns:
    # The fixed kinds' share, taken off the points, counts as predicted.
    var predicted = turn.total - turn.points
    for i in 0 ..< n: predicted += turn.units[i] * cost[i]
    ratios.add predicted / turn.total
    actual.add turn.total
    under.add (predicted - turn.total, predicted, turn.total)
  ratios.sort
  actual.sort
  under.sort
  proc at(values: seq[float], share: float): float = values[min(values.high, int(share * float(values.len)))]
  echo &"predicted/actual p1 {ratios.at(0.01):.2f} p10 {ratios.at(0.1):.2f} p50 {ratios.at(0.5):.2f} " &
    &"p90 {ratios.at(0.9):.2f} p99 {ratios.at(0.99):.2f}"
  echo &"judge points: p50 {actual.at(0.5) / 1e6:.1f}M, max {actual[^1] / 1e6:.1f}M"
  echo "most underestimated:"
  for (_, predicted, points) in under[0 ..< min(5, under.len)]:
    echo &"  {predicted / 1e6:.1f}M predicted for {points / 1e6:.1f}M"
