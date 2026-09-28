## The verdict's judge when the baseline is also an opponent: its own games put
## it on both sides, so only the recorded side can score them.

import std/[json, options, tables]
import ../[records, verdict]

let plan = %*{"candidate": "cand", "baseline": "base", "opponents": ["base"],
  "effect_elo": 70.0, "alpha": 0.05, "power": 0.8, "cap": 155}
var played: Table[int, Game]
for fixture in 0 ..< 20:
  let side = fixture mod 2
  # The candidate wins its game; the baseline, on the same side of its own game
  # against itself, loses.
  var names = ["base", "base"]
  names[side] = "cand"
  played[2 * fixture] = Game(a: names[0], b: names[1], status: "completed", winner: side,
    seed: newJInt(fixture))
  played[2 * fixture + 1] = Game(a: "base", b: "base", status: "completed", winner: 1 - side,
    seed: newJInt(fixture))
let state = judge(plan, played)
doAssert state.ties["base"] == 0
doAssert state.tests["base"].decision == "better" and state.tests["base"].decidedAt == some(16)
echo "PASS a baseline that is also an opponent is scored by side"
