# Run the pinned Battlecode CLI and retain each game's evidence.
[group("Evaluation")]
round-robin *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    import itertools
    import zlib
    from concurrent.futures import ThreadPoolExecutor
    from datetime import UTC, datetime
    from pathlib import Path

    from harness.parallel import cpu_workers, prepare_bots
    from harness.tournament import (
        __doc__,
        discover_bots,
        forget_game,
        game_id,
        play_game,
        reusable_games,
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
        parser.add_argument(
            "--engine",
            choices=["judge", "toolkit"],
            default="judge",
            help="Play sandboxed games between compiled bots in the Zig judge (default) "
            "or all through the toolkit; Python bots always play through the toolkit",
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
            "engine": args.engine,
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
            forget_game(directory, f"{stem}.log")
            return play_game(
                directory,
                stem,
                map_path,
                seed,
                team_a,
                team_b,
                timeout=args.timeout,
                sandbox=args.sandbox,
                engine=args.engine,
            )

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

# Play sequential runs for candidates until their tests decide.
[group("Evaluation")]
batch *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    from pathlib import Path

    from harness.batch import IN_FLIGHT, __doc__, play_sequential
    from harness.compare import plan_arguments
    from harness.parallel import cpu_workers


    def main() -> int:
        parser = argparse.ArgumentParser(
            prog="batch",
            description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter,
        )
        parser.add_argument("--bots", nargs="+", required=True, help="Candidate bots")
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--timeout", type=float, default=600)
        parser.add_argument("--workers", type=int, default=cpu_workers())
        parser.add_argument(
            "--in-flight",
            type=int,
            default=IN_FLIGHT,
            help=f"Games playing at once (default {IN_FLIGHT}); a sequential run "
            "stops soon after its tests decide",
        )
        plan_arguments(parser)
        parser.add_argument(
            "--engine",
            choices=["judge", "toolkit"],
            default="judge",
            help="Play sandboxed games between compiled bots in the Zig judge (default) "
            "or all through the toolkit; Python bots always play through the toolkit",
        )
        args = parser.parse_args()
        if not (args.maps or any(Path("maps").glob("*.map"))):
            parser.error("No maps found; run just article-bots first or pass --maps")
        play_sequential(args.bots, args, args.output)
        for candidate in args.bots:
            print(f"just verdict --output {args.output} --candidate {candidate}")
        return 0


    raise SystemExit(main())

# Judge a sequential run: each opponent's test and upset faults.
[group("Evaluation")]
verdict *args:
    ../../build/bin/loong-report verdict "$@"

# Render the standard summary.md for any result directories.
[group("Evaluation")]
report *args:
    ../../build/bin/loong-report summary "$@"

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
        parser.add_argument(
            "--engine",
            choices=["judge", "toolkit"],
            default="judge",
            help="Play games between compiled bots in the Zig judge (default) or all "
            "through the toolkit; Python bots always play through the toolkit",
        )
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
        run(
            args.output,
            args.bots,
            maps,
            args.rounds,
            args.workers,
            args.resume,
            args.engine,
        )


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

# Compile loong-gamedata, loong-report and loong-sample-replays into build/bin.
[group("Build")]
tools-build:
    mkdir -p ../../build/bin
    nim c -d:release --hints:off --nimcache:../../build/nimcache/gamedata -o:../../build/bin/loong-gamedata ../../gamedata/gamedata.nim
    nim c -d:release --hints:off --nimcache:../../build/nimcache/report -o:../../build/bin/loong-report ../../harness/report/report.nim
    nim c -d:release -d:ssl --hints:off --nimcache:../../build/nimcache/sample-replays -o:../../build/bin/loong-sample-replays ../../replays/collection.nim

# Check the Zig judge meters bots and records games exactly as the toolkit does.
[group("Evaluation")]
judge-fidelity *args:
    #!/usr/bin/env -S {{quote(python)}}
    import argparse
    from pathlib import Path

    from harness.zig_judge.fidelity import __doc__, run


    def main() -> int:
        parser = argparse.ArgumentParser(
            prog="judge-fidelity",
            description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter,
        )
        parser.add_argument(
            "--bots", nargs="+", default=["room-c", "starter-c"], help="Bot directories"
        )
        parser.add_argument(
            "--maps",
            nargs="+",
            type=Path,
            default=[Path("maps/arena.map"), Path("maps/portals.map")],
        )
        parser.add_argument("--seeds", type=int, default=1, help="Seeds per map")
        parser.add_argument("--output", type=Path, default=Path("results/judge-fidelity"))
        parser.add_argument("--timeout", type=float, default=600)
        args = parser.parse_args()
        if len(args.bots) < 2 or any(not path.is_file() for path in args.maps):
            parser.error("Name at least two bots and existing maps")
        if any((Path(bot) / "main.py").is_file() for bot in args.bots):
            parser.error("The judge plays compiled bots only")
        return run(args.bots, args.maps, args.seeds, args.output, args.timeout)


    raise SystemExit(main())

# Build the Zig judge the round robin, batch and ladder play in by default.
[group("Build")]
zig-judge-build:
    zig build --build-file ../../harness/zig_judge/build.zig --cache-dir "$PWD/../../build/zig-cache" --global-cache-dir "$PWD/../../build/zig-global-cache" --prefix "$PWD/../../build/zig-judge" -Doptimize=ReleaseFast

[group("Evaluation")]
zig-judge +args:
    ../../build/zig-judge/bin/loong-judge {{args}}
