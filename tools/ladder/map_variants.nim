## Find the pearl gap tables of served map variants, from site replays
## (`just map-variants`).
##
## The ladder serves some maps in variants whose pearl gaps differ from the
## published file, and site replays zero every tile's gaps (`TILE x y 0 0`), so
## a game on a variant can't be rebuilt from the published map. The engine
## draws each countdown as `min + mt19937_64(seed)() % (max - min + 1)`: once
## per spawning tile at the start, in scan order over the tiles that own a
## shared countdown (a tile and its mirror share one, owned by the first in
## scan order), then once at every spawn attempt, in the same order within a
## round. An attempt draws whether or not the tile is free, so a gap table and
## a game's seed fix every attempt round, and a table is right for a game
## exactly when every pearl the replay shows spawning falls on one of those
## attempts.
##
## The schedule and the search run in `build/bin/loong-map-fit`
## (`tools/ladder/map_fit/`, built by its `build.sh`), with the engine's own
## generator. `fit` recovers a table from games: their first spawns give each
## tile's gaps up to the remainder, and a search over the remaining candidates
## keeps the table that explains the most spawns. `picks` returns the published
## map and the variants under `tools/evaluation/maps/variants/` that explain a
## game. This module finds the games, reads their replays, fits the maps and
## writes the variants.

import std/[algorithm, json, os, osproc, sets, streams, strutils, tables]
import ../evaluation/[paths, python_json]
import ../gamedata/[board, capnp_replay, compare, regeneration, replay_board]
import collector/sqlite
import site

let
  Maps     = Root / "tools/evaluation/maps"
  Variants = Maps / "variants"
  Manifest = Root / "results/online/manifest.sqlite"
  Seeds*   = Root / "assets/map-variants/seeds.json"
  Fit      = Root / "build/bin/loong-map-fit"

type
  Tile = (int, int)
  Gaps = Table[Tile, (int, int)]
  GameMap* = object
    ## A map file's size, symmetry and gap table, by tile.
    text:          string
    name*:         string
    symmetry:      string
    width, height: int
    gaps:          Gaps
  Spawn = tuple[round: int, tile: Tile]
  GameRecord = object
    id:      int
    seed:    uint64
    spawns:  seq[Spawn]
    served:  string
    blocked: Table[int, HashSet[Tile]]
    dragons: seq[string]

proc parseMap*(text: string): GameMap =
  result = GameMap(text: text, symmetry: "xy")
  for line in text.splitLines:
    let part = line.splitWhitespace
    if part.len == 0: continue
    case part[0]
    of "MAP": (result.width, result.height) = (parseInt(part[1]), parseInt(part[2]))
    of "SYMMETRY": result.symmetry = part[1]
    of "MAP_NAME": result.name = line[9 .. ^1].strip
    of "TILE":
      if part.len >= 5:
        result.gaps[(parseInt(part[1]), parseInt(part[2]))] = (parseInt(part[3]), parseInt(part[4]))
    else: discard

proc withGaps(board: GameMap, gaps: Gaps, dragons: seq[string], replaceDragons: bool): string =
  ## This map's text with other gaps, and other starting dragons if given.
  var lines: seq[string]
  for line in board.text.splitLines:
    let part = line.splitWhitespace
    if part.len >= 5 and part[0] == "TILE":
      let (low, high) = gaps.getOrDefault((parseInt(part[1]), parseInt(part[2])), (0, 0))
      lines.add (part[0 ..< 3] & @[$low, $high] & part[5 .. ^1]).join(" ")
    elif replaceDragons and part.len > 0 and part[0] in ["DRAGON", "DRAGON_COUNT"]:
      if part[0] == "DRAGON_COUNT": lines.add dragons
    else: lines.add line
  # Python's splitlines drops the text's last newline before the join adds one.
  if lines.len > 0 and lines[^1].len == 0 and board.text.endsWith("\n"): lines.setLen(lines.len - 1)
  lines.join("\n") & "\n"

proc runFit(command: string, payload: string): string =
  ## `loong-map-fit COMMAND` on a payload, its output.
  if not fileExists(Fit): raise newException(IOError, Fit & " is missing: run tools/ladder/map_fit/build.sh")
  let process = startProcess(Fit, args = [command], options = {})
  process.inputStream.write payload
  process.inputStream.close()
  result = process.outputStream.readAll
  let errors = process.errorStream.readAll
  if process.waitForExit != 0:
    process.close
    raise newException(IOError, "loong-map-fit " & command & " failed: " & errors)
  process.close

