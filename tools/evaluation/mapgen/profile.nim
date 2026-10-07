## What a map file shows about its size, economy, walls and forces, the
## lessons it teaches, and the envelope of the official maps a generated map
## must stay inside.

import std/[algorithm, deques, math, os, strutils, tables]
import canvas
import ../[python_json, python_math, python_random]

type
  MapProfile* = object
    name*:          string
    tiles*:         int
    aspect*:        float   # long side over short side
    supply*:        float   # pearl spawn attempts per round per 100 tiles
    spawning*:      float   # share of tiles that can spawn
    gapClasses*:    int     # distinct (min, max) spawn ranges
    kelp*:          float   # kelp edges per tile
    portalPairs*:   int
    perSide*:       int
    longest*:       int     # a side's longest starting dragon
    force*:         int     # a side's total starting length
    closed*:        bool    # the wrap edges are all kelp
    deadEnds*:      float   # share of reachable tiles with at most one exit
    detour*:        float   # walking distance over wrapped Manhattan, portals ignored
    # What the map teaches, measured on team A's side (team B's is its
    # mirror). Pearl supply is each tile's spawn attempts per round.
    portalFood*:    float   # share of supply reached only through a portal
    fountain*:      float   # share of supply in the richest 7x7 square, a dragon's view
    fountainSteps*: int     # steps from the nearest starting head to that square
    portalShort*:   int     # steps a portal saves on the way there; 99 if only a portal leads there
    farFood*:       float   # share of supply more than 20 steps from every starting head
    contested*:     float   # share of supply about as near both sides (within 30% or 2 steps)
    race*:          float   # arrival gap at the fountain; 99 if either side cannot reach it
    lanes*:         float   # share of reachable tiles in a one-wide straight corridor

  Envelope* = object
    ## The smallest and largest value of each measure over the official maps.
    ## It bounds the generator without shaping its spread: tournament maps are
    ## unseen, so a map anywhere inside the range is as plausible as the
    ## official maps' own values.
    ranges*: OrderedTable[string, (float, float)]

const
  # The measures a generated map must keep within the official maps' range:
  # size, shape, food, walls, portals and the starting forces.
  EnvelopeMeasures* = ["tiles", "aspect", "supply", "kelp", "portal_pairs", "per_side", "longest", "force",
                       "dead_ends"]
  IntegerMeasures = ["tiles", "gap_classes", "portal_pairs", "per_side", "longest", "force", "fountain_steps",
                     "portal_short"]
  ProfileMeasures* = ["tiles", "aspect", "supply", "spawning", "gap_classes", "kelp", "portal_pairs", "per_side",
                      "longest", "force", "closed", "dead_ends", "detour", "portal_food", "fountain",
                      "fountain_steps", "portal_short", "far_food", "contested", "race", "lanes"]

proc measure*(profile: MapProfile, name: string): float =
  case name
  of "tiles": float(profile.tiles)
  of "aspect": profile.aspect
  of "supply": profile.supply
  of "spawning": profile.spawning
  of "gap_classes": float(profile.gapClasses)
  of "kelp": profile.kelp
  of "portal_pairs": float(profile.portalPairs)
  of "per_side": float(profile.perSide)
  of "longest": float(profile.longest)
  of "force": float(profile.force)
  of "closed": float(ord(profile.closed))
  of "dead_ends": profile.deadEnds
  of "detour": profile.detour
  of "portal_food": profile.portalFood
  of "fountain": profile.fountain
  of "fountain_steps": float(profile.fountainSteps)
  of "portal_short": float(profile.portalShort)
  of "far_food": profile.farFood
  of "contested": profile.contested
  of "race": profile.race
  else: profile.lanes

proc measureRepr*(profile: MapProfile, name: string): string =
  ## The measure as Python's repr writes it.
  let value = profile.measure(name)
  if name in IntegerMeasures: $int(value) else: pythonFloat(value)

proc walkSteps(cv: Canvas, sources: openArray[Tile], portals = true): Distances =
  ## Steps from the nearest source to every tile reached, as the engine moves;
  ## without portals a portal edge is a wall.
  var queue = initDeque[Tile]()
  for s in sources:
    if s notin result:
      result[s] = 0
      queue.addLast s
  while queue.len > 0:
    let t = queue.popFirst
    for d in Dirs:
      if not portals and cv.kindOf(cv.edge(t, d)) == 2: continue
      let (open, n) = cv.step(t, d)
      if open and n notin result:
        result[n] = result[t] + 1
        queue.addLast n

