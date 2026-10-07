## Map-scale landmarks, one per world at most. The central ones (citadel,
## labyrinth, palace, city, serpent hall) sit on the symmetry axis and are
## planned before the camps, which settle round them. The great wall and the
## lanes are a mirrored pair of lines, one before each side; the effigies and
## the lattice spread over the whole map.

import std/[algorithm, math, tables]
import canvas, world
import ../[python_math, python_random, python_set]

proc planLandmark*(wd: World) =
  ## Fix the central landmark's footprint before the camps exist, so the
  ## camps and districts settle round it rather than the other way round.
  let cv = wd.cv
  let kind = wd.landmarkKind
  if kind notin LandmarkMinimum: return
  let (w, h) = (cv.w, cv.h)
  let road = if cv.closed: 2 else: 1
  # the camps need a strip of open ground on both ends of the axis
  var caps: seq[(int, int)]
  let strip = 2 * max(8, 5 + wd.reqPerSide)   # room for each side's camps and dragons
  if cv.sym in ["y", "xy"]: caps.add (w - strip, h - 2 * road - 2)
  if cv.sym in ["x", "xy"]: caps.add (w - 2 * road - 2, h - strip)
  let lo = LandmarkMinimum[kind]
  var fitting: seq[(int, int)]
  for c in caps:
    if min(c[0], c[1]) >= lo: fitting.add c
  if fitting.len > 0:
    var (cw, ch) = fitting[0]
    for c in fitting:
      if c[0] * c[1] > cw * ch: (cw, ch) = c
    let share = if kind == "serpent": (0.45, 0.65) else: (0.28, 0.5)
    let want = float(wd.area) * wd.rng.uniform(share[0], share[1])
    var fw = min(cw, max(lo, pythonRound(sqrt(want * float(cw) / float(ch)))))
    var fh = min(ch, max(lo, pythonRound(want / float(fw))))
    # a footprint that is its own mirror image: centred on the axis
    if cv.sym in ["y", "xy"] and floorMod(w - fw, 2) != 0: dec fw
    if cv.sym in ["x", "xy"] and floorMod(h - fh, 2) != 0: dec fh
    proc free(n, f: int): int =
      if cv.closed: wd.rng.randint(road, n - road - f) else: wd.rng.randrange(n)
    if min(fw, fh) >= lo:
      let x0 = if cv.sym in ["y", "xy"]: floorDiv(w - fw, 2) else: free(w, fw)
      let y0 = if cv.sym in ["x", "xy"]: floorDiv(h - fh, 2) else: free(h, fh)
      wd.lm = Landmark(kind: kind, x0: x0, y0: y0, fw: fw, fh: fh)
      wd.hasLm = true
      wd.reserved = setOf(wd.rect(x0 - 1, y0 - 1, fw + 2, fh + 2))
      return
  wd.landmarkKind = "wall"   # no room on the axis: fortify the fronts instead

proc lmCitadel(wd: World) =
  ## Concentric curtain walls with staggered gates, radial walls cutting the
  ## baileys into wards, corner towers, and a keep with the treasure.
  let (U, V) = (wd.fu, wd.fv)
  let g = if min(U, V) < 19: 3 else: wd.rng.choice([3, 4])
  var rings = @[(0, 0, U, V)]
  while rings.len < 3 and min(rings[^1][2], rings[^1][3]) - 2 * g >= 7:
    let (u0, v0, uw, vh) = rings[^1]
    rings.add (u0 + g, v0 + g, uw - 2 * g, vh - 2 * g)
  proc keepDim(n: int): int =
    result = n - 4   # a ward at least two wide all round
    while result > 6: result -= 2
  block:
    let (u0, v0, uw, vh) = rings[^1]
    let (ku, kv) = (keepDim(uw), keepDim(vh))
    if min(ku, kv) >= 3: rings.add (u0 + floorDiv(uw - ku, 2), v0 + floorDiv(vh - kv, 2), ku, kv)
  for r in rings: wd.lbox(r[0], r[1], r[2], r[3])
  if min(U, V) >= 13:   # corner towers
    for v in [1, V - 1]: wd.cv.post(wd.T(1, v))
  # radial walls: each bailey is cut into wards, one door in each cut
  for k in 0 ..< rings.len - 1:
    let (ou, ov, _, _) = rings[k]
    let (iu, iv, _, ih) = rings[k + 1]
    for _ in 0 ..< wd.rng.randint(1, 2):
      var run: seq[Edge]
      if wd.rng.random < 0.5 and floorDiv(U, 2) - 1 > iu + 1:
        let c = wd.rng.randint(iu + 1, floorDiv(U, 2) - 1)
        for v in ov ..< iv: run.add wd.le(c, v, 'W')
      else:
        if ih < 4: continue
        let c = wd.rng.randint(iv + 1, iv + ih - 2)
        for u in ou ..< iu: run.add wd.le(u, c, 'N')
      var onRock = false
      for e in run:
        let (a, b) = wd.cv.sides(e)
        if a in wd.cv.solid or b in wd.cv.solid: onRock = true
      if onRock: continue
      wd.lwall(run)
      wd.door(run)
  # gates, staggered ring by ring so the way in winds round each bailey
  var previous = ' '
  for k, r in rings:
    let d = if k == 0: 'W' elif previous == 'W': wd.rng.choice(['N', 'S']) else: 'W'
    var run = wd.lside(r, d)
    if d != 'W': run = nearRun(run, r[2])
    let keep = k == rings.len - 1 and k > 0
    wd.door(run, if keep: 1 else: 2)
    if k == 0 and wd.rng.random < 0.5:   # a postern on the far side
      wd.door(nearRun(wd.lside(r, wd.rng.choice(['N', 'S'])), r[2]))
    previous = d
  # treasure: the keep, then the inner ward, then the baileys
  for k, r in rings:
    let tiles = wd.lrect(r[0], r[1], r[2], r[3])
    if k == rings.len - 1 and k > 0: wd.ltag(tiles, "hot")
    elif k == rings.len - 2: wd.ltag(tiles, "rich", 0.45)
    elif k > 0: wd.ltag(tiles, "fair", 0.35)

