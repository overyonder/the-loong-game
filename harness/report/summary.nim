## The standard evaluation report, `summary.md`, for any set of games:
##
## 1. A headline table, one row per candidate and opponent: W–D–L, games,
##    score, implied Elo with its 95% interval, and the side-swapped pairs on
##    the same map and seed. A sequential verdict adds its decision, LLR and
##    games used. The games completed go on a line above the table.
## 2. The candidate's score and Elo per map-type group and per map.
## 3. Deaths by cause and final size per game, for each side.
## 4. Insights, which the analyst writes. Re-rendering keeps them.
##
## Candidates are the bots under test: those the caller names, or every bot.

import std/[algorithm, json, options, os, sequtils, strutils, tables]
import maps, rating, records

const
  Insights = "## Insights"
  KelpDeath = "hit a wall"
  ## Causes every death row shows, even at zero; others appear from 0.05 a game.
  AlwaysShown = [KelpDeath, "hit itself", "lost a head-to-head"]

type
  Decision* = object
    ## A sequential verdict's test for one pairing.
    decision*:             string
    llr*, lower*, upper*:  float
    games*, cap*:          int
    decidedAt*:            Option[int]

  Report* = object
    games*:      seq[Game]
    title*:      string
    candidates*: seq[string]
    context*:    string        ## appended to the context line
    decisions*:  Table[(string, string), Decision]
    insights*:   string

proc snprintf(buffer: cstring, size: csize_t, format: cstring): cint {.importc, header: "<stdio.h>", varargs.}

proc cFormat*(format: string, value: float): string =
  ## `value` through a C format, which rounds as Python's formatting does.
  var buffer: array[64, char]
  let length = snprintf(cast[cstring](addr buffer[0]), csize_t(buffer.len), format.cstring, value)
  result = newString(length)
  copyMem(addr result[0], addr buffer[0], length)

proc grouped*(value: int): string =
  ## An integer with thousands separators.
  let digits = $abs(value)
  for position, digit in digits:
    if position > 0 and (digits.len - position) mod 3 == 0: result.add ','
    result.add digit
  if value < 0: result = "-" & result

proc short*(bot: string): string = bot.strip(leading = false, chars = {'/'}).rsplit('/', 1)[^1]

# Who is under test

proc defaultCandidates(games: seq[Game]): seq[string] =
  ## Every bot that played.
  for game in games:
    for bot in [game.a, game.b]:
      if bot notin result: result.add bot
  result.sort

proc scored(game: Game, bot: string): Option[float] =
  ## `bot`'s score in a completed game: 1, 1/2 or 0.
  if game.status != "completed": none(float)
  elif game.winner < 0: some(0.5)
  elif [game.a, game.b][game.winner] == bot: some(1.0)
  else: some(0.0)

proc pairings(games: seq[Game], candidates: seq[string]): OrderedTable[(string, string), seq[Game]] =
  ## (candidate, opponent) to that pairing's games, self-play left out.
  for candidate in candidates:
    for game in games:
      if candidate in [game.a, game.b] and game.a != game.b:
        let opponent = if game.a == candidate: game.b else: game.a
        result.mgetOrPut((candidate, opponent), @[]).add game

proc tally(games: seq[Game], bot: string): tuple[wins, draws, losses: int] =
  for game in games:
    let score = scored(game, bot)
    if score.isSome:
      if score.get == 1: inc result.wins
      elif score.get == 0.5: inc result.draws
      else: inc result.losses

# Figures

proc signed(value: Option[float]): string =
  if value.isNone: "…" else: cFormat("%+.0f", value.get).replace("-", "−")

proc eloText(wins, draws, losses: int, interval = true): string =
  let (centre, low, high) = eloInterval(wins, draws, losses)
  if centre.isNone: "–"
  elif interval: signed(centre) & " (" & signed(low) & " to " & signed(high) & ")"
  else: signed(centre)

proc scoreOf(wins, draws, losses: int): Option[float] =
  let games = wins + draws + losses
  if games > 0: some((float(wins) + float(draws) / 2) / float(games)) else: none(float)

proc matchedPairs(games: seq[Game], bot: string): tuple[pairs, won, lost, discordant: int] =
  ## Side-swapped pairs on the same map and seed.
  var sides: OrderedTable[string, array[2, Option[float]]]
  for game in games:
    let score = scored(game, bot)
    if score.isSome:
      sides.mgetOrPut(game.map & "\t" & $game.seed, [none(float), none(float)])[
        if game.a == bot: 0 else: 1] = score
  for pair in sides.values:
    if pair[0].isSome and pair[1].isSome:
      inc result.pairs
      if pair[0].get == pair[1].get:
        if pair[0].get == 1: inc result.won
        elif pair[0].get == 0: inc result.lost
      else: inc result.discordant

