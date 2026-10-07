## The driver: a seed's world skeleton, its candidate worlds judged and
## bounded by the official envelope, and maps drawn like a given one.

import std/[algorithm, math, strutils, tables]
import canvas, world, stages, profile
import ../[python_math, python_random]

type
  Settings* = object
    ## World settings; zero, empty or NaN leaves a setting to the seed.
    w*, h*:     int
    sym*:       string
    style*:     string
    closed*:    int       # -1 drawn, 0 wrapping, 1 closed
    perSide*:   int
    supply*:    float     # target pearls per round
    landmark*:  string
    minSide*:   int

  Skeleton* = object
    w*, h*:    int
    sym*:      string
    style*:    string
    closed*:   bool
    perSide*:  int
    supply*:   float
    landmark*: string

proc defaultSettings*(): Settings =
  Settings(closed: -1, supply: NaN, minSide: 8)

proc macroSkeleton*(seed: int, settings: Settings, supplyPer100Tiles = (0.0, Inf)): Skeleton =
  ## The world's skeleton, fixed by the seed: shape, style, symmetry, border,
  ## dragon count. Candidates of one seed differ only in the details.
  let minSide = settings.minSide
  if not (8 <= minSide and minSide <= 64): raise newException(ValueError, "Minimum map side must be from 8 to 64")
  var rng = initPythonRandom(int64(seed))
  var (w, h) = (settings.w, settings.h)
  if w == 0:
    var shapes: seq[(int, int)]
    for (x, y) in Shapes:
      if min(x, y) >= minSide: shapes.add (x, y)
    (w, h) = rng.choice(shapes)
    if rng.random < FreeSizeShare:
      w = rng.randint(max(11, minSide), 64)
      h = max(minSide, min(64, pythonRound(float(w) / rng.uniform(1.0, 3.0))))
    if rng.random < 0.3: swap(w, h)
  if h == 0 or not (minSide <= w and w <= 64) or not (minSide <= h and h <= 64):
    raise newException(ValueError, "Map dimensions must be from " & $minSide & " to 64")
  let style = if settings.style.len > 0: settings.style else: rng.choice(StyleNames)
  var sym = settings.sym
  if sym.len == 0: sym = if rng.random < 0.55: "xy" elif w >= h: "y" else: "x"
  let closed = if settings.closed >= 0: settings.closed == 1 else: rng.random < style(style).closed
  var perSide = settings.perSide
  if perSide == 0: perSide = max(1, min(7, pythonRound(float(w * h) / 260 + rng.uniform(-1.0, 1.5))))
  var supply = settings.supply
  if supply.isNaN:
    # Official maps give each dragon from a third of a pearl a round (Small)
    # to dozens (Help); the envelope check trims the extremes.
    supply = float(perSide) * exp(rng.uniform(ln(0.3), ln(12.0)))
    let (low, high) = supplyPer100Tiles
    supply = min(max(supply, 1.1 * low * float(w) * float(h) / 100), 0.9 * high * float(w) * float(h) / 100)
  var landmark = settings.landmark
  if landmark.len == 0:
    var names: seq[string]
    var weights: seq[float]
    for (name, weight) in style(style).landmark:
      names.add name
      weights.add weight
    var order: seq[int]
    for index in 0 ..< names.len: order.add index
    order.sort(proc (a, b: int): int = cmp(names[a], names[b]))
    var sortedNames: seq[string]
    var sortedWeights: seq[float]
    for index in order:
      sortedNames.add names[index]
      sortedWeights.add weights[index]
    landmark = rng.choices(sortedNames, sortedWeights)[0]
  Skeleton(w: w, h: h, sym: sym, style: style, closed: closed, perSide: perSide, supply: supply, landmark: landmark)

# The lesson measures `--like` matches, each with the cap that keeps an
# unreachable 99 from swamping it. Each is divided by its spread over the
# official maps, so every lesson weighs the same.
const LessonCaps* = [("portal_food", 1.0), ("fountain", 1.0), ("fountain_steps", 40.0), ("portal_short", 20.0),
                     ("far_food", 1.0), ("contested", 1.0), ("race", 20.0), ("lanes", 1.0), ("longest", 25.0)]

type Lessons* = object
  ## The official maps' envelope and each lesson's spread over them.
  envelope*: Envelope
  spreads*:  Table[string, float]