proc lmLabyrinth(wd: World) =
  ## A great labyrinth on each side of a processional way along the axis:
  ## 2-wide corridors, or 1-wide warrens with chambers carved into them (as
  ## Stronghold and Trauma). The way holds the sanctum and is reached only
  ## through the maze; the pearls wait in the dead ends.
  let (U, V) = (wd.fu, wd.fv)
  let c = if wd.rng.random < 0.45: 1 else: 2
  let s = if c == 2: (if floorMod(U, 4) != 0: floorMod(U, 4) else: 4) else: (if floorMod(U, 2) != 0: 1 else: 2)
  let hu = floorDiv(U - s, 2)
  if hu < 2 * c or V < 6:
    wd.lmCitadel()
    return
  let (cb, rb) = (bounds(hu, c), bounds(V, c))
  let (nc, nr) = (cb.len - 1, rb.len - 1)
  let links = wd.maze(nc, nr, if c == 2: 0.07 else: 0.1)
  wd.lbox(0, 0, U, V)
  var way: seq[Edge]
  for v in 0 ..< V: way.add wd.le(hu, v, 'W')
  wd.lwall(way)   # the processional way's wall
  wd.drawMaze(cb, rb, links, proc (u, v: int, d: Direction): Edge = wd.le(u, v, d))
  # openings: into the way, and gates in the outer wall
  var population: seq[int]
  for j in 0 ..< nr: population.add j
  for j in wd.rng.sample(population, min(nr, if nr < 6: 2 else: 3)):
    wd.cv.put(wd.le(hu, wd.rng.randrange(rb[j], rb[j + 1]), 'W'), 0)
  for j in wd.rng.sample(population, min(nr, 2)):
    var run: seq[Edge]
    for v in rb[j] ..< rb[j + 1]: run.add wd.le(0, v, 'W')
    wd.lwall(run.pySlice(0, 2), 0)
  if wd.rng.random < 0.5:
    let i = wd.rng.randrange(nc)
    var run: seq[Edge]
    for u in cb[i] ..< cb[i + 1]: run.add wd.le(u, 0, 'N')
    wd.lwall(run.pySlice(0, 2), 0)
  var cells: seq[(Tile, int)]
  for cell, degree in degrees(links): cells.add (cell, degree)
  cells.sort
  for (cell, degree) in cells:
    let (i, j) = cell
    if degree == 1 and (c == 2 or wd.rng.random < 0.5):
      wd.ltag(wd.lrect(cb[i], rb[j], cb[i + 1] - cb[i], rb[j + 1] - rb[j]), "rich")
  if c == 1:
    # chambers: clear the maze inside a few rectangles; their walls are the
    # maze's own, so every way through the chamber survives
    for _ in 0 ..< max(1, floorDiv(hu * V, 45)):
      let (cw, ch) = (wd.rng.randint(2, 4), wd.rng.randint(2, 3))
      if cw >= hu - 1 or ch >= V - 1: continue
      let (u0, v0) = (wd.rng.randint(0, hu - cw), wd.rng.randint(0, V - ch))
      for u in u0 ..< u0 + cw:
        for v in v0 ..< v0 + ch:
          if u + 1 < u0 + cw: wd.cv.put(wd.le(u, v, 'E'), 0)
          if v + 1 < v0 + ch: wd.cv.put(wd.le(u, v, 'S'), 0)
      wd.ltag(wd.lrect(u0, v0, cw, ch), "rich", 0.7)
  let middle = floorDiv(V, 2)
  wd.ltag(wd.lrect(hu, middle - 1, U - 2 * hu, 2), "hot")