# Context line

proc contextLine(games: seq[Game]): string =
  ## How many games completed.
  let errors = games.countIt(it.status != "completed")
  grouped(games.len - errors) & " games completed" &
    (if errors > 0: ", " & $errors & " failed to run" else: "") & "."

# Map facts

proc mapGroups(games: seq[Game]): Table[string, Table[string, string]] =
  ## Map file name to axis to group, from the map files the games played.
  for game in games:
    if game.map notin result and fileExists(game.mapPath):
      result[game.map] = mapAxes(readFile(game.mapPath))

# Rendering

proc headline(byPairing: OrderedTable[(string, string), seq[Game]],
    decisions: Table[(string, string), Decision]): seq[string] =
  let sequential = decisions.len > 0
  var header = "| Candidate | Opponent | W–D–L | Games | Score | Elo (95% interval) " &
    "| Pairs: won both / lost both / discordant |"
  var rule = "| --- | --- | --- | ---: | ---: | --- | --- |"
  if sequential:
    header &= " Decision | LLR (lower, upper) | Games used |"
    rule &= " --- | --- | --- |"
  result = @[header, rule]
  var keys = toSeq(byPairing.keys)
  keys.sort(proc (x, y: (string, string)): int =
    cmp((x[0], -byPairing[x].len, x[1]), (y[0], -byPairing[y].len, y[1])))
  for key in keys:
    let (candidate, opponent) = key
    let games = byPairing[key]
    let (wins, draws, losses) = tally(games, candidate)
    let played = wins + draws + losses
    let failed = games.len - played
    let (pairs, won, lost, discordant) = matchedPairs(games, candidate)
    let score = scoreOf(wins, draws, losses)
    var row = "| `" & short(candidate) & "` | `" & short(opponent) & "` | " &
      $wins & "–" & $draws & "–" & $losses & " | " & $played &
      (if failed > 0: " (+" & $failed & " failed)" else: "") & " | " &
      (if score.isNone: "–" else: cFormat("%.3f", score.get)) & " | " &
      eloText(wins, draws, losses) & " | " & $won & " / " & $lost & " / " &
      $discordant & " of " & $pairs & " |"
    if sequential:
      if key in decisions:
        let test = decisions[key]
        var used = $test.games
        if test.decidedAt.isSome: used &= ", decided at " & $test.decidedAt.get
        if test.cap > 0: used &= " (cap " & $test.cap & ")"
        row &= " " & test.decision & " | " & cFormat("%+.3f", test.llr) & " (" &
          cFormat("%+.3f", test.lower) & ", " & cFormat("%+.3f", test.upper) & ") | " & used & " |"
      else: row &= " – | – | – |"
    result.add row

proc cell(games: seq[Game], bot: string, withElo = true): string =
  let (wins, draws, losses) = tally(games, bot)
  let score = scoreOf(wins, draws, losses)
  if score.isNone: return "–"
  result = cFormat("%.3f", score.get)
  if withElo: result &= ", " & eloText(wins, draws, losses, interval = false)
  result &= " (" & $(wins + draws + losses) & ")"

proc mapSection(candidate: string, mine: OrderedTable[string, seq[Game]],
    opponents: seq[string], groups: Table[string, Table[string, string]]): seq[string] =
  ## Score, Elo and games per map-type group, then score per map.
  result.add "Each cell is `" & short(candidate) & "`'s score, implied Elo and games against " &
    "that opponent. Map groups are defined in harness/report/maps.nim."
  let columns = opponents.mapIt("`" & short(it) & "`").join(" | ")
  for (axis, label) in ReportAxes:
    var values: seq[string]
    for facts in groups.values:
      if facts.len > 0 and facts[axis] notin values: values.add facts[axis]
    values.sort
    result.add ["", "### By " & label, "", "| Group | " & columns & " |",
      "| --- |" & " --- |".repeat(opponents.len)]
    for value in values:
      var cells: seq[string]
      for opponent in opponents:
        cells.add cell(mine[opponent].filterIt(
          groups.getOrDefault(it.map).getOrDefault(axis) == value), candidate)
      result.add "| " & value & " | " & cells.join(" | ") & " |"
  var everything: seq[Game]
  for games in mine.values: everything.add games
  var names: seq[string]
  for game in everything:
    if game.map notin names: names.add game.map
  names.sort
  var overall: Table[string, Option[float]]
  for name in names:
    let (w, d, l) = tally(everything.filterIt(it.map == name), candidate)
    overall[name] = scoreOf(w, d, l)
  names.sort(proc (x, y: string): int =
    cmp((overall[x].isNone, overall[x].get(0.0), x), (overall[y].isNone, overall[y].get(0.0), y)))
  result.add ["", "### By map, lowest score first", "", "| Map | All | " & columns & " |",
    "| --- | --- |" & " --- |".repeat(opponents.len)]
  for name in names:
    var cells: seq[string]
    for opponent in opponents:
      cells.add cell(mine[opponent].filterIt(it.map == name), candidate, withElo = false)
    var shown = name
    shown.removeSuffix(".map")
    result.add "| " & shown & " | " & cell(everything.filterIt(it.map == name), candidate,
      withElo = false) & " | " & cells.join(" | ") & " |"