proc putU32(output: var string, value: uint32) =
  for shift in [0, 8, 16, 24]: output.add char((value shr shift) and 0xff)
proc putI32(output: var string, value: int) = output.putU32(cast[uint32](int32(value)))
proc putU64(output: var string, value: uint64) =
  for shift in countup(0, 56, 8): output.add char((value shr shift) and 0xff)

proc boardBytes(board: GameMap): string =
  result.putU32(uint32(board.width))
  result.putU32(uint32(board.height))
  result.add char(if board.symmetry == "x": 1 elif board.symmetry == "y": 2 else: 0)

proc gapsBytes(board: GameMap, gaps: Gaps): string =
  for part in 0 .. 1:
    for y in 0 ..< board.height:
      for x in 0 ..< board.width:
        let (low, high) = gaps.getOrDefault((x, y), (0, 0))
        result.putI32(if part == 0: low else: high)

proc spawnsBytes(board: GameMap, seen: seq[Spawn]): string =
  result.putU32(uint32(seen.len))
  for spawn in seen:
    result.putU32(uint32(spawn.round))
    result.putU32(uint32(spawn.tile[1] * board.width + spawn.tile[0]))

proc explained*(board: GameMap, tables: seq[Gaps], seed: uint64, seen: seq[Spawn]): seq[float] =
  ## The share of a game's spawns that fall on each table's attempts.
  var payload = board.boardBytes
  payload.putU32(uint32(tables.len))
  for gaps in tables: payload.add board.gapsBytes(gaps)
  payload.putU64(seed)
  payload.add board.spawnsBytes(seen)
  for line in runFit("explain", payload).splitLines:
    if line.len == 0: continue
    let fields = line.splitWhitespace
    result.add parseInt(fields[0]) / max(1, parseInt(fields[1]))

proc spawnsOf*(replay: string, scripts: seq[string] = @[]): seq[Spawn] =
  ## A replay's pearl spawns as (round, tile); with `scripts`, each side's
  ## recorded replies written as the judge's scripts.
  for spawn in regeneration(replay, scripts): result.add (int(spawn.round), (int(spawn.x), int(spawn.y)))

proc servedMap*(replay: string): string =
  let message = loadReplay(replay)
  message.textField(message.root, 0)

proc record(path: string, id: int, seed: uint64): GameRecord =
  ## A stored game's spawns, served map, blocked tiles and starting dragons.
  result = GameRecord(id: id, seed: seed, spawns: spawnsOf(path))
  let message = loadReplay(path)
  result.served = message.textField(message.root, 0)
  # The tiles holding a pearl or a dragon at each round's spawn attempts, from
  # the board the replay rebuilds.
  var state = initialBoard(result.served, lenient = true)
  let events = message.eventList(path)
  for index in 0 ..< events.count:
    let event = events.listStruct(index)
    state.applyReplayEvent(message, event)
    if message.eventKind(event) == 0:
      var blocked = initHashSet[Tile]()
      for cell, pearl in state.pearls:
        if pearl: blocked.incl (cell mod state.width, cell div state.width)
      for cell, occupant in state.occupied:
        if occupant.present: blocked.incl (cell mod state.width, cell div state.width)
      result.blocked[int(state.round)] = blocked
  for line in result.served.splitLines:
    if line.startsWith("DRAGON ") or line.startsWith("DRAGON_COUNT "): result.dragons.add line