proc lmPalace(wd: World) =
  ## A great hall along the axis, wings of rooms either side split by binary
  ## partition, courtyards among them, the treasury deepest in.
  let cv = wd.cv
  let (U, V) = (wd.fu, wd.fv)
  var s = if floorMod(U, 2) != 0: wd.rng.choice([3, 5]) else: wd.rng.choice([2, 4])
  while floorDiv(U - s, 2) < 3 and s > 2: s -= 2
  let hu = floorDiv(U - s, 2)
  wd.lbox(0, 0, U, V)
  var hall: seq[Edge]
  for v in 0 ..< V: hall.add wd.le(hu, v, 'W')
  wd.lwall(hall)
  var leaves: seq[(int, int, int, int)]
  var splits: seq[seq[Edge]]
  proc split(u, v, uw, vh, depth: int) =
    let (canU, canV) = (uw >= 6, vh >= 6)
    if not (canU or canV) or (depth >= 2 and uw * vh <= 20) or (depth >= 3 and wd.rng.random < 0.35):
      leaves.add (u, v, uw, vh)
      return
    if canU and (not canV or float(uw) > float(vh) * 1.2 or wd.rng.random < 0.3):
      let c = wd.rng.randint(3, uw - 3)
      var run: seq[Edge]
      for k in 0 ..< vh: run.add wd.le(u + c, v + k, 'W')
      splits.add run
      split(u, v, c, vh, depth + 1)
      split(u + c, v, uw - c, vh, depth + 1)
    else:
      let c = wd.rng.randint(3, vh - 3)
      var run: seq[Edge]
      for k in 0 ..< uw: run.add wd.le(u + k, v + c, 'N')
      splits.add run
      split(u, v, uw, c, depth + 1)
      split(u, v + c, uw, vh - c, depth + 1)
  split(0, 0, hu, V, 0)
  for run in splits: wd.lwall(run)
  for run in splits: wd.door(run, if run.len >= 7 and wd.rng.random < 0.3: 2 else: 1)
  # rooms on the hall open into it (at least two do)
  var hallSide: seq[(int, int, int, int)]
  for leaf in leaves:
    if leaf[0] + leaf[2] == hu: hallSide.add leaf
  var indices: seq[int]
  for k in 0 ..< hallSide.len: indices.add k
  let forced = toPySet(wd.rng.sample(indices, min(2, hallSide.len)))
  for k, leaf in hallSide:
    if k in forced or wd.rng.random < 0.5: wd.door(wd.lside(leaf, 'E'))
  # the hall's great doors at both ends, and a side door into a wing
  var top, bottom: seq[Edge]
  for u in hu ..< U - hu:
    top.add wd.le(u, 0, 'N')
    bottom.add wd.le(u, V - 1, 'S')
  let cut = if s >= 4: 1 else: 0
  wd.lwall(top.pySlice(cut, top.len - cut), 0)
  wd.lwall(bottom.pySlice(cut, top.len - cut), 0)
  var outer: seq[(int, int, int, int)]
  for leaf in leaves:
    if leaf[0] == 0: outer.add leaf
  if outer.len > 0: wd.door(wd.lside(wd.rng.choice(outer), 'W'))
  if s == 5:   # colonnaded hall
    for v in countup(2, V - 2, 3): cv.post(wd.T(hu + 1, v))
  # courtyards and treasure
  let depth = wd.depthFromOutside
  var rooms: seq[(int, seq[Tile])]
  for leaf in leaves:
    let tiles = wd.lrect(leaf[0], leaf[1], leaf[2], leaf[3])
    if leaf[2] * leaf[3] >= 20 and wd.rng.random < 0.35:
      cv.post(wd.T(leaf[0] + floorDiv(leaf[2], 2), leaf[1] + floorDiv(leaf[3], 2)))   # a fountain
      wd.ltag(tiles, "fair", 0.6)
      continue
    var deepest = low(int)
    for t in tiles: deepest = max(deepest, depth.getOrDefault(t, 0))
    rooms.add (deepest, tiles)
  var keys: seq[int]
  for room in rooms: keys.add -room[0]
  for k, room in stableSortedBy(rooms, keys):
    let tiles = room[1]
    if k == 0: wd.ltag(tiles, if tiles.len <= 12: "hot" else: "rich")
    elif k <= 2: wd.ltag(tiles, "rich")
    else: wd.ltag(tiles, "fair", 0.5)
  wd.ltag(wd.lrect(hu, floorDiv(V, 2) - 1, U - 2 * hu, 2), "rich")   # the throne

proc parts(wd: World, n: int, lo = 4, hi = 9, gap = 2): seq[(int, int)] =
  ## Blocks lo..hi long with gap-wide streets between them, filling a run of
  ## n tiles; any remainder widens the last street.
  var position = 0
  while n - position >= lo:
    let rest = n - position
    if rest <= hi:
      result.add (position, rest)
      break
    let b = wd.rng.randint(lo, min(7, rest - gap - lo))
    result.add (position, b)
    position += b + gap

proc cityBlock(wd: World, kind: string, bu, bv, bw, bh: int): seq[(seq[Edge], int)] =
  ## Build one city block; return the doors to open once all walls stand.
  let cv = wd.cv
  if kind == "park":
    if min(bw, bh) >= 5 and wd.rng.random < 0.6:
      cv.post(wd.T(bu + floorDiv(bw, 2), bv + floorDiv(bh, 2)))   # an old tree
    wd.ltag(wd.lrect(bu, bv, bw, bh), "fair", 0.5)
    return
  if kind == "temple":
    wd.lbox(bu, bv, bw, bh)
    wd.lbox(bu + 1, bv + 1, bw - 2, bh - 2)
    let d = wd.rng.choice(Dirs)
    result.add (wd.lside(bu, bv, bw, bh, d), if min(bw, bh) >= 6: 2 else: 1)
    result.add (wd.lside(bu + 1, bv + 1, bw - 2, bh - 2, d.opposite), 1)
    wd.ltag(wd.lrect(bu + 1, bv + 1, bw - 2, bh - 2), "rich")
    return
  if kind == "market":
    # stalls along the two long sides, facing the aisle between them
    let alongV = bh >= bw
    let n = floorDiv(if alongV: bh else: bw, 2)
    for k in 0 ..< n:
      for row in [0, 1]:
        var (su, sv) = (0, 0)
        var front: Direction
        if alongV:
          (su, sv) = ((if row == 0: bu else: bu + bw - 2), bv + 2 * k)
          front = if row == 0: 'E' else: 'W'
        else:
          (su, sv) = (bu + 2 * k, (if row == 0: bv else: bv + bh - 2))
          front = if row == 0: 'S' else: 'N'
        wd.lbox(su, sv, 2, 2)
        result.add (wd.lside(su, sv, 2, 2, front), 1)
        wd.ltag(wd.lrect(su, sv, 2, 2), if wd.rng.random < 0.35: "rich" else: "fair")
    return
  # houses: one, or two back to back
  var houses = @[(bu, bv, bw, bh)]
  if bw * bh >= 20 and wd.rng.random < 0.7:
    if bw >= bh and bw >= 6:
      let c = wd.rng.randint(3, bw - 3)
      houses = @[(bu, bv, c, bh), (bu + c, bv, bw - c, bh)]
    elif bh >= 6:
      let c = wd.rng.randint(3, bh - 3)
      houses = @[(bu, bv, bw, c), (bu, bv + c, bw, bh - c)]
  for house in houses:
    wd.lbox(house[0], house[1], house[2], house[3])
    let (u0, v0, uw, vh) = house
    var street: seq[Direction]
    for d in Dirs:
      if (d == 'W' and u0 == bu) or (d == 'E' and u0 + uw == bu + bw) or
         (d == 'N' and v0 == bv) or (d == 'S' and v0 + vh == bv + bh): street.add d
    let n = if wd.rng.random < 0.55: 1 else: 2
    for d in wd.rng.sample(street, min(n, street.len)): result.add (wd.lside(house, d), 1)
    wd.ltag(wd.lrect(house[0], house[1], house[2], house[3]), if n == 1: "rich" else: "fair", 0.7)

