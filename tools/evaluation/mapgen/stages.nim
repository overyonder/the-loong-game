## The world's stages in pipeline order (climate, districts, biomes, borders,
## caves, the vault, pods, ridges, shrines, wormholes, repair, groves, the
## economy and the spawns), the judge that scores a finished world, its name,
## its `.map` text and its summary.

import std/[algorithm, math, strutils, tables]
import canvas, world, landmarks, buildings
import ../[python_math, python_random, python_set]

# ---------------------------------------------------------- stage 2

proc climate(wd: World) =
  let cv = wd.cv
  let base = max(6.0, sqrt(float(wd.area)) / 2.5)
  wd.elev = cv.field(wd.rng, base * 1.4)
  wd.fert = cv.field(wd.rng, base * 0.8)
  wd.wx = initValueNoise(wd.rng, cv.w, cv.h, base * 0.7)
  wd.wy = initValueNoise(wd.rng, cv.w, cv.h, base * 0.7)

# ---------------------------------------------------------- stage 3

proc campsAndDistricts(wd: World) =
  let cv = wd.cv
  let (w, h) = (cv.w, cv.h)
  let n = wd.reqPerSide
  wd.perSide = n
  let campCount = if n <= 2: 1 else: wd.rng.randint(1, min(3, n))
  let margin = if cv.closed: 2 else: 0
  var camps: seq[Tile]
  for _ in 0 ..< campCount:
    var best: Point
    var bestScore = -1e9
    for _ in 0 ..< 60:
      var p: Point
      for _ in 0 ..< 30:   # camps are drawn from the ground the landmark leaves open
        p[0] = wd.rng.uniform(float(margin + 1), float(w - 2 - margin))
        p[1] = wd.rng.uniform(float(margin + 1), float(h - 2 - margin))
        if not wd.hasLm or wd.rectDist(p, wd.lmRect) >= 3.5: break
      let t = (int(p[0]), int(p[1]))
      if not cv.isCanon(t): p = cv.mf(p)
      let separation = cv.dist(p, cv.mf(p))
      var spread = 99.0
      for c in camps: spread = min(spread, cv.dist(p, c.toPoint))
      var score = separation * wd.rng.uniform(0.8, 1.2) + min(spread, 12.0) * 1.5
      if separation < 6: score -= 100
      if wd.hasLm and wd.rectDist(p, wd.lmRect) < 3.5: score -= 1000   # a camp needs open ground outside the landmark
      if score > bestScore: (best, bestScore) = (p, score)
    camps.add (pythonRound(best[0]), pythonRound(best[1]))
  wd.camps = camps
  if wd.hasLm:
    var crowded = false
    for c in camps:
      if wd.rectDist(c.toPoint, wd.lmRect) < 3.5: crowded = true
    if crowded:
      wd.log("no room for the " & wd.lm.kind & " beside the camps")
      wd.hasLm = false
      wd.reserved = newPySet[Tile]()
      wd.landmarkKind = "wall"
  var seeds: seq[Point]
  var roles: seq[string]
  proc add(p: Point, role: string): int =
    let q = cv.mf(p)
    if cv.dist(p, q) < 0.01:
      seeds.add p
      roles.add role
      return 1
    seeds.add [p, q]
    roles.add [role, role]
    2
  for c in camps: discard add(c.toPoint, "camp")
  for p in wd.axisPoints: discard add(p, "heart")
  # ordinary districts are counted on their own: camps are small clearings and
  # must not use up the district budget of the map
  let target = max(6, min(44, pythonRound(float(wd.area) / (wd.style.darea * wd.rng.uniform(0.7, 1.3)))))
  let r = sqrt(float(wd.area) / float(target)) * 0.85
  var (tries, land) = (0, 0)
  while land < target and tries < 4000:
    inc tries
    let p = (wd.rng.uniform(0, float(w - 1)), wd.rng.uniform(0, float(h - 1)))
    var nearest = Inf
    for k, s in seeds: nearest = min(nearest, cv.dist(p, s) * (if roles[k] == "camp": 1.5 else: 1.0))
    if nearest < r * 0.9: continue
    if cv.dist(p, cv.mf(p)) < r * 0.9: continue
    if (int(p[0]), int(p[1])) in wd.reserved: continue
    land += add(p, "land")
  wd.seeds = seeds
  wd.roles = roles
  var indices: seq[int]
  for j in 0 ..< seeds.len: indices.add j
  wd.smir = @[]
  for i in 0 ..< seeds.len:
    let mirror = cv.mf(seeds[i])
    wd.smir.add indices.firstMinimum(proc (j: int): float = cv.dist(seeds[j], mirror))
  # assign tiles by warped nearest seed, canonical side first, mirror copies
  let amplitude = r * 0.45
  let campRadius = 4.5 + 0.5 * float(min(3, n))
  wd.assign = initOrderedTable[Tile, int]()
  for t in cv.tiles:
    if not cv.isCanon(t): continue
    let q = (float(t[0]) + (wd.wx.at(t[0], t[1]) - 0.5) * 2 * amplitude,
             float(t[1]) + (wd.wy.at(t[0], t[1]) - 0.5) * 2 * amplitude)
    # camps are clearings, not provinces: weaker pull and a hard radius
    let i = indices.firstMinimum(proc (j: int): float =
      let dd = cv.dist(q, seeds[j])
      if roles[j] == "camp": (if dd <= campRadius: dd * 1.5 else: 1e9) else: dd)
    wd.assign[t] = i
    let mt = cv.m(t)
    if mt != t: wd.assign[mt] = wd.smir[i]
  wd.members = newSeq[seq[Tile]](seeds.len)
  for t, i in wd.assign: wd.members[i].add t
  # role of each land district: frontier (contested) or home
  for i, s in seeds:
    if wd.roles[i] != "land": continue
    var (da, db) = (Inf, Inf)
    for c in camps:
      da = min(da, cv.dist(s, c.toPoint))
      db = min(db, cv.dist(s, cv.m(c).toPoint))
    wd.roles[i] = if abs(da - db) / max(1.0, da + db) < 0.2: "frontier" else: "home"

