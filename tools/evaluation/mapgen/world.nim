## A world under construction: its settings, the state each stage leaves for
## the next, the biome and style tables, and the drawing helpers the stages
## share (rectangles, doors, walls, outlines, mazes, sites and portal ends).

import std/[algorithm, math, tables]
import canvas
import ../[python_math, python_random, python_set]

type
  BuildOption* = tuple[kind: string, weight: float]   # kind "" leaves the ground open
  Biome* = object
    ef*:    (float, float)       # climate centre: elevation, fertility
    fert*:  float                # fertility multiplier
    build*: seq[BuildOption]     # the buildings it raises

  Style* = object
    bw*:          seq[(string, float)]   # biome weight multipliers
    build*:       seq[(string, float)]   # building weight multipliers
    stockade*:    float                  # chance each camp is walled in
    front*:       float                  # chance a home/frontier border becomes a gated wall
    darea*:       float                  # tiles per district
    worm*:        (int, int)             # wormhole count range
    shrine*:      (int, int)             # portal shrine count range
    pod*:         (int, int)             # portal pod count range
    heartPortal*: float                  # chance a portal leads into the heart
    closed*:      float                  # chance of a sealed border
    vault*:       float                  # chance the heart is a vault
    ridges*:      float                  # chance of elevation ridges
    detour*:      float                  # the path/straight-line ratio the judge aims for
    landmark*:    seq[(string, float)]   # weights of the map-scale landmark
    nest*:        float                  # chance the first dragon starts coiled in a nest
    open*:        bool                   # no buildings at all

  Landmark* = object
    kind*:           string
    x0*, y0*, fw*, fh*: int

  World* = ref object
    seed*:          int
    landmarkKind*:  string
    rng*:           PythonRandom
    styleName*:     string
    style*:         Style
    cv*:            Canvas
    area*:          int
    reqPerSide*:    int
    reqSupply*:     float
    tier*:          OrderedTable[Tile, string]
    notes*:         seq[string]
    occupied*:      PySet[Tile]
    lm*:            Landmark
    hasLm*:         bool
    reserved*:      PySet[Tile]
    lmBuilt*:       bool
    lmArea*:        int
    nestBias*:      float
    nestPath*:      seq[Tile]            # empty when there is no nest
    nestLen*:       int
    why*:           string
    elev*, fert*:   Table[Tile, float]
    wx*, wy*:       ValueNoise
    perSide*:       int
    camps*:         seq[Tile]
    seeds*:         seq[Point]
    roles*:         seq[string]
    smir*:          seq[int]
    assign*:        OrderedTable[Tile, int]
    members*:       seq[seq[Tile]]
    memset*:        seq[PySet[Tile]]
    biome*:         OrderedTable[int, string]
    tbiome*:        OrderedTable[Tile, string]
    fx*:            Tile                 # the landmark frame's origin
    ft*:            bool                 # the frame is transposed
    fu*, fv*:       int
    buildings*, wantBuildings*: int
    palette*:       OrderedTable[string, array[2, int]]
    gap*:           OrderedTable[Tile, (int, int)]
    supply*, target*: float
    dragons*:       seq[seq[Tile]]
    metrics*:       OrderedTable[string, float]
    score*:         float
    name*:          string
    origin*:        (int, int)

  FrozenPair* = object
    ## `frozenset((a, b))` of two tiles, hashed and ordered as CPython does.
    members*: PySet[Tile]
    hash:     int64

const
  BiomeNames* = ["sea", "meadow", "reef", "ruins", "caves", "maze", "camp", "vault", "garden", "landmark"]
  TierRank* = {"dead": 0, "bg": 1, "fair": 2, "rich": 3, "hot": 4}.toTable
  Landmarks* = ["citadel", "labyrinth", "palace", "city", "serpent", "wall", "lanes", "effigy", "lattice"]
  LandmarkMinimum* = {"citadel": 9, "labyrinth": 9, "palace": 9, "city": 11, "serpent": 13}.toTable
  Shapes* = [(32, 16), (48, 24), (25, 35), (32, 32), (16, 16), (54, 18), (63, 27), (60, 40), (25, 25),
             (40, 20), (36, 24), (24, 24), (44, 22), (30, 30), (11, 11), (16, 8), (64, 64)]
  FreeSizeShare* = 0.25
  TransposedDirection* = {'N': 'W', 'S': 'E', 'E': 'S', 'W': 'N'}.toTable