proc lmCity(wd: World) =
  ## A walled city: a ring road inside the wall, blocks of houses, temples,
  ## markets and parks between two-wide streets, and an avenue along the axis
  ## with a fountain square.
  let cv = wd.cv
  let (U, V) = (wd.fu, wd.fv)
  let s = if floorMod(U, 2) != 0: 3 else: wd.rng.choice([2, 4])
  let hu = floorDiv(U - s, 2)
  wd.lbox(0, 0, U, V)
  var ub, vb: seq[(int, int)]
  for (a, n) in wd.parts(hu - 1): ub.add (1 + a, n)
  for (a, n) in wd.parts(V - 2): vb.add (1 + a, n)
  var doors: seq[(seq[Edge], int)]
  for (bu, bw) in ub:
    for (bv, bh) in vb:
      var kinds = @[("house", 5.0), ("park", 1.2)]
      if min(bw, bh) >= 5: kinds.add [("temple", 1.5), ("market", 1.2)]
      if bu + bw >= hu - 1 and bv <= floorDiv(V, 2) and floorDiv(V, 2) < bv + bh:
        kinds = @[("park", 1.0)]   # the square by the avenue
      var names: seq[string]
      var weights: seq[float]
      for (k, weight) in kinds:
        names.add k
        weights.add weight
      let kind = wd.rng.choices(names, weights)[0]
      doors.add wd.cityBlock(kind, bu, bv, bw, bh)
  for (run, width) in doors: wd.door(run, width)
  # gates: the avenue's ends, and where streets meet the wall
  var avenue, back: seq[Edge]
  for u in hu ..< U - hu:
    avenue.add wd.le(u, 0, 'N')
    back.add wd.le(u, V - 1, 'S')
  let cut = if s == 4: 1 else: 0
  wd.lwall(avenue.pySlice(cut, avenue.len - cut), 0)
  wd.lwall(back.pySlice(cut, avenue.len - cut), 0)
  var streets: seq[int]
  for index in 0 ..< vb.len - 1: streets.add vb[index][0] + vb[index][1]
  for k, v in wd.rng.sample(streets, streets.len):
    if k == 0 or wd.rng.random < 0.4: wd.lwall([wd.le(0, v, 'W'), wd.le(0, v + 1, 'W')], 0)
  var crossing: seq[int]
  for index in 0 ..< ub.len - 1: crossing.add ub[index][0] + ub[index][1]
  if crossing.len > 0 and wd.rng.random < 0.6:
    let u = wd.rng.choice(crossing)
    wd.lwall([wd.le(u, 0, 'N'), wd.le(u + 1, 0, 'N')], 0)
  # the square: a fountain on the axis, pearls round it
  let mv = floorDiv(V, 2)
  if s == 3: cv.post(wd.T(hu + 1, mv))
  wd.ltag(wd.lrect(hu - 2, mv - 2, s + 4, 4), "rich", 0.7)

proc orientations(cv: Canvas): seq[char] =
  if cv.sym in ["y", "xy"]: result.add 'v'
  if cv.sym in ["x", "xy"]: result.add 'h'

proc lmWall(wd: World): bool =
  ## A great wall before each side: a fortified line across the whole map
  ## between the camps and the axis, gates flanked by towers, barracks behind
  ## it. Mirrored, so each side has its own.
  let cv = wd.cv
  let orients = cv.orientations
  for drawn in wd.rng.sample(orients, orients.len):
    let o = drawn
    let (W, Lh) = if o == 'v': (cv.w, cv.h) else: (cv.h, cv.w)
    let ax = float(W - 1) / 2
    var cs: seq[int]
    for c in wd.camps: cs.add(if o == 'v': c[0] else: c[1])
    var allLow, allHigh = true
    for c in cs:
      if not (float(c) < ax - 4): allLow = false
      if not (float(c) > ax + 4): allHigh = false
    if allLow: discard
    elif allHigh:
      for index in 0 ..< cs.len: cs[index] = W - 1 - cs[index]   # the mirror side's camps sit on the low side
    else: continue
    let (lo, hi) = (max(cs) + 4, floorDiv(W - 5, 2))
    if lo > hi: continue
    let p = wd.rng.randint(lo, hi)
    proc tile(a, b: int): Tile =
      if o == 'v': (floorMod(a, cv.w), floorMod(b, cv.h)) else: (floorMod(b, cv.w), floorMod(a, cv.h))
    proc E(a, b: int, d: Direction): Edge =   # edge at (across, along) in this orientation
      cv.edge(tile(a, b), if o == 'v': d else: TransposedDirection[d])
    var line: seq[Edge]
    for b in 0 ..< Lh: line.add E(p, b, 'W')
    var taken = false
    for a in p - 4 ..< p + 3:
      for b in 0 ..< Lh:
        if tile(a, b) in wd.occupied or tile(a, b) in cv.solid: taken = true
    if taken: continue
    wd.lwall(line)
    # gates every 6-10 tiles, each flanked by towers on the outer face
    var gates: seq[int]
    var b = wd.rng.randint(2, 5)
    while b + 1 < Lh - (if cv.closed: 2 else: 0):
      gates.add b
      b += wd.rng.randint(7, 11)
    if gates.len < 2: gates = @[floorDiv(Lh, 3), floorDiv(2 * Lh, 3)]
    for g in gates:
      # a gatehouse: the passage runs two tiles deep through the wall's outer
      # face, walled along both sides
      wd.lwall([line[g], line[floorMod(g + 1, Lh)]], 0)
      for bb in [g, g + 2]:
        if cv.closed and not (0 < bb and bb < Lh): continue
        wd.lwall([E(p, bb, 'N'), E(p + 1, bb, 'N')])
    # barracks behind the wall, between the gates
    var made = 0
    for index in 0 ..< gates.len - 1:
      let (g0, g1) = (gates[index], gates[index + 1])
      if g1 - g0 >= 7 and made < 2 and wd.rng.random < 0.7:
        let b0 = g0 + 3
        var room: seq[Tile]
        for a in p - 3 ..< p:
          for bb in b0 ..< b0 + 3: room.add tile(a, bb)
        var nearCamp = false
        for t in room:
          var closest = Inf
          for c in wd.camps: closest = min(closest, cv.dist(t, c))
          if closest < 3: nearCamp = true
        if nearCamp: continue
        cv.enclose(room)
        var run: seq[Edge]
        for bb in b0 ..< b0 + 3: run.add E(p - 3, bb, 'W')
        wd.door(run)
        for t in room: wd.tag(t, "rich")
        inc made
    let band = newPySet[Tile]()
    for a in p - 4 ..< p + 3:
      for b in 0 ..< Lh: band.incl tile(a, b)
    wd.occupied |= band | cv.mirrored(band)
    wd.log("great wall, " & $gates.len & " gates" & (if made > 0: ", " & $made & " barracks" else: ""))
    return true
  wd.log("no room for a great wall")
  false

