## Read retained complete-match pilots and workloads, one game at a time. Timing
## files are GNU time's elapsed/user/system seconds and maximum RSS in KiB.

import std/[algorithm, json, math, memfiles, os, strutils, tables]
from ../../gamedata/columns import nil

type MatchTiming = object
  elapsed, coreSeconds: float64
  maximumRssKiB: uint64

proc readMatchTiming(path: string): MatchTiming =
  let fields = readFile(path).splitWhitespace
  if fields.len != 4: raise newException(ValueError, "invalid timing: " & path)
  result = MatchTiming(elapsed: parseFloat(fields[0]),
    coreSeconds: parseFloat(fields[1]) + parseFloat(fields[2]),
    maximumRssKiB: parseBiggestUInt(fields[3]))
  if result.elapsed <= 0 or result.coreSeconds < 0 or
      classify(result.elapsed) in {fcNan, fcInf, fcNegInf} or
      classify(result.coreSeconds) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "invalid timing: " & path)

proc fileBytesEqual(firstPath, secondPath: string): bool =
  var first = memfiles.open(firstPath)
  defer: first.close()
  var second = memfiles.open(secondPath)
  defer: second.close()
  first.size > 0 and first.size == second.size and
    equalMem(first.mem, second.mem, first.size)

proc timingSummary(elapsed: seq[float64], coreSeconds: float64,
    maximumRssKiB, turns: uint64): JsonNode =
  var ordered = elapsed
  ordered.sort()
  var total = 0.0
  for seconds in elapsed: total += seconds
  %*{"serial_match_seconds": total, "cpu_core_seconds": coreSeconds,
    "games_per_serial_second": float(elapsed.len) / total,
    "turns_per_serial_second": float(turns) / total,
    "p50_seconds": ordered[int(ceil(float(ordered.len) * 0.50)) - 1],
    "p95_seconds": ordered[int(ceil(float(ordered.len) * 0.95)) - 1],
    "maximum_rss_kib": maximumRssKiB}

proc checkBatchPoints(game: columns.ColumnsFileReader, figures: seq[
    string]): bool =
  ## Compare actual jobs aggregates with the independently retained reference
  ## points. This cannot establish equality of unexported per-turn counters.
  var points: array[2, seq[uint64]]
  let turns = columns.rowCount(game, "turn.round")
  let teams = columns.columnValues[uint8](game, "turn.team").values
  let known = columns.columnValues[uint8](game, "turn.points?").values
  let spent = columns.columnValues[uint64](game, "turn.points").values
  for row in 0 ..< turns:
    if known[row] == 0 or teams[row] > 1:
      raise newException(ValueError, "reference lacks known team/points")
    if spent[row] > 0: points[int(teams[row])].add spent[row]
  result = true
  for team in 0 .. 1:
    points[team].sort()
    var total: uint64
    for spent in points[team]: total += spent
    let count = points[team].len
    let expected = if count == 0: "0/0/0" else:
      $points[team][count div 2] & "/" & $(total div uint64(count)) & "/" &
          $points[team][^1]
    if parseInt(figures[12 + team * 2]) != count or figures[13 + team * 2] != expected:
      result = false

proc readBatchFigures(path: string): Table[int, seq[string]] =
  for line in lines(path):
    let fields = line.split('\t')
    if fields.len != 17: raise newException(ValueError,
        "invalid jobs result: " & line)
    let index = parseInt(fields[0])
    if index in result: raise newException(ValueError,
        "duplicate jobs result: " & fields[0])
    result[index] = fields