proc fit(board: GameMap, games: seq[GameRecord], largest = 0, hiddenMost = 150): Gaps =
  ## The gap table that explains these games, from their seeds, spawns and
  ## blocked tiles, or empty when the search finds none.
  var parts = board.boardBytes
  parts.putU32(uint32(largest))
  parts.putU32(uint32(hiddenMost))
  parts.add board.gapsBytes(board.gaps)
  for y in 0 ..< board.height:
    for x in 0 ..< board.width: parts.add char(if (x, y) in board.gaps: 1 else: 0)
  parts.putU32(uint32(games.len))
  for game in games:
    var rounds = 0
    while rounds in game.blocked: inc rounds   # attempts stop at the first round the game didn't reach
    parts.putU64(game.seed)
    parts.putU32(uint32(rounds))
    for round in 0 ..< rounds:
      var bits = newString((board.width * board.height + 7) div 8)
      for (x, y) in game.blocked[round]:
        let cell = y * board.width + x
        bits[cell div 8] = char(uint8(bits[cell div 8]) or uint8(1 shl (cell mod 8)))
      parts.add bits
    parts.add board.spawnsBytes(game.spawns)
  for line in runFit("fit", parts).splitLines:
    if line.len == 0: continue
    let field = line.splitWhitespace
    result[(parseInt(field[0]), parseInt(field[1]))] = (parseInt(field[2]), parseInt(field[3]))

proc official(name: string): string =
  ## The published map with this MAP_NAME, at the top of the maps folder.
  var paths: seq[string]
  for path in walkFiles(Maps / "*.map"): paths.add path
  paths.sort
  for path in paths:
    if parseMap(readFile(path)).name == name: return path
  raise newException(ValueError, "no published map named " & name & " in " & Maps)

proc candidates(name: string): seq[string] =
  ## The published map and its known variants.
  result = @[official(name)]
  var variants: seq[string]
  for path in walkFiles(Variants / "*.map"):
    if parseMap(readFile(path)).name == name: variants.add path
  variants.sort
  result.add variants

proc picks*(name: string, seed: uint64, seen: seq[Spawn]): seq[string] =
  ## The published map and variants whose gaps explain every spawn of a game.
  ## An attempt on an occupied tile spawns nothing, so more than one table may
  ## explain a game; replaying it tells them apart.
  let paths = candidates(name)
  var tables: seq[Gaps]
  for path in paths: tables.add parseMap(readFile(path)).gaps
  let shares = explained(parseMap(readFile(paths[0])), tables, seed, seen)
  for index, path in paths:
    if shares[index] == 1.0: result.add path

proc storedGames(name: string, count: int, since: string): seq[int] =
  ## Up to `count` stored games on this map since `since`, spread over time.
  let database = openDatabase(Manifest, 60_000)
  defer: database.close()
  var found: seq[(string, int)]
  for row in database.rows("select games, match from battles"):
    let match = if row[1].len > 0: parseJson(row[1]) else: newJObject()
    let at = if match.kind == JObject: match{"requested_at"}.getStr else: ""
    if at < since: continue
    for game in (if row[0].len > 0: parseJson(row[0]) else: newJArray()):
      if game{"map"}.getStr == name and truthy(game{"has_replay"}): found.add (at, game["id"].getInt)
  found.sort
  let step = max(1, found.len div max(1, 3 * count))
  var at = 0
  while at < found.len:
    if fileExists(publicReplays() / $found[at][1] & ".replay"): result.add found[at][1]
    if result.len == count: break
    at += step

proc seated(board: GameMap, dragons: seq[string]): seq[string] =
  ## A served game's starting dragons with the published file's team numbers.
  ## Since 28 September the site shuffles which team plays A, and a served map
  ## swaps the teams' DRAGON lines to match.
  var published: Table[string, string]
  for line in board.text.splitLines:
    if line.startsWith("DRAGON "):
      let fields = line.splitWhitespace
      published[fields[2 .. ^1].join(" ")] = fields[1]
  var swapped = false
  for line in dragons:
    if line.startsWith("DRAGON "):
      let fields = line.splitWhitespace
      let team = published.getOrDefault(fields[2 .. ^1].join(" "), "")
      if team.len > 0 and team != fields[1]: swapped = true
  if not swapped: return dragons
  for line in dragons:
    if line.startsWith("DRAGON "):
      var fields = line.splitWhitespace
      fields[1] = if fields[1] == "0": "1" else: "0"
      result.add fields.join(" ")
    else: result.add line

proc storedSeed*(game: int): string =
  ## A game's seed in hex as the manifest holds it: the collector's `seeds`
  ## table (every stored game's), else its battle record (the seed of the game
  ## whose ID is the battle's); "" when neither has it.
  let database = openDatabase(Manifest, 60_000)
  defer: database.close()
  if database.rows("select 1 from sqlite_master where name = 'seeds'").len > 0:
    let rows = database.rows("select seed from seeds where game = ?", game)
    if rows.len > 0 and rows[0][0].len > 0: return rows[0][0]
  let rows = database.rows("select json_extract(match, '$.seed') from battles where id = ?", game)
  if rows.len > 0: rows[0][0] else: ""