# a stroke font on a vertex grid, x right, y down (Help writes with it)
proc glyph(letter: char): seq[(int, int, int, int)] =
  case letter
  of 'A': @[(0, 0, 0, 4), (3, 0, 3, 4), (0, 0, 3, 0), (0, 2, 3, 2)]
  of 'E': @[(0, 0, 0, 4), (0, 0, 3, 0), (0, 2, 2, 2), (0, 4, 3, 4)]
  of 'G': @[(0, 0, 3, 0), (0, 0, 0, 4), (0, 4, 3, 4), (3, 2, 3, 4), (2, 2, 3, 2)]
  of 'H': @[(0, 0, 0, 4), (3, 0, 3, 4), (0, 2, 3, 2)]
  of 'L': @[(0, 0, 0, 4), (0, 4, 3, 4)]
  of 'N': @[(0, 0, 0, 4), (3, 0, 3, 4), (0, 0, 1, 0), (1, 0, 1, 2), (1, 2, 2, 2), (2, 2, 2, 4), (2, 4, 3, 4)]
  of 'O': @[(0, 0, 3, 0), (0, 4, 3, 4), (0, 0, 0, 4), (3, 0, 3, 4)]
  of 'P': @[(0, 0, 0, 4), (0, 0, 3, 0), (3, 0, 3, 2), (0, 2, 3, 2)]
  of 'S': @[(0, 0, 3, 0), (0, 0, 0, 2), (0, 2, 3, 2), (3, 2, 3, 4), (0, 4, 3, 4)]
  of 'T': @[(0, 0, 4, 0), (2, 0, 2, 4)]
  else: @[(0, 0, 0, 4), (3, 0, 3, 4), (0, 4, 3, 4)]   # U

const Words = ["HELP", "GO", "EAT", "NEST", "LOOP", "HOLE", "GATE", "SEAL", "STOP", "SLOT", "PLAN", "GLUE",
               "TUNNEL", "PEN", "TOP", "HUNT", "SNAP", "GULP", "SPOT"]

proc glyphWidth(letter: char): int =
  for stroke in glyph(letter): result = max(result, max(stroke[0], stroke[2]))

proc wordWidth(word: string): int =
  for letter in word: result += glyphWidth(letter)
  result += 2 * (word.len - 1)

proc inscription(wd: World): bool =
  ## A word in kelp strokes on open ground; the mirror writes it again the
  ## other way round, as on Help.
  let cv = wd.cv
  let room = (if cv.sym == "x": cv.w else: floorDiv(cv.w, 2)) - 4
  var fits: seq[string]
  for word in Words:
    if wordWidth(word) <= room: fits.add word
  if fits.len == 0: return false
  let word = wd.rng.choice(fits)
  let (tw, th) = (wordWidth(word), 4)
  for _ in 0 ..< 80:
    let (x0, y0) = (wd.rng.randrange(cv.w), wd.rng.randrange(cv.h))
    if cv.closed and not (1 <= x0 and x0 + tw <= cv.w - 1 and 1 <= y0 and y0 + th <= cv.h - 1): continue
    let area = setOf(wd.rect(x0 - 1, y0 - 1, tw + 2, th + 2))
    if cv.mirrored(area).meets(area) or not wd.clearOf(area, camps = 3): continue
    var x = x0
    for letter in word:
      for (a, b, c, d) in glyph(letter):
        if b == d:
          for k in min(a, c) ..< max(a, c): cv.put(('h', floorMod(x + k, cv.w), floorMod(y0 + b, cv.h)), 1)
        else:
          for k in min(b, d) ..< max(b, d): cv.put(('v', floorMod(x + a, cv.w), floorMod(y0 + k, cv.h)), 1)
      x += glyphWidth(letter) + 2
    wd.claim(area, ring = 0)
    wd.log("the word " & word)
    return true
  false