# ---------------------------------------------------------- stage 4

proc pickBiomes(wd: World) =
  let cv = wd.cv
  wd.biome = initOrderedTable[int, string]()
  for i, s in wd.seeds:
    if i in wd.biome: continue
    let role = wd.roles[i]
    let members = wd.members[i]
    var b: string
    if role == "camp": b = "camp"
    elif role == "heart":
      var inside = (floorMod(pythonRound(s[0]), cv.w), floorMod(pythonRound(s[1]), cv.h)) in wd.reserved
      inside = inside or wd.landmarkKind == "effigy"   # the centrepiece figure is the heart
      b = if wd.rng.random < wd.style.vault and members.len >= 16 and not inside: "vault"
          else: wd.rng.choice(["garden", "reef", "ruins"])
    else:
      var (e, f) = (0.5, 0.5)
      if members.len > 0:
        var elevations, fertilities: seq[float]
        for t in members:
          elevations.add wd.elev[t]
          fertilities.add wd.fert[t]
        e = pythonSum(elevations) / float(members.len)
        f = pythonSum(fertilities) / float(members.len)
      var (best, bestScore) = ("sea", -1.0)
      for name in BiomeNames:
        if name in ["camp", "vault", "garden", "landmark"]: continue
        let (ce, cf) = biome(name).ef
        var a = exp(-(pow(e - ce, 2.0) + pow(f - cf, 2.0)) / 0.2)
        a *= wd.style.bw.weight(name)
        if role == "frontier":
          a *= (case name
                of "reef", "ruins": 1.5
                of "maze": 0.7
                of "sea": 0.8
                else: 1.0)
        else:
          a *= (case name
                of "sea", "meadow": 1.3
                of "caves": 1.2
                else: 1.0)
        a *= wd.rng.uniform(0.6, 1.4)
        if a > bestScore: (best, bestScore) = (name, a)
      b = best
      if b == "maze" and members.len < 14: b = "ruins"
    wd.biome[i] = b
    wd.biome[wd.smir[i]] = b
  wd.tbiome = initOrderedTable[Tile, string]()
  for t, i in wd.assign: wd.tbiome[t] = wd.biome[i]

# ---------------------------------------------------------- stage 5

proc ridges(wd: World) =
  ## Long organic walls along elevation contour lines, with fords.
  let cv = wd.cv
  if wd.rng.random >= wd.style.ridges: return
  let count = wd.rng.randint(1, 2)
  var levels = wd.rng.sample([0.3, 0.45, 0.6, 0.75], count)
  levels.sort
  var edges: seq[Edge]
  for t in cv.tiles:
    if wd.tbiome[t] in ["camp", "vault"] or t in wd.occupied: continue
    for d in ['E', 'S']:
      let n = cv.nb(t, d)
      if wd.tbiome[n] in ["camp", "vault"] or n in wd.occupied: continue
      let (a, b) = (wd.elev[t], wd.elev[n])
      for level in levels:
        if min(a, b) < level and level <= max(a, b):
          edges.add cv.edge(t, d)
          break
  let done = newPySet[Edge]()
  var made = 0
  for chain in cv.chains(edges):
    if chain.len >= 6 and wd.fresh(chain, done):
      wd.wallChain(chain, wd.rng.randint(6, 11))
      inc made
  if made > 0: wd.log($made & " ridge(s)")

proc borders(wd: World) =
  let cv = wd.cv
  var walls = initTable[(int, int), seq[Edge]]()
  for t in cv.tiles:
    for d in ['E', 'S']:
      let n = cv.nb(t, d)
      if t in wd.reserved or n in wd.reserved: continue
      let (a, b) = (wd.assign[t], wd.assign[n])
      if a != b: walls.mgetOrPut((min(a, b), max(a, b)), @[]).add cv.edge(t, d)
  var keys: seq[(int, int)]
  for key in walls.keys: keys.add key
  keys.sort
  var done = initTable[(int, int), bool]()
  for key in keys:
    let (a, b) = key
    if key in done: continue
    let (ma, mb) = (wd.smir[a], wd.smir[b])
    done[key] = true
    done[(min(ma, mb), max(ma, mb))] = true
    let (ba, bb) = (wd.biome[a], wd.biome[b])
    # A border wall has a job: the outer wall of an enclosure (maze, caves),
    # or a gated front line between home ground and the contested frontier.
    # Anything else stays open ground.
    let enclosure = ba != bb and "caves" in [ba, bb] and not (ba in ["vault", "camp"] or bb in ["vault", "camp"])
    let roles = (wd.roles[a], wd.roles[b])
    let front = (roles == ("home", "frontier") or roles == ("frontier", "home")) and wd.rng.random < wd.style.front
    if not (enclosure or front): continue
    for chain in cv.chains(walls[key]): wd.wallChain(chain, wd.rng.randint(6, 10))

# ---------------------------------------------------------- stage 6: interiors

