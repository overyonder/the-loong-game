"""The judge fidelity check, `just judge-fidelity`: whether the Zig judge records
games exactly as the organiser's toolkit does. Run it after building the judge
and after changing toolkit, since the judge plays the toolkit's own engine.

It meters every bot's module with the toolkit's pass and the judge's and compares
the two byte for byte. It then plays each seeded game twice, once through the
toolkit and once in the judge, and compares the replays byte for byte and every
log line apart from progress timings, elapsed times and where the replay was
written. Both runs name each team by its bot directory, as the toolkit does.

Inputs: bot directories (built with `just bot-build`), maps and seeds per map.
Output: OUTPUT/toolkit and OUTPUT/judge, each game's log, replay and result
record, and OUTPUT/report.json. It prints what matched and exits 1 on any
difference.
"""

import itertools
import json
import re
import subprocess
import tempfile
import zlib
from pathlib import Path

from harness import toolkit
from harness.tournament import forget_game, play_game, toolkit_version
from harness.zig_judge import harness as judge

ENGINES = ("toolkit", "judge")
# Log lines that differ between two plays of one game: progress timings and
# where the replay was written. A result line's elapsed time is cut off.
VOLATILE = ("running round ", "wrote replay: ")
ELAPSED = re.compile(r" \(\d+(?:\.\d+)?s\)$| \(\d+m\d\ds\)$")


def check_metering(bots: list[str]) -> dict:
    """Each bot's module metered by the toolkit and by the judge."""
    toolkit.sandbox_module()  # puts the toolkit's packages on sys.path
    from unswbc import metering

    mismatches = []
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary) / "metered.wasm"
        for bot in bots:
            module = judge.compiled(bot)
            subprocess.run(
                [
                    str(judge.check_judge()),
                    "--meter",
                    str(module),
                    "--output",
                    str(output),
                ],
                check=True,
            )
            if output.read_bytes() != metering.instrument(module.read_bytes()):
                mismatches.append(bot)
    return {"modules": len(bots), "mismatches": mismatches}


def schedule(bots: list[str], maps: list[Path], seeds: int) -> list[tuple]:
    """(map, bot A, bot B, seed) for every ordered pair, seeded as round robins are."""
    return [
        (path, a, b, zlib.crc32(f"{path.name}:{i}".encode()))
        for path in maps
        for i in range(seeds)
        for a, b in itertools.permutations(bots, 2)
    ]


def log_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [
        ELAPSED.sub("", line)
        for line in path.read_text(errors="replace").splitlines()
        if not line.startswith(VOLATILE)
    ]


def check_games(games: list[tuple], output: Path, timeout: float) -> dict:
    """Play every game in both engines and compare each pair."""
    pairs = []
    for index, (map_path, a, b, seed) in enumerate(games, 1):
        stem = f"{index:03d}-{Path(a).name}-vs-{Path(b).name}-{map_path.stem}-{seed}"
        records = {}
        for engine in ENGINES:
            directory = output / engine
            directory.mkdir(parents=True, exist_ok=True)
            forget_game(directory, f"{stem}.log")
            records[engine] = play_game(
                directory,
                stem,
                map_path,
                seed,
                a,
                b,
                timeout=timeout,
                sandbox=True,
                engine=engine,
            )
        replays = [output / engine / f"{stem}.replay" for engine in ENGINES]
        logs = [log_lines(output / engine / f"{stem}.log") for engine in ENGINES]
        differences = []
        if any(not path.is_file() for path in replays) or (
            replays[0].read_bytes() != replays[1].read_bytes()
        ):
            differences.append("replay")
        if not logs[0] or logs[0] != logs[1]:
            differences.append("log")
        if any(records[engine]["status"] != "completed" for engine in ENGINES):
            differences.append("status")
        pairs.append(
            {
                "stem": stem,
                "map": map_path.name,
                "a": a,
                "b": b,
                "seed": seed,
                "rounds": records["judge"]["rounds"],
                "differences": differences,
            }
        )
        print(f"{stem}: {', '.join(differences) or 'identical'}", flush=True)
    return {
        "games": pairs,
        "mismatches": [pair["stem"] for pair in pairs if pair["differences"]],
    }


def run(
    bots: list[str], maps: list[Path], seeds: int, output: Path, timeout: float
) -> int:
    output.mkdir(parents=True, exist_ok=True)
    metering = check_metering(bots)
    games = check_games(schedule(bots, maps, seeds), output, timeout)
    report = {
        "toolkit": toolkit_version(),
        "metering": metering,
        "games": games["games"],
        "mismatches": games["mismatches"],
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"metering: {metering['modules'] - len(metering['mismatches'])} of "
        f"{metering['modules']} modules identical; games: "
        f"{len(games['games']) - len(games['mismatches'])} of {len(games['games'])} "
        f"identical under toolkit {report['toolkit']}"
    )
    return int(bool(metering["mismatches"] or games["mismatches"]))