proc lmEffigy(wd: World): bool =
  ## Line-art figures across the whole map, Rorschach-mirrored: a head outline
  ## with gates, ringed eyes holding the treasure, a mouth arc, and small
  ## rings scattered round them like bubbles.
  let cv = wd.cv
  let (w, h) = (cv.w, cv.h)
  var figures = 0
  let want = 1 + ord(wd.area > 800) + ord(wd.area > 1600)
  var tries = 0
  while figures < want and tries < 60:
    inc tries
    let rx = max(3.5, float(min(w, h)) * wd.rng.uniform(0.16, 0.26) * (if figures == 0: 1.3 else: 1.0) *
                      (1 - float(tries) / 90))
    let ry = rx * wd.rng.uniform(0.8, 1.35)
    var (cx, cy) = (0.0, 0.0)
    if figures == 0 and wd.rng.random < 0.6:   # the centrepiece sits on the axis
      (cx, cy) = wd.axisPoints[0]
    else:
      (cx, cy) = (wd.rng.uniform(0, float(w - 1)), wd.rng.uniform(0, float(h - 1)))
      if cv.dist((cx, cy), cv.mf((cx, cy))) < 2 * max(rx, ry) + 2: continue
    if cv.closed and not (rx + 1 <= cx and cx <= float(w - 2) - rx and ry + 1 <= cy and cy <= float(h - 2) - ry):
      continue
    let head = wd.blob(cx, cy, rx, ry, wd.rng.choice([1.6, 2.0, 2.0, 2.6, 4.0]))
    if not wd.clearOf(head): continue
    wd.draw(wd.outline(head), wd.rng.randint(11, 17))
    let er = max(1.0, min(rx, ry) * wd.rng.uniform(0.14, 0.22))
    let ex = rx * wd.rng.uniform(0.3, 0.45)
    let ey = ry * wd.rng.uniform(0.12, 0.32)
    for sx in [-1.0, 1.0]:
      let eye = wd.blob(cx + sx * ex, cy - ey, er + 0.5, (er + 0.5) * wd.rng.uniform(0.8, 1.3))
      if eye.len >= 2:
        wd.draw(wd.outline(eye), 99)
        for t in eye: wd.tag(t, if eye.len <= 6: "hot" else: "rich")
    let mx = rx * wd.rng.uniform(0.3, 0.55)
    let my = ry * wd.rng.uniform(0.3, 0.5)
    let mouth = wd.blob(cx, cy + my - 1.5, mx, 2.0)
    var arc: seq[Edge]
    for e in wd.outline(mouth):
      let (a, b) = cv.sides(e)
      let low = floorMod(cy + my - 1.5, float(h)) - 0.01
      if (float(a[1]) >= low or not cv.closed) and (float(b[1]) >= low or not cv.closed) and
         a in head and b in head: arc.add e
    if arc.len >= 3: wd.draw(arc)
    for t in head:
      if wd.rng.random < 0.25: wd.tag(t, "fair")
    if wd.rng.random < 0.5:
      # a crown on the head, teeth along its top (Queen of Spades)
      let cw = max(2, int(rx * 0.6))
      let ch = wd.rng.randint(2, 3)
      let top = int(floor(cy - ry)) + 1
      let drawn = newPySet[Tile]()
      for dx in -cw .. cw:
        for dy in 0 ..< ch:
          if not (dy == 0 and floorMod(dx + cw, 2) == 1): drawn.incl (pythonRound(cx) + dx, top - ch + dy)
      let crown = newPySet[Tile]()
      for (x, y) in drawn:
        if not cv.closed or (0 <= x and x < w and 1 <= y and y < h): crown.incl (floorMod(x, w), floorMod(y, h))
      if crown.len > 0 and wd.clearOf(crown, camps = 3):
        wd.draw(wd.outline(crown), 99)
        for t in crown: wd.tag(t, "rich")
        wd.claim(crown)
    wd.claim(head)
    inc figures
  if wd.rng.random < 0.6: discard wd.inscription()
  var bubbles = 0
  for _ in 0 ..< floorDiv(wd.area, 40):
    if bubbles >= floorDiv(wd.area, 110): break
    let (x, y) = (wd.rng.randrange(w), wd.rng.randrange(h))
    let r = wd.rng.choice([1.0, 1.0, 1.5, 2.0])
    let ring = wd.blob(float(x), float(y), r + 0.5, r + 0.5)
    if ring.len == 0 or cv.mirrored(ring).meets(ring): continue
    let around = newPySet[Tile]()
    for t in ring:
      for d in Dirs: around.incl cv.nb(t, d)
    if not wd.clearOf(ring | around): continue
    wd.draw(wd.outline(ring), 99)
    for t in ring: wd.tag(t, if ring.len <= 4: "rich" else: "fair")
    wd.claim(ring)
    inc bubbles
  if figures > 0: wd.log($figures & " effigies, " & $bubbles & " rings")
  figures > 0

