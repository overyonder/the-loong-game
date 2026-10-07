## Buildings, chosen by biome and style and placed where they fit, with the
## spiral nests the first dragon may start coiled in and the stockades round
## the other camps.

import std/[algorithm, math, strutils, tables]
import canvas, world
import ../[python_math, python_random, python_set]

proc nest(wd: World, camp: Tile, L: int): seq[Tile] =
  ## A square spiral round a camp, as the coiled starts of Slithery Fight: one
  ## corridor winding in, walls between its turns. The first dragon lies
  ## coiled in it, head at the mouth. Nothing when it doesn't fit.
  let cv = wd.cv
  var path: seq[Tile]
  if wd.rng.random < 0.6:
    var k = 3
    while k * k < L + 2: inc k
    path = @[camp]
    var (x, y) = camp
    const steps = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    var segment = 1
    var direction = wd.rng.randrange(4)
    let turn = wd.rng.choice([1, -1])
    while path.len < k * k:
      for _ in 0 ..< 2:
        let (dx, dy) = steps[floorMod(direction, 4)]
        for _ in 0 ..< segment:
          if path.len >= k * k: break
          (x, y) = (x + dx, y + dy)
          path.add (x, y)
        direction += turn
      inc segment
  else:
    # a zig-zag channel instead, rows back and forth (community1)
    let bw = wd.rng.randint(3, 6)
    let rows = max(2, -floorDiv(-(L + 2), bw))
    let (sx, sy) = (wd.rng.choice([1, -1]), wd.rng.choice([1, -1]))
    for r in 0 ..< rows:
      if r mod 2 == 0:
        for x in 0 ..< bw: path.add (camp[0] + sx * x, camp[1] + sy * r)
      else:
        for x in countdown(bw - 1, 0): path.add (camp[0] + sx * x, camp[1] + sy * r)
    if wd.rng.random < 0.5:
      var turned: seq[Tile]
      for (x, y) in path: turned.add (camp[0] + (y - camp[1]), camp[1] + (x - camp[0]))
      path = turned
  if cv.closed:
    for (px, py) in path:
      if not (1 <= px and px < cv.w - 1 and 1 <= py and py < cv.h - 1): return
  for index in 0 ..< path.len: path[index] = (floorMod(path[index][0], cv.w), floorMod(path[index][1], cv.h))
  let square = setOf(path)
  let around = newPySet[Tile]()
  for t in square:
    for d in Dirs: around.incl cv.nb(t, d)
  let ring = square | around
  if cv.mirrored(ring).meets(ring): return
  for t in ring:
    if t in cv.solid or t in wd.occupied: return
  for t in square:
    for d in Dirs:
      if cv.kindOf(cv.edge(t, d)) != 0: return
  var index = initTable[Tile, int]()
  for i, t in path: index[t] = i
  for t in path:
    for d in Dirs:
      let n = cv.nb(t, d)
      if n notin square or abs(index[n] - index[t]) != 1: cv.put(cv.edge(t, d), 1)
  let mouth = path[^1]
  let (hx, hy) = (float(cv.w - 1) / 2, float(cv.h - 1) / 2)
  var best: Direction
  var bestScore = -Inf
  for d in Dirs:
    if cv.nb(mouth, d) in square: continue
    let score = float(d.dx) * (hx - float(mouth[0])) + float(d.dy) * (hy - float(mouth[1]))
    if score > bestScore: (best, bestScore) = (d, score)
  cv.put(cv.edge(mouth, best), 0)
  wd.occupied |= ring | cv.mirrored(ring)
  path.reversed

