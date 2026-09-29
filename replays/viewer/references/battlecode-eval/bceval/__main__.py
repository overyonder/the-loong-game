"""python -m bceval GAME.replay [--every N] [--json]"""
import argparse
import json

from . import evaluate_replay, replay_features


def main():
    ap = argparse.ArgumentParser(prog="python -m bceval", description="Win probability per round of a Battlecode replay.")
    ap.add_argument("replay")
    ap.add_argument("--every", type=int, default=10, help="score every N rounds (default 10)")
    ap.add_argument("--json", action="store_true", help="print JSON, with the log-odds split into groups")
    a = ap.parse_args()
    rows = evaluate_replay(a.replay, a.every)
    if a.json:
        print(json.dumps(rows))
        return
    game, _ = replay_features(a.replay, 500)
    print("map %s   A: %s   B: %s   winner: %s (%s, round %d)" % (
        game["map"] or "?", game["bot_a"], game["bot_b"], game["winner"] or "draw", game["end"], game["last_round"]))
    print("after round   P(A wins)   P(B wins)")
    for r in rows:
        bar = "#" * round(r["p_a"] * 40)
        print("%11d   %9.3f   %9.3f   %s" % (r["after_round"], r["p_a"], 1 - r["p_a"], bar))


if __name__ == "__main__":
    main()