proc caves(wd: World, districts: seq[int]) =
  let cv = wd.cv
  let gathered = newPySet[Tile]()
  for i in districts:
    for t in wd.members[i]: gathered.incl t
  let members = gathered - wd.reserved
  if members.len == 0: return
  var rock = initTable[Tile, bool]()
  var ordered = members.toSeq
  ordered.sort
  for t in ordered:
    if cv.isCanon(t):
      let v = wd.rng.random < 0.45
      rock[t] = v
      rock[cv.m(t)] = v
  for _ in 0 ..< 4:
    var next = initTable[Tile, bool]()
    for t in members:
      var c = 0
      for dx in [-1, 0, 1]:
        for dy in [-1, 0, 1]:
          if dx != 0 or dy != 0:
            c += ord(rock.getOrDefault((floorMod(t[0] + dx, cv.w), floorMod(t[1] + dy, cv.h)), false))
      next[t] = c >= 5 or (rock[t] and c >= 4)
    rock = next
  let solid = newPySet[Tile]()
  for t in members:
    if rock[t]: solid.incl t
  if float(solid.len) > 0.55 * float(members.len): return
  # each blob of rock becomes a grotto: its outline is the cave wall, with
  # openings, and the hollow inside holds pearls. (Solid rock drew as
  # sealed, empty rooms, and the game has no rock.)
  let left = solid.copy
  var blobs: seq[PySet[Tile]]
  while left.len > 0:
    var first = (high(int), high(int))
    for t in left: first = min(first, t)
    let blob = newPySet[Tile]()
    blob.incl first
    var stack = @[first]
    left.excl first
    while stack.len > 0:
      let t = stack.pop
      for d in Dirs:
        let n = cv.nb(t, d)
        if n in left:
          left.excl n
          blob.incl n
          stack.add n
    blobs.add blob
  for blob in blobs:
    var (lowest, lowestMirror) = ((high(int), high(int)), (high(int), high(int)))
    for t in blob:
      lowest = min(lowest, t)
      lowestMirror = min(lowestMirror, cv.m(t))
    if lowestMirror < lowest: continue   # its mirror image draws it
    if blob.len < 4:
      cv.post(lowest)
      continue
    wd.draw(wd.outline(blob), wd.rng.randint(5, 8))
    for t in blob:
      if wd.rng.random < (if blob.len <= 12: 0.6 else: 0.3): wd.tag(t, if blob.len <= 12: "rich" else: "fair")

proc interiors(wd: World) =
  var districts: seq[int]
  for i in 0 ..< wd.seeds.len:
    if wd.biome[i] == "caves": districts.add i
  wd.caves(districts)

# ---------------------------------------------------------- stage 6: structures

proc vault(wd: World) =
  let cv = wd.cv
  var hearts: seq[int]
  for i in 0 ..< wd.seeds.len:
    if wd.biome[i] == "vault" and i <= wd.smir[i]: hearts.add i
  for i in hearts:
    let (sx, sy) = wd.seeds[i]
    let size = setOf(wd.members[i]).len
    let cap = max(1, min(3, int(sqrt(float(wd.area) * 0.04) / 2)))
    let hw = max(1, min(cap, int(sqrt(float(size)) / 3) + wd.rng.randint(0, 1)))
    let hh = max(1, min(cap, int(sqrt(float(size)) / 3) + wd.rng.randint(0, 1)))
    let (x0, y0) = (int(floor(sx - float(hw) + 0.5)), int(floor(sy - float(hh) + 0.5)))
    let x1 = if cv.sym in ["y", "xy"] and wd.smir[i] == i: cv.w - 1 - x0 else: x0 + 2 * hw - 1
    let y1 = if cv.sym in ["x", "xy"] and wd.smir[i] == i: cv.h - 1 - y0 else: y0 + 2 * hh - 1
    if x1 < x0 or y1 < y0: continue
    var room: seq[Tile]
    for x in x0 .. x1:
      for y in y0 .. y1: room.add (floorMod(x, cv.w), floorMod(y, cv.h))
    var kind = wd.rng.choice(["room", "keep", "cross", "room"])
    if kind == "keep" and (x1 - x0 < 3 or y1 - y0 < 3): kind = "room"
    cv.enclose(room)
    let inRoom = setOf(room)
    for t in room:
      for step in 0 .. 4:
        let u = if step < 4: cv.nb(t, Dirs[step]) else: t
        wd.occupied |= cv.pair(u)
        for d2 in Dirs:
          wd.occupied.incl cv.nb(u, d2)
          wd.occupied.incl cv.m(cv.nb(u, d2))
    var perimeterSet = newPySet[Edge]()
    for t in room:
      for d in Dirs:
        if cv.nb(t, d) notin inRoom: perimeterSet.incl cv.edge(t, d)
    var perimeter = perimeterSet.toSeq
    perimeter.sort
    if kind == "cross":
      # doors in the middle of every side
      let (cxm, cym) = (float(x0 + x1) / 2, float(y0 + y1) / 2)
      for e in perimeter:
        let (a, b) = cv.sides(e)
        let t = if a in inRoom: a else: b
        if abs(float(t[0]) - cxm) < 0.6 or abs(float(t[1]) - cym) < 0.6: cv.put(e, 0)
    else:
      for _ in 0 ..< wd.rng.randint(1, 2): cv.put(wd.rng.choice(perimeter), 0)
    var inner = room
    if kind == "keep":
      inner = @[]
      for x in x0 + 1 ..< x1:
        for y in y0 + 1 ..< y1: inner.add (floorMod(x, cv.w), floorMod(y, cv.h))
      cv.enclose(inner)
      let inInner = setOf(inner)
      var innerPerimeter = newPySet[Edge]()
      for t in inner:
        for d in Dirs:
          if cv.nb(t, d) notin inInner: innerPerimeter.incl cv.edge(t, d)
      var sortedInner = innerPerimeter.toSeq
      sortedInner.sort
      cv.put(wd.rng.choice(sortedInner), 0)
    # A portal shortcut into the heart, as into Trophy's cup: from far ground
    # one side reaches first, and its mirror for the other.
    var sideRng = initPythonRandom(int64(wd.seed) * 7919 + 2)
    if sideRng.random < wd.style.heartPortal:
      var open: seq[Tile]
      for c in wd.camps:
        if c notin cv.solid: open.add c
      let reach = cv.bfs(open)
      swap(wd.rng, sideRng)
      for e1 in wd.rng.sample(perimeter, perimeter.len):
        let (found, e2) = wd.farAnchor(e1, room, reach)
        if found and cv.link(e1, e2): break
      swap(wd.rng, sideRng)
    for t in room: wd.tag(t, "rich")
    var keys: seq[float]
    for t in inner: keys.add cv.dist(t.toPoint, (sx, sy))
    for t in stableSortedBy(inner, keys).pySlice(0, max(1, floorDiv(inner.len, 3))): wd.tag(t, "hot")
    wd.log("vault " & kind & " " & $(x1 - x0 + 1) & "x" & $(y1 - y0 + 1))