proc biome*(name: string): Biome =
  case name
  of "sea": Biome(ef: (0.15, 0.25), fert: 0.5, build: @[("rampart", 3.0), ("room", 1.5), ("", 4.0)])
  of "meadow": Biome(ef: (0.25, 0.75), fert: 0.9,
                     build: @[("room", 3.0), ("stalls", 3.0), ("complex", 2.0), ("", 1.5)])
  of "reef": Biome(ef: (0.50, 0.80), fert: 1.3,
                   build: @[("colonnade", 3.0), ("room", 2.0), ("stalls", 2.0), ("complex", 2.0)])
  of "ruins": Biome(ef: (0.55, 0.35), fert: 0.9, build: @[("complex", 4.0), ("cloister", 3.0), ("colonnade", 2.0)])
  of "caves": Biome(ef: (0.85, 0.65), fert: 1.0)
  of "maze": Biome(ef: (0.85, 0.25), fert: 0.7, build: @[("labyrinth", 1.0)])
  of "camp": Biome(ef: (0.30, 0.50), fert: 0.8)
  of "vault": Biome(ef: (0.50, 0.50), fert: 1.5)
  of "garden": Biome(ef: (0.30, 0.90), fert: 1.6, build: @[("colonnade", 3.0), ("stalls", 2.0)])
  else: Biome(ef: (0.50, 0.50), fert: 1.0)

const StyleNames* = ["archipelago", "caverns", "fortress", "labyrinth", "open", "pods", "shrines", "wilds"]

proc style*(name: string): Style =
  case name
  of "open":
    Style(bw: @[("caves", 0.0), ("maze", 0.0), ("ruins", 0.3)], stockade: 0, front: 0, darea: 160,
          worm: (0, 2), shrine: (0, 1), pod: (0, 0), heartPortal: 0.0, closed: 0.3, vault: 0, ridges: 0,
          detour: 1.05, landmark: @[("none", 1.0)], nest: 0, open: true)
  of "wilds":
    Style(stockade: 0.35, front: 0.2, darea: 110, worm: (0, 1), shrine: (0, 2), pod: (0, 1),
          heartPortal: 0.25, closed: 0.5, vault: 0.6, ridges: 0.6, detour: 1.3,
          landmark: @[("citadel", 1.0), ("labyrinth", 1.0), ("palace", 1.0), ("city", 1.0), ("wall", 1.0),
                      ("serpent", 1.0), ("effigy", 1.0), ("lattice", 0.7), ("lanes", 1.0), ("none", 0.8)],
          nest: 0.3)
  of "archipelago":
    Style(bw: @[("sea", 3.0), ("reef", 2.0), ("meadow", 1.5), ("maze", 0.3), ("ruins", 0.5)],
          build: @[("colonnade", 2.0), ("rampart", 1.5)], stockade: 0.2, front: 0.0, darea: 130,
          worm: (1, 2), shrine: (0, 2), pod: (0, 1), heartPortal: 0.3, closed: 0.3, vault: 0.4, ridges: 0.3,
          detour: 1.15,
          landmark: @[("city", 1.0), ("wall", 1.5), ("citadel", 0.5), ("palace", 0.5), ("effigy", 2.0),
                      ("lattice", 1.0), ("none", 1.2)],
          nest: 0.2)
  of "labyrinth":
    Style(bw: @[("maze", 3.5), ("ruins", 1.5), ("sea", 0.4), ("meadow", 0.5)], build: @[("complex", 2.0)],
          stockade: 0.4, front: 0.3, darea: 110, worm: (0, 1), shrine: (0, 1), pod: (0, 1), heartPortal: 0.2,
          closed: 0.7, vault: 0.7, ridges: 0.2, detour: 1.6,
          landmark: @[("labyrinth", 4.0), ("palace", 1.0), ("citadel", 1.0), ("serpent", 2.0), ("lanes", 1.0),
                      ("none", 0.4)],
          nest: 0.3)
  of "caverns":
    Style(bw: @[("caves", 3.5), ("reef", 1.2), ("sea", 0.5)], build: @[("colonnade", 1.5)], stockade: 0.3,
          front: 0.1, darea: 120, worm: (0, 1), shrine: (0, 1), pod: (0, 1), heartPortal: 0.2, closed: 0.6,
          vault: 0.5, ridges: 0.8, detour: 1.4,
          landmark: @[("palace", 1.0), ("labyrinth", 1.0), ("wall", 1.0), ("citadel", 0.5), ("effigy", 1.5),
                      ("serpent", 1.0), ("none", 1.0)],
          nest: 0.3)
  of "fortress":
    Style(bw: @[("ruins", 2.5), ("maze", 1.2), ("meadow", 1.0)],
          build: @[("complex", 2.5), ("cloister", 2.5), ("room", 1.5)], stockade: 0.85, front: 0.6, darea: 100,
          worm: (0, 1), shrine: (0, 1), pod: (0, 2), heartPortal: 0.4, closed: 0.9, vault: 1.0, ridges: 0.3,
          detour: 1.4,
          landmark: @[("citadel", 4.0), ("wall", 2.0), ("palace", 1.0), ("city", 0.5), ("serpent", 1.0),
                      ("lanes", 1.5), ("none", 0.2)],
          nest: 0.15)
  of "shrines":
    Style(bw: @[("meadow", 2.0), ("sea", 1.5), ("ruins", 1.2)], build: @[("stalls", 3.0)], stockade: 0.3,
          front: 0.1, darea: 110, worm: (0, 1), shrine: (3, 6), pod: (1, 2), heartPortal: 0.4, closed: 0.8,
          vault: 0.3, ridges: 0.4, detour: 1.25,
          landmark: @[("city", 2.0), ("palace", 2.0), ("citadel", 1.0), ("lattice", 3.0), ("none", 0.5)],
          nest: 0.2)
  else: # pods
    Style(bw: @[("meadow", 2.0), ("ruins", 1.5), ("sea", 1.0)], build: @[("room", 2.0), ("stalls", 2.0)],
          stockade: 0.3, front: 0.2, darea: 110, worm: (0, 1), shrine: (0, 1), pod: (2, 4), heartPortal: 0.5,
          closed: 0.6, vault: 0.6, ridges: 0.3, detour: 1.3,
          landmark: @[("city", 1.0), ("palace", 1.0), ("citadel", 1.0), ("lattice", 1.0), ("none", 1.5)],
          nest: 0.2)