proc stockade(wd: World, camp: Tile): bool =
  ## A gated palisade round a spawn clearing.
  let cv = wd.cv
  let r = wd.rng.choice([3, 3, 4])
  let (x0, y0) = (camp[0] - r, camp[1] - r)
  let n = 2 * r + 1
  if cv.closed and (x0 < 1 or y0 < 1 or x0 + n > cv.w - 1 or y0 + n > cv.h - 1): return false
  let tiles = wd.rect(x0, y0, n, n)
  let ring = setOf(wd.rect(x0 - 1, y0 - 1, n + 2, n + 2))
  if ring.meets(wd.occupied): return false
  for t in ring:
    if t in cv.solid: return false
  if cv.mirrored(ring).meets(ring): return false
  for t in tiles:
    for d in Dirs:
      if cv.kindOf(cv.edge(t, d)) != 0: return false
  let chain = wd.side(x0, y0, n, n, 'N') & wd.side(x0, y0, n, n, 'E') &
              wd.side(x0, y0, n, n, 'S').reversed & wd.side(x0, y0, n, n, 'W').reversed
  wd.wallChain(chain, wd.rng.randint(5, 7))
  wd.occupied |= ring | cv.mirrored(ring)
  true

proc bRoom(wd: World, i: int): bool =
  var (bw, bh) = (wd.fit(3, 6), wd.fit(3, 5))
  if wd.rng.random < 0.5: swap(bw, bh)
  let (found, at) = wd.site(i, bw, bh)
  if not found: return false
  let (x0, y0) = at
  let tiles = wd.rect(x0, y0, bw, bh)
  wd.cv.enclose(tiles)
  let sides = wd.facing(x0, y0, bw, bh)
  wd.door(wd.side(x0, y0, bw, bh, sides[0]), wd.rng.choice([1, 1, 2]))
  let oneDoor = wd.rng.random < 0.4
  if not oneDoor: wd.door(wd.side(x0, y0, bw, bh, wd.rng.choice(sides[1 .. ^1])))
  # a one-door room is a pocket: worth more, and a trap
  let tier = if oneDoor: "rich" else: "fair"
  for t in tiles: wd.tag(t, tier)
  true

proc bComplex(wd: World, i: int): bool =
  ## A building of several rooms: binary space partition, one door per inner
  ## wall, two ways in. The deepest room holds the treasure.
  let cv = wd.cv
  let cap = max(6, int(sqrt(float(wd.members[i].len))) + 1)
  var bw = wd.fit(6, min(10, cap + 2))
  var bh = wd.fit(5, min(8, cap))
  if bw == 0 or bh == 0: return wd.bRoom(i)
  if wd.rng.random < 0.5: swap(bw, bh)
  let (found, at) = wd.site(i, bw, bh)
  if not found: return false
  let (x0, y0) = at
  var leaves: seq[(int, int, int, int)]
  proc split(x, y, ww, hh, depth: int) =
    let (canV, canH) = (ww >= 6, hh >= 6)
    if not (canV or canH) or ww * hh <= 12 or (depth >= 2 and wd.rng.random < 0.4):
      leaves.add (x, y, ww, hh)
      return
    let vertical = canV and (not canH or ww > hh or (ww == hh and wd.rng.random < 0.5))
    var wall: seq[Edge]
    if vertical:
      let c = wd.rng.randint(3, ww - 3)
      for dy in 0 ..< hh: wall.add cv.edge(wd.R(x0, y0, x + c, y + dy), 'W')
      split(x, y, c, hh, depth + 1)
      split(x + c, y, ww - c, hh, depth + 1)
    else:
      let c = wd.rng.randint(3, hh - 3)
      for dx in 0 ..< ww: wall.add cv.edge(wd.R(x0, y0, x + dx, y + c), 'N')
      split(x, y, ww, c, depth + 1)
      split(x, y + c, ww, hh - c, depth + 1)
    for e in wall: cv.put(e, 1)
    wd.door(wall, if wall.len >= 6 and wd.rng.random < 0.3: 2 else: 1)
  let tiles = wd.rect(x0, y0, bw, bh)
  cv.enclose(tiles)
  split(0, 0, bw, bh, 0)
  let sides = wd.facing(x0, y0, bw, bh)
  var entry: seq[Tile]
  let inside = setOf(tiles)
  for d in [sides[0], wd.rng.choice(sides[2 .. ^1])]:
    let run = wd.side(x0, y0, bw, bh, d)
    wd.door(run, wd.rng.choice([1, 2]))
    for e in run:
      if cv.kindOf(e) == 0:
        let (a, b) = cv.sides(e)
        for t in [a, b]:
          if t in inside: entry.add t
  let depth = cv.bfs(entry, blocked = proc (t: Tile): bool = t notin inside)
  var rooms: seq[(int, seq[Tile])]
  for (x, y, ww, hh) in leaves:
    let roomTiles = wd.rect(x0 + x, y0 + y, ww, hh)
    var shallowest = high(int)
    for t in roomTiles: shallowest = min(shallowest, depth.getOrDefault(t, 99))
    rooms.add (shallowest, roomTiles)
  var keys: seq[int]
  for room in rooms: keys.add -room[0]
  for k, room in stableSortedBy(rooms, keys):
    let roomTiles = room[1]
    let tier = if k == 0: (if roomTiles.len <= 9: "hot" else: "rich") elif k == 1: "fair" else: ""
    if tier.len > 0:
      for t in roomTiles: wd.tag(t, tier)
  true

