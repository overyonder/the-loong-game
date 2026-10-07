## Play `games` on this host or the fleet and return their records in order.
##
## Games play in the Zig judge. Playing is all this does: each game's log,
## points and result record land in its directory's game store, and analysis
## is its own stage. Each record names both seats' registered builds, so
## `just regenerate` replays any game exactly. Local games keep their
## replays; a fleet run downloads only the replays its placement asks for.

import std/json
import runner, tournament

proc playGames*(games: seq[Game], place: Placement, workers, vcpus: int, work: string,
                onResult: Landed = nil, choose: Chooser = nil, inFlight = 0): seq[JsonNode] =
  ## Locally each game goes through `runGame`, so the game cache applies.
  ## With `vcpus`, or when only collecting, one fleet run plays them all from
  ## `work`. `choose(landed, running)` returns the indices worth starting next,
  ## in order; the run ends when it returns none and nothing is in flight. At
  ## most `inFlight` games play at once. Games never started stay nil.
  if games.len == 0: return
  if vcpus == 0 and not place.collectOnly:
    return playLocally(games, place.timeout, workers, onResult, choose, inFlight)
  raise newException(ValueError, "This standalone release runs local games; use --vcpus 0.")
