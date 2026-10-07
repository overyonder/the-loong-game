## The mimics' behavioural likeness (roadmap item 5's bar, part 6): in matches
## among the mimics, each mimic's score against another team's mimic set beside
## its team's actual queen-era score against that team on the ladder, written
## as `likeness.tsv` and `likeness.md`.
##
## A score is wins plus half the draws over the games. The ladder's come from a
## census of the teams' games (`loong-census measure`, kind `census`: each
## game's winner and its sides' team IDs); the mimics' from the result sets
## their round-robin left (records.loadGames), each bot named to its team by a
## TSV of `bot<TAB>team`. A pair counts when the ladder has at least
## `minGames` of its games and the mimics played it. A mimic passes when its
## mean absolute difference over its counted pairs is at most `bar`; it has no
## verdict when no pair counts.

import std/[algorithm, math, os, strutils, tables]
import ../../gamedata/columns
import records

type
  Tally = object
    games: int
    points: float      ## the first team's wins plus half the draws

  Pair = tuple[team, other: int]

proc add(t: var Tally, points: float) =
  t.games += 1
  t.points += points

proc score(t: Tally): float = (if t.games > 0: t.points / t.games.float else: NaN)

proc ladderTallies(census: string): Table[Pair, Tally] =
  ## Each ordered pair of teams' score on the ladder, from a census file.
  var file = openColumnsFile(census)
  defer: file.closeColumnsFile()
  let games = file.rowCount("game.id")
  var winners = newSeq[int](games)
  for g in 0 ..< games: winners[g] = int(file.numberAt("game.winner", g))   # 0 a, 1 b, 2 draw
  var teams = newSeq[array[2, int]](games)
  for g in 0 ..< games: teams[g] = [-1, -1]
  let flagged = file.rowCount("side.team_id?") > 0   # a `?` column marks which rows know the ID
  for s in 0 ..< file.rowCount("side.game"):
    let g = int(file.numberAt("side.game", s))
    let side = int(file.numberAt("side.team", s))
    if g < games and side in 0 .. 1 and (not flagged or file.numberAt("side.team_id?", s) != 0):
      teams[g][side] = int(file.numberAt("side.team_id", s))
  for g in 0 ..< games:
    let (a, b) = (teams[g][0], teams[g][1])
    if a < 0 or b < 0 or a == b: continue
    let pointsA = case winners[g]
      of 0: 1.0
      of 1: 0.0
      else: 0.5
    result.mgetOrPut((a, b), Tally()).add pointsA
    result.mgetOrPut((b, a), Tally()).add(1 - pointsA)

proc botTeams(path: string): Table[string, int] =
  for line in readFile(path).splitLines:
    let fields = line.strip.split('\t')
    if fields.len >= 2 and fields[0].len > 0 and fields[0][0] != '#':
      result[fields[0]] = parseInt(fields[1])

proc mimicTallies(results: seq[string], bots: Table[string, int]): Table[Pair, Tally] =
  ## Each ordered pair of teams' score among their mimics' completed games.
  for game in loadGames(results):
    if game.status != "completed" or game.a notin bots or game.b notin bots: continue
    let (a, b) = (bots[game.a], bots[game.b])
    if a == b: continue
    let pointsA = case game.winner
      of 0: 1.0
      of 1: 0.0
      else: 0.5
    result.mgetOrPut((a, b), Tally()).add pointsA
    result.mgetOrPut((b, a), Tally()).add(1 - pointsA)

proc likeness*(census: string, results: seq[string], botsPath, output: string, minGames: int, bar: float): int =
  ## Writes the comparison into `output`; 0 when every mimic with a verdict
  ## passes and at least one has one, 1 otherwise.
  let bots = botTeams(botsPath)
  let ladder = ladderTallies(census)
  let mimic = mimicTallies(results, bots)
  var teams: seq[int]
  for _, team in bots:
    if team notin teams: teams.add team
  teams.sort()
  createDir(output)
  var tsv = "team\tother\tladder_games\tladder_score\tmimic_games\tmimic_score\tdifference\n"
  var md = "# Mimic likeness\n\nEach mimic's score against another team's mimic beside its team's ladder " &
    "score against that team, over pairs with at least " & $minGames & " ladder games that the mimics played. " &
    "A mimic passes when its mean absolute difference is at most " & formatFloat(bar, ffDecimal, 2) & ".\n\n" &
    "| Team | Pairs counted | Mean difference | Verdict |\n| ---: | ---: | ---: | --- |\n"
  var verdicts, passes = 0
  for team in teams:
    var total = 0.0
    var counted = 0
    for other in teams:
      if other == team: continue
      let l = ladder.getOrDefault((team, other))
      let m = mimic.getOrDefault((team, other))
      let difference = if l.games >= minGames and m.games > 0: abs(m.score - l.score) else: NaN
      tsv.add [$team, $other, $l.games, formatFloat(l.score, ffDecimal, 4), $m.games,
               formatFloat(m.score, ffDecimal, 4), formatFloat(difference, ffDecimal, 4)].join("\t") & "\n"
      if not difference.isNaN:
        total += difference
        counted += 1
    let mean = if counted > 0: total / counted.float else: NaN
    let verdict = if counted == 0: "no pair counted" elif mean <= bar: "passes" else: "fails"
    if counted > 0:
      verdicts += 1
      if mean <= bar: passes += 1
    md.add "| " & $team & " | " & $counted & " | " & (if counted > 0: formatFloat(mean, ffDecimal, 3) else: "-") &
      " | " & verdict & " |\n"
  writeFile(output / "likeness.tsv", tsv)
  writeFile(output / "likeness.md", md)
  stdout.write md
  if verdicts > 0 and passes == verdicts: 0 else: 1