proc bLabyrinth(wd: World, i: int): bool =
  ## A walled labyrinth: 2x2 cells, or a dense 1-wide warren; a perfect maze
  ## with a few loops, two or three gates, pearls in its dead ends.
  let cv = wd.cv
  let sideLength = int(sqrt(float(wd.members[i].len)))
  let c = wd.rng.choice([1, 2])
  let limit = floorDiv(max(3, floorDiv(min(cv.w, cv.h), 2) - 2), c)
  if limit < 3: return wd.bRoom(i)
  var found = false
  var at: Tile
  let top = if c == 2: 8 else: 14
  let shapes = newPySet[Tile]()
  for a in [0, -1, -2, -4]:
    for b in [0, -1, -2, -4]:
      shapes.incl (max(3, min(min(top, limit), floorDiv(sideLength, c) + a)),
                   max(3, min(min(top - 1, limit), floorDiv(sideLength, c) + b)))
  var candidates = shapes.toSeq
  var keys: seq[int]
  for p in candidates: keys.add -p[0] * p[1]
  var (cw, chh) = (0, 0)
  for shape in stableSortedBy(candidates, keys):
    (cw, chh) = shape
    if wd.rng.random < 0.5: swap(cw, chh)
    (found, at) = wd.site(i, c * cw, c * chh)
    if found: break
  if not found: return false
  let (x0, y0) = at
  let (bw, bh) = (c * cw, c * chh)
  cv.enclose(wd.rect(x0, y0, bw, bh))
  let links = wd.maze(cw, chh, 0.08)
  wd.drawMaze(bounds(bw, c), bounds(bh, c), links,
              proc (u, v: int, d: Direction): Edge = cv.edge(wd.R(x0, y0, u, v), d))
  let sides = wd.facing(x0, y0, bw, bh)
  var gates = @[sides[0], sides[0].opposite]
  if wd.rng.random < 0.6: gates.add wd.rng.choice(sides[1 .. 2])
  for gate in gates:
    let run = wd.side(x0, y0, bw, bh, gate)
    let k = wd.rng.randrange(floorDiv(run.len, c))
    for e in run.pySlice(c * k, c * k + c): cv.put(e, 0)
  for cell, degree in degrees(links):
    let (a, b) = cell
    if degree == 1 and (c == 2 or wd.rng.random < 0.5):
      for t in wd.rect(x0 + c * a, y0 + c * b, c, c): wd.tag(t, "rich")
  true