proc shrines(wd: World) =
  let cv = wd.cv
  let (lo, hi) = wd.style.shrine
  let want = wd.rng.randint(lo, hi)
  var made = 0
  for _ in 0 ..< want * 30:
    if made >= want: break
    let (bw, bh) = wd.rng.choice([(1, 1), (2, 1), (1, 2), (2, 2), (2, 2)])
    let (x, y) = (wd.rng.randrange(cv.w), wd.rng.randrange(cv.h))
    if not cv.isCanon((x, y)): continue
    let box = wd.freeBox(x, y, bw, bh)
    if box.len == 0: continue
    let inBox = setOf(box)
    var perimeter: seq[Edge]
    for t in box:
      for d in Dirs:
        if cv.nb(t, d) notin inBox: perimeter.add cv.edge(t, d)
    let e1 = wd.rng.choice(perimeter)
    let (found, e2) = wd.farAnchor(e1, box, cv.bfs([cv.nb(box[0], 'N')]))
    if not found: continue
    let snapshot = cv.kind
    cv.enclose(box)
    if not cv.link(e1, e2):
      cv.kind = snapshot
      continue
    for t in box: wd.occupied |= cv.pair(t)
    for t in box: wd.tag(t, if box.len > 1: "rich" else: "hot")
    inc made
  if made > 0: wd.log($made & " portal shrine pair(s)")

proc pods(wd: World) =
  ## Walled rooms entered only through portals, holding a rich share of the
  ## food: the pods of Queen of Spades, Default's boxes and Trauma's halls.
  ## Each is a mirrored pair with one or two portals from ground the camps
  ## reach. Every choice draws from its own generator, so from the same
  ## skeleton a world without pods is the one earlier versions built.
  let cv = wd.cv
  var rng = initPythonRandom(int64(wd.seed) * 7919 + 1)
  let (lo, hi) = wd.style.pod
  let want = rng.randint(lo, hi)
  var made = 0
  for _ in 0 ..< want * 40:
    if made >= want: break
    let bw = rng.randint(3, max(3, min(7, floorDiv(cv.w, 4))))
    let bh = rng.randint(2, max(2, min(6, floorDiv(cv.h, 4))))
    let (x, y) = (rng.randrange(cv.w), rng.randrange(cv.h))
    if not cv.isCanon((x, y)): continue
    let box = wd.podBox(x, y, bw, bh)
    if box.len == 0: continue
    let inBox = setOf(box)
    var perimeter: seq[Edge]
    for t in box:
      for d in Dirs:
        if cv.nb(t, d) notin inBox: perimeter.add cv.edge(t, d)
    var open: seq[Tile]
    for c in wd.camps:
      if c notin cv.solid: open.add c
    let reach = cv.bfs(open)
    let snapshot = cv.kind
    for t in box:   # a pod replaces what stood there
      for d in ['E', 'S']:
        if cv.nb(t, d) in inBox: cv.put(cv.edge(t, d), 0)
    cv.enclose(box)
    var doors = 0
    let wantDoors = rng.randint(1, 2)
    for e1 in rng.sample(perimeter, perimeter.len):
      if doors >= wantDoors: break
      let (found, e2) = wd.farAnchor(e1, box, reach)
      if found and cv.link(e1, e2): inc doors
    if doors == 0:
      cv.kind = snapshot
      continue
    for t in box: wd.occupied |= cv.pair(t)
    let middle = (float(x) + float(bw - 1) / 2, float(y) + float(bh - 1) / 2)
    var keys: seq[float]
    for t in box: keys.add cv.dist(t.toPoint, middle)
    let core = stableSortedBy(box, keys).pySlice(0, max(1, floorDiv(box.len, 4)))
    for t in box: wd.tag(t, "rich")
    for t in core: wd.tag(t, "hot")
    inc made
  if made > 0: wd.log($made & " portal pod pair(s)")

proc wormholes(wd: World) =
  let cv = wd.cv
  let (lo, hi) = wd.style.worm
  let want = wd.rng.randint(lo, hi)
  var made = 0
  for _ in 0 ..< want * 40:
    if made >= want: break
    let t = wd.rng.choice(cv.tiles)
    if not cv.isCanon(t) or t in cv.solid or wd.tbiome.getOrDefault(t, "") in ["camp", "vault"]: continue
    let e = cv.edge(t, wd.rng.choice(Dirs))
    if cv.kindOf(e) == 2 or cv.isBorder(e): continue
    let (a, b) = cv.sides(e)
    if a in cv.solid or b in cv.solid or a in wd.occupied or b in wd.occupied: continue
    let mirror = cv.me(e)
    if cv.dist(a, cv.sides(mirror)[0]) < float(min(cv.w, cv.h)) * 0.4: continue
    if cv.link(e, mirror): inc made
  if made > 0: wd.log($made & " wormhole(s)")

proc groves(wd: World) =
  let cv = wd.cv
  let n = max(1, pythonRound(float(wd.area) / 350 * wd.rng.uniform(0.5, 1.5)))
  proc shelter(t: Tile): float =
    var k = 0
    for dx in -2 .. 2:
      for dy in -2 .. 2:
        let u = (floorMod(t[0] + dx, cv.w), floorMod(t[1] + dy, cv.h))
        for d in ['N', 'W']:
          if cv.kindOf(cv.edge(u, d)) == 1: inc k
    min(1.0, float(k) / 12)
  var peaks: seq[Tile]
  var keys: seq[float]
  for t in cv.tiles:
    let b = wd.tbiome.getOrDefault(t, "")
    if cv.isCanon(t) and t notin cv.solid and t notin wd.occupied and b notin ["vault", "camp"]:
      peaks.add t
      keys.add -(wd.fert[t] * biome(wd.tbiome[t]).fert + 0.6 * shelter(t) + 0.2 * wd.rng.random)
  var used: seq[Tile]
  for t in stableSortedBy(peaks, keys):
    if used.len >= n: break
    var crowded = false
    for u in used:
      if cv.dist(t, u) < 7: crowded = true
    if crowded or cv.dist(t, cv.m(t)) < 3: continue
    used.add t
    let size = wd.rng.randint(3, 9)
    let blob = newPySet[Tile]()
    blob.incl t
    var frontier = @[t]
    while frontier.len > 0 and blob.len < size:
      let index = wd.rng.randrange(frontier.len)
      let c = frontier[index]
      frontier.delete(index)
      for d in Dirs:
        let (open, n2) = cv.step(c, d)
        if open and n2 notin blob and cv.m(n2) notin blob and n2 notin wd.occupied:
          blob.incl n2
          frontier.add n2
    let tier = if wd.rng.random < 0.5: "rich" else: "fair"
    for b in blob: wd.tag(b, tier)
  wd.log($used.len & " grove(s)")