proc lessons(profile: var MapProfile, cv: Canvas, gaps: OrderedTable[Tile, (int, int)], team, rival: seq[seq[Tile]],
             reach: Distances) =
  ## The features the official maps teach through: food only a portal reaches
  ## or a portal shortens the way to, a fountain and how far and how
  ## contested it is, food far from both sides, food both sides reach about
  ## as soon, and one-wide lanes.
  var rate = initOrderedTable[Tile, float]()
  for t, (lo, hi) in gaps:
    if hi > 0 and t in reach: rate[t] = 2 / float(lo + hi)
  var rates: seq[float]
  for r in rate.values: rates.add r
  var total = pythonSum(rates)
  if total == 0: total = 1.0
  var heads, rivalHeads: seq[Tile]
  for body in team: heads.add body[0]
  for body in rival: rivalHeads.add body[0]
  let ours = cv.walkSteps(heads)
  let theirs = cv.walkSteps(rivalHeads)
  let onFoot = cv.walkSteps(heads, portals = false)
  proc square(c: Tile): seq[Tile] =
    for dx in -3 .. 3:
      for dy in -3 .. 3: result.add (floorMod(c[0] + dx, cv.w), floorMod(c[1] + dy, cv.h))
  var (richest, centre) = (-1.0, (0, 0))
  for c in cv.tiles:
    var terms: seq[float]
    for t in square(c): terms.add rate.getOrDefault(t, 0.0)
    let supply = pythonSum(terms)
    if supply > richest: (richest, centre) = (supply, c)
  var fountain, near: seq[Tile]
  for t in square(centre):
    if t in rate: fountain.add t
  for t in square(centre) & square(cv.m(centre)):
    if t in rate: near.add t
  var steps = 0
  var walked = 0.0
  if near.len > 0:
    steps = high(int)
    walked = Inf
    for t in near:
      steps = min(steps, ours[t])
      walked = pythonMin(walked, (if t in onFoot: float(onFoot[t]) else: Inf))
  var arrivals: array[2, float]
  for index, side in [ours, theirs]:
    if fountain.len > 0:
      arrivals[index] = Inf
      for t in fountain: arrivals[index] = pythonMin(arrivals[index], (if t in side: float(side[t]) else: Inf))
  let race = abs(arrivals[0] - arrivals[1])
  var lanes = 0
  for t in reach.keys:
    var exits: set[char]
    for d in Dirs:
      if cv.step(t, d)[0]: exits.incl d
    if exits == {'N', 'S'} or exits == {'E', 'W'}: inc lanes
  var portalFood, farFood, contested: seq[float]
  for t, r in rate:
    if t notin onFoot: portalFood.add r
    if pythonMin(float(ours[t]), (if t in theirs: float(theirs[t]) else: Inf)) > 20: farFood.add r
    if t in theirs and float(abs(ours[t] - theirs[t])) <= max(2.0, 0.3 * float(min(ours[t], theirs[t]))):
      contested.add r
  profile.portalFood = pythonSum(portalFood) / total
  profile.fountain = richest / total
  profile.fountainSteps = steps
  profile.portalShort = if walked < Inf: int(walked) - steps else: 99
  profile.farFood = pythonSum(farFood) / total
  profile.contested = pythonSum(contested) / total
  profile.race = pythonMin(race, 99)
  profile.lanes = float(lanes) / float(max(1, reach.len))