proc bCloister(wd: World, i: int): bool =
  ## A walled ring round an inner sanctum; the two doors never line up.
  let (bw, bh) = (wd.fit(7, 9), wd.fit(7, 8))
  if bw == 0 or bh == 0: return wd.bComplex(i)
  let (found, at) = wd.site(i, bw, bh)
  if not found: return false
  let (x0, y0) = at
  let cv = wd.cv
  cv.enclose(wd.rect(x0, y0, bw, bh))
  let inner = wd.rect(x0 + 2, y0 + 2, bw - 4, bh - 4)
  cv.enclose(inner)
  let sides = wd.facing(x0, y0, bw, bh)
  wd.door(wd.side(x0, y0, bw, bh, sides[0]), wd.rng.choice([1, 2]))
  wd.door(wd.side(x0 + 2, y0 + 2, bw - 4, bh - 4, sides[0].opposite))
  for t in inner: wd.tag(t, "rich")
  true

proc bStalls(wd: World, i: int): bool =
  ## Two rows of 2x2 stalls facing a two-wide aisle, one door each, like the
  ## pearl boxes of the official Portals map.
  let cv = wd.cv
  var k = wd.fit(4, 8)
  if k == 0 or wd.fit(6, 6) == 0: return wd.bRoom(i)
  k = floorDiv(k, 2)
  let horizontal = wd.rng.random < 0.5
  let (bw, bh) = if horizontal: (2 * k, 6) else: (6, 2 * k)
  let (found, at) = wd.site(i, bw, bh)
  if not found: return false
  let (x0, y0) = at
  for j in 0 ..< k:
    for row in [0, 4]:
      let (sx, sy) = if horizontal: (x0 + 2 * j, y0 + row) else: (x0 + row, y0 + 2 * j)
      let cell = wd.rect(sx, sy, 2, 2)
      cv.enclose(cell)
      let front = if horizontal: (if row == 0: 'S' else: 'N') else: (if row == 0: 'E' else: 'W')
      let run = wd.side(sx, sy, 2, 2, front)
      cv.put(run[wd.rng.randrange(2)], 0)
      let tier = if wd.rng.random < 0.35: "rich" else: "fair"
      for t in cell: wd.tag(t, tier)
  true

proc bColonnade(wd: World, i: int): bool =
  ## A plaza of pillars three apart: cover to weave through, pearls between.
  let (bw, bh) = (wd.fit(5, 10), wd.fit(5, 9))
  if bw == 0 or bh == 0: return wd.bRoom(i)
  let (found, at) = wd.site(i, bw, bh)
  if not found: return false
  let (x0, y0) = at
  let (ox, oy) = (wd.rng.randint(1, 2), wd.rng.randint(1, 2))
  for dy in countup(oy, bh - 1, 3):
    for dx in countup(ox, bw - 1, 3): wd.cv.post(wd.R(x0, y0, dx, dy))
  for t in wd.rect(x0, y0, bw, bh):
    if wd.rng.random < 0.6: wd.tag(t, "fair")
  true

proc bRampart(wd: World, i: int): bool =
  ## A breakwater: one long straight wall across open water, with gates.
  let cv = wd.cv
  let memset = wd.memset[i]
  let (sx, sy) = (floorMod(pythonRound(wd.seeds[i][0]), cv.w), floorMod(pythonRound(wd.seeds[i][1]), cv.h))
  let horizontal = wd.rng.random < 0.5
  var run = @[(sx, sy)]
  for sign in [-1, 1]:
    var t = (sx, sy)
    while true:
      t = cv.nb(t, if horizontal: (if sign > 0: 'E' else: 'W') else: (if sign > 0: 'S' else: 'N'))
      if t notin memset or t in wd.occupied or t in cv.solid or t in run or run.len > 30: break
      run.add t
  run.sort
  if run.len < 8: return false
  var chain: seq[Edge]
  for t in run: chain.add cv.edge(t, if horizontal: 'N' else: 'W')
  for e in chain:
    if cv.kindOf(e) != 0 or cv.me(e) in chain: return false
  wd.wallChain(chain, wd.rng.randint(5, 8))
  let band = newPySet[Tile]()
  for t in run:
    let both = newPySet[Tile]()
    both.incl t
    both.incl cv.nb(t, if horizontal: 'N' else: 'W')
    band |= both
  wd.occupied |= band | cv.mirrored(band)
  true

