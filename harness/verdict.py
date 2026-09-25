"""Decide whether a candidate bot beats a baseline, with an exact sign test.

    python3 -m harness.verdict --candidate room-pearls --baseline room-c --maps maps/*.map \\
        --seeds 4 --output results/pearls-vs-room

The candidate plays the baseline on every map, from both sides, once per seed.
Draws and errored games don't count towards either bot. The verdict is
"better" or "worse" when a one-sided exact binomial test rejects an even match
at the chosen significance level, and "undecided" otherwise, with an estimate
of how many decisive games the observed win rate would need.
"""

import argparse
import json
import math
import os
from dataclasses import asdict
from pathlib import Path

from harness.round_robin import build_each_bot_once, run_games_in_parallel, schedule_round_robin

Z_ONE_SIDED = {0.05: 1.645, 0.01: 2.326}
Z_POWER_80  = 0.842


def probability_of_at_least(wins: int, games: int) -> float:
    """P(X >= wins) for X ~ Binomial(games, 1/2): the chance an even match does this well."""
    return sum(math.comb(games, k) for k in range(wins, games + 1)) / 2**games


def decisive_games_needed(win_rate: float, significance: float) -> int | None:
    """Games needed to detect this win rate against 50% with 80% power."""
    if win_rate == 0.5:
        return None
    effect = abs(win_rate - 0.5)
    spread = Z_ONE_SIDED[significance] * 0.5 + Z_POWER_80 * math.sqrt(win_rate * (1 - win_rate))
    return math.ceil((spread / effect) ** 2)


def decide(candidate_wins: int, candidate_losses: int, significance: float) -> dict:
    decisive = candidate_wins + candidate_losses
    p_better = probability_of_at_least(candidate_wins, decisive)
    p_worse = probability_of_at_least(candidate_losses, decisive)
    verdict = "better" if p_better < significance else "worse" if p_worse < significance else "undecided"
    win_rate = candidate_wins / decisive if decisive else 0.5
    return {"verdict": verdict, "wins": candidate_wins, "losses": candidate_losses,
            "p_better": p_better, "p_worse": p_worse, "win_rate": win_rate,
            "decisive_games_needed": decisive_games_needed(win_rate, significance)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--maps", nargs="+", required=True)
    parser.add_argument("--seeds", type=int, default=4, help="games per map and side")
    parser.add_argument("--base-seed", default="loong")
    parser.add_argument("--significance", type=float, choices=sorted(Z_ONE_SIDED), default=0.05)
    parser.add_argument("--workers", type=int, default=os.cpu_count())
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    schedule = schedule_round_robin([arguments.candidate, arguments.baseline], arguments.maps,
                                    arguments.seeds, arguments.base_seed)
    build_each_bot_once([arguments.candidate, arguments.baseline], arguments.maps[0])
    games = run_games_in_parallel(schedule, arguments.output, arguments.workers, arguments.timeout)
    wins = sum(1 for game in games if not game.error and game.winner and
               (game.team_a_bot if game.winner == "A" else game.team_b_bot) == arguments.candidate)
    losses = sum(1 for game in games if not game.error and game.winner and
                 (game.team_a_bot if game.winner == "A" else game.team_b_bot) == arguments.baseline)
    draws = sum(1 for game in games if not game.error and game.winner is None)
    errors = sum(1 for game in games if game.error)
    result = decide(wins, losses, arguments.significance) | {"draws": draws, "errors": errors, "games": len(games)}
    (arguments.output / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    (arguments.output / "games.json").write_text(json.dumps([asdict(game) for game in games], indent=2) + "\n")
    print(f"{arguments.candidate} against {arguments.baseline}: {wins} wins, {losses} losses, {draws} draws, {errors} errors")
    print(f"chance an even match does this well: {result['p_better']:.4f}   this badly: {result['p_worse']:.4f}")
    needed = result["decisive_games_needed"]
    print(f"verdict: {result['verdict']}" + ("" if result["verdict"] != "undecided" or needed is None
          else f" (at a {result['win_rate']:.0%} win rate, about {needed} decisive games would settle it)"))


if __name__ == "__main__":
    main()