proc mapProfile*(text, name: string): MapProfile =
  ## Measure a .map file's text; a replay carries the same text.
  var (w, h) = (0, 0)
  var sym = "xy"
  var gaps = initOrderedTable[Tile, (int, int)]()
  var pairs = initOrderedTable[int, seq[Edge]]()
  var sides = initOrderedTable[int, seq[seq[Tile]]]()
  var kelp: seq[Edge]
  for line in text.splitLines:
    let f = line.splitWhitespace
    if f.len == 0: continue
    case f[0]
    of "MAP": (w, h) = (parseInt(f[1]), parseInt(f[2]))
    of "SYMMETRY": sym = f[1]
    of "TILE": gaps[(parseInt(f[1]), parseInt(f[2]))] = (parseInt(f[3]), parseInt(f[4]))
    of "EDGE":
      # Official maps also list open edges, as kind 0.
      let index = parseInt(f[1])
      let (row, x) = (floorDiv(index, w + 1), floorMod(index, w + 1))
      let e: Edge = ((if floorMod(row, 2) == 0: 'h' else: 'v'), x, floorDiv(row, 2))
      if f[2] == "1": kelp.add e
      elif f[2] == "2": pairs.mgetOrPut(parseInt(f[3]), @[]).add e
    of "DRAGON":
      let n = parseInt(f[2])
      var body: seq[Tile]
      for i in 0 ..< n: body.add (parseInt(f[3 + 2 * i]), parseInt(f[4 + 2 * i]))
      sides.mgetOrPut(parseInt(f[1]), @[]).add body
    else: discard
  let cv = newCanvas(w, h, sym, closed = false)
  for e in kelp: cv.kind[e] = 1
  for pid, ends in pairs:
    for e in ends:
      cv.kind[e] = 2
      cv.pid[e] = pid
    if ends.len == 2:
      cv.partner[ends[0]] = ends[1]
      cv.partner[ends[1]] = ends[0]
  let tiles = w * h
  var spawning: seq[(int, int)]
  for g in gaps.values:
    if g[1] > 0: spawning.add g
  var teams: seq[int]
  for team in sides.keys: teams.add team
  let team = sides[min(teams)]
  var heads: seq[Tile]
  for body in team: heads.add body[0]
  let reach = cv.bfs(heads)
  result.name = name
  result.lessons(cv, gaps, team, sides[max(teams)], reach)
  var rng = initPythonRandom(0)
  var live: seq[Tile]
  for t in reach.keys: live.add t
  live.sort
  var ratios: seq[float]
  for s in rng.sample(live, min(16, live.len)):
    let walked = cv.bfs([s], portals = false)
    for t in rng.sample(live, min(40, live.len)):
      let (dx, dy) = (abs(t[0] - s[0]), abs(t[1] - s[1]))
      let g = min(dx, w - dx) + min(dy, h - dy)
      if g >= 4 and t in walked: ratios.add float(walked[t]) / float(g)
  var lengths: seq[int]
  for body in team: lengths.add body.len
  var rates: seq[float]
  var classes: seq[(int, int)]
  for (lo, hi) in spawning:
    rates.add 2 / float(lo + hi)
    if (lo, hi) notin classes: classes.add (lo, hi)
  var portalEnds = 0
  for ends in pairs.values: portalEnds += ends.len
  var closed = true
  for x in 0 ..< w:
    if cv.kindOf(('h', x, 0)) != 1: closed = false
  for y in 0 ..< h:
    if cv.kindOf(('v', 0, y)) != 1: closed = false
  var deadEnds = 0
  for t in reach.keys:
    if cv.exits(t) <= 1: inc deadEnds
  result.tiles = tiles
  result.aspect = float(max(w, h)) / float(min(w, h))
  result.supply = 100 * pythonSum(rates) / float(tiles)
  result.spawning = float(spawning.len) / float(tiles)
  result.gapClasses = classes.len
  result.kelp = float(kelp.len) / float(tiles)
  result.portalPairs = floorDiv(portalEnds, 2)
  result.perSide = team.len
  result.longest = max(lengths)
  result.force = sum(lengths)
  result.closed = closed
  result.deadEnds = float(deadEnds) / float(max(1, reach.len))
  result.detour = if ratios.len > 0: fmean(ratios) else: 1.0

proc outside*(envelope: Envelope, profile: MapProfile): seq[string] =
  ## The measures on which `profile` falls outside.
  for m in EnvelopeMeasures:
    let (lo, hi) = envelope.ranges[m]
    let value = profile.measure(m)
    if not (lo <= value and value <= hi): result.add m

proc mapProfiles*(directory: string): seq[MapProfile] =
  var paths: seq[string]
  for kind, path in walkDir(directory):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".map"): paths.add path
  paths.sort(system.cmp)
  for path in paths: result.add mapProfile(readFile(path), path.extractFilename)

proc officialEnvelope*(officialMaps: string): Envelope =
  let profiles = mapProfiles(officialMaps)
  for m in EnvelopeMeasures:
    var (lo, hi) = (Inf, -Inf)
    for p in profiles:
      lo = min(lo, p.measure(m))
      hi = max(hi, p.measure(m))
    result.ranges[m] = (lo, hi)

proc profileTable*(groups: seq[(string, seq[MapProfile])]): string =
  ## Quartiles of every measure for each named group of profiles, as Markdown.
  var header = "| Measure | "
  var cells: seq[string]
  for (name, _) in groups: cells.add name & " (min / q1 / median / q3 / max)"
  var lines = @[header & cells.join(" | ") & " |", "| --- |" & " ---: |".repeat(groups.len)]
  for m in ProfileMeasures:
    var row: seq[string]
    for (_, profiles) in groups:
      var xs: seq[float]
      for p in profiles: xs.add p.measure(m)
      xs.sort
      let q = if xs.len > 1: quartiles(xs) else: [xs[0], xs[0], xs[0]]
      var values: seq[string]
      for v in [xs[0], q[0], q[1], q[2], xs[^1]]: values.add pythonFixed(v, 2)
      row.add values.join(" / ")
    lines.add "| " & m & " | " & row.join(" | ") & " |"
  lines.join("\n")
