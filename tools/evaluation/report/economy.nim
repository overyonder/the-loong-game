## `loong-report economy`: whole-game economy from `result` records, and judge
## points per dragon turn. For a result set it writes the record a game with a
## replay is missing, beside its log, which is the economy stage's job; a replay
## given directly is summarised without writing anything.

import std/[algorithm, json, os, sequtils, strutils, tables]
import ../../gamedata/[columns, gamedata, result]
import records, summary

const PointLimit = 100_000_000   ## the judge's CPU points per dragon turn (planning/rules.md)

type Row = tuple[label: string, side: JsonNode]

proc resultSides(path: string): seq[JsonNode] =
  ## Each side of a `result` file's first game, as the table reads it; empty
  ## for a game that left no replay.
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  result = @[newJNull(), newJNull()]
  if file.numberAt("game.rounds?", 0) == 0: return @[]
  for row in 0 ..< file.rowCount("side.game"):
    if file.numberAt("side.game", row) != 0: continue
    var side = newJObject()
    for name in ["pearls_per_dragon_turn", "dragon_turns", "splits", "deaths", "final_units",
        "final_longest", "final_total_length", "head_coverage"]:
      side[name] = %file.numberAt("side." & name, row)
    result[int(file.numberAt("side.team", row))] = side

proc computeResult(replay, output, map: string, seed: uint64, bots: array[2, string]) =
  ## A result record from the replay, through its game columns.
  let game = getTempDir() / "loong-economy-" & $getCurrentProcessId() & ".cols"
  defer: removeFile(game)
  writeGameColumns(replay, game)
  writeResultColumns(game, GameHarnessFacts(map: map, seed: seed, bots: bots), output)

proc number(side: JsonNode, name: string): float =
  ## A side's field, integer or not, as a result record or a legacy summary holds it.
  let node = side{name}
  if node == nil: 0.0 elif node.kind == JInt: float(node.getBiggestInt) else: node.getFloat

proc tableRow(label: string, side: JsonNode): string =
  var cells = @[label, cFormat("%.4f", side.number("pearls_per_dragon_turn"))]
  for name in ["dragon_turns", "splits", "deaths", "final_units", "final_longest", "final_total_length"]:
    cells.add $int64(side.number(name))
  cells.add cFormat("%.1f", side.number("head_coverage") * 100) & "%"
  "| " & cells.join(" | ") & " |"

proc setRows(directory, bot: string): seq[Row] =
  ## `bot`'s side of each completed game in a result set, by map, side, seed
  ## and opponent.
  var keyed: seq[(string, string, int64, string, JsonNode)]
  for entry in parseFile(directory / "results.json")["games"]:
    if entry["status"].getStr != "completed": continue
    var sides: seq[int]
    for team, key in ["A", "B"]:
      if entry[key].getStr == bot: sides.add team
    if sides.len == 0: continue
    let log = entry["log"].getStr
    let record = besideLog(directory, log, ".result.cols")
    var found: seq[JsonNode]
    if fileExists(record): found = resultSides(record)
    else:
      let legacy = readJsonFile(besideLog(directory, log, ".economy.json"))
      if legacy != nil:
        if "error" notin legacy and legacy{"sides"} != nil and legacy["sides"].len > 0:
          found = @[legacy["sides"]{"a"}, legacy["sides"]{"b"}]
      elif entry{"replay"}.getStr.len > 0 and fileExists(gameFile(directory, entry["replay"].getStr)):
        try:
          computeResult(gameFile(directory, entry["replay"].getStr), record,
            entry["map"].getStr.extractFilename, uint64(entry{"seed"}.getBiggestInt),
            [entry["A"].getStr, entry["B"].getStr])
          found = resultSides(record)
        except CatchableError: discard   # an unreadable game has no economy
    if found.len == 0: continue
    for team in sides:
      if found[team] != nil and found[team].kind != JNull:
        keyed.add (entry["map"].getStr.extractFilename, ["A", "B"][team],
          entry{"seed"}.getBiggestInt(-1), entry[["B", "A"][team]].getStr, found[team])
  keyed.sort(proc (x, y: (string, string, int64, string, JsonNode)): int =
    cmp((x[0], x[1], x[2], x[3]), (y[0], y[1], y[2], y[3])))
  for (map, side, _, opponent, record) in keyed:
    result.add (map & " " & side & " vs " & short(opponent), record)

proc replayRows(replay: string): seq[Row] =
  let output = getTempDir() / "loong-economy-" & $getCurrentProcessId() & ".result.cols"
  defer: removeFile(output)
  computeResult(replay, output, "", 0, ["", ""])
  let sides = resultSides(output)
  if sides.len == 0: raise newException(ValueError, replay & ": loong-gamedata could not read the replay")
  for team, side in sides: result.add (replay.splitFile.name & " " & "AB"[team], side)

