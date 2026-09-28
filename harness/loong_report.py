"""The compiled `loong-report` (`just tools-build`), called from the Python
runners: summaries and the rating fit."""

import json
import subprocess
from pathlib import Path

BINARY = Path(__file__).resolve().parents[1] / "build/bin/loong-report"


def binary() -> str:
    if not BINARY.is_file():
        raise SystemExit(f"{BINARY} is missing: run just tools-build")
    return str(BINARY)


def summary(
    paths: list[Path],
    output: Path,
    *,
    title: str,
    context: str = "",
    candidates: list[str] = (),
) -> str:
    """Render `output/summary.md` for result directories, keeping its insights;
    a set no game has landed in yet renders empty."""
    command = [binary(), "summary", *map(str, paths), f"--output={output}"]
    command += [f"--title={title}", f"--context={context}", "--allow-empty"]
    if candidates:
        command.append(f"--candidates={','.join(candidates)}")
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def fit_ratings(
    bots: list[str], games: list[dict], start: dict[str, float] | None = None
) -> dict[str, float]:
    """Bradley–Terry ratings on the Elo scale, pool mean 1500; errored games
    are left out."""
    request = {
        "bots": bots,
        "games": [
            {k: game.get(k) for k in ("A", "B", "winner_side", "status")}
            for game in games
        ],
        "start": start or {},
    }
    done = subprocess.run(
        [binary(), "ratings"],
        input=json.dumps(request),
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(done.stdout)
