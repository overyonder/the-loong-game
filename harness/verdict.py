"""Decide whether a candidate bot is better than the baseline it changes.

    python3 -m harness.verdict --candidate tactics-coil --baseline roles-bot --behaviour Coil \\
        --maps maps/*.map --seeds 4 --output results/coil

Every game is paired. The candidate plays the baseline on each map, side and seed, and the
same game is played with the baseline in the candidate's seat. Seeded games are
deterministic, so where the change never fires the two games are identical and cancel out.
Only pairs whose result changed count, each weighted by the share of the candidate's turns
in which the changed behaviour was active, as the bot reports it in its indicator.

The p values come from random sign flips of those weighted changes: how often a coin
deciding each change's direction does at least as well. The candidate and baseline also play
each weak bot on the same seeds. A candidate that loses more games to weak bots than it wins
back isn't better, however it does head to head, and one that loses significantly more is worse.
Every such loss is listed. Wins are compared by length too.
"""

import argparse
import hashlib
import json
import os
import random
import re
import statistics
from dataclasses import asdict
from pathlib import Path

from harness.round_robin import PlayedGame, ScheduledGame, build_each_bot_once, run_games_in_parallel

# A dragon's turn in `unswbc run -v`: its stdout, up to the next line the toolkit writes.
TURN = re.compile(r"^round \d+: bot \d+ \(team (?P<team>[AB])\) stdout:\n(?P<output>(?:(?!round \d).*\n)*)", re.M)
INDICATOR = re.compile(r"^INDICATOR (.*)$", re.M)


def paired_seed(base_seed: str, map_path: str, repeat: int) -> str:
    """The same seed for every game on one map and repeat, whichever bots play it."""
    return "0x" + hashlib.sha256(f"{base_seed}/{map_path}/{repeat}".encode()).digest()[:8].hex()


def score(game: PlayedGame, side: str) -> float | None:
    if game.error:
        return None
    return 0.5 if game.winner is None else float(game.winner == side)


def activation(game: PlayedGame, side: str, behaviours: list[str]) -> float:
    """Share of the side's dragon-turns whose indicator names one of the behaviours."""
    turns = [" ".join(INDICATOR.findall(match["output"]))
             for match in TURN.finditer(Path(game.log_path).read_text(errors="replace")) if match["team"] == side]
    if not turns:
        return 0.0
    return sum(any(word in turn.split() for word in behaviours) for turn in turns) / len(turns)


def sign_flip_p_values(changes: list[float], trials: int = 200_000) -> tuple[float, float]:
    """P(a random sign on each change sums to at least, and at most, the observed total)."""
    changes = [change for change in changes if change]
    if not changes:
        return 1.0, 1.0
    observed = sum(changes)
    magnitudes = [abs(change) for change in changes]
    generator = random.Random(0)
    at_least = at_most = 0
    for _ in range(trials):
        total = sum(magnitude if generator.random() < 0.5 else -magnitude for magnitude in magnitudes)
        at_least += total >= observed - 1e-12
        at_most += total <= observed + 1e-12
    return at_least / trials, at_most / trials