proc millions(points: uint64): string = cFormat("%.1f", float(points) / 1e6) & "M"

proc printPoints(replay: string, worst: int) =
  if dirExists(replay): quit(replay & ": --points reads replays; pass " & replay & "/*.replay", 2)
  let game = getTempDir() / "loong-economy-" & $getCurrentProcessId() & ".cols"
  defer: removeFile(game)
  writeGameColumns(replay, game)
  var columns = openColumnsFile(game)
  defer: columns.closeColumnsFile()
  let bots = [columns.stringRow("meta.bot_a", 0), columns.stringRow("meta.bot_b", 0)]
  var teams: Table[uint32, int]
  for row in 0 ..< columns.rowCount("start.dragon"):
    teams[uint32(columns.numberAt("start.dragon", row))] = int(columns.numberAt("start.team", row))
  for row in 0 ..< columns.rowCount("event.kind"):
    if columns.numberAt("event.kind", row) == 6:
      teams[uint32(columns.numberAt("event.b", row))] = int(columns.numberAt("event.c", row))
  echo replay.extractFilename, ", judge limit ", millions(PointLimit), " per dragon turn"
  let pointsPath = pointsFileFor(replay)
  if not fileExists(pointsPath):
    echo "  no ", pointsPath.extractFilename, ": only a --sandbox match run through ",
      "the judge records points"
    return
  var points = openColumnsFile(pointsPath)
  defer: points.closeColumnsFile()
  type Turn = tuple[round: int, dragon: uint32, points: uint64, failure: string]
  var bySide: array[2, seq[Turn]]
  for row in 0 ..< points.rowCount("turn.dragon"):
    let dragon = uint32(points.numberAt("turn.dragon", row))
    if dragon notin teams: continue
    bySide[teams[dragon]].add (int(points.numberAt("turn.round", row)), dragon,
      points.columnValues[:uint64]("turn.points").values[row], points.stringRow("turn.failure", row))
  proc failureText(turn: Turn): string = (if turn.failure.len > 0: " (" & turn.failure & ")" else: "")
  for side in 0 .. 1:
    let mine = bySide[side]
    if mine.len == 0: continue
    var ordered = mine.mapIt(it.points)
    ordered.sort
    proc quantile(fraction: float): uint64 = ordered[min(ordered.len - 1, int(fraction * float(ordered.len)))]
    var dragons: OrderedTable[uint32, tuple[turns: int, total, peak: uint64, peakRound: int]]
    var failed: seq[Turn]
    var over = 0
    for turn in mine:
      var record = dragons.getOrDefault(turn.dragon)
      inc record.turns
      record.total += turn.points
      if turn.points > record.peak: (record.peak, record.peakRound) = (turn.points, turn.round)
      dragons[turn.dragon] = record
      if turn.failure.len > 0: failed.add turn
      if float(turn.points) >= 0.9 * float(PointLimit): inc over
    echo "  ", "AB"[side], " ", bots[side], ": ", mine.len, " turns, median ", millions(quantile(0.5)),
      ", p90 ", millions(quantile(0.9)), ", p99 ", millions(quantile(0.99)), ", max ",
      millions(ordered[^1]), ", ", over, " at 90% or more, ", failed.len, " failed"
    for turn in failed:
      echo "    failed: r", turn.round, " dragon ", turn.dragon, " ", millions(turn.points), turn.failureText
    var heaviest = mine
    heaviest.sort(proc (x, y: Turn): int = cmp(y.points, x.points))
    echo "    worst: ", heaviest[0 ..< min(worst, heaviest.len)].mapIt(
      "r" & $it.round & " d" & $it.dragon & " " & millions(it.points) & it.failureText).join(", ")
    var peaks = toSeq(dragons.pairs)
    peaks.sort(proc (x, y: (uint32, tuple[turns: int, total, peak: uint64, peakRound: int])): int =
      cmp(y[1].peak, x[1].peak))
    echo "    top dragons (peak, mean): ", peaks[0 ..< min(worst, peaks.len)].mapIt(
      "d" & $it[0] & " " & millions(it[1].peak) & "@r" & $it[1].peakRound & " " &
      millions(it[1].total div uint64(it[1].turns))).join(", ")

proc economyCommand*(paths: seq[string], bot: string, pointsWanted: bool, worst: int): int =
  if pointsWanted:
    for path in paths: printPoints(path, worst)
    return 0
  var rows: seq[Row]
  for path in paths:
    if dirExists(path):
      if bot.len == 0: quit("a results directory needs --bot", 2)
      rows.add setRows(path.absolutePath.normalizedPath, bot)
    else: rows.add replayRows(path)
  echo "| Game | Pearls per dragon-turn | Dragon-turns | Splits | Deaths ",
    "| Final units | Final longest | Final total | Head coverage |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  for (label, side) in rows: echo tableRow(label, side)