proc weight*(pairs: seq[(string, float)], name: string, default = 1.0): float =
  for (key, value) in pairs:
    if key == name: return value
  default

# ------------------------------------------------------------------ Python helpers

proc pySlice*[T](items: openArray[T], first, last: int): seq[T] =
  ## `items[first:last]`, with Python's clamping and negative indices.
  var (a, b) = (first, last)
  if a < 0: a = max(0, items.len + a)
  if b < 0: b = max(0, items.len + b)
  a = min(a, items.len)
  b = min(b, items.len)
  for index in a ..< b: result.add items[index]

proc firstMinimum*[T](items: openArray[T], key: proc (item: T): float): T =
  ## `min(items, key=key)`: the first item with the least key.
  var best = Inf
  var found = false
  for item in items:
    let value = key(item)
    if not found or value < best:
      (best, result, found) = (value, item, true)

proc stableSortedBy*[T, K](items: openArray[T], keys: openArray[K]): seq[T] =
  ## `sorted(items, key=...)` given the keys already drawn in item order.
  var order = newSeq[(K, int)](items.len)
  for index in 0 ..< items.len: order[index] = (keys[index], index)
  order.sort(proc (a, b: (K, int)): int = cmp(a, b))
  for (_, index) in order: result.add items[index]

proc setOf*(tiles: openArray[Tile]): PySet[Tile] = toPySet(tiles)

proc mirrored*(cv: Canvas, tiles: PySet[Tile]): PySet[Tile] =
  ## `{cv.m(t) for t in tiles}`.
  result = newPySet[Tile]()
  for t in tiles: result.incl cv.m(t)

proc mirrored*(cv: Canvas, tiles: openArray[Tile]): PySet[Tile] =
  result = newPySet[Tile]()
  for t in tiles: result.incl cv.m(t)

proc meets*(a, b: PySet[Tile]): bool =
  ## `bool(a & b)`.
  for t in (if a.len <= b.len: a else: b):
    if t in (if a.len <= b.len: b else: a): return true