# ---------------------------------------------------------- stage 7

proc repair(wd: World): bool =
  let cv = wd.cv
  for _ in 0 ..< 400:
    var component = initTable[Tile, int]()
    var sizes: seq[int]
    for t in cv.tiles:
      if t in cv.solid or t in component: continue
      let reached = cv.bfs([t])
      let id = sizes.len
      for u in reached.keys: component[u] = id
      sizes.add reached.len
    if sizes.len <= 1: return true
    var main = 0
    for c in 1 ..< sizes.len:
      if sizes[c] > sizes[main]: main = c
    var small: seq[int]
    var keys: seq[int]
    for c in 0 ..< sizes.len:
      if c != main:
        small.add c
        keys.add sizes[c]
    let c = stableSortedBy(small, keys)[0]
    var tiles: seq[Tile]
    for t, id in component:
      if id == c: tiles.add t
    tiles.sort
    var doorsMain, doorsAny: seq[Edge]
    for t in tiles:
      for d in Dirs:
        let e = cv.edge(t, d)
        if cv.kindOf(e) != 1 or cv.isBorder(e): continue
        let n = cv.nb(t, d)
        if n in cv.solid or component.getOrDefault(n, -1) == c: continue
        if component.getOrDefault(n, -1) == main: doorsMain.add e else: doorsAny.add e
    let doors = if doorsMain.len > 0: doorsMain else: doorsAny
    if doors.len == 0:
      for t in tiles:
        cv.makeSolid(t)
        wd.tier.del t
        wd.tier.del cv.m(t)
      continue
    cv.put(wd.rng.choice(doors), 0)
  false

# ---------------------------------------------------------- stage 8

proc economy(wd: World) =
  let cv = wd.cv
  # camp food: a little early income inside each camp
  for c in wd.camps:
    if c in cv.solid: continue
    for t, steps in cv.bfs([c]):
      if 2 <= steps and steps <= 5 and wd.rng.random < 0.35: wd.tag(t, "fair")
  let cover = wd.rng.choice([0.0, 0.05, 0.15, 0.3, 1.0])
  let blanket = wd.rng.random < 0.3   # every live tile spawns, as on Big Empty or Help
  for t in cv.tiles:
    if not cv.isCanon(t) or t in cv.solid: continue
    let v = wd.fert[t] * biome(wd.tbiome[t]).fert
    if v > 1.2: wd.tag(t, "fair")
    elif blanket or wd.rng.random < cover * min(1.0, v * 1.5): wd.tag(t, "bg")
  var palette = initOrderedTable[string, array[2, int]]()
  palette["hot"] = [1, wd.rng.choice([1, 1, 2, 3, 5])]
  let rich0 = wd.rng.randint(1, 5)
  palette["rich"] = [rich0, wd.rng.randint(10, 60)]
  let fair0 = wd.rng.randint(1, 20)
  palette["fair"] = [fair0, wd.rng.randint(80, 300)]
  palette["bg"] = [1, wd.rng.choice([500, 1000, 1500, 2559, 3849])]
  let target = wd.reqSupply
  var live: seq[Tile]
  for t in cv.tiles:
    if wd.tier.getOrDefault(t, "dead") != "dead" and t notin cv.solid: live.add t
  # hot tiles at most ~60% of the budget: demote the outer ones to rich
  var hot: seq[Tile]
  var keys: seq[float]
  for t in live:
    if wd.tier[t] == "hot":
      hot.add t
      keys.add wd.rng.random
  hot = stableSortedBy(hot, keys)
  let perHot = 2 / float(palette["hot"][0] + palette["hot"][1])
  var keep = int(target * 0.6 / perHot)
  keep -= floorMod(keep, 2)
  for t in hot.pySlice(keep, hot.len): wd.tier[t] = "rich"
  for t in cv.tiles:   # restore symmetry after the shuffle
    if cv.isCanon(t):
      let (a, b) = (wd.tier.getOrDefault(t, "dead"), wd.tier.getOrDefault(cv.m(t), "dead"))
      if a != b:
        let top = if TierRank[a] < TierRank[b]: a else: b
        wd.tier[t] = top
        wd.tier[cv.m(t)] = top
  # Most official maps use one or two gap classes: fold the tiers together.
  let classes = wd.rng.choice([1, 2, 2, 0, 0])
  proc fold(tier: string): string =
    case classes
    of 1: (if tier in ["hot", "rich", "bg"]: "fair" else: tier)
    of 2: (if tier == "hot": "rich" elif tier == "fair": "bg" else: tier)
    else: tier
  for t in live: wd.tier[t] = fold(wd.tier[t])
  var hotTerms: seq[float]
  for t in live:
    if wd.tier[t] == "hot": hotTerms.add perHot
  let hotSupply = pythonSum(hotTerms)
  var rest: seq[Tile]
  for t in live:
    if wd.tier[t] in ["rich", "fair", "bg"]: rest.add t
  proc supply(k: float): float =
    for t in rest:
      let (lo, hi) = (palette[wd.tier[t]][0], palette[wd.tier[t]][1])
      result += 2 / float(lo + max(lo, pythonRound(float(hi) * k)))
  let goal = max(0.3, target - hotSupply)
  var (lowK, highK) = (0.05, 60.0)
  for _ in 0 ..< 40:
    let middle = sqrt(lowK * highK)
    if supply(middle) > goal: lowK = middle else: highK = middle
  let k = sqrt(lowK * highK)
  for tier in ["rich", "fair", "bg"]:
    palette[tier][1] = max(palette[tier][0], pythonRound(float(palette[tier][1]) * k))
  wd.palette = palette
  wd.gap = initOrderedTable[Tile, (int, int)]()
  for t in cv.tiles:
    let tier = wd.tier.getOrDefault(t, "dead")
    wd.gap[t] = if tier == "dead" or t in cv.solid: (0, 0) else: (palette[tier][0], palette[tier][1])
  var terms: seq[float]
  for (a, b) in wd.gap.values:
    if b > 0: terms.add 2 / float(a + b)
  wd.supply = pythonSum(terms)
  wd.target = target

