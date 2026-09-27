"""Shared CPU scheduling and one-time bot preparation.

Workers run independent official compiled engine / WASM matches. Python only
orchestrates jobs; it never simulates turns. One global match executor avoids
nested candidate-by-match pools and caps total runnable games.
"""

import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def cpu_workers() -> int:
    return max(1, os.process_cpu_count() or 1)


def prepare_bots(
    paths: list[Path],
    workers: int,
    deadline: float | None = None,
    *,
    sandbox: bool = True,
) -> None:
    # The toolkit's source/build caches are not safe for concurrent first use
    # of the same bot. Build each unique directory before scheduling matches, so
    # every game finds the toolkit's cached build and names teams by directory.

    def build(path):
        remaining = None if deadline is None else deadline - time.monotonic()
        if remaining is not None and remaining <= 0:
            raise TimeoutError("Build deadline exhausted")
        result = subprocess.run(
            [
                "just",
                "bot-build",
                str(path),
                "judge" if sandbox else "native",
            ],
            capture_output=True,
            text=True,
            timeout=remaining,
            env={**os.environ, "NO_COLOR": "1"},
        )
        if result.returncode:
            raise RuntimeError(
                f"Build failed for {path}: {result.stdout}{result.stderr}"
            )

    with ThreadPoolExecutor(max_workers=workers) as executor:
        try:
            list(executor.map(build, sorted(set(path.resolve() for path in paths))))
        except subprocess.TimeoutExpired as error:
            raise TimeoutError("Build deadline exhausted") from error


def match_verbosity() -> list[str]:
    # The toolkit reports outcomes, deaths, execution errors and aggregate CPU
    # metrics without -v. Avoid per-turn stdout dumps during bulk self-play.
    return ["-v"] if os.environ.get("LOONG_VERBOSE_MATCHES") == "1" else []
