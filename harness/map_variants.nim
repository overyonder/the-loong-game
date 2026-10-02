## Pearl-gap fitting and table selection, derived from the private map_variants
## algorithm. Replays are decoded one game at a time by the released reader.
import std/[algorithm, os, sets, strutils, tables]
import ../gamedata/[board, capnp_replay, gzip_inflate, replay_board]

const Rounds = 500

type
  Gap = tuple[low, high: int]
  GapMap* = object
    text*, name*: string
    width*, height*: int
    symmetry: string
    gaps: seq[Gap]
  Spawn = tuple[round, cell: int]
  Evidence = object
    seed: uint64
    served: string
    spawns: HashSet[Spawn]
    blocked: seq[seq[bool]]
    draws: seq[uint64]
  Mersenne = object
    state: array[312, uint64]
    index: int
  Choice = tuple[low, span: int]
  Fit = object
    gaps: seq[Gap]
    unresolved: seq[int]

proc parseGapMap*(text: string): GapMap =
  result.text = text
  result.symmetry = "none"
  for line in text.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 0 or fields[0].startsWith("#"): continue
    if fields[0] in ["MAP", "TILE", "MAP_NAME", "SYMMETRY"]:
      let needed = if fields[0] == "TILE": 5 elif fields[0] == "MAP": 3 else: 2
      if fields.len < needed or (fields[0] == "TILE" and fields.len != 5):
        raise newException(ValueError, "Unsupported map field layout: " & line)
    case fields[0]
    of "MAP":
      result.width = parseInt(fields[1]); result.height = parseInt(fields[2])
      if result.width < 1 or result.height < 1 or result.width > 64 or result.height > 64:
        raise newException(ValueError, "Unsupported map dimensions")
      result.gaps = newSeq[Gap](result.width * result.height)
    of "MAP_NAME": result.name = fields[1 .. ^1].join(" ")
    of "SYMMETRY":
      result.symmetry = fields[1]
      if result.symmetry notin ["x", "y", "xy", "none"]:
        raise newException(ValueError, "Unsupported symmetry")
    of "TILE":
      let x = parseInt(fields[1]); let y = parseInt(fields[2])
      if x < 0 or y < 0 or x >= result.width or y >= result.height:
        raise newException(ValueError, "Tile outside map")
      let low = parseInt(fields[3]); let high = parseInt(fields[4])
      if high < low or low < 0 or (high > 0 and low == 0):
        raise newException(ValueError, "Invalid spawn gap")
      result.gaps[y * result.width + x] = (low, high)
    else: discard
  if result.gaps.len == 0 or result.name.len == 0:
    raise newException(ValueError, "Map needs MAP and MAP_NAME")

proc mirror(map: GapMap, cell: int): int =
  let x = cell mod map.width; let y = cell div map.width
  case map.symmetry
  of "x": (map.height - 1 - y) * map.width + x
  of "y": y * map.width + map.width - 1 - x
  of "xy": (map.height - 1 - y) * map.width + map.width - 1 - x
  of "none": cell
  else: raise newException(ValueError, "Unsupported symmetry")

proc owner(map: GapMap, cell: int): int = min(cell, map.mirror(cell))

proc seedRng(seed: uint64): Mersenne =
  result.state[0] = seed
  for index in 1 ..< 312:
    let previous = result.state[index - 1]
    result.state[index] = 6364136223846793005'u64 * (previous xor (previous shr 62)) + uint64(index)
  result.index = 312