# ---------------------------------------------------------- stage 9

proc grow(wd: World, head: Tile, L: int, taken: PySet[Tile], away: Distances): seq[Tile] =
  ## Self-avoiding body from the head backwards, away from the enemy; nothing
  ## when no body fits.
  let cv = wd.cv
  let bad = taken | cv.mirrored(taken)
  for _ in 0 ..< 30:
    var body = @[head]
    var previous = ' '
    var ok = true
    while body.len < L:
      let t = body[^1]
      var best: (float, char, Tile)
      var found = false
      for d in Dirs:
        if cv.kindOf(cv.edge(t, d)) != 0: continue   # bodies never straddle kelp or portals
        let n = cv.nb(t, d)
        if n in cv.solid or n in bad or n in body or cv.m(n) in body or cv.m(n) == n: continue
        let score = float(away.getOrDefault(n, 0) - away.getOrDefault(t, 0)) + (if d == previous: 1.5 else: 0.0) +
                    wd.rng.random * 1.2
        let option = (score, d, n)
        if not found or option > best: (best, found) = (option, true)
      if not found:
        ok = false
        break
      previous = best[1]
      body.add best[2]
    if ok:
      let blocked = bad | setOf(body) | cv.mirrored(body)
      if cv.exits(head, proc (t: Tile): bool = t in blocked) >= 2: return body

proc spawns(wd: World): bool =
  let cv = wd.cv
  let n = wd.perSide
  var lengths: seq[int]
  for _ in 0 ..< n: lengths.add wd.rng.choice([2, 3, 3, 4, 4, 5])
  # A flagship, as Dilemma (11), Autarky and Help (14) and Slithery Fight (25)
  # start with; the organisers promise more such maps.
  if wd.rng.random < 0.25: lengths[0] = wd.rng.randint(6, 16)
  if wd.rng.random < 0.08 and wd.area > 500: lengths[0] = wd.rng.randint(17, 25)
  var taken = newPySet[Tile]()
  var dragons: seq[seq[Tile]]
  var enemy: seq[Tile]
  for c in wd.camps:
    if cv.m(c) notin cv.solid: enemy.add cv.m(c)
  let away = cv.bfs(enemy)
  var anchor = initTable[Tile, Tile]()
  for c in wd.camps: anchor[c] = c
  if wd.nestPath.len > 0:
    # the first dragon lies coiled in the nest, head at the mouth; the nest's
    # other tiles stay empty, and its camp's other dragons start outside the
    # mouth
    lengths[0] = min(wd.nestLen, wd.nestPath.len)
    taken |= setOf(wd.nestPath)
    let mouth = wd.nestPath[0]
    var outside: seq[Tile]
    for d in Dirs:
      let (open, t) = cv.step(mouth, d)
      if open and t notin taken: outside.add t
    if outside.len == 0:
      wd.why = "no way out of the nest"
      return false
    anchor[wd.camps[0]] = outside[0]
    taken.incl outside[0]   # the mouth stays clear
  for i, L in lengths:
    let camp = anchor[wd.camps[i mod wd.camps.len]]
    if i == 0 and wd.nestPath.len > 0:
      dragons.add wd.nestPath.pySlice(0, L)
      continue
    if camp in cv.solid:
      wd.why = "camp blocked"
      return false
    let blocked = taken | cv.mirrored(taken)
    let ring = cv.bfs([camp], blocked = proc (t: Tile): bool = t in blocked)
    var candidates: seq[Tile]
    var keys: seq[float]
    for t, steps in ring:
      if t notin taken and cv.m(t) notin taken and cv.m(t) != t:
        candidates.add t
        keys.add float(steps) + wd.rng.random * 2
    var placed: seq[Tile]
    for head in stableSortedBy(candidates, keys).pySlice(0, 40):
      let body = wd.grow(head, L, taken, away)
      if body.len > 0:
        placed = body
        break
    if placed.len == 0:
      wd.why = "no room to coil a dragon"
      return false
    taken |= setOf(placed)
    dragons.add placed
  taken = newPySet[Tile]()
  for d in dragons:
    for t in d: taken.incl t
  let mirrorTaken = cv.mirrored(taken)
  if mirrorTaken.meets(taken):
    wd.why = "bodies overlap their mirror"
    return false
  wd.dragons = dragons
  var heads: seq[Tile]
  for d in dragons: heads.add d[0]
  let blocked = taken | mirrorTaken
  let da = cv.bfs(heads, blocked = proc (t: Tile): bool = t in blocked)
  var meet = 999
  for d in dragons: meet = min(meet, da.getOrDefault(cv.m(d[0]), 999))
  if meet < 6:
    wd.why = "first contact " & $meet & " steps"
    return false
  for d in dragons:
    if cv.exits(d[0], proc (t: Tile): bool = t in blocked) < 1:
      wd.why = "a head with no exit"
      return false
  true

# ---------------------------------------------------------- stage 10

