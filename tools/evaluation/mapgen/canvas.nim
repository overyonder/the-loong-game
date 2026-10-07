## One map's tiles, edges and portals, with every mutation symmetric, and the
## noise fields the climate is drawn from.
##
## Edges: ('h', x, y) is the north side of tile (x, y), ('v', x, y) its west
## side. Kinds: 0 open, 1 kelp, 2 portal (the engine's convention).

import std/[algorithm, deques, math, tables]
import ../[python_math, python_random, python_set]

type
  Tile*  = (int, int)
  Point* = (float, float)
  Edge*  = tuple[o: char, x, y: int]
  Direction* = char                     # 'N', 'E', 'S' or 'W'
  Canvas* = ref object
    w*, h*:   int
    sym*:     string                    # "x", "y" or "xy"
    closed*:  bool
    kind*:    OrderedTable[Edge, int]   # edges that are not open
    pid*:     OrderedTable[Edge, int]   # portal edges' pair numbers
    partner*: Table[Edge, Edge]         # each portal edge's other end
    npid*:    int
    solid*:   PySet[Tile]
    tiles*:   seq[Tile]                 # row by row

const Dirs* = ['N', 'E', 'S', 'W']

proc dx*(d: Direction): int =
  case d
  of 'E': 1
  of 'W': -1
  else: 0

proc dy*(d: Direction): int =
  case d
  of 'N': -1
  of 'S': 1
  else: 0

proc opposite*(d: Direction): Direction =
  case d
  of 'N': 'S'
  of 'S': 'N'
  of 'E': 'W'
  else: 'E'

proc pyHash*(e: Edge): int64 =
  ## Edge sets are only ever read in sorted order, so any stable hash serves.
  pyHash(((ord(e.o), e.x), (e.y, 0)))

proc toPoint*(t: Tile): Point = (float(t[0]), float(t[1]))

proc put*(cv: Canvas, e: Edge, k: int, force = false)

proc newCanvas*(w, h: int, sym: string, closed: bool): Canvas =
  result = Canvas(w: w, h: h, sym: sym, closed: closed, solid: newPySet[Tile]())
  for y in 0 ..< h:
    for x in 0 ..< w: result.tiles.add (x, y)
  if closed:
    for x in 0 ..< w: result.put(('h', x, 0), 1, force = true)
    for y in 0 ..< h: result.put(('v', 0, y), 1, force = true)

# --- symmetry

proc m*(cv: Canvas, t: Tile): Tile =
  if cv.sym == "y": return (cv.w - 1 - t[0], t[1])
  if cv.sym == "x": return (t[0], cv.h - 1 - t[1])
  (cv.w - 1 - t[0], cv.h - 1 - t[1])

proc mf*(cv: Canvas, p: Point): Point =
  ## Mirror of a float point (district seeds may sit on the axis).
  if cv.sym == "y": return (float(cv.w - 1) - p[0], p[1])
  if cv.sym == "x": return (p[0], float(cv.h - 1) - p[1])
  (float(cv.w - 1) - p[0], float(cv.h - 1) - p[1])

proc me*(cv: Canvas, e: Edge): Edge =
  let (w, h) = (cv.w, cv.h)
  if e.o == 'h':
    if cv.sym == "y": return ('h', w - 1 - e.x, e.y)
    if cv.sym == "x": return ('h', e.x, floorMod(h - e.y, h))
    return ('h', w - 1 - e.x, floorMod(h - e.y, h))
  if cv.sym == "y": return ('v', floorMod(w - e.x, w), e.y)
  if cv.sym == "x": return ('v', e.x, h - 1 - e.y)
  ('v', floorMod(w - e.x, w), h - 1 - e.y)

proc isCanon*(cv: Canvas, t: Tile): bool = t <= cv.m(t)

# --- geometry

proc nb*(cv: Canvas, t: Tile, d: Direction): Tile =
  (floorMod(t[0] + d.dx, cv.w), floorMod(t[1] + d.dy, cv.h))

proc edge*(cv: Canvas, t: Tile, d: Direction): Edge =
  let (x, y) = t
  case d
  of 'N': ('h', x, y)
  of 'S': ('h', x, floorMod(y + 1, cv.h))
  of 'W': ('v', x, y)
  else: ('v', floorMod(x + 1, cv.w), y)

proc sides*(cv: Canvas, e: Edge): (Tile, Tile) =
  if e.o == 'h': return ((e.x, floorMod(e.y - 1, cv.h)), (e.x, e.y))
  ((floorMod(e.x - 1, cv.w), e.y), (e.x, e.y))

proc isBorder*(cv: Canvas, e: Edge): bool =
  cv.closed and ((e.o == 'h' and e.y == 0) or (e.o == 'v' and e.x == 0))

