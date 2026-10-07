## Which public replays the store keeps (Kieran, 28 September: replays are
## plentiful and we train nothing on them, so keep what we study). Each run
## judges every game with one leaderboard snapshot. A game is kept when a class
## selects it, and the most protective class that does decides when a full
## store evicts it:
##
## 4. ours: every game the configured team played, to study our mistakes;
## 3. the top pool: each team rated 1950 or more keeps its newest 500 games;
## 2. pins: games a role asked for, kept until it releases them;
## 1. above us: each team rated above our current rating keeps its newest 40.
##
## The store holds at most 100 GB of replay files. Before a fetch would pass the
## cap, games no class selects are evicted first, then the other classes from
## the least protected, oldest (lowest game id) first within each; a fetch never
## evicts a game more protected than itself.

import std/[algorithm, json, sets, strutils, tables]
import sqlite

const
  OurTeam*       = 0
  AboveSample*   = 40
  TopRating*     = 1950.0
  TopSample*     = 500
  StoreCap*      = 100_000_000_000'i64
  ClassNames*    = ["unselected", "above us", "pinned", "top pool", "ours"]

type
  Retention* = object
    ownTeam*:     int = OurTeam        ## configurable team whose games are protected
    ratings*:     Table[int, float]     ## team to Elo in this run's snapshot
    ourRating*:   float
    teamsOf*:     Table[int, seq[int]]  ## game to its two teams
    gamesOf*:     Table[int, seq[int]]  ## team to its downloadable games, ascending
    pins*:        HashSet[int]
    stored*:      Table[int, int64]     ## game to its replay's bytes
    storedBytes*: int64

proc finished*(game: JsonNode): bool =
  ## Whether a game has ended: won, drawn or crashed.
  game["status"].getStr in ["completed", "draw", "crashed"]

proc downloadable*(game: JsonNode): bool =
  ## A game that ended in a result, win or draw, with a replay the site serves.
  game["has_replay"].getBool and game["status"].getStr in ["completed", "draw"]

proc addBattle*(retention: var Retention, teams, games: JsonNode) =
  ## A battle's downloadable games, as known games of its teams.
  var ids: seq[int]
  for team in teams: ids.add team["id"].getInt
  for game in games:
    if not game.downloadable: continue
    let id = game["id"].getInt
    if id in retention.teamsOf: continue
    retention.teamsOf[id] = ids
    for team in ids:
      var known = addr retention.gamesOf.mgetOrPut(team, @[])
      known[].insert(id, known[].upperBound(id))

proc newer(retention: Retention, team, game: int): int =
  ## How many of the team's known games are newer than `game`.
  let known = retention.gamesOf.getOrDefault(team)
  known.len - known.upperBound(game)

proc keepClass*(retention: Retention, game: int): int =
  ## The most protective class that selects the game, 0 when none does.
  let teams = retention.teamsOf.getOrDefault(game)
  if retention.ownTeam in teams: return 4
  for team in teams:
    if retention.ratings.getOrDefault(team) >= TopRating and retention.newer(team, game) < TopSample:
      return 3
  if game in retention.pins: return 2
  for team in teams:
    if retention.ratings.getOrDefault(team) > retention.ourRating and
        retention.newer(team, game) < AboveSample:
      return 1

proc outOfSample*(retention: Retention, team: int): seq[int] =
  ## The team's games just past its above-us and top-pool samples, which a
  ## newer game pushed out.
  let known = retention.gamesOf.getOrDefault(team)
  for size in [AboveSample, TopSample]:
    if known.len > size: result.add known[known.len - 1 - size]

proc evictionOrder*(retention: Retention): seq[(int, int)] =
  ## Every stored game as (class, game), in the order a full store evicts them.
  for game in retention.stored.keys: result.add (retention.keepClass(game), game)
  result.sort

proc loadRetention*(db: Database, snapshot: JsonNode, ownTeam = OurTeam): Retention =
  ## The manifest's known battles, pins and stored replays, judged with the
  ## leaderboard snapshot's ratings.
  for id, team in snapshot:
    result.ratings[team["id"].getInt] = team["elo"].getFloat
  result.ownTeam = ownTeam
  if ownTeam notin result.ratings:
    raise newException(ValueError, "Configured team is absent from the ratings snapshot")
  result.ourRating = result.ratings[ownTeam]
  for row in db.rows("SELECT teams, games FROM battles"):
    result.addBattle(parseJson(row[0]), parseJson(row[1]))
  for row in db.rows("SELECT DISTINCT game FROM pins"): result.pins.incl parseInt(row[0])
  for row in db.rows("SELECT id, bytes FROM replays"):
    let bytes = parseBiggestInt(row[1])
    result.stored[parseInt(row[0])] = bytes
    result.storedBytes += bytes
