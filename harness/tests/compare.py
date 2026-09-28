"""Check the sequential judge when the baseline is also an opponent."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from harness.compare import judge, schedule, teams  # noqa: E402

plan = {
    "candidate": "cand",
    "baseline": "base",
    "opponents": ["base"],
    "effect_elo": 70.0,
    "alpha": 0.05,
    "power": 0.8,
    "cap": 155,
    "upset_bot": "starter-c",
    "upset_games": 0,
    "maps": ["maps/arena.map"],
    "seed_start": 0,
}
played = {}
for position, entry in enumerate(schedule(plan)[:40]):
    a, b = teams(entry)
    # The candidate wins each of its games; the baseline loses its own, which it
    # plays against itself, so only the side tells the two apart.
    won = entry["side"] if entry["player"] == "cand" else "AB"[entry["side"] == "A"]
    game = {"A": a, "B": b, "status": "completed", "winner_side": won}
    played[position] = {**game, "map": str(entry["map"]), "seed": entry["seed"]}
state = judge(plan, played)
test = state["tests"]["base"]
assert state["ties"]["base"] == 0, state["ties"]
assert test.decision == "better" and test.decided_at == 16, (
    test.decision,
    test.decided_at,
)
print("PASS a baseline that is also an opponent is scored by side")