proc deathSection(candidate: string, mine: OrderedTable[string, seq[Game]],
    opponents: seq[string]): seq[string] =
  result = @["Means per game from each game's economy summary. Hitting a wall is " &
    "crossing kelp.", "",
    "| Opponent | Side | Games | Deaths | By cause | Final longest " &
    "| Final total length | Final units | Splits |",
    "| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |"]
  for opponent in opponents:
    for (label, ours) in [(short(candidate), true), (short(opponent), false)]:
      var records: seq[SideRecord]
      for game in mine[opponent]:
        if game.economy: records.add game.sides[if (game.a == candidate) == ours: 0 else: 1]
      if records.len == 0:
        result.add "| `" & short(opponent) & "` | `" & label & "` | 0 | – | no economy summaries " &
          "| – | – | – | – |"
        continue
      let count = float(records.len)
      var causes: OrderedTable[string, float]
      for cause in AlwaysShown: causes[cause] = 0
      var observed: OrderedTable[string, float]
      for record in records:
        for (cause, number) in record.causes:
          observed[cause] = observed.getOrDefault(cause) + number / count
      # The record's causes by frequency, over the always-shown zeros.
      var byFrequency = toSeq(observed.pairs)
      byFrequency.sort(proc (x, y: (string, float)): int = cmp(y[1], x[1]))
      for (cause, value) in byFrequency: causes[cause] = value
      var ordered = toSeq(causes.pairs)
      ordered.sort(proc (x, y: (string, float)): int = cmp(y[1], x[1]))
      var shown: seq[string]
      for (cause, value) in ordered:
        if value >= 0.05 or cause in AlwaysShown:
          shown.add cause & (if cause == KelpDeath: " (kelp)" else: "") & " " & cFormat("%.1f", value)
      proc mean(field: proc (record: SideRecord): float): string =
        var total = 0.0
        for record in records: total += field(record)
        cFormat("%.1f", total / count)
      result.add "| `" & short(opponent) & "` | `" & label & "` | " & $records.len &
        " | " & mean(proc (r: SideRecord): float = r.deaths) & " | " &
        (if shown.len > 0: shown.join(", ") else: "–") &
        " | " & mean(proc (r: SideRecord): float = r.finalLongest) &
        " | " & mean(proc (r: SideRecord): float = r.finalTotalLength) &
        " | " & mean(proc (r: SideRecord): float = r.finalUnits) &
        " | " & mean(proc (r: SideRecord): float = r.splits) & " |"

proc render*(report: Report): string =
  ## The report's markdown.
  let candidates = if report.candidates.len > 0: report.candidates
                   else: defaultCandidates(report.games)
  let byPairing = pairings(report.games, candidates)
  var lines = @["# " & report.title, "", contextLine(report.games)]
  if report.context.len > 0: lines[^1] &= " " & report.context
  lines.add ""
  lines.add headline(byPairing, report.decisions)
  let groups = mapGroups(report.games)
  for candidate in candidates:
    var mine: OrderedTable[string, seq[Game]]
    for key, games in byPairing:
      if key[0] == candidate: mine[key[1]] = games
    if mine.len == 0: continue
    var opponents = toSeq(mine.keys)
    opponents.sort(proc (x, y: string): int = cmp((-mine[x].len, x), (-mine[y].len, y)))
    let heading = if candidates.len > 1: " for `" & short(candidate) & "`" else: ""
    lines.add ["", "## Maps" & heading, ""]
    lines.add mapSection(candidate, mine, opponents, groups)
    lines.add ["", "## Deaths and final state" & heading, ""]
    lines.add deathSection(candidate, mine, opponents)
  lines.add ["", Insights, ""]
  if report.insights.strip.len > 0: lines.add [report.insights.strip, ""]
  lines.join("\n").strip(leading = false) & "\n"

proc existingInsights*(summary: string): string =
  ## The analyst's insights from a summary about to be re-rendered.
  if not fileExists(summary): return
  let text = readFile(summary)
  var at = 0
  for line in text.splitLines:
    if line.strip(leading = false) == Insights:
      return text[at + line.len .. ^1].strip
    at += line.len + 1
