## Read RL's native_profile.h TSV1 stream without interpreting overlapping
## intervals as a decomposition. Dense rows preserve missing stages as unknown.

import std/[json, options, os, strutils]
from ../../gamedata/columns import nil

const
  HostStages = ["setup", "run", "next", "drain", "observations", "bot_wave",
    "callback_sum", "apply", "parse_replies", "copy_enqueue", "stream_wait",
    "consume_events", "serialize", "cleanup"]
  DeviceStages = ["begin", "advance", "apply", "actions_htod", "acting_dtoh",
    "state_events_dtoh"]
  CopyDirections = ["htod", "dtoh"]

type
  StageMeasurement = object
    calls, value: uint64 ## ns for stages, requested bytes for copies
  BatchProfile = object
    games: uint64
    completed, failed: bool
    host: array[HostStages.len, Option[StageMeasurement]]
    device: array[DeviceStages.len, Option[StageMeasurement]]
    copies: array[CopyDirections.len, Option[StageMeasurement]]
    waves: Option[StageMeasurement] ## calls=waves, value=active decisions
    lastRank: int
    rows: int
  ProfileStream = object
    present: bool
    batches: seq[BatchProfile]
    error: string

proc decimal(field: string): uint64 =
  if field.len == 0: raise newException(ValueError, "empty profile integer")
  for character in field:
    if character notin {'0' .. '9'}:
      raise newException(ValueError, "profile integer is not unsigned decimal")
  parseBiggestUInt(field)

proc stageIndex(names: openArray[string], name: string): int =
  for index, value in names:
    if value == name: return index
  raise newException(ValueError, "unknown profile stage: " & name)

proc addChecked(total: var uint64, value: uint64) =
  if value > high(uint64) - total:
    raise newException(ValueError, "profile aggregate overflow")
  total += value

proc readProfileStream(path: string, scheduled: int): ProfileStream =
  try:
    for line in lines(path):
      if not line.startsWith("native-profile\t"): continue
      result.present = true
      let fields = line.split('\t')
      if fields.len < 3 or fields[1] != "1":
        raise newException(ValueError, "unsupported native-profile stream version")
      if fields[2] == "batch":
        if fields.len != 8:
          raise newException(ValueError, "invalid native-profile batch header")
        if fields[4] != "completed" or fields[6] != "failed":
          raise newException(ValueError, "invalid native-profile batch header")
        if fields[5] notin ["0", "1"] or fields[7] notin ["0", "1"]:
          raise newException(ValueError, "invalid native-profile batch header")
        let games = decimal(fields[3])
        if games == 0 or games > uint64(scheduled) or
            result.batches.len >= scheduled:
          raise newException(ValueError, "invalid native-profile game denominator")
        result.batches.add BatchProfile(games: games, completed: fields[5] ==
            "1",
          failed: fields[7] == "1", rows: 1)
        continue
      if result.batches.len == 0 or fields.len != 6:
        raise newException(ValueError, "profile row has no batch or wrong arity")
      var batch = addr result.batches[^1]
      var rank: int
      let measurement = StageMeasurement(calls: decimal(
        if fields[2] == "waves": fields[3] else: fields[4]),
        value: decimal(fields[5]))
      case fields[2]
      of "host":
        let index = stageIndex(HostStages, fields[3])
        rank = 1 + index
        if rank <= batch.lastRank: raise newException(ValueError,
            "duplicate or reordered native-profile row")
        batch.host[index] = some(measurement)
      of "device":
        let index = stageIndex(DeviceStages, fields[3])
        rank = 1 + HostStages.len + index
        if rank <= batch.lastRank: raise newException(ValueError,
            "duplicate or reordered native-profile row")
        batch.device[index] = some(measurement)
      of "waves":
        if fields[4] != "decisions": raise newException(ValueError,
            "invalid native-profile wave counter")
        rank = 21
        if rank <= batch.lastRank: raise newException(ValueError,
            "duplicate or reordered native-profile row")
        batch.waves = some(measurement)
      of "copy":
        let index = stageIndex(CopyDirections, fields[3])
        rank = 22 + index
        if rank <= batch.lastRank: raise newException(ValueError,
            "duplicate or reordered native-profile row")
        batch.copies[index] = some(measurement)
      else: raise newException(ValueError, "unknown native-profile row kind")
      batch.lastRank = rank
      inc batch.rows
  except CatchableError as failure:
    result.error = failure.msg

proc complete(batch: BatchProfile): bool =
  batch.rows == 24 and batch.lastRank == 23 and batch.completed and
    not batch.failed and batch.host[12].isSome and
    batch.host[12].get.calls == batch.games

proc verifiedWorkload(store: string, scheduled: int): bool =
  ## Consume the previous canonical validation stage, never replay games or
  ## silently invoke another stage. Reference and known SDK aggregates required.
  let path = store / "native-workload.cols"
  if not fileExists(path): return false
  var file = columns.openColumnsFile(path)
  defer: columns.closeColumnsFile(file)
  if file.kind != "native-workload" or
      columns.rowCount(file, "meta.version") != 1 or
      columns.rowCount(file, "meta.scheduled_games") != 1 or
      columns.rowCount(file, "meta.backend") != 1 or
      columns.rowCount(file, "game.index") != scheduled: return false
  if columns.columnValues[uint32](file, "meta.version").values[0] != 2 or
      columns.columnValues[uint32](file, "meta.scheduled_games").values[0] !=
        uint32(scheduled) or columns.stringRow(file, "meta.backend", 0) != "cuda":
    return false
  let indexes = columns.columnValues[uint32](file, "game.index")
  for index in 0 ..< scheduled:
    if indexes.values[index] != uint32(index): return false
  for name in ["game.reference_equal?", "game.reference_equal",
      "game.aggregate_points_equal?", "game.aggregate_points_equal"]:
    if columns.rowCount(file, name) != scheduled: return false
    let values = columns.columnValues[uint8](file, name)
    for index in 0 ..< scheduled:
      if values.values[index] != 1: return false
  true