proc writeCudaPilotReport(store, output, reference: string): int =
  if reference.len == 0: raise newException(ValueError, "CUDA pilot needs --reference STORE")
  let figures = readBatchFigures(store / "figures.tsv")
  var measured = columns.initColumnsFileWriter("native-pilot")
  var gameCount, equalPoints, botFailures: int
  var totalTurns, totalEvents, totalReplayBytes: uint64
  for line in lines(store / "pilot.tsv"):
    let fields = line.split('\t')
    if fields.len != 4 or parseInt(fields[0]) != gameCount or
        parseInt(fields[3]) != gameCount mod 2 or gameCount notin figures:
      raise newException(ValueError, "invalid/missing pilot job: " & line)
    let directory = store / "games" / fields[0]
    let expected = reference / "games" / fields[0]
    if readFile(directory / "replay-bytes.status").strip != "identical" or
        not fileBytesEqual(directory / "cuda.replay", expected /
            "reference.replay"):
      raise newException(ValueError, "replay mismatch: " & directory)
    var game = columns.openColumnsFile(directory / "cuda.cols")
    let turns = uint64(columns.rowCount(game, "turn.round"))
    let events = uint64(columns.rowCount(game, "event.kind"))
    columns.closeColumnsFile(game)
    if turns == 0 or events == 0: raise newException(ValueError,
        "empty decoded game: " & directory)
    var original = columns.openColumnsFile(expected / "reference.cols")
    let pointsEqual = checkBatchPoints(original, figures[gameCount])
    columns.closeColumnsFile(original)
    if pointsEqual: inc equalPoints
    botFailures += parseInt(figures[gameCount][10]) + parseInt(figures[
        gameCount][11])
    let replayBytes = uint64(getFileSize(directory / "cuda.replay"))
    totalTurns += turns
    totalEvents += events
    totalReplayBytes += replayBytes
    columns.appendValue(measured, "game.index", uint32(gameCount))
    columns.appendString(measured, "game.map", fields[1])
    columns.appendValue(measured, "game.seed", uint64(parseBiggestUInt(fields[2])))
    columns.appendValue(measured, "game.seat_order", uint8(parseInt(fields[3])))
    columns.appendValue(measured, "game.turns", turns)
    columns.appendValue(measured, "game.events", events)
    columns.appendValue(measured, "game.replay_bytes", replayBytes)
    columns.appendValue(measured, "game.aggregate_points_equal", uint8(pointsEqual))
    inc gameCount
  if gameCount != 44 or figures.len != gameCount:
    raise newException(ValueError, "SDK22 pilot needs exactly 44 completed jobs")
  let timing = readMatchTiming(store / "process.time.tsv")
  let report = %*{"status": "complete", "backend": "cuda", "games": gameCount,
    "byte_identical_replay_pairs": gameCount, "dragon_turns": totalTurns,
    "events": totalEvents, "replay_bytes": totalReplayBytes,
    "aggregate_points_equal_games": equalPoints, "bot_failures": botFailures,
    "process_seconds": timing.elapsed, "cpu_core_seconds": timing.coreSeconds,
    "maximum_rss_kib": timing.maximumRssKiB, "reference_store": reference,
    "limits": "semantic pilot on different hardware; four host threads/four-game waves; no throughput or per-turn meter-fidelity claim",
    "timing_scope": "single canonical jobs invocation through replay close; validation and final sync outside process timer",
    "measurement_columns": "native-pilot.cols"}
  createDir(output)
  columns.writeColumnsFile(measured, store / "native-pilot.cols")
  writeFile(output / "timings.json", report.pretty & "\n")
  echo report.pretty

