[group("Evaluation")]
round-robin *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import json
    import os
    import subprocess
    from dataclasses import asdict
    from pathlib import Path

    from harness.round_robin import (
        __doc__,
        run_games_in_parallel,
        schedule_round_robin,
        summarise_standings,
    )


    def main() -> None:
        parser = argparse.ArgumentParser(
            prog="round-robin",
            description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter,
        )
        parser.add_argument(
            "--bots", nargs="+", default=["starter-c", "starter-py", "room-c", "room-py"]
        )
        parser.add_argument(
            "--maps",
            nargs="+",
            default=[str(path) for path in sorted(Path("maps").glob("*.map"))],
        )
        parser.add_argument(
            "--seeds", type=int, default=2, help="games per map and side for each pairing"
        )
        parser.add_argument("--base-seed", default="loong")
        parser.add_argument("--workers", type=int, default=os.cpu_count())
        parser.add_argument(
            "--timeout", type=float, default=600, help="seconds before a game is killed"
        )
        parser.add_argument("--output", type=Path, default=Path("results/round-robin"))
        arguments = parser.parse_args()
        if not arguments.maps:
            parser.error("No maps found; run just setup first or pass --maps")

        schedule = schedule_round_robin(
            arguments.bots, arguments.maps, arguments.seeds, arguments.base_seed
        )
        subprocess.run(
            [
                "just",
                "_prepare-bots",
                min(arguments.maps, key=lambda path: Path(path).stat().st_size),
                *arguments.bots,
            ],
            check=True,
        )
        games = run_games_in_parallel(
            schedule, arguments.output, arguments.workers, arguments.timeout
        )
        standings = summarise_standings(arguments.bots, games)
        (arguments.output / "games.json").write_text(
            json.dumps([asdict(game) for game in games], indent=2) + "\n"
        )
        print(f"{'bot':<16}{'wins':>6}{'draws':>7}{'losses':>8}{'errors':>8}")
        for row in standings:
            print(
                f"{row['bot']:<16}{row['wins']:>6}{row['draws']:>7}{row['losses']:>8}{row['errors']:>8}"
            )
        print(
            f"{len(games)} games, {sum(game.seconds for game in games) / 60:.1f} minutes of games"
        )
        for game in games:
            if game.error:
                print(
                    f"error: {game.team_a_bot} vs {game.team_b_bot} on {game.map_path} seed {game.seed}: {game.error}"
                )


    main()

