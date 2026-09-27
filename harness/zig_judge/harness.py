"""Run games through loong-judge from the Python harness.

The judge plays the official engine (unswbc_engine.wasm) against metered bot modules
and prints one line of figures per game. This module meters bots with the toolkit's
own pass, writes a jobs file, runs a batch on N threads and parses the figures into
the outcome dictionaries the harness already uses.

    from harness.zig_judge.harness import play_batch
    outcomes = play_batch(jobs, threads=8)

Each job is (map path, bot A directory or .wasm, bot B directory or .wasm, seed,
replay path or None). A C or C++ bot directory is compiled with the judge's clang,
as `unswbc run --sandbox` compiles it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JUDGE = Path(os.environ.get("LOONG_JUDGE", ROOT / "build/zig-judge/bin/loong-judge"))


def toolkit_packages() -> Path:
    """site-packages of the Python that `uv tool install` gave the `unswbc` launcher."""
    if "LOONG_TOOLKIT" in os.environ:
        return Path(os.environ["LOONG_TOOLKIT"])
    launcher = shutil.which("unswbc")
    if launcher is None:
        raise FileNotFoundError(
            "unswbc is not on PATH: install the organiser's toolkit"
        )
    shebang = Path(launcher).read_bytes().split(b"\n", 1)[0]
    interpreter = Path(shebang.removeprefix(b"#!").decode().strip())
    return next(interpreter.parent.parent.glob("lib/python*/site-packages"))


TOOLKIT = toolkit_packages()
ENGINE = Path(
    os.environ.get("LOONG_JUDGE_ENGINE", TOOLKIT / "unswbc/unswbc_engine.wasm")
)

END_REASONS = {0: "by elimination", 1: "on length"}
DRAW_REASONS = {0: "both teams eliminated", 1: "equal length"}
DEATH_CODES = "WSOHA"


def metered(bot: str | Path) -> Path:
    """Meter a bot with the toolkit, using the toolkit's own build cache."""
    if str(TOOLKIT) not in sys.path:
        sys.path.insert(0, str(TOOLKIT))
    from unswbc import clangtool
    from unswbc.sandbox import _metered  # the toolkit's cache of instrumented modules

    path = Path(bot)
    wasm = path if path.suffix == ".wasm" else clangtool.build(path)
    if not wasm.is_file():
        raise FileNotFoundError(f"{bot}: no compiled module")
    return _metered(wasm)


def _split(field: str) -> list[int]:
    return [int(x) for x in field.split(",")] if field else []


def parse_line(line: str) -> dict:
    """One batch line into an outcome: winner_side, rounds, reason, and the figures."""
    fields = line.rstrip("\n").split("\t")
    job_id = fields[0]
    if fields[1] == "error":
        return {
            "id": job_id,
            "status": "error",
            "error": fields[2],
            "winner_side": None,
            "rounds": None,
            "reason": None,
        }
    winner = None if fields[1] == "-" else fields[1]
    code = int(fields[3])
    reason = (DRAW_REASONS if winner is None else END_REASONS).get(code, "over")
    a_p50, a_mean, a_max = (int(x) for x in fields[13].split("/"))
    b_p50, b_mean, b_max = (int(x) for x in fields[15].split("/"))
    return {
        "id": job_id,
        "status": "completed",
        "error": None,
        "winner_side": winner,
        "rounds": int(fields[2]),
        "reason": reason,
        "dragons": (int(fields[4]), int(fields[5])),
        "length": (int(fields[6]), int(fields[7])),
        "deaths": (
            dict(zip(DEATH_CODES, _split(fields[8]), strict=True)),
            dict(zip(DEATH_CODES, _split(fields[9]), strict=True)),
        ),
        "bot_failures": (int(fields[10]), int(fields[11])),
        "turns": (int(fields[12]), int(fields[14])),
        "points": (
            {"p50": a_p50, "mean": a_mean, "max": a_max},
            {"p50": b_p50, "mean": b_mean, "max": b_max},
        ),
        "wall_ms": int(fields[16]),
    }


def play_batch(
    jobs: list[tuple],
    threads: int = os.cpu_count() or 1,
    names: dict[str, str] | None = None,
    judge: Path = JUDGE,
    engine: Path = ENGINE,
) -> list[dict]:
    """Play each (map, bot_a, bot_b, seed, replay) job; return outcomes in order.

    `names` maps a bot path to the team name written into replays; the default is the
    bot path itself, as `unswbc run` names them.
    """
    modules = {bot: metered(bot) for job in jobs for bot in job[1:3]}
    with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as handle:
        for index, (map_path, bot_a, bot_b, seed, replay) in enumerate(jobs):
            name_a = (names or {}).get(bot_a, str(bot_a))
            name_b = (names or {}).get(bot_b, str(bot_b))
            handle.write(
                f"{index}\t{map_path}\t{modules[bot_a]}\t{modules[bot_b]}\t"
                f"{seed}\t{replay or ''}\t{name_a}\t{name_b}\n"
            )
        jobs_path = handle.name
    try:
        completed = subprocess.run(
            [
                str(judge),
                "--engine",
                str(engine),
                "--jobs",
                jobs_path,
                "--threads",
                str(threads),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    finally:
        os.unlink(jobs_path)
    outcomes = {
        int(o["id"]): o
        for o in (
            parse_line(line) for line in completed.stdout.splitlines() if line.strip()
        )
    }
    return [outcomes[i] for i in range(len(jobs))]
