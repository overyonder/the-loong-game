## The verdict's judge on the cases compare.judge's test covers, in both forms.

import std/[json, options, tables]
import ../[records, verdict]

block baselineAsOpponent:
  # The baseline's own games put it on both sides, so only the recorded side
  # can score them. The candidate wins every fixture; the baseline, on the same
  # side of its game against itself, loses.
  let plan = %*{"candidate": "cand", "baseline": "base", "opponents": ["base"],
    "effect_elo": 70.0, "alpha": 0.05, "power": 0.8, "cap": 155, "upset_games": 0}
  var played: Table[int, Game]
  var order: seq[ScheduleEntry]
  for fixture in 0 ..< 20:
    let side = fixture mod 2
    var names = ["base", "base"]
    names[side] = "cand"
    order.add ScheduleEntry(opponent: "base", player: "cand", side: side, fixture: fixture)
    order.add ScheduleEntry(opponent: "base", player: "base", side: side, fixture: fixture)
    played[2 * fixture] = Game(a: names[0], b: names[1], status: "completed", winner: side)
    played[2 * fixture + 1] = Game(a: "base", b: "base", status: "completed", winner: 1 - side)
  let state = judge(plan, played, order)
  doAssert state.ties["base"] == 0
  doAssert state.tests["base"].decision == "better" and state.tests["base"].decidedAt == some(16)
  echo "PASS a baseline that is also an opponent is scored by side"

block decidedOpponentLeavesGaps:
  # Once `quick` decides, its later positions are never played; `slow`, won three
  # games in four, must keep reading past those gaps.
  let plan = %*{"candidate": "cand", "baseline": nil, "opponents": ["quick", "slow"],
    "effect_elo": 70.0, "alpha": 0.05, "power": 0.8, "cap": 155, "upset_games": 0}
  var played: Table[int, Game]
  var order: seq[ScheduleEntry]
  var quick, slow = 0
  for position in 0 ..< 400:
    let opponent = if position mod 4 < 2: "quick" else: "slow"
    let side = position mod 2
    order.add ScheduleEntry(opponent: opponent, player: "cand", side: side, fixture: position)
    var names = [opponent, opponent]
    names[side] = "cand"
    var winner = side
    if opponent == "quick":
      if quick >= 16: continue
      inc quick
    else:
      inc slow
      if slow mod 4 == 0: winner = 1 - side
    played[position] = Game(a: names[0], b: names[1], status: "completed", winner: winner)
  let state = judge(plan, played, order)
  doAssert state.tests["quick"].decision == "better", state.tests["quick"].decision
  doAssert state.tests["slow"].decision == "better", state.tests["slow"].decision
  echo "PASS a decided opponent's unplayed positions don't freeze the other tests"

block margin:
  # The non-inferiority form, as compare.py's test has it: straight wins over
  # `weak` show the candidate not worse by the margin, straight losses to
  # `strong` show it worse.
  let plan = %*{"candidate": "cand", "baseline": nil, "opponents": ["weak", "strong"],
    "margin_elo": 70.0, "alpha": 0.05, "power": 0.8, "cap": 153, "upset_games": 0}
  var played: Table[int, Game]
  var order: seq[ScheduleEntry]
  for position in 0 ..< 60:
    let opponent = if position mod 4 < 2: "weak" else: "strong"
    let side = position mod 2
    order.add ScheduleEntry(opponent: opponent, player: "cand", side: side, fixture: position)
    var names = [opponent, opponent]
    names[side] = "cand"
    let winner = if opponent == "weak": side else: 1 - side
    played[position] = Game(a: names[0], b: names[1], status: "completed", winner: winner)
  let state = judge(plan, played, order)
  doAssert state.tests["weak"].decision == "not worse" and state.tests["weak"].decidedAt == some(13)
  doAssert state.tests["strong"].decision == "worse" and state.tests["strong"].decidedAt == some(9)
  echo "PASS a margin test decides not worse and worse"

block marginMatched:
  # With a baseline the margin test reads matched pairs: the candidate losing
  # every fixture its baseline wins is worse.
  let plan = %*{"candidate": "cand", "baseline": "base", "opponents": ["opp"],
    "margin_elo": 70.0, "alpha": 0.05, "power": 0.8, "cap": 153, "upset_games": 0}
  var played: Table[int, Game]
  var order: seq[ScheduleEntry]
  for fixture in 0 ..< 20:
    let side = fixture mod 2
    for (index, player) in [(0, "cand"), (1, "base")]:
      order.add ScheduleEntry(opponent: "opp", player: player, side: side, fixture: fixture)
      var names = ["opp", "opp"]
      names[side] = player
      let winner = if player == "base": side else: 1 - side
      played[2 * fixture + index] = Game(a: names[0], b: names[1], status: "completed", winner: winner)
  let test = judge(plan, played, order).tests["opp"]
  doAssert test.decision == "worse" and test.decidedAt == some(9)
  echo "PASS a margin test reads matched pairs"