proc pair*(cv: Canvas, t: Tile): PySet[Tile] =
  ## `{t, cv.m(t)}`.
  result = newPySet[Tile]()
  result.incl t
  result.incl cv.m(t)

proc frozenPair*(a, b: Tile): FrozenPair =
  result.members = newPySet[Tile]()
  result.members.incl a
  result.members.incl b
  result.hash = frozensetHash(result.members)

proc `==`*(a, b: FrozenPair): bool = a.hash == b.hash and sameElements(a.members, b.members)

proc pyHash*(value: FrozenPair): int64 = value.hash

# ------------------------------------------------------------------ world basics

proc log*(wd: World, message: string) = wd.notes.add message

proc tag*(wd: World, t: Tile, tier: string) =
  for s in wd.cv.pair(t):
    if TierRank[tier] > TierRank[wd.tier.getOrDefault(s, "dead")]: wd.tier[s] = tier

proc R*(wd: World, x0, y0, dx, dy: int): Tile =
  (floorMod(x0 + dx, wd.cv.w), floorMod(y0 + dy, wd.cv.h))

proc rect*(wd: World, x0, y0, bw, bh: int): seq[Tile] =
  for dy in 0 ..< bh:
    for dx in 0 ..< bw: result.add wd.R(x0, y0, dx, dy)

proc side*(wd: World, x0, y0, bw, bh: int, d: Direction): seq[Edge] =
  ## The perimeter edges of a rectangle on one side, in order.
  let cv = wd.cv
  case d
  of 'N':
    for dx in 0 ..< bw: result.add cv.edge(wd.R(x0, y0, dx, 0), 'N')
  of 'S':
    for dx in 0 ..< bw: result.add cv.edge(wd.R(x0, y0, dx, bh - 1), 'S')
  of 'W':
    for dy in 0 ..< bh: result.add cv.edge(wd.R(x0, y0, 0, dy), 'W')
  else:
    for dy in 0 ..< bh: result.add cv.edge(wd.R(x0, y0, bw - 1, dy), 'E')

proc door*(wd: World, edges: openArray[Edge], width = 1) =
  ## Open a doorway in a run of wall, away from the corners.
  let n = edges.len
  let width = min(width, max(1, n - 2))
  let (lo, hi) = if n >= 3: (1, n - 1 - width) else: (0, n - width)
  let position = wd.rng.randint(lo, max(lo, hi))
  for e in edges.pySlice(position, position + width): wd.cv.put(e, 0)

proc facing*(wd: World, x0, y0, bw, bh: int): seq[Direction] =
  ## Sides of a footprint, the one facing the heart of the map first.
  let cv = wd.cv
  let (hx, hy) = (float(cv.w - 1) / 2, float(cv.h - 1) / 2)
  let (cx, cy) = (float(x0) + float(bw - 1) / 2, float(y0) + float(bh - 1) / 2)
  let (ddx, ddy) = (hx - cx, hy - cy)
  var keys: seq[float]
  for d in Dirs: keys.add -(float(d.dx) * ddx + float(d.dy) * ddy)
  stableSortedBy(Dirs, keys)

proc fit*(wd: World, lo, hi: int): int =
  ## A building dimension in [lo, hi], capped by what the map can hold beside
  ## its own mirror image; 0 when even lo does not fit.
  let cap = max(3, min(wd.cv.w, wd.cv.h) div 2 - 2)
  if cap >= lo: wd.rng.randint(lo, min(hi, cap)) else: 0

proc wallChain*(wd: World, chain: openArray[Edge], spacing: int, ruined = false) =
  ## Kelp along an ordered chain with gates every ~spacing edges (1-2 wide).
  ## A ruined wall also loses whole runs, never single edges.
  if chain.len < 3: return   # a one- or two-edge wall is a stub, not a structure
  let n = chain.len
  var walled = newSeq[bool](n)
  for j in 0 ..< n: walled[j] = true
  var position = wd.rng.randint(0, max(0, min(n - 1, spacing div 2)))
  while position < n:
    for j in position ..< min(n, position + wd.rng.choice([1, 1, 2])): walled[j] = false
    position += max(3, int(float(spacing) * wd.rng.uniform(0.6, 1.4)))
  if ruined:
    var j = wd.rng.randint(0, 4)
    while j < n:
      let gap = wd.rng.randint(1, 3)
      for k in j ..< min(n, j + gap): walled[k] = false
      j += gap + wd.rng.randint(3, 7)
  for index, e in chain:
    if walled[index]: wd.cv.put(e, 1)