proc appendMeasurement(file: var columns.ColumnsFileWriter, tableName,
    stage: string, batch: int, measurement: Option[StageMeasurement],
        unit: string) =
  let value = measurement.get(StageMeasurement())
  columns.appendValue(file, tableName & ".batch", uint32(batch))
  columns.appendString(file, tableName & ".stage", stage)
  columns.appendValue(file, tableName & ".known", uint8(measurement.isSome))
  columns.appendValue(file, tableName & ".calls", value.calls)
  columns.appendValue(file, tableName & "." & unit, value.value)

proc writeNativeProfileReport*(store, output: string, scheduled: int,
    expectation: string): int =
  if scheduled < 1 or scheduled > 10000 or expectation notin ["enabled", "disabled"]:
    raise newException(ValueError, "invalid profile denominator or expectation")
  createDir(output)
  let stream = readProfileStream(store / "judge.log", scheduled)
  var measured = columns.initColumnsFileWriter("native-profile")
  columns.appendValue(measured, "meta.version", 1'u32)
  columns.appendValue(measured, "meta.expected_stream_version", 1'u32)
  columns.appendValue(measured, "meta.scheduled_games", uint32(scheduled))
  columns.appendValue(measured, "meta.profile_present", uint8(stream.present))
  columns.appendString(measured, "meta.expectation", expectation)
  var games: uint64
  var profileComplete = stream.present and stream.error.len == 0
  var failure = stream.error
  for index, batch in stream.batches:
    addChecked(games, batch.games)
    profileComplete = profileComplete and batch.complete()
    columns.appendValue(measured, "batch.index", uint32(index))
    columns.appendValue(measured, "batch.games", batch.games)
    columns.appendValue(measured, "batch.completed", uint8(batch.completed))
    columns.appendValue(measured, "batch.failed", uint8(batch.failed))
    columns.appendValue(measured, "batch.stream_complete", uint8(batch.complete()))
    columns.appendValue(measured, "batch.waves?", uint8(batch.waves.isSome))
    columns.appendValue(measured, "batch.waves", batch.waves.get(
        StageMeasurement()).calls)
    columns.appendValue(measured, "batch.decisions", batch.waves.get(
        StageMeasurement()).value)
    for stage, name in HostStages:
      measured.appendMeasurement("host", name, index, batch.host[stage], "ns")
    for stage, name in DeviceStages:
      measured.appendMeasurement("device", name, index, batch.device[stage], "ns")
    for direction, name in CopyDirections:
      measured.appendMeasurement("copy", name, index, batch.copies[direction], "bytes")
  profileComplete = profileComplete and games == uint64(scheduled)
  let modeMatches = fileExists(store / "profile-mode.txt") and
    readFile(store / "profile-mode.txt").strip == expectation
  var workloadVerified = false
  try: workloadVerified = verifiedWorkload(store, scheduled)
  except CatchableError as error: failure = error.msg
  let acceptableStream = (if expectation == "enabled": profileComplete else:
    not stream.present and failure.len == 0)
  let accepted = acceptableStream and modeMatches and workloadVerified
  columns.appendValue(measured, "meta.stream_complete", uint8(profileComplete))
  columns.appendValue(measured, "meta.workload_verified", uint8(workloadVerified))
  var report = %*{"status": (if not stream.present and failure.len == 0: "unknown"
    elif accepted: "complete" else: "incomplete"), "expectation": expectation,
    "profile_present": stream.present, "profile_known": stream.batches.len > 0,
    "profile_stream_complete": profileComplete,
    "scheduled_games": scheduled, "profile_games": games,
        "batches": stream.batches.len,
    "mode_matches": modeMatches, "workload_verified": workloadVerified,
    "accepted": accepted, "error": failure,
        "measurement_columns": "native-profile.cols",
    "limits": "Inclusive host intervals overlap; callback_sum adds actual worker callbacks, not wall time. Device copy spans include host enqueue gaps. Host/device totals must not be added. Replay writes/close/sync are separate driver intervals. Missing profile/stages are unknown; this is not an instrumentation-overhead or throughput claim."}
  if profileComplete:
    for group in ["host", "device", "copy"]:
      let names = if group == "host": @HostStages elif group == "device":
          @DeviceStages else: @CopyDirections
      var totals = newJObject()
      for stage, name in names:
        var total: StageMeasurement
        for batch in stream.batches:
          let value = (if group == "host": batch.host[stage] elif group == "device":
            batch.device[stage] else: batch.copies[stage]).get()
          addChecked(total.calls, value.calls)
          addChecked(total.value, value.value)
        totals[name] = %*{"calls": total.calls}
        totals[name][if group == "copy": "bytes" else: "ns"] = %total.value
      report[group] = totals
  columns.writeColumnsFile(measured, store / "native-profile.cols")
  writeFile(output / "profile-summary.json", report.pretty & "\n")
  echo report.pretty
  if accepted: 0 else: 2