proc writeNativePilotReport*(store, output: string, backend = "kvm",
    reference = ""): int =
  ## Reject incomplete captures; write human summary JSON and dense per-game
  ## measurements beside the raw games. This reads results and never plays.
  if readFile(store / "status").strip != "complete":
    raise newException(ValueError, "pilot did not complete: " & store)
  if backend == "cuda": return writeCudaPilotReport(store, output, reference)
  if backend notin ["kvm", "cpu"]:
    raise newException(ValueError, "unsupported pilot backend: " & backend)
  let cpu = backend == "cpu"
  if cpu and not fileExists(store / "native-cpu.sha256"):
    raise newException(ValueError, "native CPU library identity missing: " & store)
  let measurementFile = if cpu: "native-cpu-pilot.cols" else: "native-pilot.cols"
  let summaryFile = if cpu: "cpu-timings.json" else: "timings.json"
  var measured = columns.initColumnsFileWriter("native-pilot")
  var elapsed: array[2, seq[float64]]
  var coreSeconds: array[2, float64]
  var maximumRssKiB: array[2, uint64]
  var totalTurns, totalEvents, totalReplayBytes: uint64
  var gameCount = 0
  for line in lines(store / "pilot.tsv"):
    let fields = line.split('\t')
    if fields.len != 4 or parseInt(fields[0]) != gameCount or
        parseInt(fields[3]) != gameCount mod 2:
      raise newException(ValueError, "invalid pilot schedule row: " & line)
    let directory = store / "games" / fields[0]
    let replayStatus = if cpu: "cpu-replay-bytes.status" else: "replay-bytes.status"
    if readFile(directory / replayStatus).strip != "identical" or
        not fileBytesEqual(directory / (backend & ".replay"), directory /
            "reference.replay"):
      raise newException(ValueError, "replay mismatch: " & directory)
    if cpu:
      if readFile(directory / "cpu-points-bytes.status").strip != "identical" or
          not fileBytesEqual(directory / "cpu.points.cols", directory /
              "reference.points.cols"):
        raise newException(ValueError, "native CPU per-turn points mismatch: " & directory)
      columns.appendValue(measured, "game.per_turn_points_equal", 1'u8)
    var game = columns.openColumnsFile(directory / "reference.cols")
    let turns = uint64(columns.rowCount(game, "turn.round"))
    let events = uint64(columns.rowCount(game, "event.kind"))
    columns.closeColumnsFile(game)
    if turns == 0 or events == 0:
      raise newException(ValueError, "empty decoded game: " & directory)
    let replayBytes = uint64(getFileSize(directory / "reference.replay"))
    totalTurns += turns
    totalEvents += events
    totalReplayBytes += replayBytes
    columns.appendValue(measured, "game.index", uint32(gameCount))
    columns.appendString(measured, "game.map", fields[1])
    columns.appendValue(measured, "game.seed", uint64(parseBiggestUInt(fields[2])))
    columns.appendValue(measured, "game.seat_order", uint8(parseInt(fields[3])))
    columns.appendValue(measured, "game.turns", turns)
    columns.appendValue(measured, "game.events", events)
    columns.appendValue(measured, "game.replay_bytes", replayBytes)
    for backendIndex, name in [backend, "reference"]:
      let timing = readMatchTiming(directory / (name & ".time.tsv"))
      elapsed[backendIndex].add timing.elapsed
      coreSeconds[backendIndex] += timing.coreSeconds
      maximumRssKiB[backendIndex] = max(maximumRssKiB[backendIndex],
          timing.maximumRssKiB)
      columns.appendValue(measured, name & ".elapsed_seconds", timing.elapsed)
      columns.appendValue(measured, name & ".core_seconds", timing.coreSeconds)
      columns.appendValue(measured, name & ".maximum_rss_kib",
          timing.maximumRssKiB)
    inc gameCount
  if gameCount == 0: raise newException(ValueError, "empty pilot schedule")
  if cpu and gameCount != 44: raise newException(ValueError, "native CPU SDK22 pilot needs 44 games")
  let candidateTiming = timingSummary(elapsed[0], coreSeconds[0], maximumRssKiB[
      0], totalTurns)
  let officialTiming = timingSummary(elapsed[1], coreSeconds[1], maximumRssKiB[
      1], totalTurns)
  let report = %*{"status": "complete", "backend": backend, "games": gameCount,
    "byte_identical_replay_pairs": gameCount, "dragon_turns": totalTurns,
    "events": totalEvents, "replay_bytes_per_backend": totalReplayBytes,
    "official_wasm_reference": officialTiming,
    "timing_scope": "sum of serial process invocations through replay close; final filesystem sync outside each invocation",
    "percentiles": "nearest rank", "timing_resolution_seconds": 0.01,
    "measurement_columns": measurementFile}
  report[backend] = candidateTiming
  report["reference_over_" & backend & "_elapsed"] =
    %(officialTiming["serial_match_seconds"].getFloat / candidateTiming[
        "serial_match_seconds"].getFloat)
  report["reference_over_" & backend & "_core_seconds"] = %(coreSeconds[1] /
      coreSeconds[0])
  if cpu: report["per_turn_points_equal_games"] = %gameCount
  if fileExists(store / "concurrency.txt"):
    var scaling = newJArray()
    var fastest = Inf
    var selected = 0
    for line in lines(store / "concurrency.txt"):
      let concurrency = parseInt(line)
      if concurrency notin [1, 2, 4, 8, 16]: raise newException(ValueError, "invalid concurrency")
      let batch = store / (if cpu: "cpu-concurrency" else: "concurrency") / line
      if readFile(batch / "status").strip != "complete":
        raise newException(ValueError, "incomplete scaling batch: " & batch)
      var figures: Table[int, seq[string]]
      if cpu:
        figures = readBatchFigures(batch / "figures.tsv")
        if figures.len != gameCount: raise newException(ValueError,
            "incomplete CPU job results: " & batch)
      var equalPoints = 0
      for row in lines(store / "pilot.tsv"):
        let index = row.split('\t')[0]
        let directory = batch / "games" / index
        if readFile(directory / "replay-bytes.status").strip != "identical" or
            not fileBytesEqual(directory / (backend & ".replay"), store /
                "games" / index / "reference.replay"):
          raise newException(ValueError, "scaling replay mismatch: " & directory)
        if cpu:
          let jobIndex = parseInt(index)
          if jobIndex notin figures: raise newException(ValueError,
              "missing CPU job: " & index)
          var original = columns.openColumnsFile(store / "games" / index / "reference.cols")
          let pointsEqual = checkBatchPoints(original, figures[jobIndex])
          columns.closeColumnsFile(original)
          if not pointsEqual or parseInt(figures[jobIndex][10]) != 0 or
              parseInt(figures[jobIndex][11]) != 0:
            raise newException(ValueError,
                "CPU aggregate points or bot failure mismatch: " & directory)
          inc equalPoints
      let timing = readMatchTiming(batch / "batch.time.tsv")
      scaling.add %*{"concurrency": concurrency, "games": gameCount,
        "dispatch_to_sync_seconds": timing.elapsed,
        "cpu_core_seconds": timing.coreSeconds,
        "outer_process_maximum_rss_kib": timing.maximumRssKiB,
        "games_per_second": float(gameCount) / timing.elapsed}
      columns.appendValue(measured, "batch.concurrency", uint32(concurrency))
      columns.appendValue(measured, "batch.elapsed_seconds", timing.elapsed)
      columns.appendValue(measured, "batch.core_seconds", timing.coreSeconds)
      columns.appendValue(measured, "batch.outer_rss_kib", timing.maximumRssKiB)
      if cpu:
        scaling[scaling.len - 1]["aggregate_points_equal_games"] = %equalPoints
        columns.appendValue(measured, "batch.aggregate_points_equal_games",
            uint32(equalPoints))
      if timing.elapsed < fastest:
        fastest = timing.elapsed
        selected = concurrency
    report["scaling"] = scaling
    report["selected_concurrency"] = %selected
    report["scaling_limits"] = %"one 44-game repetition per setting; different from serial process timings; outer RSS is not aggregate pool memory"
  createDir(output)
  columns.writeColumnsFile(measured, store / measurementFile)
  writeFile(output / summaryFile, report.pretty & "\n")
  echo report.pretty

type NativeJobMeasurementColumns = object
  ## Dense indexes of the canonical jobs TSV; completion order is arbitrary.
  seen: seq[bool]
  winner: seq[int8]
  rounds: seq[uint32]
  elapsed: seq[float64]
  botFailures: array[2, seq[uint32]]
  points: array[2, array[4, seq[uint64]]] # count, median, mean, maximum

proc readNativeJobMeasurements(path: string,
    games: int, recordBotFailures: bool): NativeJobMeasurementColumns =
  result.seen = newSeq[bool](games)
  result.winner = newSeq[int8](games)
  result.rounds = newSeq[uint32](games)
  result.elapsed = newSeq[float64](games)
  for team in 0 .. 1:
    result.botFailures[team] = newSeq[uint32](games)
    for field in 0 .. 3: result.points[team][field] = newSeq[uint64](games)
  var count = 0
  for line in lines(path):
    let fields = line.split('\t')
    if fields.len != 17: raise newException(ValueError, "invalid jobs figures")
    let index = parseInt(fields[0])
    if index < 0 or index >= games or result.seen[index]:
      raise newException(ValueError, "unexpected or duplicate job: " & fields[0])
    result.seen[index] = true
    result.winner[index] = case fields[1]
      of "A": 0'i8
      of "B": 1'i8
      of "-": -1'i8
      else: raise newException(ValueError, "invalid job winner: " & fields[1])
    let rounds = parseBiggestUInt(fields[2])
    if rounds == 0 or rounds > 500: raise newException(ValueError, "invalid job rounds")
    result.rounds[index] = uint32(rounds)
    for team in 0 .. 1:
      let failures = parseBiggestUInt(fields[10 + team])
      if failures > uint64(high(uint32)):
        raise newException(ValueError, "invalid bot failure count: " & fields[0])
      result.botFailures[team][index] = uint32(failures)
      if failures != 0 and not recordBotFailures:
        raise newException(ValueError, "bot failure in job " & fields[0])
    result.elapsed[index] = float64(parseBiggestUInt(fields[16])) / 1000.0
    for team in 0 .. 1:
      result.points[team][0][index] = parseBiggestUInt(fields[12 + team * 2])
      let points = fields[13 + team * 2].split('/')
      if points.len != 3: raise newException(ValueError, "invalid job points")
      for field in 0 .. 2:
        result.points[team][field + 1][index] = parseBiggestUInt(points[field])
    inc count
  if count != games: raise newException(ValueError, "missing completed job figures")

proc requireGameScalar[T](game: columns.ColumnsFileReader, name: string): T =
  if columns.rowCount(game, name) != 1:
    raise newException(ValueError, "missing scalar replay evidence: " & name)
  columns.columnValues[T](game, name).values[0]

proc writeNativeWorkloadReport*(store, output, maps, backend: string,
    scheduledGames: int, reference = "", recordBotFailures = false): int =
  ## The fixed denominator comes from the caller, not the number of files found.
  ## Map only one replay's columns at a time; retain measurements as dense SoA.
  if backend notin ["cpu", "cuda", "kvm"] or scheduledGames < 44 or
      scheduledGames > 10000 or scheduledGames mod 2 != 0:
    raise newException(ValueError, "invalid workload backend or paired game count")
  createDir(output)
  var measured = columns.initColumnsFileWriter("native-workload")
  var gameCount, identical: int
  var referenceMismatchGames: seq[int]
  var totalTurns, totalEvents, totalBytes: uint64
  var failedBotTurns: uint64
  var gamesWithBotFailures: int
  var latency: seq[float64]
  try:
    let native = backend != "kvm"
    let jobs = if native: readNativeJobMeasurements(store / "figures.tsv",
        scheduledGames, recordBotFailures) else: NativeJobMeasurementColumns()
    var mapNames, mapTexts: seq[string]
    var seedStart: uint64
    columns.appendValue(measured, "meta.version", 2'u32)
    columns.appendValue(measured, "meta.scheduled_games", uint32(scheduledGames))
    columns.appendString(measured, "meta.backend", backend)
    columns.appendString(measured, "meta.bot_failure_policy",
        if recordBotFailures: "record" else: "reject")
    for line in lines(store / "schedule.tsv"):
      let fields = line.split('\t')
      if fields.len != 4 or gameCount >= scheduledGames or
          fields[0] != align($gameCount, 3, '0') or
          parseInt(fields[3]) != gameCount mod 2:
        raise newException(ValueError, "invalid workload schedule: " & line)
      let seed = uint64(parseBiggestUInt(fields[2]))
      if gameCount == 0: seedStart = seed
      if seedStart > high(uint64) - 4999'u64 or
          seed != seedStart + uint64(gameCount div 2):
        raise newException(ValueError, "wrong scheduled seed: " & line)
      let mapName = fields[1]
      if mapName.len == 0 or mapName.extractFilename != mapName or
          mapName.find({'\r', '\n'}) >= 0:
        raise newException(ValueError, "invalid scheduled map")
      let mapIndex = (gameCount div 2) mod 22
      if gameCount < 44 and gameCount mod 2 == 0:
        if mapName in mapNames: raise newException(ValueError, "repeated SDK prefix map")
        mapNames.add mapName
        mapTexts.add readFile(maps / mapName)
      elif mapNames[mapIndex] != mapName:
        raise newException(ValueError, "wrong cyclic map: " & line)
      let directory = store / "games" / fields[0]
      var game = columns.openColumnsFile(directory / "game.cols")
      defer: columns.closeColumnsFile(game)
      if game.kind != "game" or
          requireGameScalar[uint8](game, "meta.terminated") != 1 or
          requireGameScalar[uint32](game, "meta.replay_format") != 2 or
          requireGameScalar[uint8](game, "meta.seed?") != 1 or
          requireGameScalar[uint64](game, "meta.seed") != seed:
        raise newException(ValueError, "incomplete replay or wrong seed: " & directory)
      if columns.rowCount(game, "meta.map_text") != 1 or
          columns.stringRow(game, "meta.map_text", 0) != mapTexts[mapIndex] or
          columns.stringRow(game, "meta.bot_a", 0) != "A" or
          columns.stringRow(game, "meta.bot_b", 0) != "B":
        raise newException(ValueError, "wrong replay map or seat names: " & directory)
      let turns = uint64(columns.rowCount(game, "turn.round"))
      let events = uint64(columns.rowCount(game, "event.kind"))
      if turns == 0 or events == 0:
        raise newException(ValueError, "empty replay: " & directory)
      let rounds = columns.columnValues[uint32](game, "turn.round")
      let winner = requireGameScalar[int8](game, "meta.winner")
      if native and (jobs.winner[gameCount] != winner or
          jobs.rounds[gameCount] != rounds.values[rounds.count - 1] + 1):
        raise newException(ValueError, "job/replay result mismatch: " & directory)
      let replay = directory / "game.replay"
      let bytes = uint64(getFileSize(replay))
      if bytes == 0: raise newException(ValueError, "empty packed replay: " & directory)
      var referenceEqual = false
      if reference.len > 0:
        let expected = reference / "games" / fields[0]
        referenceEqual = fileBytesEqual(replay, expected / "game.replay")
        if referenceEqual: inc identical
        else: referenceMismatchGames.add gameCount
        if native:
          var original = columns.openColumnsFile(expected / "game.cols")
          defer: columns.closeColumnsFile(original)
          let spent = columns.columnValues[uint64](original,
              "turn.points").values
          let known = columns.columnValues[uint8](original,
              "turn.points?").values
          let teams = columns.columnValues[uint8](original, "turn.team").values
          # Jobs exports no per-turn counters. Compare aggregates only when
          # the reference actually retained every turn's points.
          var knownTurns = true
          var points: array[2, seq[uint64]]
          for row in 0 ..< columns.rowCount(original, "turn.round"):
            if known[row] != 1 or teams[row] > 1:
              knownTurns = false
              break
            if spent[row] > 0: points[int(teams[row])].add spent[row]
          if knownTurns:
            for team in 0 .. 1:
              points[team].sort()
              let count = points[team].len
              var total: uint64
              for value in points[team]: total += value
              let expectedPoints = if count == 0: [0'u64, 0, 0, 0] else:
                [uint64(count), points[team][count div 2], total div uint64(
                    count), points[team][^1]]
              for field in 0 .. 3:
                if jobs.points[team][field][gameCount] != expectedPoints[field]:
                  raise newException(ValueError,
                      "reference aggregate points mismatch: " & directory)
          columns.appendValue(measured, "game.aggregate_points_equal?", uint8(knownTurns))
          columns.appendValue(measured, "game.aggregate_points_equal", uint8(knownTurns))
      if reference.len == 0 or not native:
        columns.appendValue(measured, "game.aggregate_points_equal?", 0'u8)
        columns.appendValue(measured, "game.aggregate_points_equal", 0'u8)
      let elapsed = if native: jobs.elapsed[gameCount] else:
        readMatchTiming(directory / "process.time.tsv").elapsed
      latency.add elapsed
      totalTurns += turns
      totalEvents += events
      totalBytes += bytes
      columns.appendValue(measured, "game.index", uint32(gameCount))
      columns.appendString(measured, "game.map", mapName)
      columns.appendValue(measured, "game.seed", seed)
      columns.appendValue(measured, "game.seat_order", uint8(gameCount mod 2))
      columns.appendValue(measured, "game.turns", turns)
      columns.appendValue(measured, "game.events", events)
      columns.appendValue(measured, "game.replay_bytes", bytes)
      columns.appendValue(measured, "game.winner", winner)
      columns.appendValue(measured, "game.rounds", rounds.values[rounds.count -
          1] + 1)
      columns.appendValue(measured, "game.end_reason", requireGameScalar[
          uint16](game, "meta.end_reason"))
      columns.appendValue(measured, "game.latency_seconds", elapsed)
      columns.appendValue(measured, "game.reference_equal?", uint8(
          reference.len > 0))
      columns.appendValue(measured, "game.reference_equal", uint8(
          referenceEqual))
      if native:
        let failures = uint64(jobs.botFailures[0][gameCount]) +
            uint64(jobs.botFailures[1][gameCount])
        failedBotTurns += failures
        if failures != 0: inc gamesWithBotFailures
      for team in 0 .. 1:
        columns.appendValue(measured, "side.game", uint32(gameCount))
        columns.appendValue(measured, "side.team", uint8(team))
        columns.appendValue(measured, "side.points?", uint8(native))
        columns.appendValue(measured, "side.bot_failures?", uint8(native))
        columns.appendValue(measured, "side.bot_failures",
            if native: jobs.botFailures[team][gameCount] else: 0'u32)
        for field, name in ["point_turns", "point_median", "point_mean",
            "point_maximum"]:
          columns.appendValue(measured, "side." & name,
              if native: jobs.points[team][field][gameCount] else: 0'u64)
      inc gameCount
    if gameCount != scheduledGames:
      raise newException(ValueError, "missing scheduled games: " & $gameCount &
          "/" & $scheduledGames)
    if referenceMismatchGames.len > 0:
      raise newException(ValueError, "reference replay mismatch: " &
          $referenceMismatchGames.len & " scheduled games")
    let timing = readMatchTiming(store / "batch.time.tsv")
    latency.sort()
    let report = %*{"status": "complete", "backend": backend,
      "scheduled_games": scheduledGames, "validated_games": gameCount,
      "byte_identical_reference_pairs": identical,
      "reference": reference, "dragon_turns": totalTurns, "events": totalEvents,
      "replay_bytes": totalBytes, "dispatch_to_sync_seconds": timing.elapsed,
      "cpu_core_seconds": timing.coreSeconds,
      "outer_process_maximum_rss_kib": timing.maximumRssKiB,
      "games_per_second": float64(scheduledGames) / timing.elapsed,
      "turns_per_second": float64(totalTurns) / timing.elapsed,
      "p50_match_seconds": latency[int(ceil(float64(gameCount) * 0.50)) - 1],
      "p95_match_seconds": latency[int(ceil(float64(gameCount) * 0.95)) - 1],
      "latency_boundary": (if native: "canonical jobs reported game wall time; millisecond resolution" else: "KVM child process through replay close; 0.01-second resolution"),
      "bot_failure_policy": (if recordBotFailures: "record" else: "reject"),
      "bot_failures_known": native,
      "failed_bot_turns": (if native: %failedBotTurns else: newJNull()),
      "games_with_bot_failures": (if native: %gamesWithBotFailures else: newJNull()),
      "timing_scope": "dispatch through complete replay writes and final filesystem sync; setup/validation/publication separate",
      "points": (if native: "actual jobs count/median/mean/max; no exported per-turn counters" else: "unknown; no comparable exported counters"),
      "limits": "outer GNU-time RSS is not pool memory; reference absent means unknown equality; no strength inference",
      "measurement_columns": "native-workload.cols"}
    columns.writeColumnsFile(measured, store / "native-workload.cols")
    writeFile(output / "workload-timings.json", report.pretty & "\n")
    echo report.pretty
  except CatchableError as failure:
    let report = %*{"status": "incomplete", "backend": backend,
      "scheduled_games": scheduledGames, "validated_games": gameCount,
      "byte_identical_reference_pairs": identical,
      "reference_mismatch_count": referenceMismatchGames.len,
      "bot_failure_policy": (if recordBotFailures: "record" else: "reject"),
      "first_reference_mismatch_games": referenceMismatchGames[0 ..< min(
          referenceMismatchGames.len, 16)],
      "error": failure.msg, "limits": "no throughput claim; denominator unchanged"}
    writeFile(output / "workload-timings.json", report.pretty & "\n")
    raise
