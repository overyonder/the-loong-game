"""Run a resumable, frozen offline ladder under the judge's resource limits."""

import csv
import hashlib
import itertools
import json
import shutil
import time
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from harness import toolkit
from harness.parallel import match_verbosity, prepare_bots
from harness.rating import fit_ratings, head_to_head
from harness.tournament import discover_bots, read_outcome, run_game


def pairing_rounds(names: list[str], rounds: int) -> list[list[tuple[str, str]]]:
    """Circle schedule: n-1 rounds meet everyone; next cycle reverses sides."""
    if len(names) < 2 or len(set(names)) != len(names):
        raise ValueError("Require at least two distinct bots")
    rotation = list(names) + ([None] if len(names) % 2 else [])
    size = len(rotation)
    cycle = []
    for index in range(size - 1):
        pairs = list(
            zip(
                rotation[: size // 2],
                reversed(rotation[size // 2 :]),
                strict=True,
            )
        )
        pairs = [(a, b) for a, b in pairs if a is not None and b is not None]
        if index % 2:
            pairs = [(right, left) for left, right in pairs]
        cycle.append(pairs)
        rotation = [rotation[0], rotation[-1], *rotation[1:-1]]
    return [
        [(right, left) for left, right in cycle[index % len(cycle)]]
        if (index // len(cycle)) % 2
        else cycle[index % len(cycle)]
        for index in range(rounds)
    ]


def history(bots: list[str], games: list) -> list[dict]:
    """The fit to all games up to the end of each played round."""
    snapshots = [{"round": 0, "ratings": dict.fromkeys(bots, 1500.0)}]
    for number in sorted({game["round"] for game in games}):
        played = [game for game in games if game["round"] <= number]
        ratings = fit_ratings(bots, played, snapshots[-1]["ratings"])
        snapshots.append({"round": number, "ratings": ratings})
    return snapshots


def save(directory: Path, report: dict) -> None:
    ratings = report["history"][-1]["ratings"]
    report["ratings"] = ratings
    # Atomic replacement leaves the preceding complete round resumable on interruption.
    temporary = directory / "results.json.tmp"
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(directory / "results.json")
    with (directory / "ratings.csv").open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(["round", *report["bots"]])
        for snapshot in report["history"]:
            writer.writerow(
                [
                    snapshot["round"],
                    *(snapshot["ratings"][name] for name in report["bots"]),
                ]
            )
    last = report["history"][-21:]
    earlier = last[0]["ratings"]
    lines = [
        "# Offline ladder",
        "",
        f"State: {report['status']}. "
        f"{len(report['history']) - 1}/{report['rounds']} rounds; "
        f"{len(report['games'])} games.",
        "Bradley–Terry ratings fitted to every game so far, on the Elo scale "
        "(400 points is ten-to-one odds; the pool averages 1500). "
        "A draw is half a win each way; failed executions are unscored.",
        "",
        "| Bot | Rating | W–D–L | Errors | Last 20 rounds Δ | Last 20 range |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name in sorted(ratings, key=lambda name: -ratings[name]):
        wins = draws = losses = errors = 0
        for game in report["games"]:
            if name not in (game["A"], game["B"]):
                continue
            if game["status"] != "completed":
                errors += 1
            elif game["winner_side"] is None:
                draws += 1
            elif game[game["winner_side"]] == name:
                wins += 1
            else:
                losses += 1
        values = [snapshot["ratings"][name] for snapshot in last]
        lines.append(
            f"| {name} | {ratings[name]:.1f} | {wins}–{draws}–{losses} | "
            f"{errors} | {ratings[name] - earlier[name]:+.1f} | "
            f"{min(values):.1f}–{max(values):.1f} |"
        )
    # One rating per bot hides a circle (A beats B beats C beats A); the table
    # shows it as a lower-rated row with more than half the points.
    ranked = sorted(ratings, key=lambda name: -ratings[name])
    scores = head_to_head(ranked, report["games"])
    lines += [
        "",
        "Points each row bot scored against each column bot, of the rated games "
        "between them (a draw is half a point):",
        "",
        "| Bot | " + " | ".join(ranked) + " |",
        "| --- |" + " ---: |" * len(ranked),
    ]
    for name in ranked:
        cells = [
            f"{scores[name, other]:g}/{scores[name, other] + scores[other, name]:g}"
            if other != name
            else "·"
            for other in ranked
        ]
        lines.append(f"| {name} | " + " | ".join(cells) + " |")
    lines += [
        "",
        "Each round has at most one game per bot (one rotating bye for odd pools). "
        "Pairings rotate, sides reverse every "
        "opponent cycle, and maps rotate after both sides have been played. "
        "Each game's seed comes from its map and round, "
        "so reruns replay the same games.",
        "",
        "These ratings describe this fixed pool and map schedule; "
        "they are not official competition Elo.",
        "",
        "[Rating history](ratings.csv) · [Full results](results.json)",
        "",
    ]
    (directory / "summary.md").write_text("\n".join(lines))


def play_game(directory: Path, job: dict, timeout: float) -> dict:
    stem = (
        f"r{job['round']:03d}-{job['A'].replace('/', '-')}-vs-"
        f"{job['B'].replace('/', '-')}"
    )
    log = directory / "games" / f"{stem}.log"
    replay = log.with_suffix(".replay")
    # The seed depends only on the map and round, never on the bots, so renaming or
    # refreezing a bot doesn't change which games it plays.
    seed = zlib.crc32(f"{job['map']}:{job['round']}".encode())
    command = [
        *toolkit.toolkit_match_command(),
        "run",
        "--sandbox",
        *match_verbosity(),
        "-o",
        str(replay),
        "--seed",
        str(seed),
        str(directory / "maps" / job["map"]),
        # The toolkit names each team by its argument, so pass the bot directory.
        str(directory / "bots" / job["A"]),
        str(directory / "bots" / job["B"]),
    ]
    started = time.monotonic()
    code, expired = run_game(command, log, timeout)
    outcome = read_outcome(log, code, expired)
    if outcome["status"] == "completed" and not replay.is_file():
        outcome.update(status="error", error="Replay missing")
    return {
        **job,
        "seed": seed,
        **outcome,
        "seconds": time.monotonic() - started,
        "log": str(log.relative_to(directory)),
        "replay": str(replay.relative_to(directory)),
    }


def run(
    directory: Path,
    names: list[str],
    maps: list[Path],
    rounds: int,
    workers: int,
    resume: bool,
) -> None:
    directory = directory.resolve()
    if resume:
        report = json.loads((directory / "results.json").read_text())
    else:
        schedule = pairing_rounds(names, rounds)
        discover_bots(names)
        if any(Path(name).is_absolute() or ".." in Path(name).parts for name in names):
            raise ValueError("Name bots by directories below the working directory")
        directory.mkdir(parents=True, exist_ok=False)
        (directory / "games").mkdir()
        (directory / "maps").mkdir()
        hashes = {}
        for name in names:
            shutil.copytree(
                name,
                directory / "bots" / name,
                ignore=shutil.ignore_patterns("__pycache__", ".unswbc-build"),
            )
        for path in maps:
            shutil.copyfile(path, directory / "maps" / path.name)
        for path in sorted((directory / "bots").rglob("*")) + sorted(
            (directory / "maps").iterdir()
        ):
            if path.is_file():
                hashes[str(path.relative_to(directory))] = hashlib.sha256(
                    path.read_bytes()
                ).hexdigest()
        report = {
            "bots": names,
            "maps": [str(path) for path in maps],
            "rounds": rounds,
            "games": [],
            "status": "running",
            "source_hashes": hashes,
            "history": history(names, []),
            "schedule": [
                [
                    {
                        "round": index + 1,
                        "A": a,
                        "B": b,
                        "map": maps[
                            (index // (2 * (len(names) - 1 + len(names) % 2)))
                            % len(maps)
                        ].name,
                    }
                    for a, b in pairs
                ]
                for index, pairs in enumerate(schedule)
            ],
        }
        save(directory, report)
    # The sources and map files used for resume must still match their frozen manifest.
    for relative, expected in report["source_hashes"].items():
        if hashlib.sha256((directory / relative).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Frozen ladder input changed: {relative}")
    report["status"] = "running"
    remaining = report["schedule"][len(report["history"]) - 1 :]
    prepare_bots([directory / "bots" / name for name in report["bots"]], workers)
    report["workers"] = workers
    with ThreadPoolExecutor(max_workers=workers) as executor:
        ordered = executor.map(
            lambda job: play_game(directory, job, 600),
            itertools.chain.from_iterable(remaining),
        )
        for jobs in remaining:
            results = list(itertools.islice(ordered, len(jobs)))
            report["games"].extend(results)
            ratings = fit_ratings(
                report["bots"], report["games"], report["history"][-1]["ratings"]
            )
            report["history"].append({"round": jobs[0]["round"], "ratings": ratings})
            save(directory, report)
            errors = sum(game["status"] != "completed" for game in results)
            leader = max(ratings, key=ratings.get)
            print(
                f"Round {jobs[0]['round']}/{report['rounds']}: "
                f"{leader} {ratings[leader]:.0f}; "
                f"errors={errors}",
                flush=True,
            )
    report["status"] = (
        "completed_with_errors"
        if any(g["status"] != "completed" for g in report["games"])
        else "completed"
    )
    save(directory, report)
    print((directory / "summary.md").read_text())