proc fresh*(wd: World, chain: openArray[Edge], done: PySet[Edge]): bool =
  ## True once per mirrored pair of chains (the mirror would redraw it).
  var all = true
  for e in chain:
    if e notin done: all = false
  if all: return false
  for e in chain:
    done.incl e
    done.incl wd.cv.me(e)
  true

proc axisPoints*(wd: World): seq[Point] =
  let cv = wd.cv
  var (cx, cy) = (float(cv.w - 1) / 2, float(cv.h - 1) / 2)
  if wd.hasLm:
    let L = wd.lm
    cx = floorMod(float(L.x0) + float(L.fw - 1) / 2, float(cv.w))
    cy = floorMod(float(L.y0) + float(L.fh - 1) / 2, float(cv.h))
    if cv.sym == "y" or cv.sym == "x": return @[(cx, cy)]
  if cv.sym == "xy":
    result = @[(cx, cy)]
    if not cv.closed and wd.rng.random < 0.5:
      result.add (floorMod(cx + float(cv.w) / 2, float(cv.w)), floorMod(cy + float(cv.h) / 2, float(cv.h)))
    return
  if cv.sym == "y": return @[(cx, wd.rng.uniform(float(cv.h) * 0.3, float(cv.h) * 0.7))]
  @[(wd.rng.uniform(float(cv.w) * 0.3, float(cv.w) * 0.7), cy)]

proc lmRect*(wd: World): (int, int, int, int) = (wd.lm.x0, wd.lm.y0, wd.lm.fw, wd.lm.fh)

proc rectDist*(wd: World, p: Point, r: (int, int, int, int)): float =
  ## Distance from a point to a rectangle of tiles (on the torus if it wraps).
  let cv = wd.cv
  let (x0, y0, fw, fh) = r
  proc d1(a: float, lo, n, size: int): float =
    let shifts = if cv.closed: @[0] else: @[-size, 0, size]
    result = Inf
    for sh in shifts:
      result = min(result, max(max(0.0, float(lo) - (a + float(sh))), (a + float(sh)) - float(lo + n - 1)))
  pythonHypot(d1(p[0], x0, fw, cv.w), d1(p[1], y0, fh, cv.h))

# ------------------------------------------------------------------ the landmark's local frame
# The central landmarks are drawn in a local frame: u runs across the
# symmetry axis (u = 0 is the outer wall facing one side's camps), v runs
# along it. Anything random is drawn on the near half only, u < fu/2; every
# write is mirrored, so the far half is its exact image.

proc frame*(wd: World, x0, y0, fw, fh: int) =
  wd.fx = (x0, y0)
  wd.ft = wd.cv.sym == "x"
  (wd.fu, wd.fv) = if wd.ft: (fh, fw) else: (fw, fh)

proc T*(wd: World, u, v: int): Tile =
  let (x0, y0) = wd.fx
  if wd.ft: wd.R(x0, y0, v, u) else: wd.R(x0, y0, u, v)

proc le*(wd: World, u, v: int, d: Direction): Edge =
  wd.cv.edge(wd.T(u, v), if wd.ft: TransposedDirection[d] else: d)

proc lrect*(wd: World, u0, v0, uw, vh: int): seq[Tile] =
  for du in 0 ..< uw:
    for dv in 0 ..< vh: result.add wd.T(u0 + du, v0 + dv)

proc lside*(wd: World, u0, v0, uw, vh: int, d: Direction): seq[Edge] =
  case d
  of 'N':
    for k in 0 ..< uw: result.add wd.le(u0 + k, v0, 'N')
  of 'S':
    for k in 0 ..< uw: result.add wd.le(u0 + k, v0 + vh - 1, 'S')
  of 'W':
    for k in 0 ..< vh: result.add wd.le(u0, v0 + k, 'W')
  else:
    for k in 0 ..< vh: result.add wd.le(u0 + uw - 1, v0 + k, 'E')

proc lside*(wd: World, r: (int, int, int, int), d: Direction): seq[Edge] = wd.lside(r[0], r[1], r[2], r[3], d)