[group("Evaluation")]
verdict *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import json
    import os
    import statistics
    import subprocess
    from dataclasses import asdict
    from pathlib import Path

    from harness.round_robin import ScheduledGame, run_games_in_parallel
    from harness.verdict import (
        __doc__,
        activation,
        changed_games_needed,
        paired_seed,
        score,
        sign_flip_p_values,
    )


    def main() -> None:
        parser = argparse.ArgumentParser(
            prog="verdict",
            description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter,
        )
        parser.add_argument("--candidate", required=True)
        parser.add_argument("--baseline", required=True)
        parser.add_argument(
            "--behaviour",
            nargs="*",
            default=[],
            help="indicator words naming the changed behaviour; without them every changed pair counts fully",
        )
        parser.add_argument("--weak", nargs="*", default=["starter-c", "starter-py"])
        parser.add_argument(
            "--maps",
            nargs="+",
            default=[str(path) for path in sorted(Path("maps").glob("*.map"))],
        )
        parser.add_argument("--seeds", type=int, default=4, help="games per map and side")
        parser.add_argument("--base-seed", default="loong")
        parser.add_argument("--significance", type=float, default=0.05)
        parser.add_argument("--workers", type=int, default=os.cpu_count())
        parser.add_argument("--timeout", type=float, default=600)
        parser.add_argument("--output", type=Path, default=Path("results/verdict"))
        arguments = parser.parse_args()
        if not arguments.maps:
            parser.error("No maps found; run just setup first or pass --maps")
        candidate, baseline = arguments.candidate, arguments.baseline
        # A bot never counts as a weak opponent of itself: its games are already head to head.
        arguments.weak = [bot for bot in arguments.weak if bot not in (candidate, baseline)]

        # For each map, repeat and opponent: the candidate's game from each side, and the baseline's.
        fixtures = [
            (map_path, repeat, opponent, side)
            for map_path in arguments.maps
            for repeat in range(arguments.seeds)
            for opponent in [baseline, *arguments.weak]
            for side in "AB"
        ]
        schedule, index = [], {}
        for map_path, repeat, opponent, side in fixtures:
            seed = paired_seed(arguments.base_seed, map_path, repeat)
            for bot in (candidate, baseline):
                teams = (bot, opponent) if side == "A" else (opponent, bot)
                key = (*teams, map_path, seed)
                if key not in index:  # the baseline's self-play game serves both sides
                    index[key] = len(schedule)
                    schedule.append(ScheduledGame(*teams, map_path, seed))
        subprocess.run(
            [
                "just",
                "_prepare-bots",
                arguments.maps[0],
                *sorted({candidate, baseline, *arguments.weak}),
            ],
            check=True,
        )
        games = run_games_in_parallel(
            schedule, arguments.output, arguments.workers, arguments.timeout, verbose=True
        )

        def game(bot, opponent, side, map_path, repeat):
            teams = (bot, opponent) if side == "A" else (opponent, bot)
            return games[
                index[
                    (*teams, map_path, paired_seed(arguments.base_seed, map_path, repeat))
                ]
            ]

        head_to_head, weak_drops, weak_gains, errors = [], [], 0, 0
        faster = slower = 0
        candidate_win_rounds, baseline_win_rounds = [], []
        for map_path, repeat, opponent, side in fixtures:
            mine, theirs = (
                game(candidate, opponent, side, map_path, repeat),
                game(baseline, opponent, side, map_path, repeat),
            )
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
                weight = (
                    activation(mine, side, arguments.behaviour)
                    if arguments.behaviour
                    else 1.0
                )
                head_to_head.append(
                    {
                        "map": map_path,
                        "repeat": repeat,
                        "side": side,
                        "change": my_score - their_score,
                        "weight": weight,
                    }
                )
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
            outliers = [
                entry
                for entry in candidate_win_rounds
                if entry[0] < low - 1.5 * (high - low)
            ]

        result = {
            "verdict": verdict,
            "pairs": len(head_to_head),
            "gained": gained,
            "dropped": dropped,
            "p_worse_against_weak_bots": p_worse_weak,
            "weighted_total": sum(weighted),
            "p_better": p_better,
            "p_worse": p_worse,
            "weak_drops": [asdict(played) for played in weak_drops],
            "weak_gains": weak_gains,
            "faster_wins": faster,
            "slower_wins": slower,
            "errors": errors,
            "median_rounds_to_win": {
                candidate: statistics.median(rounds) if rounds else None,
                baseline: statistics.median(baseline_win_rounds)
                if baseline_win_rounds
                else None,
            },
            "changed_games_needed": changed_games_needed(
                gained, dropped, arguments.significance
            ),
            "short_win_outliers": [asdict(played) for _, played in outliers],
            "pairs_detail": head_to_head,
        }
        (arguments.output / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
        (arguments.output / "games.json").write_text(
            json.dumps([asdict(played) for played in games], indent=2) + "\n"
        )

        weighting = (
            f", weighted by {' / '.join(arguments.behaviour)} activation"
            if arguments.behaviour
            else ""
        )
        print(
            f"{candidate} in place of {baseline}: {len(head_to_head)} paired games, "
            f"{gained} gained, {dropped} dropped, {len(head_to_head) - gained - dropped} unchanged{weighting}"
        )
        print(
            f"chance random signs do this well: {p_better:.4f}   this badly: {p_worse:.4f}"
        )
        print(
            f"weak bots ({', '.join(arguments.weak)}): {len(weak_drops)} games lost that {baseline} won, "
            f"{weak_gains} won that it lost (chance this badly: {p_worse_weak:.4f})"
        )
        for played in weak_drops[:5]:
            print(
                f"  lost: {played.team_a_bot} vs {played.team_b_bot} on {Path(played.map_path).stem} seed {played.seed}"
            )
        if len(weak_drops) > 5:
            print(f"  ... and {len(weak_drops) - 5} more, all listed in verdict.json")
        medians = result["median_rounds_to_win"]
        print(
            f"rounds to win: {candidate} {medians[candidate]}, {baseline} {medians[baseline]}; "
            f"paired wins {faster} faster, {slower} slower"
        )
        for _, played in outliers:
            print(
                f"  unusually short win: {played.rounds} rounds on {Path(played.map_path).stem} seed {played.seed}"
            )
        if errors:
            print(f"{errors} pairs had an error and don't count")
        needed = changed_games_needed(gained, dropped, arguments.significance)
        print(
            f"verdict: {verdict}"
            + (
                f" (at this rate, about {needed} changed games would settle it)"
                if verdict == "undecided" and needed and needed > gained + dropped
                else ""
            )
        )


    main()

[group("Evaluation")]
ladder *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import json
    import os
    import subprocess
    from dataclasses import asdict
    from pathlib import Path

    from harness.ladder import __doc__, fit_ratings, head_to_head
    from harness.round_robin import run_games_in_parallel, schedule_round_robin


    def main() -> None:
        parser = argparse.ArgumentParser(
            prog="ladder",
            description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter,
        )
        parser.add_argument(
            "--bots",
            nargs="+",
            default=[
                "starter-c",
                "starter-py",
                "room-c",
                "room-py",
                "room-nim",
                "room-pearls",
            ],
        )
        parser.add_argument(
            "--maps",
            nargs="+",
            default=[str(path) for path in sorted(Path("maps").glob("*.map"))],
        )
        parser.add_argument(
            "--seeds", type=int, default=1, help="games per map and side for each pairing"
        )
        parser.add_argument("--base-seed", default="loong")
        parser.add_argument("--workers", type=int, default=os.cpu_count())
        parser.add_argument("--timeout", type=float, default=600)
        parser.add_argument("--output", type=Path, default=Path("results/ladder"))
        arguments = parser.parse_args()
        if not arguments.maps:
            parser.error("No maps found; run just setup first or pass --maps")

        if "room-nim" in arguments.bots:
            subprocess.run(["just", "room-nim"], check=True)
        games_file = arguments.output / "games.json"
        if games_file.exists():
            # Refit an earlier run without playing it again.
            from harness.round_robin import PlayedGame

            games = [PlayedGame(**game) for game in json.loads(games_file.read_text())]
        else:
            schedule = schedule_round_robin(
                arguments.bots, arguments.maps, arguments.seeds, arguments.base_seed
            )
            subprocess.run(
                [
                    "just",
                    "_prepare-bots",
                    min(arguments.maps, key=lambda path: Path(path).stat().st_size),
                    *arguments.bots,
                ],
                check=True,
            )
            games = run_games_in_parallel(
                schedule, arguments.output, arguments.workers, arguments.timeout
            )
            games_file.write_text(
                json.dumps([asdict(game) for game in games], indent=2) + "\n"
            )

        scores = head_to_head(arguments.bots, games)
        ratings = fit_ratings(arguments.bots, scores)
        ranked = sorted(arguments.bots, key=lambda bot: -ratings[bot])
        (arguments.output / "ratings.json").write_text(
            json.dumps(
                {
                    "ratings": ratings,
                    "head_to_head": {
                        f"{a} vs {b}": score for (a, b), score in scores.items()
                    },
                },
                indent=2,
            )
            + "\n"
        )

        width = max(len(bot) for bot in ranked) + 2
        print(
            f"{'bot':<{width}}{'rating':>7}   "
            + "".join(f"{bot[:11]:>12}" for bot in ranked)
        )
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
        print(
            f"{len(games)} games, {errors} errors, {sum(game.seconds for game in games) / 60:.1f} minutes of games"
        )


    main()

# The organiser owns compilation; prepare caches before parallel games.
[private]
_prepare-bots map +bots:
    #!/usr/bin/env bash
    set -euo pipefail
    map="$1"
    shift
    for bot in "$@"; do
        unswbc run --sandbox --no-replay --seed 0x0 "$map" "$bot" "$bot" >/dev/null
    done

[group("Evaluation")]
mapgen *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import random
    from pathlib import Path

    from harness.mapgen import generate_map, serialise_map

    parser = argparse.ArgumentParser(prog="mapgen")
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--output", type=Path, default=Path("maps-generated"))
    args = parser.parse_args()
    generator = random.Random(args.seed)
    args.output.mkdir(parents=True, exist_ok=True)
    for number in range(1, args.count + 1):
        layout = generate_map(generator, f"Generated {args.seed}-{number:02d}")
        output = args.output / f"gen_{args.seed}_{number:02d}.map"
        output.write_text(serialise_map(layout))
        print(output)