proc seedOf*(game: int, cache: JsonNode): uint64 =
  ## A game's seed: the manifest's (`storedSeed`), else the site's record of
  ## the game, kept in `cache`.
  if not cache.hasKey($game):
    let stored = storedSeed(game)
    if stored.len > 0: cache[$game] = %stored
  if not cache.hasKey($game):
    cache[$game] = %apiRequest("/battles/" & $game)["match"]["seed"].getStr
    sleep(500)   # well inside the API's 120 requests a minute
  fromHex[uint64](cache[$game].getStr)

proc survey(name: string, games: seq[GameRecord]): JsonNode =
  ## Which known table explains each of these games on a map, fitting a new
  ## variant from the games none explains.
  result = %*{"map": name, "games": games.len, "tables": {}}
  let paths = candidates(name)
  var tables: seq[Gaps]
  for path in paths: tables.add parseMap(readFile(path)).gaps
  let first = parseMap(readFile(paths[0]))
  var owner: Table[int, string]
  for game in games:
    let shares = explained(first, tables, game.seed, game.spawns)
    owner[game.id] = ""
    for index, path in paths:
      if shares[index] == 1.0:
        owner[game.id] = path.extractFilename
        break
  for path in paths:
    var ids = newJArray()
    for game in games:
      if owner[game.id] == path.extractFilename: ids.add %game.id
    result["tables"][path.extractFilename] = ids
  var left: seq[GameRecord]
  for game in games:
    if owner[game.id].len == 0: left.add game
  let published = parseMap(readFile(official(name)))
  while left.len >= 3:
    let gaps = fit(published, left)
    var mine: seq[GameRecord]
    for game in left:
      if gaps.len > 0 and explained(published, @[gaps], game.seed, game.spawns)[0] == 1.0: mine.add game
    if mine.len < 3: break
    let stem = official(name).splitFile.name
    var number = 1
    for _ in walkFiles(Variants / stem & "-*.map"): inc number
    let path = Variants / stem & "-" & $number & ".map"
    createDir(Variants)
    writeFile(path, published.withGaps(gaps, seated(published, mine[0].dragons), true))
    var ids = newJArray()
    for game in mine: ids.add %game.id
    result["tables"][path.extractFilename] = ids
    var still: seq[GameRecord]
    for game in left:
      var taken = false
      for chosen in mine: taken = taken or chosen.id == game.id
      if not taken: still.add game
    left = still
  var unexplained = newJArray()
  for game in left: unexplained.add %game.id
  result["unexplained"] = unexplained

proc mapVariants*(names: seq[string], count = 40, since = "2026-09-26T00:00") =
  ## Survey each served map from up to `count` stored games since `since`,
  ## printing one report a map.
  var cache = if fileExists(Seeds): parseFile(Seeds) else: newJObject()
  var chosen: seq[(string, seq[int])]
  for name in names: chosen.add (name, storedGames(name, count, since))
  var seeds: Table[int, uint64]
  for (_, games) in chosen:
    for game in games: seeds[game] = seedOf(game, cache)
  createDir(Seeds.parentDir)
  writeFile(Seeds, pythonDumps(cache))
  for (name, games) in chosen:
    var records: seq[GameRecord]
    for game in games:
      var found = record(publicReplays() / $game & ".replay", game, seeds[game])
      records.add found
    echo pythonDumps(survey(name, records))

when isMainModule:
  import ../evaluation/arguments
  let line = parseCommandLine(commandLineParams(), "usage: just map-variants MAP... [--games N] [--since UTC]", @[
    OptionSpec(name: "games", arity: One, help: "Stored games per map (default 40)"),
    OptionSpec(name: "since", arity: One, help: "Earliest request time UTC (default 2026-09-26T00:00)")])
  if line.positional.len == 0: line.fail "give at least one served map name"
  if line.integer("games", 40) < 1: line.fail "--games must be positive"
  try: mapVariants(line.positional, line.integer("games", 40), line.last("since", "2026-09-26T00:00"))
  except CatchableError as error:
    stderr.writeLine error.msg
    quit 1