proc lwall*(wd: World, edges: openArray[Edge], k = 1) =
  for e in edges: wd.cv.put(e, k)

proc lbox*(wd: World, u0, v0, uw, vh: int) = wd.cv.enclose(wd.lrect(u0, v0, uw, vh))

proc ltag*(wd: World, tiles: openArray[Tile], tier: string, p = 1.0) =
  for t in tiles:
    if wd.rng.random < p: wd.tag(t, tier)

proc nearRun*(run: seq[Edge], uw: int): seq[Edge] =
  ## The part of a wall run that lies on the near half (for N/S walls that
  ## cross the axis), so a gate there is mirrored, not doubled.
  let k = max(2, uw div 2 - 1)
  if run.len > k + 1: run[0 ..< k] else: run

proc depthFromOutside*(wd: World): Distances =
  ## Steps from the road round the landmark to every tile inside it.
  let (x0, y0, fw, fh) = wd.lmRect
  let inside = setOf(wd.rect(x0, y0, fw, fh))
  var ring: seq[Tile]
  for t in wd.reserved:
    if t notin inside: ring.add t
  let reserved = wd.reserved
  wd.cv.bfs(ring, blocked = proc (t: Tile): bool = t notin reserved)

# ------------------------------------------------------------------ mazes

proc maze*(wd: World, nc, nr: int, loops = 0.07): PySet[FrozenPair] =
  ## A perfect maze on an nc x nr grid of cells (depth-first), braided with a
  ## few loops: the set of linked cell pairs.
  let start = (wd.rng.randrange(nc), wd.rng.randrange(nr))
  var seen = newPySet[Tile]()
  seen.incl start
  var stack = @[start]
  result = newPySet[FrozenPair]()
  while stack.len > 0:
    let c = stack[^1]
    var next: seq[Tile]
    for d in Dirs:
      let n = (c[0] + d.dx, c[1] + d.dy)
      if 0 <= n[0] and n[0] < nc and 0 <= n[1] and n[1] < nr and n notin seen: next.add n
    if next.len == 0:
      discard stack.pop
      continue
    let n = wd.rng.choice(next)
    result.incl frozenPair(c, n)
    seen.incl n
    stack.add n
  for i in 0 ..< nc:
    for j in 0 ..< nr:
      if i + 1 < nc and wd.rng.random < loops: result.incl frozenPair((i, j), (i + 1, j))
      if j + 1 < nr and wd.rng.random < loops: result.incl frozenPair((i, j), (i, j + 1))

proc bounds*(n, c: int): seq[int] =
  ## Cell boundaries for n tiles cut into cells of c (a short last cell joins
  ## the one before it).
  var b = 0
  while b <= n:
    result.add b
    b += c
  if result[^1] != n: result[^1] = n

proc drawMaze*(wd: World, cb, rb: seq[int], links: PySet[FrozenPair],
               E: proc (u, v: int, d: Direction): Edge) =
  ## Walls between unlinked neighbour cells; E(u, v, d) gives the edge.
  let (nc, nr) = (cb.len - 1, rb.len - 1)
  for i in 0 ..< nc:
    for j in 0 ..< nr:
      if i + 1 < nc and frozenPair((i, j), (i + 1, j)) notin links:
        var run: seq[Edge]
        for v in rb[j] ..< rb[j + 1]: run.add E(cb[i + 1], v, 'W')
        wd.lwall(run)
      if j + 1 < nr and frozenPair((i, j), (i, j + 1)) notin links:
        var run: seq[Edge]
        for u in cb[i] ..< cb[i + 1]: run.add E(u, rb[j + 1], 'N')
        wd.lwall(run)

proc degrees*(links: PySet[FrozenPair]): OrderedTable[Tile, int] =
  ## Each cell's number of links, cells in the order the links name them.
  for link in links:
    for cell in link.members: result[cell] = result.getOrDefault(cell, 0) + 1

# ------------------------------------------------------------------ line art
# Shapes as regions of tiles; their outlines are the walls. Every drawing is
# symmetrised first and drawn from its canonical half, so a gate left in a
# wall is mirrored as a gate, never closed by the mirror.

