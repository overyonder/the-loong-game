"""Play sequential runs for one candidate or several at once.

`play_sequential` plays each candidate's interleaved schedule (harness/compare.py)
in one pool of local sandboxed games and stops starting a candidate's games once
its tests have decided. At most `--in-flight` games play at once, so a run stops
close to where its tests decide. Each candidate's plan and games land in
`OUTPUT/<candidate>/results.json`, every game with its schedule position; a
rerun keeps the completed games and carries on. `batch` prints each candidate's
`verdict` command; judging is its own stage.

    just batch --bots tactics-bot --baseline roles-bot --output results/tactics
"""

import json
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from itertools import zip_longest
from pathlib import Path

from harness.compare import plan, schedule, teams, wanted
from harness.parallel import prepare_bots
from harness.tournament import forget_game, play_game

IN_FLIGHT = 16


def result_directory(output: Path, candidate: str) -> Path:
    """A candidate's results in OUTPUT, by its directory's name."""
    return output / Path(candidate).name


def play_sequential(candidates: list[str], args, output: Path) -> None:
    """Play every candidate's schedule until its tests decide.

    `args` carries `plan_arguments`, `--engine`, `--in-flight`, `--timeout` and
    `--workers`.
    A results set whose recorded plan differs from this one is refused rather
    than mixed.
    """
    plans = {candidate: plan(args, candidate) for candidate in candidates}
    bots = set(candidates)
    for run in plans.values():
        bots |= {*run["opponents"], run["upset_bot"]}
        if run["baseline"]:
            bots.add(run["baseline"])
    prepare_bots([Path(name) for name in sorted(bots)], args.workers)
    games, where, played, reports = [], [], {}, {}
    for candidate, run in plans.items():
        directory = result_directory(output, candidate)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "results.json"
        previous = json.loads(path.read_text()) if path.is_file() else {}
        if previous.get("plan", run) != run:
            raise SystemExit(f"{path} holds another plan; use a new --output")
        played[candidate] = {
            game["position"]: game
            for game in previous.get("games", [])
            if game["status"] == "completed"
        }
        reports[candidate] = {
            "status": "running",
            "plan": run,
            "games": list(played[candidate].values()),
        }
        for position, entry in enumerate(schedule(run)):
            a, b = teams(entry)
            stem = (
                f"{position:04d}-{Path(a).name}-vs-{Path(b).name}-{entry['map'].stem}"
            )
            if position not in played[candidate]:
                forget_game(directory, f"{stem}.log")
            games.append((directory, stem, entry["map"], entry["seed"], a, b))
            where.append((candidate, position))
    index_of = {key: index for index, key in enumerate(where)}

    def choose(landed: dict, running: set) -> list[int]:
        # Each candidate's wanted games, taken in turn so none waits for another.
        queues = []
        for candidate, run in plans.items():
            done = dict(played[candidate])
            done |= {
                where[i][1]: record
                for i, record in landed.items()
                if where[i][0] == candidate
            }
            flying = {where[i][1] for i in running if where[i][0] == candidate}
            queues.append([index_of[candidate, p] for p in wanted(run, done, flying)])
        return [i for turn in zip_longest(*queues) for i in turn if i is not None]

    def land(index: int, record: dict) -> None:
        candidate, position = where[index]
        if record["status"] == "completed":
            played[candidate][position] = {**record, "position": position}
        report = reports[candidate]
        report["games"] = [g for g in report["games"] if g["position"] != position]
        report["games"].append({**record, "position": position})
        (result_directory(output, candidate) / "results.json").write_text(
            json.dumps(report, indent=2) + "\n"
        )

    for candidate, run in plans.items():
        measure = (
            f"matched against {run['baseline']} over at most {2 * run['cap']} "
            "fixtures each"
            if run["baseline"]
            else f"at most {run['cap']} games against each"
        )
        print(
            f"{candidate}: {measure} of {', '.join(run['opponents'])}, and "
            f"{run['upset_games']} against {run['upset_bot']}, "
            f"{args.in_flight} at a time",
            flush=True,
        )

    def play(index: int) -> dict:
        directory, stem, map_path, seed, a, b = games[index]
        return play_game(
            directory,
            stem,
            map_path,
            seed,
            a,
            b,
            timeout=args.timeout,
            sandbox=True,
            engine=args.engine,
        )

    landed = {}
    limit = max(1, min(args.workers, args.in_flight))
    with ThreadPoolExecutor(max_workers=limit) as executor:
        running = {}
        while True:
            flying = set(running.values())
            # A game is tried once a run; an error ends the prefix, and a rerun
            # plays it again.
            fresh = [
                i for i in choose(landed, flying) if i not in flying and i not in landed
            ]
            for index in fresh[: limit - len(running)]:
                running[executor.submit(play, index)] = index
            if not running:
                break
            finished, _ = wait(running, return_when=FIRST_COMPLETED)
            for future in finished:
                index = running.pop(future)
                landed[index] = future.result()
                land(index, landed[index])
                candidate = where[index][0]
                record = landed[index]
                print(
                    f"{candidate}: {record['A']} vs {record['B']} on "
                    f"{Path(record['map']).name}: {record['status']}",
                    flush=True,
                )
    for candidate, report in reports.items():
        still = choose(landed, set())
        # Incomplete: an error left games the tests still want.
        report["status"] = (
            "incomplete"
            if any(where[i][0] == candidate for i in still)
            else "completed"
        )
        (result_directory(output, candidate) / "results.json").write_text(
            json.dumps(report, indent=2) + "\n"
        )