proc dist*(cv: Canvas, a, b: Point): float =
  var (dx, dy) = (abs(a[0] - b[0]), abs(a[1] - b[1]))
  if not cv.closed:
    dx = min(dx, float(cv.w) - dx)
    dy = min(dy, float(cv.h) - dy)
  pythonHypot(dx, dy)

proc dist*(cv: Canvas, a, b: Tile): float = cv.dist(a.toPoint, b.toPoint)

proc kindOf*(cv: Canvas, e: Edge): int = cv.kind.getOrDefault(e, 0)

# --- mutation (always symmetric)

proc put*(cv: Canvas, e: Edge, k: int, force = false) =
  let mirror = cv.me(e)
  let targets = if mirror == e: @[e] else: @[e, mirror]
  for x in targets:
    if cv.kindOf(x) == 2: continue          # never overwrite a portal
    if not force and cv.isBorder(x): continue   # the border stays shut
    if k != 0: cv.kind[x] = k
    else: cv.kind.del x

proc link*(cv: Canvas, e1, e2: Edge): bool =
  ## Portal pair e1<->e2 plus its mirror pair. False if illegal.
  if e1.o != e2.o or e1 == e2: return false
  let (m1, m2) = (cv.me(e1), cv.me(e2))
  if m1 == e1 or m2 == e2: return false     # never on the symmetry line
  let sameEnds = (m1 == e1 or m1 == e2) and (m2 == e1 or m2 == e2) and
                 (e1 == m1 or e1 == m2) and (e2 == m1 or e2 == m2)
  let pairs = if sameEnds: @[(e1, e2)] else: @[(e1, e2), (m1, m2)]
  var used: seq[Edge]
  for (a, b) in pairs:
    for e in [a, b]:
      if e notin used: used.add e
  if used.len != 2 * pairs.len: return false
  for e in used:
    if cv.kindOf(e) == 2 or cv.isBorder(e): return false
  for (a, b) in pairs:
    for e in [a, b]:
      cv.kind[e] = 2
      cv.pid[e] = cv.npid
    cv.partner[a] = b
    cv.partner[b] = a
    inc cv.npid
  true

proc pair(cv: Canvas, t: Tile): PySet[Tile] =
  ## `{t, m(t)}`.
  result = newPySet[Tile]()
  result.incl t
  result.incl cv.m(t)

proc makeSolid*(cv: Canvas, t: Tile) =
  let both = cv.pair(t)
  for s in both: cv.solid.incl s
  for s in both:
    for d in Dirs:
      if cv.nb(s, d) notin cv.solid: cv.put(cv.edge(s, d), 1)

proc post*(cv: Canvas, v: Tile, arm = 1) =
  ## A pillar: a cross of kelp round the vertex v (the north-west corner of
  ## tile v). It blocks the way between the four tiles round it and encloses
  ## none of them, so it never reads as a sealed room.
  let (x, y) = v
  for k in 0 ..< arm:
    for e in [('h', floorMod(x - 1 - k, cv.w), y), ('h', floorMod(x + k, cv.w), y),
              ('v', x, floorMod(y - 1 - k, cv.h)), ('v', x, floorMod(y + k, cv.h))]:
      cv.put(e, 1)

proc verts*(cv: Canvas, e: Edge): (Tile, Tile) =
  if e.o == 'h': return ((e.x, e.y), (floorMod(e.x + 1, cv.w), e.y))
  ((e.x, e.y), (e.x, floorMod(e.y + 1, cv.h)))

proc chains*(cv: Canvas, edges: openArray[Edge]): seq[seq[Edge]] =
  ## Split edges into runs that touch end to end, each in walking order, so a
  ## wall can be drawn along its length with gates in it.
  var byVertex = initTable[Tile, seq[Edge]]()
  for e in edges:
    let (a, b) = cv.verts(e)
    for v in [a, b]: byVertex.mgetOrPut(v, @[]).add e
  var left = initOrderedTable[Edge, bool]()
  for e in edges: left[e] = true
  while left.len > 0:
    var start: Edge
    var best = (high(int), ('z', 0, 0))
    for e in left.keys:
      let (a, b) = cv.verts(e)
      let key = (byVertex[a].len + byVertex[b].len, e)
      if key < best: (best, start) = (key, e)
    var chain: seq[Edge]
    var stack = @[start]
    while stack.len > 0:
      let e = stack.pop
      if e notin left: continue
      left.del e
      chain.add e
      var next: seq[Edge]
      let (a, b) = cv.verts(e)
      for v in [a, b]:
        for f in byVertex[v]:
          if f in left: next.add f
      next.sort
      stack.add next
    result.add chain

