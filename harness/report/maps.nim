## Each map's group on the report's five axes, from its text. Starting force
## is `flagship` when one team's longest starting dragon is at least
## `FlagshipLength` and at least twice its second longest, `even` otherwise.
## Food is the expected pearl spawn attempts per round per 100 tiles: the share
## of tiles that can spawn, divided by their mean gap. Size is the tile count,
## portals whether any edge is a portal, and kelp the kelp edges per tile.

import std/[algorithm, strutils, tables]

const
  FlagshipLength    = 8
  FoodRatePlentiful = 0.5
  SmallTiles        = 600
  LargeTiles        = 2000
  KelpSome          = 0.1
  KelpHeavy         = 0.5
  ReportAxes* = [("force", "starting force"), ("food", "food"), ("size", "size"),
                 ("portals", "portals"), ("kelp", "kelp")]

proc mapAxes*(text: string): Table[string, string] =
  ## Axis to this map's group; empty for a map with no size or no dragons.
  var width, height, kelpEdges, portalEdges = 0
  var gaps: seq[float]
  var lengthsByTeam: Table[int, seq[int]]
  for line in text.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 0: continue
    case fields[0]
    of "MAP": (width, height) = (parseInt(fields[1]), parseInt(fields[2]))
    of "TILE":
      let (minimum, maximum) = (parseInt(fields[3]), parseInt(fields[4]))
      if maximum > 0: gaps.add (minimum + maximum) / 2
    of "DRAGON": lengthsByTeam.mgetOrPut(parseInt(fields[1]), @[]).add parseInt(fields[2])
    of "EDGE":
      # Official maps also list open edges, as kind 0.
      if fields[2] == "1": inc kelpEdges
      elif fields[2] == "2": inc portalEdges
    else: discard
  if width == 0 or height == 0 or lengthsByTeam.len == 0: return
  let tiles = width * height
  var gapTotal = 0.0
  for gap in gaps: gapTotal += gap
  let rate = if gaps.len > 0: 100 * (gaps.len / tiles) / (gapTotal / float(gaps.len)) else: 0.0
  var teams: seq[int]
  for team in lengthsByTeam.keys: teams.add team
  var lengths = lengthsByTeam[min(teams)]
  lengths.sort(Descending)
  let longest = lengths[0]
  let rest = if lengths.len > 1: lengths[1] else: 0
  result["force"] = if longest >= FlagshipLength and longest >= 2 * rest: "flagship" else: "even"
  result["food"] = if rate >= FoodRatePlentiful: "plentiful" else: "scarce"
  result["size"] = if tiles <= SmallTiles: "small" elif tiles >= LargeTiles: "large" else: "medium"
  result["portals"] = if portalEdges > 0: "portals" else: "no portals"
  let density = kelpEdges / tiles
  result["kelp"] = if density >= KelpHeavy: "kelp-heavy" elif density >= KelpSome: "some kelp" else: "open"