proc next(rng: var Mersenne): uint64 =
  if rng.index >= 312:
    for index in 0 ..< 312:
      let value = (rng.state[index] and 0xFFFFFFFF80000000'u64) or
        (rng.state[(index + 1) mod 312] and 0x7FFFFFFF'u64)
      rng.state[index] = rng.state[(index + 156) mod 312] xor (value shr 1) xor
        (if (value and 1) != 0: 0xB5026F5AA96619E9'u64 else: 0'u64)
    rng.index = 0
  var value = rng.state[rng.index]; inc rng.index
  value = value xor ((value shr 29) and 0x5555555555555555'u64)
  value = value xor ((value shl 17) and 0x71D67FFFEDA60000'u64)
  value = value xor ((value shl 37) and 0xFFF7EEE000000000'u64)
  value xor (value shr 43)

proc draw(game: var Evidence, index: int): uint64 =
  if game.draws.len <= index:
    var rng = seedRng(game.seed)
    let count = max(index + 1, max(1024, game.draws.len * 2))
    game.draws = newSeq[uint64](count)
    for value in game.draws.mitems: value = rng.next()
  game.draws[index]

proc readEvidence(path: string, seed: uint64): Evidence =
  var packed = readFile(path)
  if packed.isGzip: packed = packed.gunzip
  let message = readCapnpPackedMessage(packed.toOpenArrayByte(0, packed.high))
  let replay = message.root
  if message.uint32Field(replay, 0) != 2:
    raise newException(ValueError, "Unsupported replay format version")
  result.seed = seed; result.served = message.textField(replay, 0)
  var state = initialBoard(result.served, false)
  let events = message.listField(replay, 3)
  var ticking = false
  for index in 0 ..< events.count:
    let event = events.listStruct(index)
    let kind = message.eventKind(event)
    if kind > 12: raise newException(ValueError, "Unsupported replay event " & $kind)
    let member = message.structField(event, 0)
    if kind == 0:
      let round = int(message.int32Field(member, 0))
      if round != result.blocked.len or round >= Rounds:
        raise newException(ValueError, "Unsupported replay round order")
      var blocked = newSeq[bool](state.pearls.len)
      for cell in 0 ..< blocked.len: blocked[cell] = state.pearls[cell] or state.occupied[cell].present
      result.blocked.add blocked
      ticking = true
    elif kind == 1: ticking = false
    elif kind == 3 and ticking and message.boolField(member, 0):
      result.spawns.incl (int(state.round), state.cellOf(message, message.structField(member, 0)))
    state.applyReplayEvent(message, event)
  if result.blocked.len == 0: raise newException(ValueError, "Replay has no completed observations")

proc shape(text: string): seq[string] =
  for line in text.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 0 or fields[0].startsWith("#") or fields[0] in ["DRAGON",
        "DRAGON_COUNT"]: continue
    result.add (if fields[0] == "TILE": fields[0 .. 2].join(" ") else: fields.join(" "))

proc checkGeometry(map: GapMap, game: Evidence) =
  if map.text.shape != game.served.shape:
    raise newException(ValueError, "Candidate differs from served geometry, metadata or tile layout")

proc attemptList(map: GapMap, gaps: seq[Gap], game: var Evidence): seq[Spawn] =
  var due: array[Rounds, seq[int]]
  var index = 0
  for cell, gap in gaps:
    if map.owner(cell) != cell or gap.high <= 0: continue
    let round = gap.low + int(game.draw(index) mod uint64(gap.high - gap.low + 1)) - 1
    inc index
    if round < Rounds: due[round].add cell
  for round in 0 ..< Rounds:
    due[round].sort()
    for cell in due[round]:
      result.add (round, cell)
      let gap = gaps[cell]
      let following = round + gap.low + int(game.draw(index) mod uint64(gap.high - gap.low + 1))
      inc index
      if following < Rounds: due[following].add cell

proc contradiction(map: GapMap, gaps: seq[Gap], game: var Evidence): int =
  var tried: HashSet[Spawn]
  for (round, tile) in map.attemptList(gaps, game):
    if round >= game.blocked.len: break
    for cell in [tile, map.mirror(tile)]:
      tried.incl (round, cell)
      if (not game.blocked[round][cell]) != ((round, cell) in game.spawns): return round
  result = Rounds
  for (round, cell) in game.spawns:
    if (round, cell) notin tried: result = min(result, round)

proc withGaps(map: GapMap, gaps: seq[Gap], served = ""): string =
  var dragons: seq[string]
  if served.len > 0:
    for line in served.splitLines:
      if line.startsWith("DRAGON ") or line.startsWith("DRAGON_COUNT "): dragons.add line
  for line in map.text.splitLines:
    let fields = line.splitWhitespace
    if fields.len > 0 and fields[0] == "TILE":
      let cell = parseInt(fields[2]) * map.width + parseInt(fields[1])
      let gap = gaps[cell]
      result.add fields[0 .. 2].join(" ") & " " & $gap.low & " " & $gap.high & "\n"
    elif dragons.len > 0 and fields.len > 0 and fields[0] in ["DRAGON", "DRAGON_COUNT"]:
      if fields[0] == "DRAGON_COUNT": result.add dragons.join("\n") & "\n"
    else: result.add line & "\n"

proc fit(map: GapMap, games: seq[Evidence], largest, hiddenMost: int): Fit =
  var evidence = games
  var first = newSeq[Table[int, int]](evidence.len)
  var seenSet: HashSet[int]
  for gameIndex, game in evidence:
    for (round, cell) in game.spawns:
      let tile = map.owner(cell); seenSet.incl tile
      first[gameIndex][tile] = min(first[gameIndex].getOrDefault(tile, Rounds), round)
  var seen: seq[int]
  for tile in seenSet: seen.add tile
  seen.sort()
  if seen.len == 0: raise newException(ValueError, "No observed spawns to fit")
  proc startsWell(tile, index, low, span: int): bool =
    for gameIndex in 0 ..< evidence.len:
      let attempt = low + int(evidence[gameIndex].draw(index) mod uint64(span)) - 1
      if first[gameIndex].getOrDefault(tile, Rounds) < attempt: return false
      if attempt < evidence[gameIndex].blocked.len:
        for cell in [tile, map.mirror(tile)]:
          if not evidence[gameIndex].blocked[attempt][cell] and (attempt, cell) notin evidence[
              gameIndex].spawns: return false
    true
  proc options(tile, index: int, every = false): seq[Choice] =
    var reference = -1
    var possible: seq[int]
    for gameIndex in 0 ..< evidence.len:
      if tile notin first[gameIndex]: continue
      var rounds = @[first[gameIndex][tile]]
      if every:
        for round in 0 ..< first[gameIndex][tile]:
          if evidence[gameIndex].blocked[round][tile] and evidence[gameIndex].blocked[round][
              map.mirror(tile)]: rounds.add round
      if reference < 0 or rounds.len < possible.len: reference = gameIndex; possible = rounds
    for span in 1 .. largest:
      var lows: CountTable[int]
      if every:
        for round in possible: lows.inc round + 1 - int(evidence[reference].draw(index) mod uint64(span))
      else:
        for gameIndex in 0 ..< evidence.len:
          if tile in first[gameIndex]: lows.inc first[gameIndex][tile] + 1 - int(evidence[
              gameIndex].draw(index) mod uint64(span))
      var ordered: seq[(int, int)]
      for low, count in lows: ordered.add (count, low)
      ordered.sort(proc(a, b: (int, int)): int =
        let countOrder = cmp(b[0], a[0])
        if countOrder != 0: countOrder else: cmp(a[1], b[1]))
      for position, item in ordered:
        if not every and position >= 2: break
        let low = item[1]
        if low >= 1 and startsWell(tile, index, low, span): result.add (low, span)
  var offset = 0
  var offsets: seq[int]
  for index, tile in seen:
    var observed = 0
    for game in first:
      if tile in game: inc observed
    if observed >= 3 and not (options(tile, index + offset).len > 0 and options(tile, index +
        offset + 1).len > 0):
      for jump in 0 ..< max(0, hiddenMost - offset):
        if options(tile, index + offset + jump).len > 0: offset += jump; break
    offsets.add offset
  var hidden: seq[int]
  var previous = -1
  var before = 0
  for index, tile in seen:
    let wanted = offsets[index] - before
    var spare: seq[int]
    for cell in previous + 1 ..< tile:
      if map.owner(cell) == cell and cell notin seenSet: spare.add cell
    spare.sort(proc(a, b: int): int =
      let enabled = cmp(int(map.gaps[a].high == 0), int(map.gaps[b].high == 0))
      if enabled != 0: enabled else: cmp(a, b))
    if spare.len < wanted: return
    for cell in spare[0 ..< wanted]: hidden.add cell
    previous = tile; before = offsets[index]
  var order = seen & hidden; order.sort()
  var position: Table[int, int]
  for index, tile in order: position[tile] = index
  var candidates: Table[int, seq[Choice]]
  var choices = newSeq[Choice](map.gaps.len)
  for tile in seen:
    candidates[tile] = options(tile, position[tile])
    if candidates[tile].len == 0: return
    let published = (map.gaps[tile].low, map.gaps[tile].high - map.gaps[tile].low + 1)
    choices[tile] = if published in candidates[tile]: published else: candidates[tile][0]
  proc gapsFor(choices: seq[Choice]): seq[Gap] =
    result = newSeq[Gap](map.gaps.len)
    for tile in hidden: result[tile] = (Rounds + 1, Rounds + 1); result[map.mirror(tile)] = result[tile]
    for tile in seen:
      result[tile] = (choices[tile].low, choices[tile].low + choices[tile].span - 1)
      result[map.mirror(tile)] = result[tile]
  proc reached(choices: seq[Choice]): seq[int] =
    let gaps = gapsFor(choices)
    for index in 0 ..< evidence.len: result.add map.contradiction(gaps, evidence[index])
  proc score(rounds: seq[int]): int =
    for round in rounds: result += round
  var rounds = reached(choices)
  var widened: HashSet[int]
  while min(rounds) < Rounds:
    let worst = rounds.find(min(rounds)); let failingRound = rounds[worst]
    var suspects: seq[int]
    let current = gapsFor(choices)
    let attempts = map.attemptList(current, evidence[worst])
    for index in countdown(attempts.high, 0):
      let (round, tile) = attempts[index]
      if round <= failingRound and tile in candidates and tile notin suspects: suspects.add tile
    for tile in seen:
      if tile notin suspects: suspects.add tile
    var bestChoices: seq[Choice]
    var bestRounds: seq[int]
    proc improve(tiles: seq[int], whole: bool) =
      for tile in tiles:
        for candidate in candidates[tile]:
          if candidate == choices[tile]: continue
          var trial = choices; trial[tile] = candidate
          let trials = reached(trial)
          if trials[worst] <= failingRound or (whole and trials[worst] < Rounds): continue
          if score(trials) > (if bestRounds.len > 0: score(bestRounds) else: score(rounds)):
            bestChoices = trial; bestRounds = trials
        if bestRounds.len > 0 and min(bestRounds) == Rounds: break
    improve(suspects, true)
    for tile in suspects:
      if bestRounds.len > 0: break
      if tile in widened: continue
      widened.incl tile
      for candidate in options(tile, position[tile], true):
        if candidate notin candidates[tile]: candidates[tile].add candidate
      improve(@[tile], true)
    if bestRounds.len == 0: improve(suspects, false)
    if bestRounds.len == 0: return
    choices = bestChoices; rounds = bestRounds
  result.gaps = gapsFor(choices)
  # A hidden tile's actual long gap is unobserved. Never publish the temporary
  # 501-round placeholder as reconstructible state.
  result.unresolved = hidden
  for tile, gap in map.gaps:
    if map.owner(tile) == tile and gap.high > 0 and tile notin seenSet and tile notin
        result.unresolved:
      result.unresolved.add tile
  # A different gap that explains every supplied game is unresolved too.
  for tile in seen:
    for candidate in options(tile, position[tile], true):
      if candidate == choices[tile]: continue
      var trial = choices; trial[tile] = candidate
      if min(reached(trial)) == Rounds: result.unresolved.add tile; break

proc parseSeed*(value: string): uint64 =
  if value.toLowerAscii.startsWith("0x"): uint64(parseHexInt(value))
  else: parseBiggestUInt(value)

proc compatibleMap*(replayPath: string, seed: uint64, directories: seq[string]): string =
  var game = readEvidence(replayPath, seed)
  var matches: seq[string]
  var tables: HashSet[string]
  for directory in directories:
    if not dirExists(directory): continue
    for path in walkFiles(directory / "*.map"):
      let map = parseGapMap(readFile(path))
      if map.name != parseGapMap(game.served).name or map.text.shape != game.served.shape: continue
      if map.contradiction(map.gaps, game) == Rounds:
        let key = $map.gaps
        if key notin tables: matches.add path; tables.incl key
  if matches.len != 1:
    raise newException(ValueError, "Reconstruction requires exactly one compatible gap table; found " & $matches.len)
  matches[0]

proc main() =
  let arguments = commandLineParams()
  if arguments.len == 0 or arguments[0] in ["--help", "-h"]:
    echo "loong-map-variants fit --map FILE --games SEED_REPLAY.tsv --output FILE [--largest-span N] [--hidden-most N]"
    echo "loong-map-variants lookup --replay FILE --seed UINT64 --maps DIR [--variants DIR] [--output FILE]"
    echo "loong-map-variants check --map FILE --replay FILE --seed UINT64"
    return
  var values: Table[string, string]
  var at = 1
  while at < arguments.len:
    if at + 1 >= arguments.len or not arguments[at].startsWith("--"):
      raise newException(ValueError, "Expected --option VALUE")
    if arguments[at] notin ["--map", "--games", "--output", "--largest-span", "--hidden-most",
        "--replay", "--seed", "--maps", "--variants"]:
      raise newException(ValueError, "Unknown option " & arguments[at])
    values[arguments[at]] = arguments[at + 1]; at += 2
  proc required(name: string): string =
    if name notin values: raise newException(ValueError, "Missing " & name)
    values[name]
  case arguments[0]
  of "fit":
    let map = parseGapMap(readFile(required("--map")))
    var games: seq[Evidence]
    for line in lines(required("--games")):
      if line.strip.len == 0 or line.startsWith("seed\t"): continue
      let fields = line.split('\t')
      if fields.len != 2: raise newException(ValueError, "Games TSV is seed<TAB>replay path")
      var game = readEvidence(fields[1], parseSeed(fields[0])); map.checkGeometry(game)
      games.add game
    if games.len < 3: raise newException(ValueError, "Fit requires at least three seeded replays")
    let largest = parseInt(values.getOrDefault("--largest-span", "2000"))
    let hiddenMost = parseInt(values.getOrDefault("--hidden-most", "150"))
    if largest < 1 or hiddenMost < 0:
      raise newException(ValueError, "Span must be positive and hidden count nonnegative")
    let found = fit(map, games, largest, hiddenMost)
    if found.gaps.len == 0: raise newException(ValueError, "No table explains every recorded spawn and blocked attempt")
    if found.unresolved.len > 0:
      raise newException(ValueError, "Unresolved spawn gaps at owner cells " & $found.unresolved & "; no map written")
    let output = required("--output")
    writeFile(output & ".partial", map.withGaps(found.gaps, games[0].served))
    moveFile(output & ".partial", output)
    echo output
  of "lookup":
    let replay = required("--replay")
    let path = compatibleMap(replay, parseSeed(required("--seed")),
      @[required("--maps"), values.getOrDefault("--variants", getEnv("MAP_VARIANTS"))])
    if "--output" in values:
      let map = parseGapMap(readFile(path))
      var game = readEvidence(replay, parseSeed(required("--seed")))
      writeFile(values["--output"], map.withGaps(map.gaps, game.served))
    echo path
  of "check":
    let map = parseGapMap(readFile(required("--map")))
    var game = readEvidence(required("--replay"), parseSeed(required("--seed")))
    map.checkGeometry(game)
    let round = map.contradiction(map.gaps, game)
    echo "first_contradiction_round\t", (if round == Rounds: "none" else: $round)
    if round < Rounds: quit(1)
  else: raise newException(ValueError, "Unknown map-variants mode")

when isMainModule:
  try: main()
  except CatchableError as error: quit(error.msg, 2)

proc restoredMap*(replayPath: string, seed: uint64, directories: seq[string]): string =
  let path = compatibleMap(replayPath, seed, directories)
  let map = parseGapMap(readFile(path))
  var game = readEvidence(replayPath, seed)
  map.withGaps(map.gaps, game.served)
