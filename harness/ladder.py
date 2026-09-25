"""Rate a pool of bots against each other from one round robin.

    python3 -m harness.ladder --bots starter-c room-c first-bot --maps maps/*.map \\
        --seeds 1 --output results/ladder

Every pair plays on every map from both sides, through the round-robin harness.
The ratings are then fitted to all the games at once (a Bradley-Terry model),
so they don't depend on the order the games were played in. They're printed on
the Elo scale: 400 points is ten-to-one odds. Draws count as half a win each way,
and errors are left out. The table of head-to-head results is printed too,
because a single rating can hide a pool where A beats B, B beats C and C beats A.
"""

import argparse
import json
import math
import os
from dataclasses import asdict
from pathlib import Path

from harness.round_robin import build_each_bot_once, run_games_in_parallel, schedule_round_robin

ELO_SCALE = 400 / math.log(10)


def head_to_head(bots: list[str], games: list) -> dict[tuple[str, str], float]:
    """Points each bot scored against each other bot: 1 for a win, 1/2 for a draw."""
    scores = {(a, b): 0.0 for a in bots for b in bots if a != b}
    for game in games:
        if game.error:
            continue
        a, b = game.team_a_bot, game.team_b_bot
        if game.winner is None:
            scores[a, b] += 0.5
            scores[b, a] += 0.5
        else:
            winner, loser = (a, b) if game.winner == "A" else (b, a)
            scores[winner, loser] += 1
    return scores


def fit_ratings(bots: list[str], scores: dict[tuple[str, str], float], iterations: int = 2000) -> dict[str, float]:
    """Bradley-Terry strengths by the classic minorisation-maximisation update,
    with a small prior of one draw against an average bot, so a bot that won or
    lost every game still gets a finite rating."""
    strength = dict.fromkeys(bots, 1.0)
    for _ in range(iterations):
        updated = {}
        for bot in bots:
            points = 0.5 + sum(scores[bot, other] for other in bots if other != bot)
            weight = 1 / (strength[bot] + 1)
            for other in bots:
                if other != bot:
                    games = scores[bot, other] + scores[other, bot]
                    weight += games / (strength[bot] + strength[other])
            updated[bot] = points / weight
        # Keep the average strength at 1, which puts the average rating at 1500.
        mean_log = sum(math.log(value) for value in updated.values()) / len(bots)
        strength = {bot: value / math.exp(mean_log) for bot, value in updated.items()}
    return {bot: 1500 + ELO_SCALE * math.log(strength[bot]) for bot in bots}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bots", nargs="+", required=True)
    parser.add_argument("--maps", nargs="+", required=True)
    parser.add_argument("--seeds", type=int, default=1, help="games per map and side for each pairing")
    parser.add_argument("--base-seed", default="loong")
    parser.add_argument("--workers", type=int, default=os.cpu_count())
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    games_file = arguments.output / "games.json"
    if games_file.exists():
        # Refit an earlier run without playing it again.
        from harness.round_robin import PlayedGame
        games = [PlayedGame(**game) for game in json.loads(games_file.read_text())]
    else:
        schedule = schedule_round_robin(arguments.bots, arguments.maps, arguments.seeds, arguments.base_seed)
        build_each_bot_once(arguments.bots, min(arguments.maps, key=lambda path: Path(path).stat().st_size))
        games = run_games_in_parallel(schedule, arguments.output, arguments.workers, arguments.timeout)
        games_file.write_text(json.dumps([asdict(game) for game in games], indent=2) + "\n")

    scores = head_to_head(arguments.bots, games)
    ratings = fit_ratings(arguments.bots, scores)
    ranked = sorted(arguments.bots, key=lambda bot: -ratings[bot])
    (arguments.output / "ratings.json").write_text(json.dumps(
        {"ratings": ratings, "head_to_head": {f"{a} vs {b}": score for (a, b), score in scores.items()}},
        indent=2) + "\n")

    width = max(len(bot) for bot in ranked) + 2
    print(f"{'bot':<{width}}{'rating':>7}   " + "".join(f"{bot[:11]:>12}" for bot in ranked))
    for bot in ranked:
        cells = []
        for other in ranked:
            if other == bot:
                cells.append(f"{'·':>12}")
            else:
                played = scores[bot, other] + scores[other, bot]
                cells.append(f"{scores[bot, other]:>6g}/{played:<5g}")
        print(f"{bot:<{width}}{ratings[bot]:>7.0f}   " + "".join(cells))
    errors = sum(1 for game in games if game.error)
    print(f"{len(games)} games, {errors} errors, {sum(game.seconds for game in games) / 60:.1f} minutes of games")


if __name__ == "__main__":
    main()
