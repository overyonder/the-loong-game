"""Run games through loong-judge from the Python harness.

The judge plays the official engine (unswbc_engine.wasm) against bot modules it
meters itself with a port of the toolkit's metering pass (src/metering.zig).
`match_command()` replaces `unswbc` in a sandboxed match command: it takes the
arguments `unswbc run --sandbox` takes and writes the same log lines and replay,
with each dragon turn's judge points beside the replay (src/run.zig). `play_batch`
writes a jobs file, runs a batch on N threads and parses the figures into the
outcome dictionaries the harness already uses.

    from harness.zig_judge.harness import play_batch
    outcomes = play_batch(jobs, threads=8)

Each job is (map path, bot A directory or .wasm, bot B directory or .wasm, seed,
replay path or None). A C or C++ bot directory is compiled with the judge's clang,
as `unswbc run --sandbox` compiles it. The judge plays compiled modules only, so
Python bots play through the toolkit.
"""

from __future__ import annotations

import math
import os
import subprocess
import tempfile
from functools import cache
from pathlib import Path

from harness import toolkit

ROOT = Path(__file__).resolve().parents[2]
JUDGE = Path(os.environ.get("LOONG_JUDGE", ROOT / "build/zig-judge/bin/loong-judge"))
# The exit code of a game the judge's `--timeout` ended (src/main.zig).
TIMED_OUT = 124

END_REASONS = {0: "by elimination", 1: "on length"}
DRAW_REASONS = {0: "both teams eliminated", 1: "equal length"}
DEATH_CODES = "WSOHA"


@cache
def engine() -> Path:
    """The organiser's engine the judge plays: the toolkit's own copy, so a new
    toolkit brings its engine. Run `just judge-fidelity` after changing toolkit."""
    found = sorted(
        toolkit.toolkit_interpreter().parent.parent.glob(
            "lib/python*/site-packages/unswbc/unswbc_engine.wasm"
        )
    )
    if not found:
        raise FileNotFoundError("the toolkit has no unswbc_engine.wasm")
    return found[-1]


def compiled(bot: str | Path) -> Path:
    """A bot's module: a .wasm as given, or a C or C++ directory built with the
    judge's clang into the toolkit's cache, as `unswbc run --sandbox` builds it."""
    path = Path(bot)
    if path.suffix == ".wasm":
        return path
    toolkit.sandbox_module()  # puts the toolkit's packages on sys.path
    from unswbc import clangtool

    return clangtool.build(path)


def check_judge(judge: Path = JUDGE) -> Path:
    """`judge`, refused when missing or older than the sources it is built from."""
    if not judge.is_file():
        raise FileNotFoundError(f"{judge} is missing: run just zig-judge-build")
    sources = Path(__file__).parent
    built = judge.stat().st_mtime
    if any(
        source.stat().st_mtime > built
        for source in (
            sources / "build.zig",
            *sources.glob("src/*.zig"),
            *sources.glob("reference/*.h"),
            *sources.glob("reference/*.cc"),
        )
    ):
        raise RuntimeError(
            f"{judge} is older than its sources: run just zig-judge-build"
        )
    return judge


def match_command() -> list[str]:
    """Replaces `unswbc` in a sandboxed match command: `match_command() + ["run",
    "--sandbox", ...]` plays the game in the judge."""
    return [str(check_judge()), "--engine", str(engine())]


def play(command: list[str], log: Path, timeout: float) -> tuple[int, bool]:
    """Play a `match_command()` game with its output in `log`, ended at `timeout`
    wall seconds: its exit code and whether the limit ended it. The judge ends
    itself; one still running a minute later is killed."""
    at = command.index("run")
    limit = ["--log", str(log), "--timeout", str(math.ceil(timeout))]
    log.parent.mkdir(parents=True, exist_ok=True)
    try:
        code = subprocess.run(
            [*command[:at], *limit, *command[at:]],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout + 60,
        ).returncode
    except subprocess.TimeoutExpired:
        return -9, True
    return code, code == TIMED_OUT


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
    engine_path: Path | None = None,
) -> list[dict]:
    """Play each (map, bot_a, bot_b, seed, replay) job; return outcomes in order.

    `names` maps a bot path to the team name written into replays; the default is the
    bot path itself, as `unswbc run` names them.
    """
    modules = {bot: compiled(bot) for job in jobs for bot in job[1:3]}
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
                str(engine_path or engine()),
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