proc judge(wd: World): bool =
  ## Score a finished world; false when some open tile can't be reached.
  let cv = wd.cv
  var heads, mirrorHeads: seq[Tile]
  for d in wd.dragons:
    heads.add d[0]
    mirrorHeads.add cv.m(d[0])
  let (da, db) = (cv.bfs(heads), cv.bfs(mirrorHeads))
  var live: seq[Tile]
  for t in cv.tiles:
    if t notin cv.solid: live.add t
  for t in live:
    if t notin da: return false
  var supplyTiles: seq[(Tile, float)]
  for t, (a, b) in wd.gap:
    if b > 0: supplyTiles.add (t, 2 / float(a + b))
  var all, contestedTerms, earlyTerms: seq[float]
  for (t, v) in supplyTiles:
    all.add v
    if abs(da[t] - db[t]) <= 2: contestedTerms.add v
    if da[t] <= 8: earlyTerms.add v
  var total = pythonSum(all)
  if total == 0: total = 1
  let contested = pythonSum(contestedTerms) / total
  let early = pythonSum(earlyTerms) / total
  var meet = high(int)
  for head in heads: meet = min(meet, db[head])
  let span = float(cv.w + cv.h) / 2
  var rng = initPythonRandom(int64(wd.seed xor 0x5EED))
  var ratios: seq[float]
  for s in rng.sample(live, min(16, live.len)):
    let walked = cv.bfs([s], portals = false)
    for t in rng.sample(live, min(40, live.len)):
      var g = abs(t[0] - s[0]) + abs(t[1] - s[1])
      if not cv.closed:
        g = min(abs(t[0] - s[0]), cv.w - abs(t[0] - s[0])) + min(abs(t[1] - s[1]), cv.h - abs(t[1] - s[1]))
      if g >= 4 and t in walked: ratios.add float(walked[t]) / float(g)
  let detour = if ratios.len > 0: pythonSum(ratios) / float(ratios.len) else: 1.0
  var deadEnds = 0
  for t in live:
    if cv.exits(t) <= 1: inc deadEnds
  let deadEndShare = float(deadEnds) / float(max(1, live.len))
  let noPortals = cv.bfs(heads, portals = false)
  var gained = 0
  for t in live:
    if da[t] < noPortals.getOrDefault(t, 1_000_000): inc gained
  let portalGain = float(gained) / float(max(1, live.len))
  var kinds = newPySet[(int, int)]()
  var names: seq[string]
  for b in wd.biome.values:
    if b notin names: names.add b
  let biomes = names.len
  discard kinds
  var s = 0.0
  s -= pow((contested - 0.25) / 0.15, 2.0)
  s -= pow((float(meet) / span - 0.8) / 0.4, 2.0)
  s -= pow((detour - wd.style.detour) / 0.25, 2.0)
  s -= max(0.0, deadEndShare - 0.06) * 30
  s -= (if early > 0.04: 0.0 else: 2.0)
  s += min(portalGain, 0.3) * 3
  s += float(min(biomes, 5)) * 0.3
  # architecture: a world with its buildings beats a bare one
  let structure = min(1.0, float(wd.buildings) / float(max(1, wd.wantBuildings)))
  s += 1.5 * structure
  s += (if wd.lmBuilt: 1.5 else: 0.0)
  wd.metrics = initOrderedTable[string, float]()
  wd.metrics["contested"] = contested
  wd.metrics["early"] = early
  wd.metrics["meet"] = float(meet)
  wd.metrics["detour"] = detour
  wd.metrics["dead_ends"] = deadEndShare
  wd.metrics["portal_gain"] = portalGain
  wd.metrics["biomes"] = float(biomes)
  wd.metrics["structure"] = structure
  wd.metrics["landmark"] = (if wd.lmBuilt: 1.0 else: 0.0)
  wd.score = s
  true

proc check(wd: World) =
  ## The world is exactly symmetric and its portals pair up.
  let cv = wd.cv
  for t in cv.tiles:
    doAssert wd.gap[t] == wd.gap[cv.m(t)], "gap asymmetric at " & $t
    doAssert (t in cv.solid) == (cv.m(t) in cv.solid)
  for e, k in cv.kind: doAssert cv.kindOf(cv.me(e)) == k, "edge asymmetric at " & $e
  var byPair = initOrderedTable[int, seq[Edge]]()
  for e, p in cv.pid: byPair.mgetOrPut(p, @[]).add e
  for p, ends in byPair:
    doAssert ends.len == 2 and ends[0].o == ends[1].o, "portal " & $p
    doAssert cv.me(ends[0]) != ends[0]

# ------------------------------------------------------------------ names

const
  Adjectives = ["Sunken", "Drowned", "Tidal", "Abyssal", "Brackish", "Gilded", "Broken", "Whispering", "Silent",
                "Coral", "Moonlit", "Hollow", "Salt", "Siren", "Pale", "Twisting", "Forgotten"]

proc nouns(biome: string): seq[string] =
  case biome
  of "sea": @["Shallows", "Expanse", "Deep", "Straits"]
  of "meadow": @["Beds", "Flats", "Lagoon"]
  of "reef": @["Reef", "Shoals", "Gardens"]
  of "ruins": @["Ruins", "Colonnade", "Atrium"]
  of "caves": @["Grottoes", "Caverns", "Hollows"]
  of "maze": @["Labyrinth", "Warrens", "Coils"]
  of "vault": @["Vault", "Sanctum", "Crown"]
  of "garden": @["Orchard", "Gardens"]
  else: @["Nests"]

proc landmarkNouns(kind: string): seq[string] =
  case kind
  of "citadel": @["Citadel", "Bastion", "Stronghold"]
  of "labyrinth": @["Labyrinth", "Maze", "Warren"]
  of "palace": @["Palace", "Halls", "Court"]
  of "city": @["City", "Market", "Town"]
  of "wall": @["Wall", "Ramparts", "Bulwark"]
  of "serpent": @["Coils", "Serpentarium", "Slither"]
  of "effigy": @["Faces", "Effigies", "Idols"]
  of "lattice": @["Lattice", "Gates", "Mirrors"]
  else: @["Lanes", "Furrows", "Pews"]