proc officialLessons*(officialMaps: string): Lessons =
  let profiles = mapProfiles(officialMaps)
  for m in EnvelopeMeasures:
    var (lo, hi) = (Inf, -Inf)
    for p in profiles:
      lo = min(lo, p.measure(m))
      hi = max(hi, p.measure(m))
    result.envelope.ranges[m] = (lo, hi)
  for (m, cap) in LessonCaps:
    var (lo, hi) = (Inf, -Inf)
    for p in profiles:
      let value = pythonMin(p.measure(m), cap)
      lo = pythonMin(lo, value)
      if hi < value: hi = value
    result.spreads[m] = max(1e-6, hi - lo)

proc lessonDistance*(lessons: Lessons, profile, like: MapProfile): float =
  ## How far apart two maps are on the lessons: the sum over the lesson caps
  ## of each capped measure's difference over its official spread.
  var terms: seq[float]
  for (m, cap) in LessonCaps:
    terms.add abs(pythonMin(profile.measure(m), cap) - pythonMin(like.measure(m), cap)) / lessons.spreads[m]
  pythonSum(terms)

proc startingPairs(seed: int, dragons: seq[seq[Tile]]): seq[seq[Tile]] =
  ## Uniform, seeded pair order, independent of length or placement quality.
  ## Applied after candidate selection so scoring cannot prefer a queen
  ## assignment.
  result = dragons
  var rng = initPythonRandom(int64(seed))
  rng.shuffle(result)

proc generate*(seed: int, lessons: Lessons, candidates = 8, settings = defaultSettings(),
               like: ptr MapProfile = nil): (bool, World) =
  ## Build worlds from sub-seeds of `seed` until `candidates` are valid and
  ## inside the envelope; keep the best, or with `like` the one nearest it
  ## (`lessonDistance`). False when none is.
  let skeleton = macroSkeleton(seed, settings, lessons.envelope.ranges["supply"])
  var best: World
  var bestKey = 0.0
  var valid = 0
  for i in 0 ..< candidates * 6:
    if valid >= candidates: break
    let wd = newWorld(seed * 1009 + i, skeleton.w, skeleton.h, skeleton.sym, skeleton.style, skeleton.closed,
                      skeleton.perSide, skeleton.supply, skeleton.landmark)
    wd.origin = (seed, i)
    if not wd.build(): continue
    let profile = mapProfile(wd.text, wd.name)
    if lessons.envelope.outside(profile).len > 0: continue
    inc valid
    let key = if like != nil: lessons.lessonDistance(profile, like[]) else: -wd.score
    if best == nil or key < bestKey: (best, bestKey) = (wd, key)
  if best == nil: return (false, nil)
  best.dragons = startingPairs(seed, best.dragons)
  (true, best)

proc likeSettings*(text: string): (MapProfile, Settings) =
  ## The settings a sibling of a map shares with it: size, symmetry, border,
  ## dragons per side and pearl supply. Layout, style and landmark are drawn.
  var fields = initTable[string, seq[string]]()
  for line in text.splitLines:
    let f = line.splitWhitespace
    if f.len > 0: fields[f[0]] = f[1 .. ^1]
  let profile = mapProfile(text, "like")
  let (w, h) = (parseInt(fields["MAP"][0]), parseInt(fields["MAP"][1]))
  var settings = defaultSettings()
  settings.w = w
  settings.h = h
  settings.sym = if "SYMMETRY" in fields: fields["SYMMETRY"][0] else: "xy"
  settings.closed = ord(profile.closed)
  settings.perSide = profile.perSide
  settings.supply = profile.supply * float(w) * float(h) / 100
  (profile, settings)

type Sibling* = tuple[distance: float, number: int, world: World, profile: MapProfile]

proc siblings*(text: string, count, seed: int, lessons: Lessons, candidates = 3, draws = 6,
               minSide = 8): (MapProfile, seq[Sibling]) =
  ## `count` maps like the map `text`: `count * draws` worlds with its
  ## settings (`likeSettings`) and drawn styles, each the nearest of its
  ## seed's candidates, and the `count` nearest of them, nearest first.
  var (like, settings) = likeSettings(text)
  settings.minSide = minSide
  var found: seq[Sibling]
  for number in 0 ..< count * draws:
    for attempt in 0 ..< 5:
      let (ok, world) = generate((seed * 1000 + number) * 5 + attempt, lessons, candidates, settings, like.addr)
      if not ok: continue
      let profile = mapProfile(world.text, world.name)
      found.add (lessons.lessonDistance(profile, like), number, world, profile)
      break
  found.sort(proc (a, b: Sibling): int = cmp((a.distance, a.number), (b.distance, b.number)))
  (like, found.pySlice(0, count))
