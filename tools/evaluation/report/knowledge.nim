## `loong-report knowledge`, and the Knowledge section of summary.md: how well
## each team knew its world, from the `knowledge` columns
## (tools/gamedata/format.md) that `just knowledge` writes beside a game's log.
## The viewer owns the measures and grades every fact
## (tools/viewer/knowledge.odin); nothing here rebuilds a dragon.
##
## Every measure is a ratio of sums over rounds and games, so a round with more
## dragons and facts weighs more:
## - Connectivity: the share of the other graded dragons stating each stated
##   fact too; beside it, the dragons sharing at least half of what they state.
## - Agreement: pairs of dragons stating one fact that agree; beside it, the
##   dragons in a contradiction.
## - Coverage: facts anyone states of those that exist; beside it, each
##   dragon's share of those it could state.
## - Validity: stated facts that are true; beside it, the facts two or more
##   dragons state that are false for most of them.

import std/[algorithm, json, os, sequtils, strutils, tables]
import ../../gamedata/columns
import records

const
  Checkpoints* = [100, 250, 400, 480]   ## Rounds a game's own table shows.
  Measures = ["Connectivity", "Agreement", "Coverage", "Validity"]

type
  Tally* = object
    ## One belief's sums over some rounds of one team.
    dragons*, possible*, capacity*, facts*, correct*, covered*, known*,
      sharable*, shared*, linkable*,
      linked*, comparisons*, conflicts*, disputing*, agreed*, misled*: float

  Knowledge* = object
    ## A game's knowledge file: per team, round and belief, its sums.
    beliefs*: seq[string]
    rounds*: array[2, Table[int, OrderedTable[string, Tally]]]

proc add(total: var Tally, part: Tally) =
  for name, value in total.fieldPairs:
    for other, amount in part.fieldPairs:
      when name == other: value += amount

proc ratio(part, whole: float): float = (if whole > 0: part / whole else: -1.0)

proc percent(share: float): string =
  if share < 0: "–" else: $int(share * 100 + 0.5) & "%"

proc measures*(tally: Tally): array[4, (float, float)] =
  ## Each measure and its second figure, as shares; -1 where nothing was there.
  let agreement = ratio(tally.comparisons - tally.conflicts, tally.comparisons)
  [(ratio(tally.shared, tally.sharable), ratio(tally.linked, tally.linkable)),
   (agreement, ratio(tally.disputing, tally.linkable)),
   (ratio(tally.known, tally.possible), ratio(tally.covered, tally.capacity)),
   (ratio(tally.correct, tally.facts), ratio(tally.misled, tally.agreed))]

proc cells(tally: Tally): seq[string] =
  let values = measures(tally)
  @[percent(values[0][0]) & " (" & percent(values[0][1]) & " share)",
    percent(values[1][0]) & " (" & percent(values[1][1]) & " disputing)",
    percent(values[2][0]) & " (each " & percent(values[2][1]) & ")",
    percent(values[3][0]) & " (" & percent(values[3][1]) & " misled)"]

proc knowledgePath*(game: Game): string =
  ## Where `just knowledge` writes a game's record: beside its log.
  let (directory, name, _) = game.log.splitFile
  directory / (name & ".knowledge.cols")

proc readKnowledge*(path: string): Knowledge =
  var file = openColumnsFile(path)
  defer: file.closeColumnsFile()
  for row in 0 ..< file.rowCount("enum.category"):
    result.beliefs.add file.stringRow("enum.category", row)
  for row in 0 ..< file.rowCount("row.round"):
    proc at(name: string): float = file.numberAt("row." & name, row)
    let tally = Tally(dragons: at("dragons"), possible: at("possible"),
      capacity: at("dragons") * at("each"), facts: at("facts"),
      correct: at("correct"), covered: at("covered"), known: at("known"),
      sharable: at("sharable"), shared: at("shared"), linkable: at("linkable"),
      linked: at("linked"), comparisons: at("comparisons"),
      conflicts: at("conflicts"), disputing: at("disputing"),
      agreed: at("agreed"), misled: at("misled"))
    let team = int(at("team")) and 1
    let belief = result.beliefs[int(at("category"))]
    result.rounds[team].mgetOrPut(int(at("round")), initOrderedTable[string, Tally]())[belief] = tally

