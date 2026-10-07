## What every runner (round-robin, batch, ladder) shares: where games play,
## this host or the cloud fleet, and which games an earlier fleet run already
## returned. A run plays on this host unless `--fleet-vcpus` is given: the
## fleet launches AWS workers, which spend the shared budget (AGENTS.md).

import std/[algorithm, json, options, os, sets, strutils, tables]
import arguments, tournament
from report/records import fleetExit

const
  ## A game's default wall limit: a 500-round big_empty game between expert
  ## bots that spend most of their points a turn took 355 seconds on a full
  ## core (expert-0001g-bceval-leaf against expert-0001, 6 October),
  ## and a fleet game runs on one vCPU, so five times that.
  GameTimeout* = 1800.0
  ## A launch reserves its vCPUs for the fleet's whole deadline, so a run gets
  ## one vCPU per this many games by default (the verdict's 5,124 games took
  ## about 34 vCPU-hours), never the whole fleet for a small run.
  GamesPerDefaultVcpu = 25
  MinDefaultVcpus = 8
  ## Fleet policy cap per worker region (Kieran, 28 Sep).
  RegionVcpuLimit* = 320

proc spotVcpuLimit*(): int =
  ## The fleet-wide allowance: the regional cap in every worker region.
  0

proc runnerOptions*(): seq[OptionSpec] =
  ## The options that choose where `playGames` plays, shared by every runner.
  @[OptionSpec(name: "timeout", arity: One, help: "Wall seconds per game (default: 1800)") ]

type Placement* = object
  ## Where and how a run plays, from `runnerOptions`.
  fleetVcpus*:    int      ## -1 for this host, 0 for the default allowance
  timeout*:       float
  rootVolumeGib*: int      ## 0 for the default
  collectOnly*:   bool
  replayCount*:   int      ## an evenly spaced count of games, or
  replayStems*:   seq[string]   ## these games

proc placement*(line: CommandLine): Placement =
  result.fleetVcpus = if line.given("fleet-vcpus"): line.integer("fleet-vcpus", 0) else: -1
  result.timeout = line.number("timeout", GameTimeout)
  if result.timeout <= 0: line.fail "--timeout must be positive"
  result.rootVolumeGib = line.integer("root-volume-gib", 0)
  result.collectOnly = line.given("collect-only")
  let wanted = line.all("replays")
  if wanted.len == 1 and wanted[0].allCharsInSet(Digits): result.replayCount = parseInt(wanted[0])
  else: result.replayStems = wanted

proc fleetAllowance*(place: Placement, games: seq[Game]): int =
  ## The fleet vCPUs a run of `games` uses; 0 is this host.
  if place.fleetVcpus < 0 or games.len == 0: return 0
  for game in games:
    if game.seed.isNone:
      raise newException(ValueError, "The fleet plays seeded games only; pass --seeds")
  if place.fleetVcpus > 0: return place.fleetVcpus
  min(spotVcpuLimit(), max(MinDefaultVcpus, (games.len + GamesPerDefaultVcpu - 1) div GamesPerDefaultVcpu))

proc fleetKey*(a, b, map: string, seed: JsonNode): string = [a, b, map, $seed].join("\t")

proc returnedGames*(work: string): Table[string, int] =
  ## Games an earlier fleet run into `work` returned, by (A, B, map, seed),
  ## with the job IDs that run gave them. Runners collect them, never play them.
  let (remote, previous) = (work / "out", work / "jobs.json")
  if not (dirExists(remote) and fileExists(previous)): return
  for job in parseFile(previous):
    if fleetExit(remote, job["id"].getInt).returned:
      result[fleetKey(job["a"].getStr, job["b"].getStr, job["map"].getStr, job{"seed"})] = job["id"].getInt

proc botsToPlay*(games: seq[Game], work: string): seq[string] =
  ## The bots with a game still to play, not returned to `work` by an earlier
  ## fleet run. Only they need registered builds.
  let returned = returnedGames(work)
  var bots = initHashSet[string]()
  for game in games:
    if fleetKey(game.a, game.b, game.mapPath.extractFilename, game.seedJson) notin returned:
      bots.incl game.a
      bots.incl game.b
  for bot in bots: result.add bot
  result.sort(system.cmp)