proc tidy*(cv: Canvas) =
  ## Kelp between two rock tiles is invisible and meaningless: drop it.
  var edges: seq[Edge]
  for e in cv.kind.keys: edges.add e
  for e in edges:
    let (a, b) = cv.sides(e)
    if cv.kind[e] == 1 and a in cv.solid and b in cv.solid and not cv.isBorder(e):
      cv.kind.del e

proc enclose*(cv: Canvas, tiles: openArray[Tile]) =
  let inside = toPySet(tiles)
  for t in inside:
    for d in Dirs:
      if cv.nb(t, d) notin inside: cv.put(cv.edge(t, d), 1)

# --- movement (mirrors the engine's resolve)

proc step*(cv: Canvas, t: Tile, d: Direction): (bool, Tile) =
  ## The tile a move from t towards d lands on, if the move is open.
  let e = cv.edge(t, d)
  let k = cv.kindOf(e)
  if k == 1: return (false, (0, 0))
  var n: Tile
  if k == 2:
    let p = cv.partner[e]
    if p.o == 'h': n = (if d == 'S': (p.x, p.y) else: (p.x, floorMod(p.y - 1, cv.h)))
    else: n = (if d == 'E': (p.x, p.y) else: (floorMod(p.x - 1, cv.w), p.y))
  else:
    n = cv.nb(t, d)
  if n in cv.solid: return (false, (0, 0))
  (true, n)

type Distances* = OrderedTable[Tile, int]

proc bfs*(cv: Canvas, sources: openArray[Tile], portals = true,
          blocked: proc (t: Tile): bool = nil): Distances =
  ## Steps from the nearest source to every reachable tile, in visiting order.
  var queue = initDeque[Tile]()
  for s in sources:
    if s notin result:
      result[s] = 0
      queue.addLast s
  while queue.len > 0:
    let t = queue.popFirst
    for d in Dirs:
      var n: Tile
      if not portals and cv.kindOf(cv.edge(t, d)) == 2:
        n = cv.nb(t, d)
        if n in cv.solid: continue
      else:
        let (open, landed) = cv.step(t, d)
        if not open: continue
        n = landed
      if n in result or (blocked != nil and blocked(n)): continue
      result[n] = result[t] + 1
      queue.addLast n

proc exits*(cv: Canvas, t: Tile, blocked: proc (t: Tile): bool = nil): int =
  for d in Dirs:
    let (open, n) = cv.step(t, d)
    if open and (blocked == nil or not blocked(n)): inc result

# ------------------------------------------------------------------ noise

type ValueNoise* = object
  ## Periodic value noise: tiles the torus exactly, so wrap maps have no seam.
  gx, gy, w, h: int
  v: seq[seq[float]]

proc initValueNoise*(rng: var PythonRandom, w, h: int, cell: float): ValueNoise =
  result.gx = max(1, pythonRound(float(w) / cell))
  result.gy = max(1, pythonRound(float(h) / cell))
  result.w = w
  result.h = h
  for _ in 0 ..< result.gy:
    var row: seq[float]
    for _ in 0 ..< result.gx: row.add rng.random
    result.v.add row

proc at*(noise: ValueNoise, x, y: int): float =
  let u = float(x) / float(noise.w) * float(noise.gx)
  let v = float(y) / float(noise.h) * float(noise.gy)
  let (i, j) = (int(floor(u)), int(floor(v)))
  var (fu, fv) = (u - float(i), v - float(j))
  fu = fu * fu * (3 - 2 * fu)
  fv = fv * fv * (3 - 2 * fv)
  let (i0, i1) = (floorMod(i, noise.gx), floorMod(i + 1, noise.gx))
  let (j0, j1) = (floorMod(j, noise.gy), floorMod(j + 1, noise.gy))
  let a = noise.v[j0][i0] + (noise.v[j0][i1] - noise.v[j0][i0]) * fu
  let b = noise.v[j1][i0] + (noise.v[j1][i1] - noise.v[j1][i0]) * fu
  a + (b - a) * fv

proc field*(cv: Canvas, rng: var PythonRandom, cell: float, octaves = 3): Table[Tile, float] =
  ## Symmetric fBm field over the tiles, equalised to ranks in [0, 1].
  var layers: seq[ValueNoise]
  for o in 0 ..< octaves:
    layers.add initValueNoise(rng, cv.w, cv.h, max(2.0, cell / float(2 ^ o)))
  proc raw(t: Tile): float =
    var terms: seq[float]
    for o, layer in layers: terms.add layer.at(t[0], t[1]) * pow(0.5, float(o))
    pythonSum(terms)
  var keyed: seq[((float, Tile), int)]
  for index, t in cv.tiles:
    keyed.add(((raw(t) + raw(cv.m(t)), min(t, cv.m(t))), index))
  keyed.sort
  let n = max(1, keyed.len - 1)
  for rank, entry in keyed: result[cv.tiles[entry[1]]] = float(rank) / float(n)