proc pooled*(knowledge: Knowledge, team: int, first = 0, last = high(int)): OrderedTable[string, Tally] =
  ## A team's sums per belief over rounds `first` to `last`.
  var rounds: seq[int]
  for round in knowledge.rounds[team].keys: rounds.add round
  rounds.sort
  for belief in knowledge.beliefs:
    for round in rounds:
      if round < first or round > last: continue
      if belief in knowledge.rounds[team][round]:
        result.mgetOrPut(belief, Tally()).add knowledge.rounds[team][round][belief]

proc table(beliefs: OrderedTable[string, Tally]): seq[string] =
  result = @["| Belief | " & Measures.join(" | ") & " |", "| --- | --- | --- | --- | --- |"]
  for belief, tally in beliefs:
    result.add "| " & belief & " | " & cells(tally).join(" | ") & " |"

proc gameSection(game: Game, knowledge: Knowledge): seq[string] =
  ## One game's knowledge, each rebuilt team pooled over the game, then at
  ## each checkpoint round.
  var shown = game.map
  shown.removeSuffix(".map")
  result.add "## `" & game.a & "` (A) against `" & game.b & "` (B), " & shown & ", seed " & $game.seed
  for team in 0 .. 1:
    if knowledge.rounds[team].len == 0: continue
    result.add ["", "### `" & [game.a, game.b][team] & "`, team " & "AB"[team], ""]
    result.add table(pooled(knowledge, team))
    result.add ["", "At the end of rounds " & Checkpoints.join(", ") &
      ": connectivity · agreement · coverage · validity.", "",
      "| Belief | " & Checkpoints.mapIt("r" & $it).join(" | ") & " |",
      "| --- |" & " --- |".repeat(Checkpoints.len)]
    for belief in knowledge.beliefs:
      var row = "| " & belief & " |"
      var any = false
      for round in Checkpoints:
        let at = knowledge.rounds[team].getOrDefault(round)
        if belief in at:
          any = true
          let values = measures(at[belief])
          row &= " " & percent(values[0][0]) & " · " & percent(values[1][0]) & " · " &
            percent(values[2][0]) & " · " & percent(values[3][0]) & " |"
        else: row &= " – |"
      if any: result.add row

proc knowledgeCommand*(paths: seq[string]): int =
  ## Every game with a knowledge record under the result directories.
  var shown = 0
  for game in loadGames(paths):
    let path = knowledgePath(game)
    if not fileExists(path): continue
    if shown > 0: echo ""
    echo gameSection(game, readKnowledge(path)).join("\n")
    inc shown
  if shown == 0:
    stderr.writeLine "No knowledge records: run `just knowledge RESULT_DIR` first"
    return 1

proc knowledgeSection*(candidate: string, opponents: seq[string],
    mine: OrderedTable[string, seq[Game]]): seq[string] =
  ## Summary.md's Knowledge section for one candidate: each side's knowledge
  ## per belief, pooled over every round of the games with a record. Empty
  ## when no game has one.
  var recorded, total = 0
  for opponent in opponents:
    for game in mine[opponent]:
      inc total
      if fileExists(knowledgePath(game)): inc recorded
  if recorded == 0: return
  result.add "Team knowledge from `just knowledge`, pooled over every round of " &
    $recorded & " of " & $total & " games (tools/evaluation/README.md, Team knowledge)."
  for opponent in opponents:
    var sides: array[2, OrderedTable[string, Tally]]
    var games = 0
    for game in mine[opponent]:
      let path = knowledgePath(game)
      if not fileExists(path): continue
      inc games
      let knowledge = readKnowledge(path)
      let ours = if game.a == candidate: 0 else: 1
      for (side, team) in [(0, ours), (1, 1 - ours)]:
        for belief, tally in pooled(knowledge, team):
          sides[side].mgetOrPut(belief, Tally()).add tally
    if games == 0: continue
    for (side, bot) in [(0, candidate), (1, opponent)]:
      if sides[side].len == 0: continue
      result.add ["", "### `" & bot.rsplit('/', 1)[^1] & "` against `" &
        [opponent, candidate][side].rsplit('/', 1)[^1] & "`, " & $games & " games", ""]
      result.add table(sides[side])