def changed_games_needed(gained: int, dropped: int, significance: float) -> int | None:
    """Changed games needed to tell this gained share from an even one with 80% power."""
    if gained + dropped == 0 or gained == dropped:
        return None
    share = gained / (gained + dropped)
    z_significance = statistics.NormalDist().inv_cdf(1 - significance)
    z_power = statistics.NormalDist().inv_cdf(0.8)
    spread = z_significance * 0.5 + z_power * (share * (1 - share)) ** 0.5
    return int(-(-(spread / abs(share - 0.5)) ** 2 // 1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--behaviour", nargs="*", default=[],
                        help="indicator words naming the changed behaviour; without them every changed pair counts fully")
    parser.add_argument("--weak", nargs="*", default=["starter-c", "starter-py"])
    parser.add_argument("--maps", nargs="+", required=True)
    parser.add_argument("--seeds", type=int, default=4, help="games per map and side")
    parser.add_argument("--base-seed", default="loong")
    parser.add_argument("--significance", type=float, default=0.05)
    parser.add_argument("--workers", type=int, default=os.cpu_count())
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    candidate, baseline = arguments.candidate, arguments.baseline
    # A bot never counts as a weak opponent of itself: its games are already head to head.
    arguments.weak = [bot for bot in arguments.weak if bot not in (candidate, baseline)]

    # For each map, repeat and opponent: the candidate's game from each side, and the baseline's.
    fixtures = [(map_path, repeat, opponent, side)
                for map_path in arguments.maps for repeat in range(arguments.seeds)
                for opponent in [baseline, *arguments.weak] for side in "AB"]
    schedule, index = [], {}
    for map_path, repeat, opponent, side in fixtures:
        seed = paired_seed(arguments.base_seed, map_path, repeat)
        for bot in (candidate, baseline):
            teams = (bot, opponent) if side == "A" else (opponent, bot)
            key = (*teams, map_path, seed)
            if key not in index:  # the baseline's self-play game serves both sides
                index[key] = len(schedule)
                schedule.append(ScheduledGame(*teams, map_path, seed))
    build_each_bot_once(sorted({candidate, baseline, *arguments.weak}), arguments.maps[0])
    games = run_games_in_parallel(schedule, arguments.output, arguments.workers, arguments.timeout, verbose=True)

    def game(bot, opponent, side, map_path, repeat):
        teams = (bot, opponent) if side == "A" else (opponent, bot)
        return games[index[(*teams, map_path, paired_seed(arguments.base_seed, map_path, repeat))]]

    head_to_head, weak_drops, weak_gains, errors = [], [], 0, 0
    faster = slower = 0
    candidate_win_rounds, baseline_win_rounds = [], []
    for map_path, repeat, opponent, side in fixtures:
        mine, theirs = game(candidate, opponent, side, map_path, repeat), game(baseline, opponent, side, map_path, repeat)
        my_score, their_score = score(mine, side), score(theirs, side)
        if my_score is None or their_score is None:
            errors += 1
            continue
        if my_score == 1 == their_score:
            faster += mine.rounds < theirs.rounds
            slower += mine.rounds > theirs.rounds
        if my_score == 1:
            candidate_win_rounds.append((mine.rounds, mine))
        if their_score == 1:
            baseline_win_rounds.append(theirs.rounds)
        if opponent == baseline:
            weight = activation(mine, side, arguments.behaviour) if arguments.behaviour else 1.0
            head_to_head.append({"map": map_path, "repeat": repeat, "side": side,
                                 "change": my_score - their_score, "weight": weight})
        elif my_score < their_score:
            weak_drops.append(mine)
        elif my_score > their_score:
            weak_gains += 1

    weighted = [pair["change"] * pair["weight"] for pair in head_to_head]
    p_better, p_worse = sign_flip_p_values(weighted)
    gained = sum(pair["change"] > 0 for pair in head_to_head)
    dropped = sum(pair["change"] < 0 for pair in head_to_head)
    # Against weak bots every changed game counts in full: none of them should ever be lost.
    _, p_worse_weak = sign_flip_p_values([-1.0] * len(weak_drops) + [1.0] * weak_gains)
    if p_worse < arguments.significance or p_worse_weak < arguments.significance:
        verdict = "worse"
    elif p_better < arguments.significance and len(weak_drops) <= weak_gains:
        verdict = "better"
    else:
        verdict = "undecided"

    # A win far shorter than the rest of the run's wins is worth a look before trusting it.
    rounds = [win_rounds for win_rounds, _ in candidate_win_rounds]
    outliers = []
    if len(rounds) >= 8:
        low, _, high = statistics.quantiles(rounds, n=4)
        outliers = [entry for entry in candidate_win_rounds if entry[0] < low - 1.5 * (high - low)]

    result = {"verdict": verdict, "pairs": len(head_to_head), "gained": gained, "dropped": dropped,
              "p_worse_against_weak_bots": p_worse_weak,
              "weighted_total": sum(weighted), "p_better": p_better, "p_worse": p_worse,
              "weak_drops": [asdict(played) for played in weak_drops], "weak_gains": weak_gains,
              "faster_wins": faster, "slower_wins": slower, "errors": errors,
              "median_rounds_to_win": {candidate: statistics.median(rounds) if rounds else None,
                                       baseline: statistics.median(baseline_win_rounds) if baseline_win_rounds else None},
              "changed_games_needed": changed_games_needed(gained, dropped, arguments.significance),
              "short_win_outliers": [asdict(played) for _, played in outliers], "pairs_detail": head_to_head}
    (arguments.output / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    (arguments.output / "games.json").write_text(json.dumps([asdict(played) for played in games], indent=2) + "\n")

    weighting = f", weighted by {' / '.join(arguments.behaviour)} activation" if arguments.behaviour else ""
    print(f"{candidate} in place of {baseline}: {len(head_to_head)} paired games, "
          f"{gained} gained, {dropped} dropped, {len(head_to_head) - gained - dropped} unchanged{weighting}")
    print(f"chance random signs do this well: {p_better:.4f}   this badly: {p_worse:.4f}")
    print(f"weak bots ({', '.join(arguments.weak)}): {len(weak_drops)} games lost that {baseline} won, "
          f"{weak_gains} won that it lost (chance this badly: {p_worse_weak:.4f})")
    for played in weak_drops[:5]:
        print(f"  lost: {played.team_a_bot} vs {played.team_b_bot} on {Path(played.map_path).stem} seed {played.seed}")
    if len(weak_drops) > 5:
        print(f"  ... and {len(weak_drops) - 5} more, all listed in verdict.json")
    medians = result["median_rounds_to_win"]
    print(f"rounds to win: {candidate} {medians[candidate]}, {baseline} {medians[baseline]}; "
          f"paired wins {faster} faster, {slower} slower")
    for _, played in outliers:
        print(f"  unusually short win: {played.rounds} rounds on {Path(played.map_path).stem} seed {played.seed}")
    if errors:
        print(f"{errors} pairs had an error and don't count")
    needed = changed_games_needed(gained, dropped, arguments.significance)
    print(f"verdict: {verdict}" + (f" (at this rate, about {needed} changed games would settle it)"
                                   if verdict == "undecided" and needed and needed > gained + dropped else ""))


if __name__ == "__main__":
    main()
