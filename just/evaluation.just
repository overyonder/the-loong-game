# Run the pinned Battlecode CLI and retain each game's evidence.
[group("Evaluation")]
round-robin *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import itertools
    import time
    import zlib
    from concurrent.futures import ThreadPoolExecutor
    from datetime import UTC, datetime
    from pathlib import Path

    from harness import toolkit
    from harness.parallel import cpu_workers, match_verbosity, prepare_bots
    from harness.tournament import (
        __doc__,
        discover_bots,
        forget_game,
        game_id,
        read_outcome,
        reusable_games,
        run_game,
        save_results,
    )


    def main() -> int:
        parser = argparse.ArgumentParser(prog="round-robin", description=__doc__)
        parser.add_argument(
            "--bots",
            nargs="+",
            default=["starter-c", "starter-py", "room-c", "room-py"],
            help="Bot directories",
        )
        parser.add_argument(
            "--maps",
            nargs="+",
            default=[str(path) for path in sorted(Path("maps").glob("*.map"))],
        )
        parser.add_argument(
            "--sandbox", action="store_true", help="Play in the judge's sandbox"
        )
        parser.add_argument(
            "--dry-run", action="store_true", help="Print the schedule without running"
        )
        parser.add_argument(
            "--output",
            type=Path,
            help="Final result directory; an existing one is resumed, playing again "
            "only the games that did not complete",
        )
        parser.add_argument(
            "--timeout", type=float, default=600, help="Seconds per match (default: 600)"
        )
        parser.add_argument("--workers", type=int, default=cpu_workers())
        parser.add_argument(
            "--seeds",
            type=int,
            default=0,
            help="Seeded games per map and side; 0 leaves seeding random",
        )
        parser.add_argument(
            "--seed-start", type=int, default=0, help="Index of the first seed per map"
        )
        args = parser.parse_args()
        selected = args.bots
        # Naming one bot twice plays it against itself once per map and seed.
        self_play = len(selected) == 2 and selected[0] == selected[1]
        if not self_play and (len(set(selected)) != len(selected) or len(selected) < 2):
            parser.error(
                "Select at least two distinct bots, or one bot twice for self-play"
            )
        try:
            bots = discover_bots(list(dict.fromkeys(selected)))
        except ValueError as error:
            parser.error(str(error))
        if args.workers < 1:
            parser.error("workers must be positive")
        if args.timeout <= 0:
            parser.error("--timeout must be positive")
        if not args.maps:
            parser.error("No maps found; run just article-bots first or pass --maps")
        maps = [Path(path).resolve() for path in args.maps]
        if len(set(maps)) != len(maps) or any(not path.is_file() for path in maps):
            parser.error("Maps must be distinct existing files")
        # Seeds depend only on the map and its index, so every pairing and both
        # sides meet the same pearl schedules and results stay reproducible.
        schedule = [
            (map_path, team_a, team_b, seed)
            for map_path in maps
            for seed in (
                [
                    zlib.crc32(f"{map_path.name}:{i}".encode())
                    for i in range(args.seed_start, args.seed_start + args.seeds)
                ]
                or [None]
            )
            for team_a, team_b in (
                [(selected[0], selected[0])]
                if self_play
                else [
                    pair
                    for left, right in itertools.combinations(bots, 2)
                    for pair in ((left, right), (right, left))
                ]
            )
        ]
        for index, (map_path, team_a, team_b, seed) in enumerate(schedule, 1):
            seeded = "" if seed is None else f" seed {seed}"
            print(
                f"{index}: {team_a} (A) vs {team_b} (B) on {map_path.name}{seeded}",
                flush=True,
            )
        if args.dry_run:
            return 0
        directory = args.output or Path("results/round-robin") / datetime.now(UTC).strftime(
            "%Y%m%dT%H%M%S%fZ"
        )
        resumed = (directory / "results.json").is_file()
        if directory.exists() and not resumed:
            parser.error(f"Result directory already exists: {directory}")
        directory.mkdir(parents=True, exist_ok=resumed)
        # A resumed set keeps its completed games and plays the rest again.
        kept = reusable_games(directory)
        keys = [
            game_id({"A": a, "B": b, "map": str(m), "seed": s}) for m, a, b, s in schedule
        ]
        pending = [
            (index, game)
            for index, (game, key) in enumerate(zip(schedule, keys, strict=True), 1)
            if key not in kept
        ]
        report = {
            "workers": args.workers,
            "created_at": datetime.now(UTC).isoformat(),
            "mode": "sandbox" if args.sandbox else "local (10-second turn limit)",
            "status": "running",
            "bots": bots,
            "scheduled_games": len(schedule),
            "games": [kept[key] for key in keys if key in kept],
        }
        save_results(directory, report)
        prepare_bots([Path(name) for name in bots], args.workers, sandbox=args.sandbox)

        def play(item):
            index, (map_path, team_a, team_b, seed) = item
            stem = f"{index:03d}-{Path(team_a).name}-vs-{Path(team_b).name}-{map_path.stem}"
            log_path = directory / f"{stem}.log"
            replay_path = directory / f"{stem}.replay"
            forget_game(directory, log_path.name)
            command = [
                *toolkit.toolkit_match_command(),
                "run",
                *match_verbosity(),
                "-o",
                str(replay_path),
            ]
            if args.sandbox:
                command.append("--sandbox")
            if seed is not None:
                command += ["--seed", str(seed)]
            # The toolkit names each team by its argument, so pass the bot directory.
            command += [str(map_path), team_a, team_b]
            started = time.monotonic()
            returncode, timed_out = run_game(command, log_path, args.timeout)
            outcome = read_outcome(log_path, returncode, timed_out)
            if not replay_path.is_file() and outcome["status"] == "completed":
                outcome.update(status="error", error="Replay was not written")
            return {
                "A": team_a,
                "B": team_b,
                "map": str(map_path),
                "seed": seed,
                "command": command,
                "log": log_path.name,
                "replay": replay_path.name if replay_path.is_file() else None,
                "seconds": round(time.monotonic() - started, 3),
                **outcome,
            }

        try:
            with ThreadPoolExecutor(max_workers=args.workers) as executor:
                for result in executor.map(play, pending):
                    report["games"].append(result)
                    save_results(directory, report)
                    print(
                        f"[{len(report['games'])}/{len(schedule)}] "
                        f"{result['A']} vs {result['B']}: {result['status']}",
                        flush=True,
                    )
        except KeyboardInterrupt:
            report["status"] = "interrupted"
            save_results(directory, report)
            print(f"Interrupted; completed results saved in {directory}")
            return 130
        except (OSError, ValueError, KeyError) as error:
            report["status"] = "error"
            report["error"] = str(error)
            save_results(directory, report)
            raise
        failed = any(game["status"] == "error" for game in report["games"])
        report["status"] = "completed_with_errors" if failed else "completed"
        print(save_results(directory, report))
        print(f"Results: {directory}")
        return int(failed)


    raise SystemExit(main())