proc makeName(wd: World): string =
  var rng = initPythonRandom(int64(wd.seed) * 7 + 1)
  var counts = initOrderedTable[string, int]()
  for b in wd.tbiome.values:
    if b notin ["camp", "landmark"]: counts[b] = counts.getOrDefault(b, 0) + 1
  var top = "sea"
  var most = -1
  for b, count in counts:
    if count > most: (top, most) = (b, count)
  if wd.lmBuilt:
    let name = rng.choice(Adjectives) & " " & rng.choice(landmarkNouns(wd.landmarkKind))
    return name & (if wd.cv.npid >= 4 and rng.random < 0.6: " of Gates" else: "")
  result = rng.choice(Adjectives) & " " & rng.choice(nouns(top))
  var vault = false
  for b in wd.biome.values:
    if b == "vault": vault = true
  if wd.cv.npid >= 4 and rng.random < 0.6: result.add " of Gates"
  elif vault and rng.random < 0.5: result.add " of the " & rng.choice(nouns("vault"))

# ------------------------------------------------------------------ pipeline

proc build*(wd: World): bool =
  wd.climate()
  wd.planLandmark()
  wd.campsAndDistricts()
  wd.pickBiomes()
  wd.landmark()
  wd.borders()
  wd.interiors()
  wd.vault()
  wd.pods()
  wd.architecture()
  wd.ridges()
  wd.shrines()
  wd.wormholes()
  if not wd.repair():
    wd.why = "repair did not converge"
    return false
  wd.cv.tidy()
  # camps must stay open ground
  for c in wd.camps:
    if c in wd.cv.solid:
      wd.why = "a camp was filled in"
      return false
  wd.groves()
  wd.economy()
  if not wd.spawns(): return false
  if not wd.judge():
    wd.why = "unreachable tiles"
    return false
  wd.check()
  wd.name = wd.makeName()
  true

proc newWorld*(seed: int, w, h: int, sym, styleName: string, closed: bool, perSide: int, supply: float,
               landmark = "none"): World =
  result = World(seed: seed, landmarkKind: landmark, rng: initPythonRandom(int64(seed)), styleName: styleName,
                 style: style(styleName), cv: newCanvas(w, h, sym, closed), area: w * h, reqPerSide: perSide,
                 reqSupply: supply, occupied: newPySet[Tile](), reserved: newPySet[Tile]())

# ------------------------------------------------------------------ output

proc mapText*(cv: Canvas, name: string, gap: OrderedTable[Tile, (int, int)], dragons: seq[seq[Tile]]): string =
  ## The .map file for a canvas, its spawn gaps and team A's bodies (team B is
  ## their mirror image), in the official files' line order.
  var lines = @["MAP " & $cv.w & " " & $cv.h, "SYMMETRY " & cv.sym, "MAP_NAME " & name,
                "TILE_COUNT " & $cv.tiles.len]
  for y in 0 ..< cv.h:
    for x in 0 ..< cv.w:
      let (lo, hi) = gap[(x, y)]
      lines.add "TILE " & $x & " " & $y & " " & $lo & " " & $hi
  var edges: seq[(int, int, int)]
  for e, k in cv.kind:
    let row = 2 * e.y + (if e.o == 'h': 0 else: 1)
    edges.add (row * (cv.w + 1) + e.x, k, cv.pid.getOrDefault(e, -1))
  edges.sort
  lines.add "EDGE_COUNT " & $edges.len
  for (index, kind, pid) in edges: lines.add "EDGE " & $index & " " & $kind & " " & $pid
  lines.add "DRAGON_COUNT " & $(2 * dragons.len)
  for d in dragons:   # alternate A, B like the official maps
    var mirror: seq[Tile]
    for t in d: mirror.add cv.m(t)
    for (team, body) in [(0, d), (1, mirror)]:
      var coordinates: seq[string]
      for (x, y) in body: coordinates.add $x & " " & $y
      lines.add "DRAGON " & $team & " " & $body.len & " " & coordinates.join(" ")
  lines.add "END"
  lines.join("\n") & "\n"

proc text*(wd: World): string = mapText(wd.cv, wd.name, wd.gap, wd.dragons)

proc summary*(wd: World): string =
  let cv = wd.cv
  var share = initOrderedTable[string, int]()
  for b in wd.tbiome.values: share[b] = share.getOrDefault(b, 0) + 1
  var biomes, counts: seq[string]
  var entries: seq[(string, int)]
  var keys: seq[int]
  for b, c in share:
    entries.add (b, c)
    keys.add -c
  for (b, c) in stableSortedBy(entries, keys): biomes.add b & " " & $floorDiv(100 * c, cv.tiles.len) & "%"
  discard counts
  var used: seq[string]
  for tier in wd.tier.values:
    if tier notin used: used.add tier
  var palette: seq[string]
  for k, range in wd.palette:
    if k in used: palette.add k & " [" & $range[0] & "," & $range[1] & "]"
  var kelp = 0
  for k in cv.kind.values:
    if k == 1: inc kelp
  var spawning = 0
  for g in wd.gap.values:
    if g[1] > 0: inc spawning
  let (seed, candidate) = wd.origin
  let border = if cv.closed: "closed" else: "wrapping"
  var lengths: seq[string]
  for d in wd.dragons: lengths.add $d.len
  let m = wd.metrics
  @[wd.name & "  (seed " & $seed & "#" & $candidate & ", style " & wd.styleName & ")",
    "  " & $cv.w & "x" & $cv.h & "  symmetry " & cv.sym & "  " & border & " border  " & $wd.dragons.len &
      " dragons/side (lengths " & lengths.join(",") & ")",
    "  biomes: " & biomes.join(", "),
    "  features: " & wd.notes.join("; "),
    "  kelp edges " & $kelp & ", portal pairs " & $cv.npid & ", rock tiles " & $cv.solid.len,
    "  pearls: " & pythonFixed(wd.supply, 1) & "/round (target " & pythonFixed(wd.target, 1) & "), " & $spawning &
      " spawning tiles; palette " & palette.join(", "),
    "  judge " & pythonFixed(wd.score, 2) & ": contested " & pythonFixed(100 * m["contested"], 0) & "%, early food " &
      pythonFixed(100 * m["early"], 0) & "%, first contact " & $int(m["meet"]) & " steps, detour x" &
      pythonFixed(m["detour"], 2) & ", dead ends " & pythonFixed(100 * m["dead_ends"], 1) & "%, portal shortcut " &
      pythonFixed(100 * m["portal_gain"], 0) & "% of tiles"].join("\n")