proc build(wd: World, kind: string, i: int): bool =
  case kind
  of "room": wd.bRoom(i)
  of "complex": wd.bComplex(i)
  of "labyrinth": wd.bLabyrinth(i)
  of "cloister": wd.bCloister(i)
  of "stalls": wd.bStalls(i)
  of "colonnade": wd.bColonnade(i)
  else: wd.bRampart(i)

proc architecture*(wd: World) =
  ## Buildings, chosen by biome and style, placed where they fit.
  wd.memset = @[]
  for members in wd.members: wd.memset.add setOf(members)
  wd.nestPath = @[]
  if wd.style.open:
    wd.buildings = 0
    wd.wantBuildings = 0
    return
  var built = initOrderedTable[string, int]()
  # camps first: the first may hold a spiral nest, the rest a stockade
  if wd.rng.random < max(wd.style.nest, wd.nestBias):
    let L = wd.rng.randint(5, 12)
    wd.nestPath = wd.nest(wd.camps[0], L)
    if wd.nestPath.len > 0:
      wd.nestLen = L
      built["nest"] = 1
  for c in wd.camps:
    if wd.nestPath.len > 0 and c == wd.camps[0]: continue
    if wd.rng.random < wd.style.stockade and wd.stockade(c):
      built["stockade"] = built.getOrDefault("stockade", 0) + 1
  var districts: seq[int]
  var keys: seq[(bool, int)]
  for j in 0 ..< wd.seeds.len:
    districts.add j
    keys.add (wd.roles[j] != "frontier", j)
  for i in stableSortedBy(districts, keys):
    if i > wd.smir[i]: continue
    let options = biome(wd.biome[i]).build
    if options.len == 0: continue
    let size = wd.members[i].len
    let count = min(4, 1 + floorDiv(size, 70))
    for _ in 0 ..< count:
      var kinds: seq[string]
      var weights: seq[float]
      for (k, weight) in options:
        kinds.add k
        weights.add weight * wd.style.build.weight(k)
      let kind = wd.rng.choices(kinds, weights)[0]
      if kind.len > 0 and wd.build(kind, i): built[kind] = built.getOrDefault(kind, 0) + 1
  # every world has architecture: open styles leave ground empty by choice,
  # but never the whole map
  let want = max(if wd.lmBuilt: 1 else: 2, pythonRound(float(wd.area - wd.lmArea) / 280))
  var candidates: seq[int]
  for i in 0 ..< wd.seeds.len:
    if i > wd.smir[i]: continue
    for (k, _) in biome(wd.biome[i]).build:
      if k.len > 0:
        candidates.add i
        break
  for _ in 0 ..< 40:
    var total = 0
    for count in built.values: total += count
    if total - built.getOrDefault("stockade", 0) >= want or candidates.len == 0: break
    let i = wd.rng.choice(candidates)
    var kinds: seq[string]
    var weights: seq[float]
    for (k, weight) in biome(wd.biome[i]).build:
      if k.len > 0:
        kinds.add k
        weights.add weight * wd.style.build.weight(k)
    let kind = wd.rng.choices(kinds, weights)[0]
    if wd.build(kind, i): built[kind] = built.getOrDefault(kind, 0) + 1
  wd.buildings = 0
  for count in built.values: wd.buildings += count
  wd.wantBuildings = want
  if built.len > 0:
    var names: seq[string]
    for k in built.keys: names.add k
    names.sort
    var parts: seq[string]
    for k in names:
      let n = built[k]
      parts.add $n & " " & k & (if n > 1 and not k.endsWith("s"): "s" else: "")
    wd.log(parts.join(", "))