# Decide whether a candidate bot is better than the baseline it changes.
[group("Evaluation")]
verdict *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import json
    import os
    import statistics
    import subprocess
    from datetime import UTC, datetime
    from pathlib import Path

    from harness.verdict import (
        __doc__,
        activation,
        changed_games_needed,
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
        parser.add_argument("--significance", type=float, default=0.05)
        parser.add_argument("--workers", type=int, default=os.cpu_count())
        parser.add_argument("--timeout", type=float, default=600)
        parser.add_argument("--output", type=Path)
        arguments = parser.parse_args()
        if not arguments.maps:
            parser.error("No maps found; run just article-bots first or pass --maps")
        candidate, baseline = arguments.candidate, arguments.baseline
        output = arguments.output or Path("results/verdict") / datetime.now(UTC).strftime(
            "%Y%m%dT%H%M%SZ"
        )
        if output.exists():
            parser.error(f"Result directory already exists: {output}")
        # A bot never counts as a weak opponent of itself: its games are already head to head.
        arguments.weak = [bot for bot in arguments.weak if bot not in (candidate, baseline)]
        opponents = [baseline, *arguments.weak]

        # Each bot plays each opponent in its own round robin on the same seeded maps.
        # The baseline's self-play game against itself serves both sides.
        games = {}
        for bot in (candidate, baseline):
            for opponent in opponents:
                directory = output / f"{Path(bot).name}-vs-{Path(opponent).name}"
                completed = subprocess.run(
                    [
                        "just",
                        "round-robin",
                        "--bots",
                        bot,
                        opponent,
                        "--sandbox",
                        "--maps",
                        *arguments.maps,
                        "--seeds",
                        str(arguments.seeds),
                        "--workers",
                        str(arguments.workers),
                        "--timeout",
                        str(arguments.timeout),
                        "--output",
                        str(directory),
                    ],
                    stdout=subprocess.DEVNULL,
                    env={
                        **os.environ,
                        "LOONG_VERBOSE_MATCHES": "1" if arguments.behaviour else "0",
                    },
                    check=False,
                )
                results = directory / "results.json"
                if not results.is_file():
                    raise SystemExit(completed.returncode or 1)
                for played in json.loads(results.read_text())["games"]:
                    played["log"] = str(directory / played["log"])
                    for side, mine in (("A", played["A"]), ("B", played["B"])):
                        if mine == bot:
                            games[bot, opponent, side, played["map"], played["seed"]] = (
                                played
                            )

        fixtures = sorted(
            {(o, side, m, s) for (_, o, side, m, s) in games if o in opponents}
        )
        head_to_head, weak_drops, weak_gains, errors = [], [], 0, 0
        faster = slower = 0
        candidate_win_rounds, baseline_win_rounds = [], []
        for opponent, side, map_path, seed in fixtures:
            mine = games.get((candidate, opponent, side, map_path, seed))
            theirs = games.get((baseline, opponent, side, map_path, seed))
            if mine is None or theirs is None:
                errors += 1
                continue
            my_score, their_score = score(mine, side), score(theirs, side)
            if my_score is None or their_score is None:
                errors += 1
                continue
            if my_score == 1 == their_score:
                faster += mine["rounds"] < theirs["rounds"]
                slower += mine["rounds"] > theirs["rounds"]
            if my_score == 1:
                candidate_win_rounds.append((mine["rounds"], mine))
            if their_score == 1:
                baseline_win_rounds.append(theirs["rounds"])
            if opponent == baseline:
                weight = (
                    activation(Path(mine["log"]), side, arguments.behaviour)
                    if arguments.behaviour
                    else 1.0
                )
                head_to_head.append(
                    {
                        "map": map_path,
                        "seed": seed,
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
            "weak_drops": weak_drops,
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
            "short_win_outliers": [played for _, played in outliers],
            "pairs_detail": head_to_head,
        }
        (output / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")

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
                f"  lost: {played['A']} vs {played['B']} on {Path(played['map']).stem} seed {played['seed']}"
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
                f"  unusually short win: {played['rounds']} rounds on {Path(played['map']).stem} seed {played['seed']}"
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
        print(f"Results: {output}")


    main()

# Rate a pool of bots on a resumable, frozen offline ladder.
[group("Evaluation")]
ladder *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import subprocess
    from pathlib import Path

    from harness.ladder import __doc__, run
    from harness.parallel import cpu_workers


    def main():
        parser = argparse.ArgumentParser(prog="ladder", description=__doc__)
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
            help="Bot directories",
        )
        parser.add_argument(
            "--maps",
            nargs="+",
            default=[str(path) for path in sorted(Path("maps").glob("*.map"))],
        )
        parser.add_argument("--output", type=Path, default=Path("results/ladder"))
        parser.add_argument("--rounds", type=int, default=100)
        parser.add_argument("--workers", type=int, default=cpu_workers())
        parser.add_argument("--resume", action="store_true")
        args = parser.parse_args()
        if args.rounds < 1 or args.workers < 1:
            parser.error("rounds and workers must be positive")
        maps = [Path(path) for path in args.maps]
        if not maps:
            parser.error("No maps found; run just article-bots first or pass --maps")
        if len({path.name for path in maps}) != len(maps) or not all(
            path.is_file() for path in maps
        ):
            parser.error("Maps must be existing files with distinct names")
        if "room-nim" in args.bots and not args.resume:
            subprocess.run(["just", "room-nim"], check=True)
        run(args.output, args.bots, maps, args.rounds, args.workers, args.resume)


    raise SystemExit(main())

# Generate symmetric maps inside the official maps' envelope, or check a directory against it.
[group("Evaluation")]
mapgen *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    from pathlib import Path

    from harness.mapgen import (
        DEFAULT_OUTPUT,
        LANDMARKS,
        OFFICIAL_MAPS,
        ROOT,
        STYLES,
        __doc__,
        generate,
        map_profiles,
        official_envelope,
        profile_table,
    )


    def main() -> int:
        parser = argparse.ArgumentParser(
            prog="mapgen",
            description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter,
        )
        parser.add_argument("--count", type=int, default=20, help="Maps to generate")
        parser.add_argument("--seed", type=int, default=2026, help="Random seed")
        parser.add_argument(
            "--output", type=Path, default=DEFAULT_OUTPUT, help="Directory for the maps"
        )
        parser.add_argument(
            "--check",
            type=Path,
            metavar="DIR",
            help="Report DIR's maps against the official envelope instead of generating",
        )
        parser.add_argument("--size", help="WxH, e.g. 48x24 (default: drawn)")
        parser.add_argument("--sym", choices=["x", "y", "xy"])
        parser.add_argument("--style", choices=sorted(STYLES))
        parser.add_argument("--landmark", choices=[*LANDMARKS, "none"])
        parser.add_argument("--border", choices=["closed", "wrap"])
        parser.add_argument("--dragons", type=int, help="Dragons per side, 1 to 7")
        parser.add_argument("--supply", type=float, help="Target pearls per round")
        parser.add_argument(
            "--candidates", type=int, default=8, help="Worlds judged per map, best kept"
        )
        args = parser.parse_args()
        if not any(OFFICIAL_MAPS.glob("*.map")):
            parser.error("No maps in maps/; run just article-bots first")
        envelope = official_envelope()
        if args.check:
            profiles = map_profiles(args.check)
            print(
                profile_table(
                    {"official": map_profiles(OFFICIAL_MAPS), str(args.check): profiles}
                )
            )
            outside = [
                (p.name, envelope.outside(p)) for p in profiles if envelope.outside(p)
            ]
            for name, measures in outside:
                print(f"outside: {name} {measures}")
            print(f"{len(outside)} of {len(profiles)} maps outside the official envelope")
            return 1 if outside else 0
        settings = {}
        if args.size:
            settings["w"], settings["h"] = map(int, args.size.split("x"))
        for key in ("sym", "style", "landmark", "supply"):
            if getattr(args, key) is not None:
                settings[key] = getattr(args, key)
        if args.border:
            settings["closed"] = args.border == "closed"
        if args.dragons:
            settings["per_side"] = max(1, min(7, args.dragons))
        args.output.mkdir(parents=True, exist_ok=True)
        for number in range(1, args.count + 1):
            # A world seed with no candidate inside the envelope moves to the next.
            for attempt in range(20):
                try:
                    world = generate(
                        (args.seed * 100 + number) * 20 + attempt,
                        envelope,
                        args.candidates,
                        **settings,
                    )
                    break
                except RuntimeError:
                    continue
            else:
                raise SystemExit(f"no map inside the envelope for number {number}")
            path = args.output / f"gen_{args.seed}_{number:02d}.map"
            path.write_text(world.text())
            print(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path)
            print(world.summary())
        return 0


    raise SystemExit(main())

# Build a bot once with the organiser's compilers, into the toolkit's own caches.
[group("Build")]
bot-build source mode="judge":
    #!/usr/bin/env -S {{quote(python)}}
    import sys
    from pathlib import Path

    from harness import toolkit


    def main() -> None:
        sandbox = toolkit.sandbox_module()
        from unswbc import clangtool
        from unswbc.project import Project

        source, mode = Path(sys.argv[1]).resolve(), sys.argv[2]
        if mode not in ("judge", "native"):
            raise SystemExit("Mode must be judge or native")
        if mode == "native" or (source / "main.py").is_file():
            # Local games and Python bots run the organiser's project build.
            print(Project.from_dir(source).compile())
        else:
            wasm = clangtool.build(source)
            sandbox.compile_once(sandbox._metered(wasm))
            print(wasm)


    main()

# Experimental Zig engine host; the organiser's toolkit remains the default.
[group("Build")]
zig-judge-build:
    zig build --build-file ../../harness/zig_judge/build.zig --cache-dir "$PWD/../../build/zig-cache" --global-cache-dir "$PWD/../../build/zig-global-cache" --prefix "$PWD/../../build/zig-judge" -Doptimize=ReleaseFast

[group("Evaluation")]
zig-judge +args:
    ../../build/zig-judge/bin/loong-judge {{args}}