proc lmLattice(wd: World): bool =
  ## A lattice of sealed pearl boxes over the whole map, reached only by
  ## portals from box to box (the Portals map), with a pearl zipper down the
  ## symmetry axis.
  let cv = wd.cv
  let (w, h) = (cv.w, cv.h)
  let (px, py) = (wd.rng.choice([4, 5, 5, 6]), wd.rng.choice([3, 4, 4, 5]))
  let (ox, oy) = (wd.rng.randrange(px), wd.rng.randrange(py))
  var boxes: seq[seq[Tile]]
  for gx in countup(ox, w - 2, px):
    for gy in countup(oy, h - 2, py):
      let box = wd.rect(gx, gy, 2, 2)
      var canonical = true
      for t in box:
        if not cv.isCanon(t): canonical = false
      if not canonical: continue
      if cv.closed and not (1 <= gx and gx + 2 <= w - 1 and 1 <= gy and gy + 2 <= h - 1): continue
      let ring = setOf(wd.rect(gx - 1, gy - 1, 4, 4))
      if cv.mirrored(ring).meets(ring) or not wd.clearOf(ring): continue
      boxes.add box
  wd.rng.shuffle(boxes)
  var made: seq[seq[Tile]]
  var linked = 0
  boxes = boxes.pySlice(0, max(4, floorDiv(wd.area, 30)))
  for box in boxes:
    cv.enclose(box)
    wd.claim(box)
    made.add box
  # portals: box to box, same side of each, so the outside of one leads into
  # the other; an odd box out opens onto far open ground
  var order = made
  while order.len >= 2:
    let b1 = order.pop
    var keys: seq[float]
    for b in order: keys.add -cv.dist(b[0], b1[0]) * wd.rng.uniform(0.6, 1.0)
    let far = stableSortedBy(order, keys)
    for b2 in far.pySlice(0, 6):
      let d = wd.rng.choice(Dirs)
      let (s1, s2) = (setOf(b1), setOf(b2))
      var o1, o2: seq[Edge]
      for t in b1:
        if cv.nb(t, d) notin s1: o1.add cv.edge(t, d)
      for t in b2:
        if cv.nb(t, d) notin s2: o2.add cv.edge(t, d)
      let e1 = wd.rng.choice(o1)
      let e2 = wd.rng.choice(o2)
      if cv.link(e1, e2):
        order.delete(order.find(b2))
        inc linked
        break
    # a box left without a partner stays sealed until repair opens a door
  for box in made: wd.ltag(box, if wd.rng.random < 0.3: "hot" else: "rich")
  # the zipper: a pearl lane on the axis between toothed walls
  var lane: seq[Tile]
  var teeth: seq[Edge]
  if cv.sym in ["y", "xy"]:
    let ax = floorDiv(w - 1, 2)
    for y in 0 ..< h: lane.add (ax, y)
    for y in 0 ..< h:
      if floorMod(y, 2) == wd.rng.randint(0, 1) or floorMod(y, 3) == 0: teeth.add cv.edge((ax, y), 'W')
  else:
    let ay = floorDiv(h - 1, 2)
    for x in 0 ..< w: lane.add (x, ay)
    for x in 0 ..< w:
      if floorMod(x, 2) == wd.rng.randint(0, 1) or floorMod(x, 3) == 0: teeth.add cv.edge((x, ay), 'N')
  var clear: seq[Tile]
  for t in lane:
    if wd.clearOf([t], camps = 3.5): clear.add t
  let keep = setOf(clear)
  for e in teeth:
    let (a, b) = cv.sides(e)
    if (a in keep or b in keep) and cv.kindOf(e) == 0: cv.put(e, 1)
  for t in keep: wd.tag(t, "rich")
  wd.claim(keep, ring = 0)
  wd.log("pearl lattice: " & $(2 * made.len) & " boxes, " & $linked & " portal pairs")
  made.len >= 4

proc lmSerpent(wd: World) =
  ## Slithery Fight's heart: a field of diagonal lanes between stepped walls,
  ## great halls on either side, and treasure galleries along the border. The
  ## lanes run one way on each side of the axis.
  let cv = wd.cv
  let (x0, y0, fw, fh) = wd.lmRect
  let (U, V) = (wd.fu, wd.fv)
  # halls on the near half; the lane field in the middle
  let hw = max(4, int(float(U) * wd.rng.uniform(0.2, 0.26)))
  let a = max(1, int(float(V) * wd.rng.uniform(0.08, 0.2)))
  let hall = (0, a, hw, V - 2 * a)
  wd.lbox(hall[0], hall[1], hall[2], hall[3])
  for d in ['W', 'N', 'S']:
    let run = wd.lside(hall, d)
    if d != 'W' or wd.rng.random < 0.6: wd.door(run, 2)
  wd.door(wd.lside(hall, 'E'), 2)
  wd.ltag(wd.lrect(1, a + 1, hw - 2, V - 2 * a - 2), "fair", 0.8)
  let (cu, cvv) = (float(U - 1) / 2, float(V - 1) / 2)
  let (rx, ry) = (float(U) / 2 - float(hw) - 0.5, float(V) / 2 - 0.3)
  let field = newPySet[Tile]()
  for u in hw + 1 ..< U - hw - 1:
    for v in 0 ..< V:
      if pow(abs((float(u) - cu) / rx), 1.6) + pow(abs((float(v) - cvv) / ry), 1.6) <= 1.0: field.incl (u, v)
  let W = wd.rng.choice([2, 2, 3])
  let sign = wd.rng.choice([-1, 1])
  proc lane(t: Tile): int = floorDiv(t[0] + sign * t[1], W)
  var walls: seq[Edge]
  for (u, v) in field:
    for d in ['E', 'S']:
      let n = (u + ord(d == 'E'), v + ord(d == 'S'))
      if n in field and lane((u, v)) != lane(n) and u < floorDiv(U, 2): walls.add wd.le(u, v, d)
  wd.draw(walls, wd.rng.randint(5, 8))
  var edgeField: seq[Edge]
  for (u, v) in field:
    for d in Dirs:
      if (u + d.dx, v + d.dy) notin field and u < floorDiv(U, 2): edgeField.add wd.le(u, v, d)
  wd.draw(edgeField, wd.rng.randint(6, 9))
  for (u, v) in field:
    if floorMod(lane((u, v)), 4) == 0 and wd.rng.random < 0.5: wd.tag(wd.T(u, v), "rich")
  wd.ltag(wd.lrect(int(cu) - 1, int(cvv) - 1, 3 - floorMod(U, 2) + 1, 2), "hot")
  # treasure galleries: pearl cells along the border, one door each
  if cv.closed:
    var cells: seq[Tile]
    if wd.ft:
      for y in y0 ..< y0 + fh: cells.add (0, y)
    else:
      for x in x0 ..< x0 + fw: cells.add (x, 0)
    if wd.clearOf(cells, camps = 4):
      let inward = if wd.ft: 'E' else: 'S'
      let stepping = if wd.ft: 'N' else: 'W'
      let far = cv.sym == (if wd.ft: "x" else: "y")   # the far border is not a mirror image here
      proc opposite(t: Tile): Tile = (if not wd.ft: (t[0], cv.h - 1) else: (cv.w - 1, t[1]))
      let farSide = if not wd.ft: 'N' else: 'W'
      for t in cells: cv.put(cv.edge(t, inward), 1)
      var k = 0
      while k < cells.len:
        let n = wd.rng.randint(3, 4)
        let cell = cells.pySlice(k, k + n)
        if cell.len >= 2:
          cv.put(cv.edge(cell[0], stepping), 1)
          cv.put(cv.edge(wd.rng.choice(cell), inward), 0)
        k += n
      if far:
        for t in cells: cv.put(cv.edge(opposite(t), farSide), 1)
        k = 0
        while k < cells.len:
          let n = wd.rng.randint(3, 4)
          var cell: seq[Tile]
          for t in cells.pySlice(k, k + n): cell.add opposite(t)
          if cell.len >= 2:
            cv.put(cv.edge(cell[0], stepping), 1)
            cv.put(cv.edge(wd.rng.choice(cell), farSide), 0)
          k += n
      for t in cells:
        wd.tag(t, if wd.rng.random < 0.4: "hot" else: "rich")
        if far: wd.tag(opposite(t), "rich")
      wd.claim(cells, ring = 1)
      if far:
        var opposites: seq[Tile]
        for t in cells: opposites.add opposite(t)
        wd.claim(opposites, ring = 1)
  wd.nestBias = 0.9