proc blob*(wd: World, cx, cy, rx, ry: float, p = 2.0): PySet[Tile] =
  ## Tiles of a superellipse |dx/rx|^p + |dy/ry|^p <= 1 (p=2 an ellipse, p=1
  ## a diamond, large p a rounded box).
  let cv = wd.cv
  result = newPySet[Tile]()
  for y in int(floor(cy - ry)) - 1 ..< int(ceil(cy + ry)) + 2:
    for x in int(floor(cx - rx)) - 1 ..< int(ceil(cx + rx)) + 2:
      if cv.closed and not (0 <= x and x < cv.w and 0 <= y and y < cv.h): continue
      if pow(abs((float(x) - cx) / rx), p) + pow(abs((float(y) - cy) / ry), p) <= 1.0:
        result.incl (floorMod(x, cv.w), floorMod(y, cv.h))

proc outlineOf(wd: World, inside: PySet[Tile]): seq[Edge] =
  let cv = wd.cv
  var edges = newPySet[Edge]()
  for t in inside:
    for d in Dirs:
      if cv.nb(t, d) notin inside: edges.incl cv.edge(t, d)
  edges.toSeq

proc outline*(wd: World, region: openArray[Tile]): seq[Edge] =
  wd.outlineOf(setOf(region) | wd.cv.mirrored(region))

proc outline*(wd: World, region: PySet[Tile]): seq[Edge] =
  wd.outlineOf(region.copy | wd.cv.mirrored(region))

proc draw*(wd: World, edges: openArray[Edge], spacing = -1) =
  ## Wall along a set of edges: gated every ~spacing, one gate if spacing is
  ## large, none if spacing is -1.
  let cv = wd.cv
  var all = newPySet[Edge]()
  for e in edges: all.incl e
  for e in edges: all.incl cv.me(e)
  var kept: seq[Edge]
  for e in all:
    if e <= cv.me(e) and not cv.isBorder(e): kept.add e
  kept.sort
  for chain in cv.chains(kept):
    if spacing < 0:
      for e in chain: cv.put(e, 1)
    else:
      wd.wallChain(chain, spacing)

proc clearOf*(wd: World, region: openArray[Tile], camps = 3.5): bool =
  ## A region is free to draw on: off rock, other structures and the camps.
  let cv = wd.cv
  var all = wd.camps
  for c in wd.camps: all.add cv.m(c)
  for t in region:
    if t in cv.solid or t in wd.occupied or wd.tbiome.getOrDefault(t, "") == "vault": return false
    for c in all:
      if cv.dist(t, c) < camps: return false
  true

proc clearOf*(wd: World, region: PySet[Tile], camps = 3.5): bool = wd.clearOf(region.toSeq, camps)

proc claimGrown(wd: World, grow: PySet[Tile], ring: int) =
  let cv = wd.cv
  for _ in 0 ..< ring:
    var around = newPySet[Tile]()
    for t in grow:
      for d in Dirs: around.incl cv.nb(t, d)
    grow |= around
  grow |= cv.mirrored(grow)
  wd.occupied |= grow
  wd.reserved |= grow

proc claim*(wd: World, region: openArray[Tile], ring = 1) = wd.claimGrown(setOf(region), ring)

proc claim*(wd: World, region: PySet[Tile], ring = 1) = wd.claimGrown(region.copy, ring)

# ------------------------------------------------------------------ sites and portal ends

proc site*(wd: World, i, bw, bh: int, allow: openArray[string] = []): (bool, Tile) =
  ## A clean footprint near district i's seed: mostly inside the district, off
  ## other structures (with a one-tile walkway round it), clear of rock and
  ## kelp, and clear of its own mirror image.
  let cv = wd.cv
  let memset = wd.memset[i]
  let (sx, sy) = wd.seeds[i]
  var best: Tile
  var found = false
  var bestScore = 1e9
  let members = wd.members[i]
  if members.len == 0: return (false, (0, 0))   # a district swallowed whole by its neighbours
  for _ in 0 ..< 120:
    let (cx, cy) = wd.rng.choice(members)
    let (x0, y0) = (cx - floorDiv(bw, 2), cy - floorDiv(bh, 2))
    if cv.closed and (x0 < 1 or y0 < 1 or x0 + bw > cv.w - 1 or y0 + bh > cv.h - 1): continue
    if not cv.closed and (bw > cv.w - 2 or bh > cv.h - 2): continue
    let tiles = wd.rect(x0, y0, bw, bh)
    var inside = 0
    for t in tiles:
      if t in memset: inc inside
    if float(inside) < 0.5 * float(tiles.len): continue   # a building may straddle a district line, not live across it
    let ring = setOf(wd.rect(x0 - 1, y0 - 1, bw + 2, bh + 2))
    var blocked = ring.meets(wd.occupied)
    if not blocked:
      for t in ring:
        if t in cv.solid: blocked = true
    if blocked: continue
    var reservedGround = false
    for t in tiles:
      let b = wd.tbiome[t]
      if (b == "camp" or b == "vault") and b notin allow: reservedGround = true
    if reservedGround: continue
    var walled = false
    for t in tiles:
      for d in Dirs:
        if cv.kindOf(cv.edge(t, d)) != 0: walled = true
    if walled: continue
    if cv.mirrored(ring).meets(ring): continue
    let score = cv.dist((float(x0) + float(bw) / 2, float(y0) + float(bh) / 2), (sx, sy)) + wd.rng.random
    if score < bestScore:
      (best, bestScore, found) = ((x0, y0), score, true)
  if found:
    let ring = setOf(wd.rect(best[0] - 1, best[1] - 1, bw + 2, bh + 2))
    wd.occupied |= ring | cv.mirrored(ring)
  (found, best)

proc farAnchor*(wd: World, e1: Edge, box: openArray[Tile], reach: Distances): (bool, Edge) =
  ## The far end of a portal from e1 on a box's wall: a door in an existing
  ## wall far from the box, else open ground, on an edge of e1's orientation
  ## beside a tile in `reach`.
  let cv = wd.cv
  let inBox = setOf(box)
  var candidates: seq[(Edge, int)]
  for e, k in cv.kind: candidates.add (e, k)
  candidates.sort
  for t in wd.rng.sample(cv.tiles, min(200, cv.tiles.len)):
    candidates.add (cv.edge(t, wd.rng.choice(Dirs)), 0)
  var best: (float, Edge)
  var found = false
  for (e, k) in candidates:
    if e.o != e1.o or k == 2 or cv.isBorder(e): continue
    let (a, b) = cv.sides(e)
    if a in cv.solid or b in cv.solid or a in inBox or b in inBox: continue
    if a notin reach and b notin reach: continue
    let far = cv.dist(a, box[0])
    if far < 6: continue
    let entry = (far * wd.rng.uniform(0.5, 1.5) + (if k == 1: 4.0 else: 0.0), e)
    if not found or entry > best: (best, found) = (entry, true)
  (found, best[1])

proc freeBox*(wd: World, x, y, bw, bh: int): seq[Tile] =
  ## A shrine's tiles at (x, y), or nothing when they or the ground round them
  ## are taken, walled, or overlap their mirror image.
  let cv = wd.cv
  var box: seq[Tile]
  for dx in 0 ..< bw:
    for dy in 0 ..< bh: box.add (floorMod(x + dx, cv.w), floorMod(y + dy, cv.h))
  let mb = cv.mirrored(box)
  if mb.meets(setOf(box)): return
  let ring = newPySet[Tile]()
  for t in box:
    for d in Dirs:
      ring.incl cv.nb(t, d)
      if cv.kindOf(cv.edge(t, d)) != 0: return
  if ring.meets(mb): return
  for t in ring.toSeq & box:
    let b = wd.tbiome.getOrDefault(t, "")
    if t in cv.solid or t in wd.occupied or b == "camp" or b == "vault": return
  box

proc podBox*(wd: World, x, y, bw, bh: int): seq[Tile] =
  ## A pod's tiles at (x, y), clear of rock, camps, the heart, the landmark and
  ## its own mirror image, walls or not; nothing when they aren't.
  let cv = wd.cv
  var box: seq[Tile]
  for dx in 0 ..< bw:
    for dy in 0 ..< bh: box.add (floorMod(x + dx, cv.w), floorMod(y + dy, cv.h))
  let mb = cv.mirrored(box)
  var around = newPySet[Tile]()
  for t in box:
    for d in Dirs: around.incl cv.nb(t, d)
  let inBox = setOf(box)
  let ring = around - inBox
  if mb.meets(inBox | ring): return
  for t in ring.toSeq & box:
    let b = wd.tbiome.getOrDefault(t, "")
    if t in cv.solid or t in wd.occupied or t in wd.reserved or b == "camp" or b == "vault": return
  box