proc lmLanes(wd: World): bool =
  ## Devil's parallel lanes: full-length walls along the axis between the
  ## camps and the middle, a few gates in each, gold cells at the lane ends,
  ## alternate lanes rich.
  let cv = wd.cv
  let orients = cv.orientations
  for drawn in wd.rng.sample(orients, orients.len):
    let o = drawn
    let (W, Lh) = if o == 'v': (cv.w, cv.h) else: (cv.h, cv.w)
    let ax = float(W - 1) / 2
    var cs: seq[int]
    for c in wd.camps: cs.add(if o == 'v': c[0] else: c[1])
    var allLow, allHigh = true
    for c in cs:
      if not (float(c) < ax): allLow = false
      if not (float(c) > ax): allHigh = false
    if allLow: discard
    elif allHigh:
      for index in 0 ..< cs.len: cs[index] = W - 1 - cs[index]
    else: continue
    let (start, stop) = (max(cs) + 4, floorDiv(W, 2))   # walls at a in [start, stop]: the W edge of column a
    if stop - start < 3: continue
    proc tile(a, b: int): Tile =
      if o == 'v': (floorMod(a, cv.w), floorMod(b, cv.h)) else: (floorMod(b, cv.w), floorMod(a, cv.h))
    proc E(a, b: int, d: Direction): Edge = cv.edge(tile(a, b), if o == 'v': d else: TransposedDirection[d])
    var walls: seq[int]
    var a = start
    while a <= stop:
      walls.add a
      a += wd.rng.choice([1, 2, 2, 3])
    var taken = false
    if walls.len >= 2:
      for a in start - 1 ..< stop + 1:
        for b in 0 ..< Lh:
          if tile(a, b) in wd.occupied or tile(a, b) in cv.solid: taken = true
    if walls.len < 2 or taken: continue
    let ending = if cv.closed: 1 else: 0
    for a in walls:
      if a == W - a: continue   # on the axis itself: drawn by its mirror
      var line: seq[Edge]
      for b in 0 ..< Lh: line.add E(a, b, 'W')
      wd.lwall(line)
      for _ in 0 ..< wd.rng.randint(1, 3):   # gates
        let g = wd.rng.randint(ending + 1, Lh - ending - 3)
        wd.lwall(line.pySlice(g, g + wd.rng.choice([1, 2])), 0)
    # lanes: alternate rich; gold cells shut off at the lane ends
    for k in 0 ..< walls.len - 1:
      let (a0, a1) = (walls[k], walls[k + 1])
      var lane: seq[Tile]
      for a in a0 ..< a1:
        for b in 0 ..< Lh: lane.add tile(a, b)
      if k mod 2 == 0: wd.ltag(lane, "fair", 0.6)
      if cv.closed and a1 - a0 <= 2:
        for laneEnd in [0, Lh - 1]:
          let b = laneEnd
          var cap: seq[Tile]
          for a in a0 ..< a1: cap.add tile(a, b)
          proc capEdge(t: Tile): Edge =
            if o == 'v': cv.edge(t, if b == 0: 'S' else: 'N') else: cv.edge(t, if b == 0: 'E' else: 'W')
          for t in cap: cv.put(capEdge(t), 1)
          let opening = wd.rng.choice(cap)
          cv.put(capEdge(opening), 0)
          wd.ltag(cap, "hot")
    let band = newPySet[Tile]()
    for a in start - 1 ..< stop + 1:
      for b in 0 ..< Lh: band.incl tile(a, b)
    wd.claim(band, ring = 0)
    wd.log($(2 * (walls.len - 1)) & " lanes")
    return true
  wd.log("no room for lanes")
  false

proc landmark*(wd: World) =
  let kind = wd.landmarkKind
  if wd.hasLm:
    let (x0, y0, fw, fh) = wd.lmRect
    wd.frame(x0, y0, fw, fh)
    case kind
    of "citadel": wd.lmCitadel()
    of "labyrinth": wd.lmLabyrinth()
    of "palace": wd.lmPalace()
    of "city": wd.lmCity()
    else: wd.lmSerpent()
    for t in wd.rect(x0, y0, fw, fh): wd.tbiome[t] = "landmark"
    wd.occupied |= wd.reserved
    wd.lmBuilt = true
    wd.lmArea = fw * fh
    let title = case kind
      of "labyrinth": "great labyrinth"
      of "city": "walled city"
      of "serpent": "serpent hall"
      else: kind
    wd.log(title & " " & $fw & "x" & $fh)
  else:
    case kind
    of "wall": wd.lmBuilt = wd.lmWall()
    of "lanes": wd.lmBuilt = wd.lmLanes()
    of "effigy": wd.lmBuilt = wd.lmEffigy()
    of "lattice": wd.lmBuilt = wd.lmLattice()
    else: discard
